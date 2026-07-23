//  CloneSimilarityGraph.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - CloneSimilarityGraph

/// Dense graph representation for clone similarity.
///
/// Leverages the fact that `ShingledDocument.id` values are contiguous
/// integers starting from 0, so no ID remapping is needed.
///
/// ## Design
///
/// - Adjacency stored as `[[Int]]` for cache efficiency
/// - No hashing overhead (direct array access)
/// - Suitable for AtomicBitmap-based visited tracking
///
/// ## Thread Safety
///
/// - Fully immutable after construction
/// - Safe for concurrent read access
struct CloneSimilarityGraph: Sendable {
  /// Adjacency list: adjacency[docId] = [neighborDocId, ...]
  let adjacency: [[Int]]

  /// Total edge count (each undirected edge counts as 2).
  let edgeCount: Int

  /// Create from verified clone pairs.
  ///
  /// - Parameters:
  ///   - pairs: Verified clone pairs.
  ///   - maxDocId: Maximum document ID (determines array size).
  init(pairs: [ClonePairInfo], maxDocId: Int) {
    var adj: [[Int]] = Array(repeating: [], count: maxDocId + 1)
    var edges = 0

    for pair in pairs {
      adj[pair.doc1.id].append(pair.doc2.id)
      adj[pair.doc2.id].append(pair.doc1.id)
      edges += 2  // Undirected = 2 directed edges per pair
    }

    self.adjacency = adj
    self.edgeCount = edges
  }

  /// Total node count.
  var nodeCount: Int { adjacency.count }

  /// Compute total out-edges from a set of nodes.
  ///
  /// - Parameter nodes: Array of node indices.
  /// - Returns: Sum of degrees.
  func totalOutEdges(from nodes: [Int]) -> Int {
    nodes.reduce(0) { total, node in
      guard node >= 0, node < adjacency.count else { return total }
      return total + adjacency[node].count
    }
  }
}
