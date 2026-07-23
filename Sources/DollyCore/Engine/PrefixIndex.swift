//  PrefixIndex.swift
//  dolly
//
//  SourcererCC-style candidate generation for the structural stage
//  (Sajnani, Saini, Svajlenko, Roy, Lopes — "SourcererCC: Scaling Code
//  Clone Detection to Big-Code", ICSE 2016), adapted to Jaccard over
//  shingle-hash feature sets: order features by global corpus frequency
//  (rarest first), index only each block's prefix, and use the position
//  filter to upper-bound the remaining overlap and abandon pairs early.
//  Deterministic — unlike LSH banding, recall does not depend on hash
//  values: every pair with Jaccard >= threshold is guaranteed to collide
//  in both prefixes under the shared global feature order.
//
//  Two phases: the prefix index is built serially (append-only), then
//  every document probes it independently — embarrassingly parallel, and
//  the result is identical to the sequential formulation because each
//  probe only considers partners with a smaller document index.

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

// MARK: - PrefixIndexCandidateGenerator

/// Generates structural candidate pairs by prefix filtering.
///
/// Derivations for Jaccard threshold θ (all conservative — rounding always
/// widens the candidate set, never narrows it):
/// - J(A,B) >= θ  ⟺  |A∩B| >= θ/(1+θ)·(|A|+|B|)  (required overlap)
/// - eligible partner sizes satisfy θ·max(|A|,|B|) <= min(|A|,|B|)
/// - the smallest required overlap over eligible partners of A is ⌈θ·|A|⌉,
///   so indexing/probing the first |A| − ⌈θ·|A|⌉ + 1 features suffices:
///   a qualifying pair's rarest shared feature falls in BOTH prefixes.
struct PrefixIndexCandidateGenerator: Sendable {
  /// Jaccard similarity threshold (0, 1].
  let threshold: Double

  /// Maximum concurrent probe tasks.
  let maxConcurrency: Int

  init(threshold: Double, maxConcurrency: Int = 1) {
    self.threshold = threshold
    self.maxConcurrency = max(1, maxConcurrency)
  }

  /// One posting in the prefix index.
  private struct Posting: Sendable {
    let document: Int32
    let position: Int32
  }

  /// Candidate pairs over the documents' shingle-hash feature sets.
  ///
  /// The result is a superset of all pairs with exact Jaccard >= threshold
  /// (property-tested against brute force); verification prunes the rest.
  /// Same-file line-overlapping windows — the 50%-overlap block neighbours,
  /// which can never become clones — are excluded here so they don't cost
  /// a bucket walk per shared feature.
  func candidatePairs(for documents: [ShingledDocument]) async -> Set<DocumentPair> {
    guard documents.count >= 2, threshold > 0 else { return [] }

    // Global feature frequency — the ordering that makes prefixes rare.
    var frequency: [UInt64: Int32] = [:]
    for document in documents {
      for feature in document.shingleHashes {
        frequency[feature, default: 0] += 1
      }
    }

    // Features per document, rarest first; ties broken by value so the
    // order (and therefore the candidate set) is fully deterministic.
    // Frequencies are paired up front so the sort comparator touches no
    // dictionary.
    let sortedFeatures: [[UInt64]] = documents.map { document in
      var pairs = document.shingleHashes.map { (frequency: frequency[$0] ?? 0, feature: $0) }
      pairs.sort { lhs, rhs in
        lhs.frequency != rhs.frequency
          ? lhs.frequency < rhs.frequency : lhs.feature < rhs.feature
      }
      return pairs.map(\.feature)
    }

    // Compact per-document metadata so eligibility checks in the probe
    // loop are integer array reads, never String compares or dict ops.
    var fileOrdinals: [String: Int32] = [:]
    var metadata: [(size: Int32, file: Int32, startLine: Int32, endLine: Int32)] = []
    metadata.reserveCapacity(documents.count)
    for (index, document) in documents.enumerated() {
      let file: Int32
      if let existing = fileOrdinals[document.file] {
        file = existing
      } else {
        file = Int32(fileOrdinals.count)
        fileOrdinals[document.file] = file
      }
      metadata.append(
        (
          size: Int32(sortedFeatures[index].count),
          file: file,
          startLine: Int32(clamping: document.startLine),
          endLine: Int32(clamping: document.endLine)
        ))
    }

    // Phase 1: serial CSR index over PREFIX features — one contiguous
    // postings array plus feature -> range, instead of a dict of arrays.
    // Postings are appended in ascending document order, so probes can
    // stop at the first posting >= their own document index.
    var prefixLengths = [Int](repeating: 0, count: documents.count)
    var featureCounts: [UInt64: Int] = [:]
    for (documentIndex, features) in sortedFeatures.enumerated() {
      let size = features.count
      guard size > 0 else { continue }
      let prefixLength = min(size - requiredOverlap(ofSize: size) + 1, size)
      prefixLengths[documentIndex] = prefixLength
      for position in 0..<prefixLength {
        featureCounts[features[position], default: 0] += 1
      }
    }

    var featureRanges: [UInt64: Range<Int>] = [:]
    featureRanges.reserveCapacity(featureCounts.count)
    var offset = 0
    for (feature, count) in featureCounts {
      featureRanges[feature] = offset..<offset
      offset += count
    }
    var postings = [Posting](repeating: Posting(document: 0, position: 0), count: offset)
    for (documentIndex, features) in sortedFeatures.enumerated() {
      for position in 0..<prefixLengths[documentIndex] {
        let feature = features[position]
        let range = featureRanges[feature]!
        postings[range.upperBound] =
          Posting(document: Int32(documentIndex), position: Int32(position))
        featureRanges[feature] = range.lowerBound..<(range.upperBound + 1)
      }
    }

    // Phase 2: parallel probes. Each document only pairs with smaller
    // indices, which reproduces the sequential formulation exactly. Each
    // chunk task reuses one flat match array (touched-list reset) so the
    // hot loop performs no dictionary or allocation work.
    let probeChunks = chunkedRanges(
      totalCount: documents.count, chunkSize: max(64, documents.count / (maxConcurrency * 8)))
    let frozenPostings = postings
    let frozenRanges = featureRanges
    let frozenFeatures = sortedFeatures
    let frozenPrefixLengths = prefixLengths
    let frozenMetadata = metadata

    let chunkResults: [[DocumentPair]] = await ParallelProcessor.map(
      probeChunks, maxConcurrency: maxConcurrency
    ) { chunk in
      var pairs: [DocumentPair] = []
      // 0 = untouched, -1 = dead, > 0 = running match count.
      var matches = [Int32](repeating: 0, count: documents.count)
      var touched: [Int] = []
      for documentIndex in chunk {
        probe(
          documentIndex: documentIndex,
          features: frozenFeatures,
          prefixLengths: frozenPrefixLengths,
          metadata: frozenMetadata,
          postings: frozenPostings,
          featureRanges: frozenRanges,
          documents: documents,
          matches: &matches,
          touched: &touched,
          into: &pairs
        )
      }
      return pairs
    }

    var candidates = Set<DocumentPair>()
    for chunk in chunkResults {
      candidates.formUnion(chunk)
    }
    return candidates
  }

  // MARK: Private

  /// Probe one document's prefix against the index, appending surviving
  /// candidate pairs. `matches` must be all zeros on entry; the touched
  /// list restores it before returning.
  private func probe(
    documentIndex: Int,
    features: [[UInt64]],
    prefixLengths: [Int],
    metadata: [(size: Int32, file: Int32, startLine: Int32, endLine: Int32)],
    postings: [Posting],
    featureRanges: [UInt64: Range<Int>],
    documents: [ShingledDocument],
    matches: inout [Int32],
    touched: inout [Int],
    into pairs: inout [DocumentPair]
  ) {
    let documentFeatures = features[documentIndex]
    let size = documentFeatures.count
    guard size > 0 else { return }
    let own = metadata[documentIndex]
    let cutoff = Int32(documentIndex)

    defer {
      for partner in touched {
        matches[partner] = 0
      }
      touched.removeAll(keepingCapacity: true)
    }

    for position in 0..<prefixLengths[documentIndex] {
      guard let range = featureRanges[documentFeatures[position]] else { continue }
      for posting in postings[range] {
        // Postings are in ascending document order.
        if posting.document >= cutoff { break }

        let partnerIndex = Int(posting.document)
        let partner = metadata[partnerIndex]
        // Size filter and the same-file overlapping-window exclusion —
        // integer reads only.
        if !sizesEligible(size, Int(partner.size))
          || (partner.file == own.file
            && partner.startLine <= own.endLine
            && own.startLine <= partner.endLine)
        {
          continue
        }

        let current = matches[partnerIndex]
        guard current >= 0 else { continue }
        if current == 0 { touched.append(partnerIndex) }

        let updated = current + 1
        // Position filter: matches so far plus everything that could
        // still match (the shorter remaining tail) bounds the overlap.
        let upperBound =
          Int(updated) + min(size - position - 1, Int(partner.size) - Int(posting.position) - 1)
        matches[partnerIndex] = upperBound < requiredOverlap(size, Int(partner.size)) ? -1 : updated
      }
    }

    for partner in touched where matches[partner] > 0 {
      pairs.append(
        DocumentPair(id1: documents[partner].id, id2: documents[documentIndex].id))
    }
  }

  /// ⌈θ·n⌉ with a conservative epsilon: floating error may only lower the
  /// requirement (lengthening prefixes → more candidates, never fewer).
  private func requiredOverlap(ofSize size: Int) -> Int {
    Int((threshold * Double(size) - 1e-9).rounded(.up))
  }

  /// ⌈θ/(1+θ)·(a+b)⌉ with the same conservative epsilon.
  private func requiredOverlap(_ a: Int, _ b: Int) -> Int {
    Int((threshold / (1 + threshold) * Double(a + b) - 1e-9).rounded(.up))
  }

  /// Partner sizes are eligible when min >= θ·max (epsilon-tolerant).
  private func sizesEligible(_ a: Int, _ b: Int) -> Bool {
    Double(min(a, b)) >= threshold * Double(max(a, b)) - 1e-9
  }
}
