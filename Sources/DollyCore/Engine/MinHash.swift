//  MinHash.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - Mersenne-prime arithmetic

/// 2^61 − 1: the largest Mersenne prime that fits inside `UInt64`. Used as
/// the MinHash modulus because reduction modulo it collapses to a couple
/// of shifts and masks, with no 64-bit hardware divide.
func mersenne61Reduce(_ value: UInt64) -> UInt64 {
  // `(r & M) + (r >> 61)` reduces values < 2^122 to < 2 * M; one more
  // fold caps the result at < M. Coefficients are kept < 2^61, so the
  // (a * x + b) product fits in 2 * 2^61 before this reduction.
  let mask: UInt64 = (1 &<< 61) &- 1
  let result = (value & mask) &+ (value &>> 61)
  return result >= mask ? result &- mask : result
}

/// SplitMix64 — the standard high-quality 64-bit PRNG for seeding other
/// algorithms.
func splitMix64(_ state: inout UInt64) -> UInt64 {
  state &+= 0x9E37_79B9_7F4A_7C15
  var value = state
  value = (value ^ (value &>> 30)) &* 0xBF58_476D_1CE4_E5B9
  value = (value ^ (value &>> 27)) &* 0x94D0_49BB_1331_11EB
  value = value ^ (value &>> 31)
  return value
}

// MARK: - MinHashSignature

/// A MinHash signature representing a document.
struct MinHashSignature: Sendable, Hashable {
  /// The signature values (minimum hashes).
  let values: [UInt64]

  /// Document ID this signature represents.
  let documentId: Int

  init(values: [UInt64], documentId: Int) {
    self.values = values
    self.documentId = documentId
  }

  /// Number of hash functions used.
  var size: Int { values.count }

  /// Estimate Jaccard similarity with another signature.
  ///
  /// - Parameter other: Another MinHash signature.
  /// - Returns: Estimated Jaccard similarity (0.0 to 1.0).
  func estimateSimilarity(with other: Self) -> Double {
    guard values.count == other.values.count, !values.isEmpty else { return 0 }

    var matches = 0
    for (v1, v2) in zip(values, other.values) where v1 == v2 {
      matches += 1
    }

    return Double(matches) / Double(values.count)
  }
}

// MARK: - MinHashGenerator

/// Generates MinHash signatures for documents.
struct MinHashGenerator: Sendable {
  /// Number of hash functions (signature dimension).
  let numHashes: Int

  /// Mersenne prime M_61 = 2^61 − 1. Used as the universal-hashing
  /// modulus because reduction is branch-free shifts and masks, suitable
  /// for SIMD lanes.
  static let mersenne61: UInt64 = (1 &<< 61) &- 1

  /// Pre-computed hash function coefficients (each < 2^61 so that the
  /// product `a * shingle` stays within the Mersenne-reduction window).
  private let coefficientsA: [UInt64]
  private let coefficientsB: [UInt64]

  init(numHashes: Int = 256, seed: UInt64 = 42) {
    self.numHashes = numHashes

    // Generate independent coefficients via SplitMix64. The Mersenne-prime
    // reduction requires `a` and `b` < M_61, so each draw is masked to
    // 61 bits; `a` is forced non-zero so the universal-hash family is
    // injective.
    let mask: UInt64 = (1 &<< 61) &- 1
    var rng = seed
    var a: [UInt64] = []
    var b: [UInt64] = []
    a.reserveCapacity(numHashes)
    b.reserveCapacity(numHashes)

    for _ in 0..<numHashes {
      var coefficientA = splitMix64(&rng) & mask
      if coefficientA == 0 { coefficientA = 1 }
      a.append(coefficientA)
      b.append(splitMix64(&rng) & mask)
    }

    coefficientsA = a
    coefficientsB = b
  }

  /// Compute MinHash signature for a set of shingle hashes.
  ///
  /// - Parameters:
  ///   - shingleHashes: Set of shingle hash values.
  ///   - documentId: ID to associate with the signature.
  /// - Returns: MinHash signature.
  func computeSignature(
    for shingleHashes: Set<UInt64>,
    documentId: Int
  ) -> MinHashSignature {
    guard !shingleHashes.isEmpty else {
      return MinHashSignature(
        values: Array(repeating: UInt64.max, count: numHashes), documentId: documentId)
    }

    // Use SIMD-optimized path for larger signatures
    let signature: [UInt64] =
      if numHashes >= 4 {
        computeSignatureSIMD(for: Array(shingleHashes))
      } else {
        computeSignatureScalar(for: Array(shingleHashes))
      }

    return MinHashSignature(values: signature, documentId: documentId)
  }

  /// Compute MinHash signature from a shingled document.
  func computeSignature(for document: ShingledDocument) -> MinHashSignature {
    computeSignature(for: document.shingleHashes, documentId: document.id)
  }

  /// Batch compute signatures for multiple documents.
  func computeSignatures(for documents: [ShingledDocument]) -> [MinHashSignature] {
    documents.map { computeSignature(for: $0) }
  }

  // MARK: - Private Implementation

  /// Scalar implementation of MinHash computation. Identical bit-for-bit
  /// to the SIMD path; kept for `numHashes < 4` and as a reference for
  /// the equivalence test.
  private func computeSignatureScalar(for hashes: [UInt64]) -> [UInt64] {
    var signature = [UInt64](repeating: UInt64.max, count: numHashes)

    for shingleHash in hashes {
      let x = shingleHash & Self.mersenne61
      for i in 0..<numHashes {
        let h = mersenne61Reduce(coefficientsA[i] &* x &+ coefficientsB[i])
        signature[i] = min(signature[i], h)
      }
    }

    return signature
  }

  /// Vectorised implementation of MinHash computation.
  ///
  /// Processes 4 hash functions at a time using `SIMD4<UInt64>`. The
  /// modulus is the Mersenne prime `M_61 = 2^61 − 1`, so reduction is
  /// `(r & M_61) + (r >> 61)` with one fold for carry — no hardware
  /// divide, fully SIMD-vectorisable across the lane. Uses plain array
  /// indexing (bounds-checked) rather than unsafe buffer pointers so the
  /// implementation stays within strict memory safety.
  private func computeSignatureSIMD(for hashes: [UInt64]) -> [UInt64] {
    var signature = [UInt64](repeating: UInt64.max, count: numHashes)

    let chunks = numHashes / 4
    let mask = SIMD4<UInt64>(repeating: Self.mersenne61)

    for shingleHash in hashes {
      let x = SIMD4<UInt64>(repeating: shingleHash & Self.mersenne61)

      for chunk in 0..<chunks {
        let baseIdx = chunk * 4
        let a = SIMD4<UInt64>(
          coefficientsA[baseIdx],
          coefficientsA[baseIdx + 1],
          coefficientsA[baseIdx + 2],
          coefficientsA[baseIdx + 3]
        )
        let b = SIMD4<UInt64>(
          coefficientsB[baseIdx],
          coefficientsB[baseIdx + 1],
          coefficientsB[baseIdx + 2],
          coefficientsB[baseIdx + 3]
        )

        // (a * x + b) using wrapping arithmetic, then
        // Mersenne-61 reduction folded once.
        var product = a &* x &+ b
        product = (product & mask) &+ (product &>> 61)
        // One more conditional fold for the carry.
        let overflow = SIMD4<UInt64>(
          product[0] >= Self.mersenne61 ? Self.mersenne61 : 0,
          product[1] >= Self.mersenne61 ? Self.mersenne61 : 0,
          product[2] >= Self.mersenne61 ? Self.mersenne61 : 0,
          product[3] >= Self.mersenne61 ? Self.mersenne61 : 0
        )
        product = product &- overflow

        // SIMD min into the running signature.
        let current = SIMD4<UInt64>(
          signature[baseIdx],
          signature[baseIdx + 1],
          signature[baseIdx + 2],
          signature[baseIdx + 3]
        )
        let reduced = pointwiseMin(current, product)
        signature[baseIdx] = reduced[0]
        signature[baseIdx + 1] = reduced[1]
        signature[baseIdx + 2] = reduced[2]
        signature[baseIdx + 3] = reduced[3]
      }

      // Scalar tail for the remainder.
      for i in (chunks * 4)..<numHashes {
        let h = mersenne61Reduce(coefficientsA[i] &* (x[0]) &+ coefficientsB[i])
        signature[i] = min(signature[i], h)
      }
    }

    return signature
  }
}

// MARK: - Jaccard Similarity

extension MinHashGenerator {
  /// Compute exact Jaccard similarity between two sets.
  ///
  /// This is O(n + m) where n, m are set sizes.
  /// Used for verification and small sets where exact computation is feasible.
  static func exactJaccardSimilarity(
    _ set1: Set<UInt64>,
    _ set2: Set<UInt64>
  ) -> Double {
    guard !set1.isEmpty || !set2.isEmpty else { return 0 }

    let intersection = set1.intersection(set2).count
    let union = set1.union(set2).count

    return Double(intersection) / Double(union)
  }

  /// Compute exact Jaccard similarity for shingled documents.
  static func exactJaccardSimilarity(
    _ doc1: ShingledDocument,
    _ doc2: ShingledDocument
  ) -> Double {
    exactJaccardSimilarity(doc1.shingleHashes, doc2.shingleHashes)
  }
}

// MARK: - Batch Processing

extension MinHashGenerator {
  /// Results from batch similarity computation.
  struct SimilarityPair: Sendable {
    let documentId1: Int
    let documentId2: Int
    let similarity: Double

  }

  /// Compute pairwise similarities between all signatures.
  ///
  /// This is O(n²) and should only be used for small sets.
  /// For large sets, use LSH instead.
  ///
  /// - Parameters:
  ///   - signatures: Array of signatures to compare.
  ///   - threshold: Minimum similarity to include in results.
  /// - Returns: Array of similar pairs above threshold.
  func computePairwiseSimilarities(
    _ signatures: [MinHashSignature],
    threshold: Double
  ) -> [SimilarityPair] {
    var results: [SimilarityPair] = []

    for (first, second) in signatures.pairCombinations() {
      let similarity = first.estimateSimilarity(with: second)
      if similarity >= threshold {
        results.append(
          SimilarityPair(
            documentId1: first.documentId,
            documentId2: second.documentId,
            similarity: similarity
          ))
      }
    }

    return results.sorted { $0.similarity > $1.similarity }
  }
}
