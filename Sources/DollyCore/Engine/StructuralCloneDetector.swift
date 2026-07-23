//  StructuralCloneDetector.swift
//  dolly
//
//  Type-3 (structural) clone detection: 50%-overlap block documents over
//  shingle-hash feature sets, SourcererCC prefix+position filtering for
//  DETERMINISTIC candidate generation (replacing MinHash+LSH banding,
//  whose recall depended on hash values), exact-Jaccard verification, and
//  a NIL-style token-LCS gate so scrambled statements don't pass as
//  clones. Grouping stays connected-components over verified pairs.

import Foundation

// MARK: - ClonePairInfo

/// Information about a pair of similar documents.
struct ClonePairInfo: Sendable {
  let doc1: ShingledDocument
  let doc2: ShingledDocument
  let similarity: Double
}

// MARK: - DocumentLocationInfo

/// Location information for a document.
struct DocumentLocationInfo: Sendable {
  let file: String
  let startLine: Int
  let startColumn: Int
  let endLine: Int
  let tokenCount: Int

  init(document: ShingledDocument) {
    file = document.file
    startLine = document.startLine
    startColumn = document.startColumn
    endLine = document.endLine
    tokenCount = document.tokenCount
  }
}

// MARK: - ParallelCloneConfiguration

/// Configuration for parallel clone detection.
struct ParallelCloneConfiguration: Sendable {
  /// Default configuration.
  static let `default` = ParallelCloneConfiguration()

  /// Minimum documents to trigger parallel processing.
  let minParallelDocuments: Int

  /// Minimum pairs to trigger parallel verification.
  let minParallelPairs: Int

  /// Maximum concurrent tasks.
  let maxConcurrency: Int

  init(
    minParallelDocuments: Int = 50,
    minParallelPairs: Int = 100,
    maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
  ) {
    self.minParallelDocuments = max(1, minParallelDocuments)
    self.minParallelPairs = max(1, minParallelPairs)
    self.maxConcurrency = max(1, maxConcurrency)
  }
}

// MARK: - StructuralCloneDetector

/// Detects Type-3 (structural) clones.
struct StructuralCloneDetector: Sendable {
  /// Minimum tokens to consider as a clone (block size).
  let minimumTokens: Int

  /// Shingle size for n-gram generation.
  let shingleSize: Int

  /// Minimum exact-Jaccard similarity threshold for clones.
  let minimumSimilarity: Double

  /// Parallel processing configuration.
  let parallelConfig: ParallelCloneConfiguration

  /// Shingle generator.
  private let shingleGenerator: ShingleGenerator

  init(
    minimumTokens: Int = 50,
    shingleSize: Int = 5,
    minimumSimilarity: Double = 0.5,
    parallelConfig: ParallelCloneConfiguration = .default
  ) {
    self.minimumTokens = minimumTokens
    self.shingleSize = shingleSize
    self.minimumSimilarity = minimumSimilarity
    self.parallelConfig = parallelConfig

    shingleGenerator = ShingleGenerator(shingleSize: shingleSize, normalize: true)
  }

  /// Detect structural clones in the given token sequences.
  ///
  /// Candidate generation is deterministic (prefix filtering); pair
  /// verification parallelizes above `minParallelPairs` and is
  /// order-preserving, so output is identical either way.
  ///
  /// - Parameter sequences: Array of token sequences from files.
  /// - Returns: Array of clone groups found.
  func detect(in sequences: [TokenSequence]) async -> [CloneGroup] {
    guard !sequences.isEmpty, minimumTokens > 0 else { return [] }

    // Generate shingled documents for all code blocks (50%-overlap block
    // windows — unchanged). Pre-size the accumulator so the N
    // append(contentsOf:) calls don't trigger O(N) reallocations.
    var allDocuments: [ShingledDocument] = []
    allDocuments.reserveCapacity(estimatedDocumentCount(for: sequences))
    var documentId = 0

    for (sequenceIndex, sequence) in sequences.enumerated() {
      let documents = shingleGenerator.generateBlockDocuments(
        from: sequence,
        sequenceIndex: sequenceIndex,
        blockSize: minimumTokens,
        startId: documentId
      )
      allDocuments.append(contentsOf: documents)
      documentId += documents.count
    }

    guard !allDocuments.isEmpty else { return [] }

    // Candidate pairs: SourcererCC prefix + position filtering.
    let generator = PrefixIndexCandidateGenerator(
      threshold: minimumSimilarity, maxConcurrency: parallelConfig.maxConcurrency)
    let candidates = await generator.candidatePairs(for: allDocuments)
    guard !candidates.isEmpty else { return [] }

    // Deterministic verification order regardless of Set iteration.
    let orderedCandidates = candidates.sorted { lhs, rhs in
      (lhs.id1, lhs.id2) < (rhs.id1, rhs.id2)
    }

    let documentMap = allDocuments.keyed(by: \.id)
    let minimumSimilarity = self.minimumSimilarity
    let verify: @Sendable (DocumentPair) -> ClonePairInfo? = { pair in
      Self.verifyPair(
        pair,
        documentMap: documentMap,
        sequences: sequences,
        minimumSimilarity: minimumSimilarity
      )
    }

    // Verification parallelizes over CHUNKS of the ordered candidate list
    // (one task per chunk, not per pair — a per-pair task allocation storm
    // dwarfs the verification work itself). compactMap keeps order, so
    // output equals the sequential run.
    let clonePairs: [ClonePairInfo]
    if orderedCandidates.count >= parallelConfig.minParallelPairs {
      let chunks = chunkedRanges(
        totalCount: orderedCandidates.count,
        chunkSize: max(
          parallelConfig.minParallelPairs,
          orderedCandidates.count / (parallelConfig.maxConcurrency * 4)))
      let verified = await ParallelProcessor.map(
        chunks, maxConcurrency: parallelConfig.maxConcurrency
      ) { chunk in
        orderedCandidates[chunk].compactMap(verify)
      }
      clonePairs = verified.flatMap(\.self)
    } else {
      clonePairs = orderedCandidates.compactMap(verify)
    }

    // Group related clones using connected components
    return await groupClones(clonePairs, maxDocId: documentId - 1)
  }

  /// Verify one candidate pair: same-file overlap skip, exact-Jaccard
  /// pre-check, then the NIL-style order-sensitive LCS gate over the
  /// blocks' normalized id lanes.
  static func verifyPair(
    _ pair: DocumentPair,
    documentMap: [Int: ShingledDocument],
    sequences: [TokenSequence],
    minimumSimilarity: Double
  ) -> ClonePairInfo? {
    guard let doc1 = documentMap[pair.id1],
      let doc2 = documentMap[pair.id2]
    else { return nil }

    // Skip if same file and overlapping lines
    if doc1.file == doc2.file {
      let overlaps = !(doc1.endLine < doc2.startLine || doc2.endLine < doc1.startLine)
      if overlaps {
        return nil
      }
    }

    // Exact Jaccard over the shingle-hash sets (allocation-free, aborts
    // as soon as the threshold is unreachable).
    guard
      let similarity = StructuralVerification.jaccardIfAtLeast(
        minimumSimilarity, doc1.shingleHashes, doc2.shingleHashes)
    else { return nil }

    // Order-sensitive gate: high bag similarity with scrambled statement
    // order is not a clone a caller could extract.
    let lcs = StructuralVerification.sequenceSimilarity(
      normIDs(of: doc1, in: sequences),
      normIDs(of: doc2, in: sequences)
    )
    guard lcs >= StructuralVerification.minimumSequenceSimilarity else { return nil }

    return ClonePairInfo(doc1: doc1, doc2: doc2, similarity: similarity)
  }

  // MARK: Private

  /// The block's normalized id lane, materialized only at verification
  /// time for the few candidates that reach the LCS gate.
  private static func normIDs(
    of document: ShingledDocument, in sequences: [TokenSequence]
  ) -> [UInt32] {
    guard document.sequenceIndex < sequences.count else { return [] }
    let records = sequences[document.sequenceIndex].records
    guard document.tokenRange.upperBound <= records.count else { return [] }
    return records[document.tokenRange].map(\.normID)
  }

  /// Heuristic capacity hint for the document accumulator before the
  /// per-sequence shingling pass. Token count divided by the block size
  /// over-approximates the number of windowed documents the shingle
  /// generator emits, so `reserveCapacity` allocates once instead of
  /// resizing through several powers of two as documents stream in.
  private func estimatedDocumentCount(for sequences: [TokenSequence]) -> Int {
    guard minimumTokens > 0 else { return sequences.count }
    let totalTokens = sequences.reduce(0) { $0 + $1.records.count }
    return max(sequences.count, totalTokens / minimumTokens)
  }

  /// Group clone pairs into clone groups using connected components.
  ///
  /// - Parameters:
  ///   - pairs: Verified clone pairs.
  ///   - maxDocId: Maximum document ID for graph sizing.
  /// - Returns: Array of clone groups.
  private func groupClones(
    _ pairs: [ClonePairInfo],
    maxDocId: Int
  ) async -> [CloneGroup] {
    guard !pairs.isEmpty else { return [] }

    // Build document info for conversion
    var documentInfo: [Int: DocumentLocationInfo] = [:]
    for pair in pairs {
      documentInfo[pair.doc1.id] = DocumentLocationInfo(document: pair.doc1)
      documentInfo[pair.doc2.id] = DocumentLocationInfo(document: pair.doc2)
    }

    // Build dense graph from pairs
    let graph = CloneSimilarityGraph(pairs: pairs, maxDocId: maxDocId)

    // Find connected components (parallel BFS above the size threshold)
    let config = ParallelConnectedComponents.Configuration(
      minParallelSize: parallelConfig.minParallelDocuments,
      maxConcurrency: parallelConfig.maxConcurrency
    )
    let groups = await ParallelConnectedComponents.findComponents(
      graph: graph,
      configuration: config
    )

    // Convert to CloneGroups
    return convertToCloneGroups(groups, documentInfo: documentInfo, pairs: pairs)
  }

  /// Convert component groups to CloneGroups.
  private func convertToCloneGroups(
    _ groups: [[Int]],
    documentInfo: [Int: DocumentLocationInfo],
    pairs: [ClonePairInfo]
  ) -> [CloneGroup] {
    groups.compactMap { component -> CloneGroup? in
      let clones = component.compactMap { docId -> Clone? in
        guard let info = documentInfo[docId] else { return nil }
        return Clone(
          file: info.file,
          startLine: info.startLine,
          startColumn: info.startColumn,
          endLine: info.endLine,
          tokenCount: info.tokenCount,
          codeSnippet: ""
        )
      }

      guard clones.count >= 2 else { return nil }

      // Calculate average similarity within group
      let groupPairs = pairs.filter { pair in
        component.contains(pair.doc1.id) && component.contains(pair.doc2.id)
      }
      let avgSimilarity =
        groupPairs.isEmpty
        ? minimumSimilarity
        : groupPairs.reduce(0.0) { $0 + $1.similarity } / Double(groupPairs.count)

      // Generate fingerprint from document IDs
      let fingerprint = component.sorted().map(String.init).joined(separator: "-")

      return CloneGroup(
        type: .structural,
        clones: clones,
        similarity: avgSimilarity,
        fingerprint: fingerprint
      )
    }
  }
}
