//  EmbeddingCloneDiscovery.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  Builds an approximate-nearest-neighbor index over snippet embeddings and
//  surfaces clone groups via top-k queries:
//    1. Embed every snippet via `provider`.
//    2. Insert into `HNSWIndex<Int>` keyed by snippet index.
//    3. For each snippet, query top-k; pairs whose cosine >= threshold (and,
//       optionally, token Jaccard >= minTokenOverlap) form similarity edges.
//    4. Union-find the edges into connected components.
//    5. Drop singletons; emit one `CloneGroup` (type `.semantic`) per
//       component with `similarity` = average pairwise cosine.

import Foundation

// MARK: - EmbeddingSnippet

/// A snippet of source code paired with its location, ready to be embedded.
struct EmbeddingSnippet: Sendable, Hashable {
  let file: String
  let startLine: Int
  let endLine: Int
  let tokenCount: Int
  let code: String
}

// MARK: - EmbeddingCloneDiscovery

struct EmbeddingCloneDiscovery: Sendable {
  let hnswConfiguration: HNSWConfiguration

  init(hnswConfiguration: HNSWConfiguration = .default) {
    self.hnswConfiguration = hnswConfiguration
  }

  /// Discover clone groups via embedding-based ANN search.
  ///
  /// - Parameters:
  ///   - snippets: Snippets to embed and index.
  ///   - provider: Embedding provider (NLContextual, HF, deterministic).
  ///   - k: Top-k neighbors per query. Larger = better recall, slower.
  ///   - similarityThreshold: Minimum cosine similarity to keep a pair.
  ///   - minTokenOverlap: Minimum Jaccard over the snippets' identifier token
  ///     sets to keep a pair. `0.0` disables the gate.
  ///   - maxGroupSize: Hard ceiling on component membership; a connected
  ///     component larger than this is discarded as embedding-collapse noise
  ///     rather than reported. `<= 0` disables the cap.
  /// - Returns: `[CloneGroup]` with `type == .semantic`.
  func discover(
    snippets: [EmbeddingSnippet],
    provider: any SemanticEmbeddingProvider,
    k: Int = 10,
    similarityThreshold: Double = 0.92,
    minTokenOverlap: Double = 0.0,
    maxGroupSize: Int = 0
  ) async throws -> [CloneGroup] {
    guard snippets.count >= 2, k > 0, provider.embeddingDimension > 0 else { return [] }

    let vectors = try await provider.embed(snippets: snippets.map(\.code))
    guard vectors.count == snippets.count else { return [] }

    var index = HNSWIndex<Int>(
      dimension: provider.embeddingDimension,
      configuration: hnswConfiguration
    )
    for (i, vector) in vectors.enumerated() {
      index.insert(id: i, vector: vector)
    }

    var pairs: [(Int, Int, Float)] = []
    var seenPair = Set<UInt64>()

    for i in 0..<snippets.count {
      let results = index.search(query: vectors[i], k: k + 1)
      for result in results {
        let j = result.id
        if j == i { continue }
        if shouldSkipPair(snippets[i], snippets[j]) { continue }
        if Double(result.similarity) < similarityThreshold { continue }

        // Multi-signal fusion: optionally require lexical co-occurrence in
        // addition to embedding agreement.
        if minTokenOverlap > 0 {
          let jaccard = TokenJaccard.similarity(snippets[i].code, snippets[j].code)
          if jaccard < minTokenOverlap { continue }
        }

        let a = min(i, j)
        let b = max(i, j)
        let key = (UInt64(a) << 32) | UInt64(b)
        if seenPair.insert(key).inserted {
          pairs.append((a, b, result.similarity))
        }
      }
    }

    guard !pairs.isEmpty else { return [] }

    var uf = UnionFind(count: snippets.count)
    for (a, b, _) in pairs { uf.union(a, b) }

    var pairsByRoot: [Int: [(Int, Int, Float)]] = [:]
    var memberSet: [Int: Set<Int>] = [:]
    for (a, b, sim) in pairs {
      let root = uf.find(a)
      memberSet[root, default: []].insert(a)
      memberSet[root, default: []].insert(b)
      pairsByRoot[root, default: []].append((a, b, sim))
    }

    var groups: [CloneGroup] = []
    groups.reserveCapacity(memberSet.count)
    for (root, members) in memberSet where members.count >= 2 {
      // Hard group-size cap: a component this large is the embedding-collapse
      // pathology (many plain declarations fused into one cone), not a real
      // clone family — drop it wholesale rather than emit hundreds of noise
      // pairs. Genuine families and code-trained bundle models stay well
      // under any sane cap, so this is a no-op for them.
      if maxGroupSize > 0, members.count > maxGroupSize { continue }
      let indices = members.sorted()
      let groupPairs = pairsByRoot[root] ?? []
      let avgSimilarity =
        groupPairs.isEmpty
        ? similarityThreshold
        : Double(groupPairs.reduce(Float(0)) { $0 + $1.2 }) / Double(groupPairs.count)

      let clones = indices.map { idx -> Clone in
        let snippet = snippets[idx]
        return Clone(
          file: snippet.file,
          startLine: snippet.startLine,
          endLine: snippet.endLine,
          tokenCount: snippet.tokenCount,
          codeSnippet: snippet.code
        )
      }
      let fingerprint = "embedding-" + indices.map(String.init).joined(separator: "-")
      groups.append(
        CloneGroup(
          type: .semantic, clones: clones, similarity: avgSimilarity, fingerprint: fingerprint)
      )
    }
    return groups
  }

  /// Filter out pairs in the same file with overlapping line ranges.
  private func shouldSkipPair(_ a: EmbeddingSnippet, _ b: EmbeddingSnippet) -> Bool {
    guard a.file == b.file else { return false }
    return !(a.endLine < b.startLine || b.endLine < a.startLine)
  }
}

// MARK: - UnionFind

/// Union-find with path compression for grouping clone pairs.
struct UnionFind: Sendable {
  private var parent: [Int]
  private var rank: [Int]

  init(count: Int) {
    parent = Array(0..<count)
    rank = [Int](repeating: 0, count: count)
  }

  mutating func find(_ x: Int) -> Int {
    if parent[x] != x {
      parent[x] = find(parent[x])
    }
    return parent[x]
  }

  mutating func union(_ a: Int, _ b: Int) {
    let rootA = find(a)
    let rootB = find(b)
    guard rootA != rootB else { return }
    if rank[rootA] < rank[rootB] {
      parent[rootA] = rootB
    } else if rank[rootA] > rank[rootB] {
      parent[rootB] = rootA
    } else {
      parent[rootB] = rootA
      rank[rootA] += 1
    }
  }
}
