//  ConcurrencyConfiguration.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

import Foundation

// MARK: - ConcurrencyConfiguration

/// Configuration for parallel processing in analysis operations.
///
/// Setting `maxConcurrentFiles == 1` (and `maxConcurrentTasks == 1`)
/// forces serial execution. `ParallelProcessor` codepaths key off
/// `maxConcurrency` alone.
struct ConcurrencyConfiguration: Sendable {
    /// Default configuration based on system capabilities.
    static let `default` = Self()

    /// Single-threaded configuration (for debugging or testing).
    static let serial = Self(maxConcurrentFiles: 1, maxConcurrentTasks: 1)

    /// Maximum number of files to process concurrently. Setting this to 1
    /// forces serial execution end-to-end.
    let maxConcurrentFiles: Int

    /// Maximum number of analysis tasks to run concurrently.
    let maxConcurrentTasks: Int

    init(maxConcurrentFiles: Int? = nil, maxConcurrentTasks: Int? = nil) {
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        self.maxConcurrentFiles = maxConcurrentFiles ?? processorCount
        self.maxConcurrentTasks = maxConcurrentTasks ?? processorCount * 2
    }
}

// MARK: - ParallelProcessor

/// Utilities for parallel file processing with concurrency limits.
enum ParallelProcessor {
    /// Process items in parallel with a strict concurrency cap.
    ///
    /// Uses the streaming-bounded pattern (start `maxConcurrency` tasks,
    /// add a new one each time one completes) — no batch-barriers, so
    /// fast items don't sit idle waiting for a slow neighbour to finish
    /// its chunk.
    ///
    /// - Parameters:
    ///   - items: Items to process.
    ///   - maxConcurrency: Maximum concurrent tasks.
    ///   - operation: Async operation to perform on each item.
    /// - Returns: Array of results in same order as input.
    static func map<T, R: Sendable>(
        _ items: [T],
        maxConcurrency: Int,
        operation: @Sendable @escaping (T) async throws -> R
    ) async throws -> [R] where T: Sendable {
        guard !items.isEmpty else { return [] }
        let cap = max(1, maxConcurrency)

        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var iterator = items.enumerated().makeIterator()
            var inFlight = 0

            // Prime up to the concurrency cap.
            while inFlight < cap, let next = iterator.next() {
                let (index, item) = next
                group.addTask { (index, try await operation(item)) }
                inFlight += 1
            }

            // Drain completions, replacing each finished slot with the
            // next pending item. Order-preserving via `index`.
            var indexedResults: [(Int, R)] = []
            indexedResults.reserveCapacity(items.count)
            while let result = try await group.next() {
                indexedResults.append(result)
                inFlight -= 1
                if let next = iterator.next() {
                    let (index, item) = next
                    group.addTask { (index, try await operation(item)) }
                    inFlight += 1
                }
            }
            return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
