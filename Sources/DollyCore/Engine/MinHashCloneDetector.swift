//  MinHashCloneDetector.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  Trimmed for dolly: the file-IO entry point, the sync/parallel twin
//  detection paths, and the streaming/backpressured verifier branch are
//  gone. One async `detect(in:)` remains; it self-tunes between
//  sequential and parallel execution based on workload size.

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

// MARK: - LSHStrategy

/// Selects which LSH backend `MinHashCloneDetector` uses to find
/// candidate structural-clone pairs.
enum LSHStrategy: Sendable, Equatable {
  /// The original `LSHIndex.findCandidatePairs` path. Default.
  case standard

  /// Multi-probe LSH (`MultiProbeLSH`). Trades index size for recall
  /// by probing nearby buckets. `probesPerBand` controls how many
  /// perturbed buckets are visited per band. See `MultiProbeLSH`'s
  /// doc comment for caveats — prefer raising `numHashes` first.
  case multiProbe(probesPerBand: Int)

  /// `ParallelLSHPipeline` — parallel signature computation +
  /// parallel candidate finding. `maxConcurrency` defaults to active
  /// processor count when nil.
  case parallel(maxConcurrency: Int?)
}

// MARK: - ParallelCloneConfiguration

/// Configuration for parallel clone detection.
struct ParallelCloneConfiguration: Sendable {
  /// Default configuration.
  static let `default` = ParallelCloneConfiguration()

  /// Minimum documents to trigger parallel MinHash.
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

// MARK: - MinHashCloneDetector

/// Detects Type-3 (structural) clones using MinHash and LSH.
struct MinHashCloneDetector: Sendable {
  /// Minimum tokens to consider as a clone.
  let minimumTokens: Int

  /// Shingle size for n-gram generation.
  let shingleSize: Int

  /// Number of hash functions for MinHash.
  let numHashes: Int

  /// Minimum similarity threshold for clones.
  let minimumSimilarity: Double

  /// Parallel processing configuration.
  let parallelConfig: ParallelCloneConfiguration

  /// Active LSH backend strategy.
  let lshStrategy: LSHStrategy

  /// Shingle generator.
  private let shingleGenerator: ShingleGenerator

  /// MinHash generator.
  private let minHashGenerator: MinHashGenerator

  /// LSH bands and rows.
  private let lshBands: Int
  private let lshRows: Int

  init(
    minimumTokens: Int = 50,
    shingleSize: Int = 5,
    numHashes: Int = 256,
    minimumSimilarity: Double = 0.5,
    parallelConfig: ParallelCloneConfiguration = .default,
    lshStrategy: LSHStrategy = .standard
  ) {
    self.minimumTokens = minimumTokens
    self.shingleSize = shingleSize
    self.numHashes = numHashes
    self.minimumSimilarity = minimumSimilarity
    self.parallelConfig = parallelConfig
    self.lshStrategy = lshStrategy

    shingleGenerator = ShingleGenerator(shingleSize: shingleSize, normalize: true)
    minHashGenerator = MinHashGenerator(numHashes: numHashes)

    // Calculate optimal LSH parameters for the threshold
    let (b, r) = LSHIndex.optimalBandsAndRows(
      signatureSize: numHashes,
      threshold: minimumSimilarity
    )
    lshBands = b
    lshRows = r
  }

  /// Detect structural clones in the given token sequences.
  ///
  /// Self-tuning: MinHash signatures, LSH candidate finding, pair
  /// verification, and connected-component grouping each fall back to
  /// sequential execution below their parallel thresholds.
  ///
  /// - Parameter sequences: Array of token sequences from files.
  /// - Returns: Array of clone groups found.
  func detectParallel(in sequences: [TokenSequence]) async -> [CloneGroup] {
    guard !sequences.isEmpty, minimumTokens > 0 else { return [] }

    // Generate shingled documents for all code blocks. Pre-size the
    // accumulator so the N append(contentsOf:) calls don't trigger
    // O(N) reallocations on large codebases.
    var allDocuments: [ShingledDocument] = []
    allDocuments.reserveCapacity(estimatedDocumentCount(for: sequences))
    var documentId = 0

    for sequence in sequences {
      let documents = shingleGenerator.generateBlockDocuments(
        from: sequence,
        blockSize: minimumTokens,
        startId: documentId
      )
      allDocuments.append(contentsOf: documents)
      documentId += documents.count
    }

    guard !allDocuments.isEmpty else { return [] }

    // Build document lookup once — needed by every code path.
    let documentMap = allDocuments.keyed(by: \.id)

    // Short-circuit for explicitly-selected alternative LSH strategies.
    // These bypass the standard sig + LSHIndex path entirely.
    switch lshStrategy {
    case .multiProbe(let probesPerBand):
      let pipeline = MultiProbeLSHPipeline(
        numHashes: numHashes,
        threshold: minimumSimilarity,
        probesPerBand: probesPerBand
      )
      let similar = pipeline.findSimilarPairs(allDocuments, verifyWithExact: true)
      let clonePairs = mapSimilarPairsToClonePairs(similar, documentMap: documentMap)
      return await groupClones(clonePairs, maxDocId: documentId - 1)

    case .parallel(let maxConcurrency):
      let pipeline = ParallelLSHPipeline(
        numHashes: numHashes,
        threshold: minimumSimilarity,
        maxConcurrency: maxConcurrency ?? parallelConfig.maxConcurrency
      )
      let similar = await pipeline.findSimilarPairs(allDocuments, verifyWithExact: true)
      let clonePairs = mapSimilarPairsToClonePairs(similar, documentMap: documentMap)
      return await groupClones(clonePairs, maxDocId: documentId - 1)

    case .standard:
      break  // Fall through to the standard path below.
    }

    // Compute MinHash signatures (parallel above the document threshold)
    let signatures: [MinHashSignature]
    if allDocuments.count >= parallelConfig.minParallelDocuments {
      let parallelMinHash = ParallelMinHashGenerator(
        numHashes: numHashes,
        maxConcurrency: parallelConfig.maxConcurrency
      )
      signatures = await parallelMinHash.computeSignatures(for: allDocuments)
    } else {
      signatures = minHashGenerator.computeSignatures(for: allDocuments)
    }

    // Build LSH index
    var lshIndex = LSHIndex(bands: lshBands, rows: lshRows)
    lshIndex.insert(signatures)

    // Find candidate pairs (parallel if enough bands)
    let candidatePairs: Set<DocumentPair>
    if lshBands >= 4 {
      candidatePairs = await lshIndex.findCandidatePairsParallel(
        maxConcurrency: parallelConfig.maxConcurrency
      )
    } else {
      candidatePairs = lshIndex.findCandidatePairs()
    }

    // Verify candidates: parallel TaskGroup verification once the pair
    // count crosses the parallel threshold, sequential otherwise.
    let clonePairs: [ClonePairInfo]
    if candidatePairs.count >= parallelConfig.minParallelPairs {
      let verifier = ParallelVerifier(
        minimumSimilarity: minimumSimilarity,
        minParallelPairs: parallelConfig.minParallelPairs,
        maxConcurrency: parallelConfig.maxConcurrency
      )
      clonePairs = await verifier.verifyCandidatePairs(candidatePairs, documentMap: documentMap)
    } else {
      clonePairs = verifyCandidatePairs(candidatePairs, documentMap: documentMap)
    }

    // Group related clones using connected components
    return await groupClones(clonePairs, maxDocId: documentId - 1)
  }

  // MARK: Private

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

  /// Convert pipeline `SimilarPair`s back into `ClonePairInfo`,
  /// dropping any pair whose document IDs don't resolve (defensive
  /// against pipeline/document-map drift) and any same-file
  /// overlapping ranges (matches the standard verifier's contract).
  private func mapSimilarPairsToClonePairs(
    _ similar: [SimilarPair],
    documentMap: [Int: ShingledDocument]
  ) -> [ClonePairInfo] {
    similar.compactMap { pair in
      guard let doc1 = documentMap[pair.documentId1],
        let doc2 = documentMap[pair.documentId2]
      else { return nil }
      if doc1.file == doc2.file,
        doc1.startLine <= doc2.endLine && doc2.startLine <= doc1.endLine
      {
        return nil
      }
      return ClonePairInfo(doc1: doc1, doc2: doc2, similarity: pair.similarity)
    }
  }

  /// Verify candidate pairs and filter by similarity threshold.
  private func verifyCandidatePairs(
    _ candidatePairs: Set<DocumentPair>,
    documentMap: [Int: ShingledDocument]
  ) -> [ClonePairInfo] {
    var clonePairs: [ClonePairInfo] = []

    for pair in candidatePairs {
      guard let doc1 = documentMap[pair.id1],
        let doc2 = documentMap[pair.id2]
      else { continue }

      // Skip if same file and overlapping lines
      if doc1.file == doc2.file {
        let overlaps = !(doc1.endLine < doc2.startLine || doc2.endLine < doc1.startLine)
        if overlaps {
          continue
        }
      }

      // Compute exact Jaccard similarity for verification
      let similarity = MinHashGenerator.exactJaccardSimilarity(doc1, doc2)

      if similarity >= minimumSimilarity {
        clonePairs.append(ClonePairInfo(doc1: doc1, doc2: doc2, similarity: similarity))
      }
    }

    return clonePairs
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
