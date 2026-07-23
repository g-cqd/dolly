//  ParallelLSH.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

import Foundation

// MARK: - ParallelLSHPipeline

/// Complete parallel LSH pipeline for finding similar documents.
struct ParallelLSHPipeline: Sendable {
    // MARK: Lifecycle

    /// Create a parallel LSH pipeline.
    ///
    /// - Parameters:
    ///   - numHashes: Number of hash functions.
    ///   - threshold: Similarity threshold.
    ///   - seed: Random seed.
    ///   - maxConcurrency: Maximum concurrent tasks.
    init(
        numHashes: Int = 256,
        threshold: Double = 0.5,
        seed: UInt64 = 42,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.minHashGenerator = ParallelMinHashGenerator(
            numHashes: numHashes,
            seed: seed,
            maxConcurrency: maxConcurrency
        )
        let (b, r) = LSHIndex.optimalBandsAndRows(
            signatureSize: numHashes,
            threshold: threshold
        )
        self.bands = b
        self.rows = r
        self.threshold = threshold
        self.maxConcurrency = maxConcurrency
    }

    // MARK: Public

    /// Parallel MinHash generator.
    let minHashGenerator: ParallelMinHashGenerator

    /// LSH index parameters.
    let bands: Int
    let rows: Int

    /// Similarity threshold.
    let threshold: Double

    /// Maximum concurrent tasks.
    let maxConcurrency: Int

    /// Find similar pairs among documents using parallel processing.
    ///
    /// - Parameters:
    ///   - documents: Array of shingled documents.
    ///   - verifyWithExact: Whether to verify candidates with exact Jaccard.
    /// - Returns: Array of similar pairs above threshold.
    func findSimilarPairs(
        _ documents: [ShingledDocument],
        verifyWithExact: Bool = false
    ) async -> [SimilarPair] {
        // Parallel signature computation
        let signatures = await minHashGenerator.computeSignatures(for: documents)

        // Build index (sequential - write-bound)
        var index = LSHIndex(bands: bands, rows: rows)
        index.insert(signatures)

        // Parallel candidate finding
        let candidatePairs = await index.findCandidatePairsParallel(
            maxConcurrency: maxConcurrency
        )

        // Verify and filter using shared logic
        return CandidateVerifier.verify(
            candidatePairs: candidatePairs,
            index: index,
            documents: documents,
            threshold: threshold,
            verifyWithExact: verifyWithExact
        )
    }
}
