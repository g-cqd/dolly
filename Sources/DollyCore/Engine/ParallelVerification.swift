//  ParallelVerification.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  Trimmed for dolly: the AsyncChannel/backpressured streaming verifier and
//  the batch/progress wrappers are gone; the TaskGroup path remains.

import Foundation

// MARK: - ParallelVerifier

/// Parallel verification of LSH candidate pairs.
///
/// Verifies candidate pairs by computing exact Jaccard similarity
/// concurrently. Each pair is processed independently.
///
/// ## Performance Characteristics
///
/// - Small batches (< minParallelPairs): Sequential fallback
/// - Large batches: Near-linear speedup up to maxConcurrency
///
/// ## Thread Safety
///
/// - Fully thread-safe using Swift Concurrency
/// - Each pair is verified independently
/// - Document map is read-only during verification
struct ParallelVerifier: Sendable {
  /// Minimum similarity threshold.
  let minimumSimilarity: Double

  /// Minimum pairs to trigger parallel processing.
  let minParallelPairs: Int

  /// Maximum concurrent tasks.
  let maxConcurrency: Int

  /// Create a parallel verifier.
  ///
  /// - Parameters:
  ///   - minimumSimilarity: Minimum similarity threshold.
  ///   - minParallelPairs: Minimum pairs to trigger parallelism.
  ///   - maxConcurrency: Maximum concurrent tasks.
  init(
    minimumSimilarity: Double = 0.5,
    minParallelPairs: Int = 100,
    maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
  ) {
    self.minimumSimilarity = max(0, min(1, minimumSimilarity))
    self.minParallelPairs = max(1, minParallelPairs)
    self.maxConcurrency = max(1, maxConcurrency)
  }

  /// Verify candidate pairs in parallel.
  ///
  /// - Parameters:
  ///   - candidatePairs: Set of candidate document pairs.
  ///   - documentMap: Map from document ID to shingled document.
  /// - Returns: Array of verified clone pairs above threshold.
  func verifyCandidatePairs(
    _ candidatePairs: Set<DocumentPair>,
    documentMap: [Int: ShingledDocument]
  ) async -> [ClonePairInfo] {
    let pairs = Array(candidatePairs)

    // Fall back to sequential for small batches
    guard pairs.count >= minParallelPairs else {
      return await verifySequential(pairs, documentMap: documentMap)
    }

    // Parallel verification with chunking
    let chunkSize = max(1, pairs.count / maxConcurrency)

    return await withTaskGroup(of: [ClonePairInfo].self) { group in
      for range in chunkedRanges(totalCount: pairs.count, chunkSize: chunkSize) {
        let chunk = Array(pairs[range])
        group.addTask {
          await self.verifySequential(chunk, documentMap: documentMap)
        }
      }

      var allPairs: [ClonePairInfo] = []
      for await partial in group {
        allPairs.append(contentsOf: partial)
      }
      return allPairs
    }
  }

  /// Verify a single pair of documents.
  ///
  /// - Parameters:
  ///   - pair: The document pair to verify.
  ///   - documentMap: Map from document ID to shingled document.
  /// - Returns: Clone pair info if similarity is above threshold, nil otherwise.
  func verifyPair(
    _ pair: DocumentPair,
    documentMap: [Int: ShingledDocument]
  ) -> ClonePairInfo? {
    guard let doc1 = documentMap[pair.id1],
      let doc2 = documentMap[pair.id2]
    else { return nil }

    // Skip overlapping in same file
    if doc1.file == doc2.file {
      let overlaps = !(doc1.endLine < doc2.startLine || doc2.endLine < doc1.startLine)
      if overlaps { return nil }
    }

    let similarity = MinHashGenerator.exactJaccardSimilarity(doc1, doc2)

    guard similarity >= minimumSimilarity else { return nil }

    return ClonePairInfo(doc1: doc1, doc2: doc2, similarity: similarity)
  }

  // MARK: Private

  /// Sequential verification for small batches or as chunk processor.
  private func verifySequential(
    _ pairs: [DocumentPair],
    documentMap: [Int: ShingledDocument]
  ) async -> [ClonePairInfo] {
    var results: [ClonePairInfo] = []
    var processedPairs = 0

    for pair in pairs {
      if let verified = verifyPair(pair, documentMap: documentMap) {
        results.append(verified)
      }

      processedPairs += 1
      if await TaskCooperation.checkpoint(iteration: processedPairs) {
        break
      }
    }

    return results
  }
}
