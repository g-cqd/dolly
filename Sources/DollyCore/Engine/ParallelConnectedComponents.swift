//  ParallelConnectedComponents.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

import Foundation

// MARK: - ParallelConnectedComponents

/// Parallel connected component finding for clone graphs.
///
/// ## Design
///
/// - `AtomicBitmap` for thread-safe visited tracking
/// - Top-down chunked expansion
/// - Direction-optimizing for dense graphs (Beamer et al.)
/// - Atomic `testAndSet` to "claim" component roots
///
/// ## Performance Characteristics
///
/// - Small graphs (< minParallelSize): Sequential fallback
/// - Large graphs: Parallel BFS per component
/// - Dense graphs: Direction-optimizing reduces edge checks
enum ParallelConnectedComponents {
    // MARK: - Configuration

    /// Configuration for parallel connected component finding.
    struct Configuration: Sendable {
        /// Default configuration.
        static let `default` = Configuration()

        /// Minimum graph size to use parallel algorithm.
        var minParallelSize: Int

        /// Maximum concurrent tasks.
        var maxConcurrency: Int

        /// Alpha threshold for switching to bottom-up.
        /// Switch when: frontierEdges * alpha > remainingEdges
        var alpha: Int

        init(
            minParallelSize: Int = 100,
            maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
            alpha: Int = 14
        ) {
            self.minParallelSize = max(1, minParallelSize)
            self.maxConcurrency = max(1, maxConcurrency)
            self.alpha = max(1, alpha)
        }
    }

    // MARK: - Main Entry Point

    /// Find connected components using parallel BFS.
    ///
    /// Uses atomic visited bitmap to "claim" component roots, enabling
    /// concurrent BFS traversals without double-visiting.
    ///
    /// - Parameters:
    ///   - graph: Clone similarity graph.
    ///   - configuration: Parallel configuration.
    /// - Returns: Array of components (each component is an array of node indices).
    static func findComponents(
        graph: CloneSimilarityGraph,
        configuration: Configuration = .default
    ) async -> [[Int]] {
        let nodeCount = graph.nodeCount
        guard nodeCount > 0, graph.edgeCount > 0 else { return [] }

        // Use sequential for small graphs (overhead dominates)
        if nodeCount < configuration.minParallelSize {
            return findComponentsSequential(graph: graph)
        }

        // AtomicBitmap for thread-safe visited tracking
        let visited = AtomicBitmap(size: nodeCount)
        var components: [[Int]] = []

        // Sequential outer loop to find component roots
        // Each root is "claimed" via atomic testAndSet
        for seed in 0..<nodeCount {
            // Skip nodes with no edges (isolated documents)
            guard !graph.adjacency[seed].isEmpty else { continue }

            // Atomic claim of this root
            guard visited.testAndSet(seed) else { continue }

            // Parallel BFS for this component
            let component = await parallelBFS(
                seed: seed,
                graph: graph,
                visited: visited,
                configuration: configuration
            )

            // Only include components with 2+ nodes (actual clone groups)
            if component.count >= 2 {
                components.append(component)
            }
        }

        return components
    }

    // MARK: - Parallel BFS

    /// Parallel BFS for a single component.
    private static func parallelBFS(
        seed: Int,
        graph: CloneSimilarityGraph,
        visited: AtomicBitmap,
        configuration: Configuration
    ) async -> [Int] {
        var frontier = [seed]
        var component = [seed]

        // Track remaining edges for direction-optimizing (mirrors Beamer et al.)
        var remainingEdges = graph.edgeCount

        while !frontier.isEmpty {
            let frontierEdges = graph.totalOutEdges(from: frontier)

            // Direction-optimizing: use bottom-up for large frontiers
            // In undirected clone graph, reverse adjacency = adjacency
            let useBottomUp = DirectionOptimizingBFS.shouldSwitchToBottomUp(
                frontierEdges: frontierEdges,
                remainingEdges: remainingEdges,
                alpha: configuration.alpha
            )

            let nextFrontier: [Int]
            if frontier.count < configuration.maxConcurrency * 2 {
                // Sequential for small frontiers
                nextFrontier = expandSequential(frontier, graph: graph, visited: visited)
            } else if useBottomUp {
                // Bottom-up: unvisited nodes check if any neighbor is in frontier.
                // Rebind to `let` so the closure captures an immutable value.
                let frontierBitmap: [Bool] = {
                    var bits = [Bool](repeating: false, count: graph.nodeCount)
                    for index in frontier { bits[index] = true }
                    return bits
                }()
                nextFrontier = await bottomUpExpand(
                    frontierBitmap: frontierBitmap,
                    graph: graph,
                    visited: visited,
                    maxConcurrency: configuration.maxConcurrency
                )
            } else {
                // Top-down: parallel frontier expansion
                nextFrontier = await topDownExpand(
                    frontier,
                    graph: graph,
                    visited: visited,
                    maxConcurrency: configuration.maxConcurrency
                )
            }

            // Update remaining edges estimate
            remainingEdges -= frontierEdges

            component.append(contentsOf: nextFrontier)
            frontier = nextFrontier
        }

        return component
    }

    // MARK: - Expansion Methods

    /// Sequential expansion for small frontiers.
    private static func expandSequential(
        _ frontier: [Int],
        graph: CloneSimilarityGraph,
        visited: AtomicBitmap
    ) -> [Int] {
        var next: [Int] = []
        for node in frontier {
            for neighbor in graph.adjacency[node] {
                if visited.testAndSet(neighbor) {
                    next.append(neighbor)
                }
            }
        }
        return next
    }

    /// Top-down parallel expansion (uses shared ParallelFrontierExpansion).
    private static func topDownExpand(
        _ frontier: [Int],
        graph: CloneSimilarityGraph,
        visited: AtomicBitmap,
        maxConcurrency: Int
    ) async -> [Int] {
        await ParallelFrontierExpansion.expandParallel(
            frontier: frontier,
            maxConcurrency: maxConcurrency,
            getNeighbors: { graph.adjacency[$0] },
            testAndSetVisited: { visited.testAndSet($0) }
        )
    }

    /// Bottom-up parallel expansion.
    ///
    /// For undirected clone graphs, reverse adjacency = adjacency,
    /// so we just check if any neighbor is in the frontier.
    private static func bottomUpExpand(
        frontierBitmap: [Bool],
        graph: CloneSimilarityGraph,
        visited: AtomicBitmap,
        maxConcurrency: Int
    ) async -> [Int] {
        await ParallelFrontierExpansion.expandRangeParallel(
            nodeCount: graph.nodeCount,
            maxConcurrency: maxConcurrency
        ) { node in
            guard !visited.test(node) else { return false }

            for neighbor in graph.adjacency[node] {
                if frontierBitmap[neighbor] {
                    return visited.testAndSet(node)
                }
            }

            return false
        }
    }

    // MARK: - Sequential Fallback

    /// Sequential fallback for small graphs.
    private static func findComponentsSequential(graph: CloneSimilarityGraph) -> [[Int]] {
        var visited = [Bool](repeating: false, count: graph.nodeCount)
        var components: [[Int]] = []

        for seed in 0..<graph.nodeCount {
            guard !graph.adjacency[seed].isEmpty else { continue }
            guard !visited[seed] else { continue }
            visited[seed] = true

            var component = [seed]
            var queue = ArrayQueue([seed])  // O(1) popFirst

            while let node = queue.popFirst() {
                for neighbor in graph.adjacency[node] where !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                    component.append(neighbor)
                }
            }

            if component.count >= 2 {
                components.append(component)
            }
        }

        return components
    }
}
