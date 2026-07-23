//  ParallelFrontierExpansion.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - ParallelFrontierExpansion

/// Generic parallel frontier expansion for BFS-like graph traversals.
///
/// This utility provides a reusable parallel expansion pattern that can be used
/// with any graph representation that provides adjacency lists and atomic visited tracking.
enum ParallelFrontierExpansion {
  /// Expand a frontier in parallel using chunked TaskGroup processing.
  ///
  /// This implements the top-down BFS expansion pattern where each frontier node
  /// expands outward to its neighbors in parallel.
  ///
  /// - Parameters:
  ///   - frontier: Current frontier nodes to expand.
  ///   - maxConcurrency: Maximum concurrent tasks.
  ///   - getNeighbors: Closure to get neighbors for a node.
  ///   - testAndSetVisited: Atomic closure that returns true if node was newly visited.
  /// - Returns: Next frontier of newly discovered nodes.
  static func expandParallel(
    frontier: [Int],
    maxConcurrency: Int,
    getNeighbors: @escaping @Sendable (Int) -> [Int],
    testAndSetVisited: @escaping @Sendable (Int) -> Bool
  ) async -> [Int] {
    let frontier = frontier
    return await collectChunked(totalCount: frontier.count, maxConcurrency: maxConcurrency) {
      node in
      var discovered: [Int] = []
      for neighbor in getNeighbors(frontier[node]) where testAndSetVisited(neighbor) {
        discovered.append(neighbor)
      }
      return discovered
    }
  }

  /// Expand a range of nodes in parallel using chunked TaskGroup processing.
  ///
  /// This implements the bottom-up BFS expansion pattern where unvisited nodes
  /// check if they should be added to the frontier.
  ///
  /// - Parameters:
  ///   - nodeCount: Total number of nodes in the graph.
  ///   - maxConcurrency: Maximum concurrent tasks.
  ///   - shouldExpand: Closure that returns true if a node should be added to next frontier.
  /// - Returns: Next frontier of newly discovered nodes.
  static func expandRangeParallel(
    nodeCount: Int,
    maxConcurrency: Int,
    shouldExpand: @escaping @Sendable (Int) -> Bool
  ) async -> [Int] {
    await collectChunked(totalCount: nodeCount, maxConcurrency: maxConcurrency) { node in
      shouldExpand(node) ? [node] : []
    }
  }

  /// Shared chunked TaskGroup skeleton: split `0..<totalCount` into one
  /// chunk per worker, run `discover` per index with periodic
  /// cancellation checkpoints, and concatenate the partial results.
  private static func collectChunked(
    totalCount: Int,
    maxConcurrency: Int,
    discover: @escaping @Sendable (Int) -> [Int]
  ) async -> [Int] {
    let chunkSize = max(1, totalCount / maxConcurrency)

    return await withTaskGroup(of: [Int].self) { group in
      for chunk in chunkedRanges(totalCount: totalCount, chunkSize: chunkSize) {
        group.addTask {
          var localNext: [Int] = []
          var processedNodes = 0

          for index in chunk {
            localNext.append(contentsOf: discover(index))

            processedNodes += 1
            if await TaskCooperation.checkpoint(iteration: processedNodes) {
              break
            }
          }
          return localNext
        }
      }

      var result: [Int] = []
      for await partial in group {
        result.append(contentsOf: partial)
        // Propagate cancellation to peer tasks once any worker
        // observes it. Without this, sibling tasks keep running
        // their full chunk before the group can return.
        if Task.isCancelled {
          group.cancelAll()
        }
      }
      return result
    }
  }
}
