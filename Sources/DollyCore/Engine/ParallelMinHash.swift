//  ParallelMinHash.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

import Foundation

// MARK: - ParallelMinHashGenerator

/// Parallel MinHash signature computation using task groups.
///
/// This generator wraps the standard `MinHashGenerator` and distributes
/// signature computation across multiple concurrent tasks for improved
/// throughput on large document sets.
///
/// ## Performance Characteristics
///
/// - Small batches (< minParallelDocuments): Sequential fallback
/// - Large batches: Near-linear speedup up to maxConcurrency
///
/// ## Thread Safety
///
/// - Fully thread-safe using Swift Concurrency
/// - Each document is processed independently
/// - Results are collected with order preservation
struct ParallelMinHashGenerator: Sendable {
    /// Number of hash functions.
    var numHashes: Int { baseGenerator.numHashes }

    /// Base sequential generator.
    private let baseGenerator: MinHashGenerator

    /// Minimum documents to use parallel processing.
    private let minParallelDocuments: Int

    /// Maximum concurrent tasks.
    private let maxConcurrency: Int

    /// Create a parallel MinHash generator.
    ///
    /// - Parameters:
    ///   - numHashes: Number of hash functions (signature dimension).
    ///   - seed: Random seed for reproducibility.
    ///   - minParallelDocuments: Minimum documents to trigger parallelism.
    ///   - maxConcurrency: Maximum concurrent tasks.
    init(
        numHashes: Int = 256,
        seed: UInt64 = 42,
        minParallelDocuments: Int = 50,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.baseGenerator = MinHashGenerator(numHashes: numHashes, seed: seed)
        self.minParallelDocuments = max(1, minParallelDocuments)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Compute signatures in parallel for multiple documents.
    ///
    /// Streaming-bounded pattern: start `maxConcurrency` tasks, add a
    /// new one on each completion. A naive "add all tasks then drain"
    /// shape would create one task per document, ignoring the cap.
    ///
    /// - Parameter documents: Documents to compute signatures for.
    /// - Returns: Array of signatures in the same order as input documents.
    func computeSignatures(
        for documents: [ShingledDocument]
    ) async -> [MinHashSignature] {
        // Fall back to sequential for small batches
        guard documents.count >= minParallelDocuments else {
            return documents.map { baseGenerator.computeSignature(for: $0) }
        }

        let cap = max(1, maxConcurrency)
        return await withTaskGroup(of: (Int, MinHashSignature).self) { group in
            var iterator = documents.enumerated().makeIterator()
            var inFlight = 0

            while inFlight < cap, let next = iterator.next() {
                let (index, document) = next
                group.addTask {
                    (index, self.baseGenerator.computeSignature(for: document))
                }
                inFlight += 1
            }

            var signatures = [MinHashSignature?](repeating: nil, count: documents.count)
            while let (index, signature) = await group.next() {
                signatures[index] = signature
                inFlight -= 1
                if let next = iterator.next() {
                    let (nextIndex, nextDocument) = next
                    group.addTask {
                        (nextIndex, self.baseGenerator.computeSignature(for: nextDocument))
                    }
                    inFlight += 1
                }
            }

            return signatures.compactMap { $0 }
        }
    }
}
