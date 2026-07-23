//  LSH.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

import Foundation

// MARK: - LSHQueryable

/// Protocol for LSH indices that can query for similar documents.
protocol LSHQueryable: Sendable {
  /// Query for candidate documents similar to the given signature.
  func query(_ signature: MinHashSignature) -> Set<Int>

  /// Get the signature for a document ID.
  func signature(for documentId: Int) -> MinHashSignature?
}

extension LSHQueryable {
  /// Query and rank results by similarity.
  ///
  /// - Parameters:
  ///   - signature: The query signature.
  ///   - threshold: Minimum similarity to include.
  /// - Returns: Array of (documentId, similarity) pairs, sorted by similarity.
  func queryWithSimilarity(
    _ signature: MinHashSignature,
    threshold: Double = 0.0,
  ) -> [(documentId: Int, similarity: Double)] {
    let candidates = query(signature)

    var results: [(documentId: Int, similarity: Double)] = []
    for docId in candidates {
      guard let candidateSignature = self.signature(for: docId) else { continue }
      let similarity = signature.estimateSimilarity(with: candidateSignature)
      if similarity >= threshold {
        results.append((docId, similarity))
      }
    }

    return results.sorted { $0.similarity > $1.similarity }
  }
}

// MARK: - LSHIndex

/// Locality Sensitive Hashing index for efficient similarity search.
struct LSHIndex: Sendable, LSHQueryable {
  // MARK: Lifecycle

  /// Create an LSH index with given parameters.
  ///
  /// The choice of bands (b) and rows (r) determines the similarity threshold.
  /// For a signature of size n = b * r:
  /// - Higher b, lower r: More sensitive (catches lower similarities)
  /// - Lower b, higher r: More specific (fewer false positives)
  ///
  /// - Parameters:
  ///   - bands: Number of bands to use.
  ///   - rows: Rows per band.
  init(bands: Int, rows: Int) {
    self.bands = bands
    self.rows = rows
    buckets = Array(repeating: [:], count: bands)
    signatures = [:]
  }

  /// Create an LSH index optimized for a target similarity threshold.
  ///
  /// - Parameters:
  ///   - signatureSize: Size of MinHash signatures.
  ///   - threshold: Target Jaccard similarity threshold (0.0 to 1.0).
  init(signatureSize: Int, threshold: Double) {
    let (b, r) = Self.optimalBandsAndRows(signatureSize: signatureSize, threshold: threshold)
    bands = b
    rows = r
    buckets = Array(repeating: [:], count: b)
    signatures = [:]
  }

  // MARK: Public

  /// Number of bands.
  let bands: Int

  /// Rows per band.
  let rows: Int

  /// Compute optimal bands and rows for a given threshold.
  ///
  /// The threshold where probability of becoming candidate is 0.5 is:
  /// t = (1/b)^(1/r)
  ///
  /// - Parameters:
  ///   - signatureSize: Size of MinHash signatures.
  ///   - threshold: Target Jaccard similarity threshold.
  /// - Returns: Tuple of (bands, rows).
  static func optimalBandsAndRows(
    signatureSize: Int,
    threshold: Double,
  ) -> (bands: Int, rows: Int) {
    var bestBands = 1
    var bestRows = signatureSize
    var bestError = Double.infinity

    // Search for b, r such that n = b * r and threshold = (1/b)^(1/r)
    for b in 1...signatureSize {
      let r = signatureSize / b
      guard r > 0, b * r <= signatureSize else { continue }

      // Threshold where P(candidate) = 0.5
      let t = pow(1.0 / Double(b), 1.0 / Double(r))
      let error = abs(t - threshold)

      if error < bestError {
        bestError = error
        bestBands = b
        bestRows = r
      }
    }

    return (bestBands, bestRows)
  }

  /// Index a signature.
  ///
  /// - Parameter signature: The MinHash signature to index.
  mutating func insert(_ signature: MinHashSignature) {
    guard signature.values.count >= bands * rows else { return }

    signatures[signature.documentId] = signature

    // Hash each band
    for band in 0..<bands {
      let bandHash = hashBand(signature: signature, band: band)
      buckets[band][bandHash, default: []].append(signature.documentId)
    }
  }

  /// Index multiple signatures.
  mutating func insert(_ signatures: [MinHashSignature]) {
    for signature in signatures {
      insert(signature)
    }
  }

  /// Find candidate pairs (documents that hash to the same bucket in at least one band).
  ///
  /// - Returns: Set of candidate document ID pairs.
  func findCandidatePairs() -> Set<DocumentPair> {
    var candidates = Set<DocumentPair>()

    for band in 0..<bands {
      for (_, docIds) in buckets[band] {
        // All pairs in the same bucket are candidates
        for (first, second) in docIds.pairCombinations() {
          candidates.insert(DocumentPair(id1: first, id2: second))
        }
      }
    }

    return candidates
  }

  /// Find similar documents to a query.
  ///
  /// - Parameter signature: The query signature.
  /// - Returns: Set of candidate document IDs.
  func query(_ signature: MinHashSignature) -> Set<Int> {
    guard signature.values.count >= bands * rows else { return [] }

    var candidates = Set<Int>()

    for band in 0..<bands {
      let bandHash = hashBand(signature: signature, band: band)
      if let docIds = buckets[band][bandHash] {
        candidates.formUnion(docIds)
      }
    }

    // Remove self if present
    candidates.remove(signature.documentId)

    return candidates
  }

  /// Get the signature for a document ID.
  func signature(for documentId: Int) -> MinHashSignature? {
    signatures[documentId]
  }

  /// Find candidate pairs in a specific range of bands.
  ///
  /// This method enables parallel candidate finding by processing
  /// different band ranges concurrently.
  ///
  /// - Parameters:
  ///   - startBand: Starting band index (inclusive).
  ///   - endBand: Ending band index (exclusive).
  /// - Returns: Candidate pairs found in the specified bands.
  func findCandidatePairsInBands(from startBand: Int, to endBand: Int) async -> Set<DocumentPair> {
    var candidates = Set<DocumentPair>()
    var inspectedPairs = 0

    for band in startBand..<min(endBand, bands) {
      if Task.isCancelled {
        return candidates
      }

      for (_, docIds) in buckets[band] {
        for (first, second) in docIds.pairCombinations() {
          candidates.insert(DocumentPair(id1: first, id2: second))
          inspectedPairs += 1

          if await TaskCooperation.checkpoint(iteration: inspectedPairs) {
            return candidates
          }
        }
      }
    }

    return candidates
  }

  /// Find candidate pairs using parallel band processing.
  ///
  /// Each band range is processed concurrently, then results are merged.
  ///
  /// - Parameter maxConcurrency: Maximum concurrent tasks.
  /// - Returns: Set of candidate document pairs.
  func findCandidatePairsParallel(
    maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
  ) async -> Set<DocumentPair> {
    // Use sequential for small band counts
    if bands < 4 {
      return findCandidatePairs()
    }

    let bandsPerChunk = max(1, bands / maxConcurrency)

    return await withTaskGroup(of: Set<DocumentPair>.self) { group in
      for chunk in chunkedRanges(totalCount: bands, chunkSize: bandsPerChunk) {
        let startBand = chunk.lowerBound
        let endBand = chunk.upperBound

        group.addTask {
          await self.findCandidatePairsInBands(from: startBand, to: endBand)
        }
      }

      var allCandidates = Set<DocumentPair>()
      for await partialCandidates in group {
        allCandidates.formUnion(partialCandidates)
      }
      return allCandidates
    }
  }

  /// Stream candidate pairs as they're discovered (band by band).
  ///
  /// This method yields candidate pairs incrementally, enabling:
  /// - Early results for progressive UI updates
  /// - Memory-bounded processing via backpressure
  /// - Suitable for ParallelMode.maximum
  ///
  /// - Parameter bufferSize: Size of the streaming buffer.
  /// - Returns: AsyncStream of candidate document pairs.
  func findCandidatePairsStreaming(
    bufferSize: Int = 1000
  ) -> AsyncStream<DocumentPair> {
    let bands = self.bands
    let buckets = self.buckets

    return TaskBackedAsyncStream.makeStream(
      bufferingPolicy: .bufferingNewest(bufferSize)
    ) { continuation in
      defer { continuation.finish() }

      var inspectedPairs = 0
      var seen = Set<DocumentPair>()

      for band in 0..<bands {
        if Task.isCancelled {
          return
        }

        for (_, docIds) in buckets[band] {
          for (first, second) in docIds.pairCombinations() {
            let documentPair = DocumentPair(id1: first, id2: second)

            // Deduplicate on the fly
            if seen.insert(documentPair).inserted {
              continuation.yield(documentPair)
            }

            inspectedPairs += 1
            if await TaskCooperation.checkpoint(iteration: inspectedPairs) {
              return
            }
          }
        }
      }
    }
  }

  /// Find candidate pairs based on parallel mode.
  ///
  /// - Parameter mode: The parallel execution mode.
  /// - Returns: Set of candidate document pairs.
  func findCandidatePairs(mode: ParallelMode) async -> Set<DocumentPair> {
    switch mode {
    case .none:
      return findCandidatePairs()

    case .safe:
      return await findCandidatePairsParallel()

    case .maximum:
      // Streaming collects into Set for compatibility
      var candidates = Set<DocumentPair>()
      for await pair in findCandidatePairsStreaming() {
        candidates.insert(pair)
      }
      return candidates
    }
  }

  // MARK: Private

  /// Hash buckets for each band. buckets[band][hash] = [documentIds].
  private var buckets: [[UInt64: [Int]]]

  /// All indexed signatures.
  private var signatures: [Int: MinHashSignature]

  // MARK: - Private Helpers

  /// Hash a band of the signature.
  ///
  /// Mixes the UInt64 values directly (no per-byte unpack) for speed; this
  /// is intentional and differs from the `FNV1a.hash(_:Sequence<UInt64>)`
  /// helper which mixes byte-by-byte for stability across architectures.
  private func hashBand(signature: MinHashSignature, band: Int) -> UInt64 {
    let start = band * rows
    let end = min(start + rows, signature.values.count)

    var hash = FNV1a.offsetBasis
    for i in start..<end {
      hash ^= signature.values[i]
      hash = hash &* FNV1a.prime
    }

    return hash
  }
}

// MARK: - DocumentPair

/// A pair of document IDs.
struct DocumentPair: Sendable, Hashable {
  // MARK: Lifecycle

  init(id1: Int, id2: Int) {
    // Normalize order for consistent hashing
    if id1 < id2 {
      self.id1 = id1
      self.id2 = id2
    } else {
      self.id1 = id2
      self.id2 = id1
    }
  }

  // MARK: Public

  let id1: Int
  let id2: Int
}

// MARK: - SimilarPair

/// Result of LSH similarity search.
struct SimilarPair: Sendable {
  // MARK: Lifecycle

  init(documentId1: Int, documentId2: Int, similarity: Double) {
    self.documentId1 = min(documentId1, documentId2)
    self.documentId2 = max(documentId1, documentId2)
    self.similarity = similarity
  }

  // MARK: Public

  /// First document ID.
  let documentId1: Int

  /// Second document ID.
  let documentId2: Int

  /// Estimated Jaccard similarity.
  let similarity: Double
}
