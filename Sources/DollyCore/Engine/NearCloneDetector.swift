//  NearCloneDetector.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  D2: a thin policy over `RollingWindows.detect` — normalized id lane
//  for matching, raw ids for the similarity gate that separates true
//  near-clones from unrelated code sharing a normalized shape.

/// Detects near-clones using normalized token comparison.
struct NearCloneDetector: Sendable {
  /// Minimum number of tokens to consider.
  let minimumTokens: Int

  /// Minimum similarity threshold (0.0 to 1.0).
  let minimumSimilarity: Double

  init(
    minimumTokens: Int = 50,
    minimumSimilarity: Double = 0.8
  ) {
    self.minimumTokens = minimumTokens
    self.minimumSimilarity = minimumSimilarity
  }

  /// Detect near-clones across the corpus.
  func detect(in corpus: TokenCorpus) -> [CloneGroup] {
    RollingWindows.detect(in: corpus, windowSize: minimumTokens, lane: .norm) { group, hash in
      let similarity = Self.groupSimilarity(group)
      guard similarity >= minimumSimilarity else { return nil }
      return CloneGroup(
        type: .near,
        clones: group.map { $0.clone(tokenCount: minimumTokens) },
        similarity: similarity,
        fingerprint: String(hash)
      )
    }
  }

  /// Average pairwise Jaccard similarity of the raw token ids.
  private static func groupSimilarity(_ group: [RecordWindow]) -> Double {
    guard group.count >= 2 else { return 0 }

    var totalSimilarity = 0.0
    var comparisons = 0

    for (first, second) in group.pairCombinations() {
      totalSimilarity += CloneDetectionUtilities.jaccardSimilarity(first.rawIDs, second.rawIDs)
      comparisons += 1
    }

    return comparisons > 0 ? totalSimilarity / Double(comparisons) : 0
  }
}
