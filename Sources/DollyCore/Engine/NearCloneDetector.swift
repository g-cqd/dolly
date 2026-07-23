//  NearCloneDetector.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - NormalizedWindow

/// A window of normalized tokens with its hash.
struct NormalizedWindow: Sendable, GroupableWindow {
  let file: String
  let hash: UInt64
  let startIndex: Int
  let endIndex: Int
  let startLine: Int
  let startColumn: Int
  let endLine: Int
  let normalizedTokens: [String]
  let originalTokens: [String]

  func matches(_ other: Self) -> Bool {
    normalizedTokens == other.normalizedTokens
  }
}

// MARK: - NearCloneDetector

/// Detects near-clones using normalized token comparison.
struct NearCloneDetector: Sendable {
  /// Minimum number of tokens to consider.
  let minimumTokens: Int

  /// Minimum similarity threshold (0.0 to 1.0).
  let minimumSimilarity: Double

  /// Token normalizer.
  private let normalizer: TokenNormalizer

  init(
    minimumTokens: Int = 50,
    minimumSimilarity: Double = 0.8
  ) {
    self.minimumTokens = minimumTokens
    self.minimumSimilarity = minimumSimilarity
    normalizer = .default
  }

  /// Detect near-clones across multiple token sequences.
  func detect(in sequences: [TokenSequence]) -> [CloneGroup] {
    guard minimumTokens > 0 else { return [] }

    var windows: [NormalizedWindow] = []
    for normalized in sequences.map(normalizer.normalize) {
      guard normalized.tokens.count >= minimumTokens else { continue }
      let normalizedTexts = normalized.tokens.map(\.normalized)
      let originalTexts = normalized.tokens.map(\.original)
      let sourceTokens = normalized.tokens
      windows += RollingWindows.scan(
        texts: normalizedTexts, windowSize: minimumTokens
      ) { start, hash in
        let end = start + minimumTokens
        return NormalizedWindow(
          file: normalized.file,
          hash: hash,
          startIndex: start,
          endIndex: end - 1,
          startLine: sourceTokens[start].line,
          startColumn: sourceTokens[start].column,
          endLine: sourceTokens[end - 1].line,
          normalizedTokens: Array(normalizedTexts[start..<end]),
          originalTokens: Array(originalTexts[start..<end])
        )
      }
    }

    return RollingWindows.detectGroups(
      windows: windows, overlapThreshold: minimumTokens / 2
    ) { group, hash in
      // Similarity over the ORIGINAL tokens separates true near-clones
      // from unrelated code that merely shares a normalized shape.
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

  /// Average pairwise Jaccard similarity of the original token texts.
  private static func groupSimilarity(_ group: [NormalizedWindow]) -> Double {
    guard group.count >= 2 else { return 0 }

    var totalSimilarity = 0.0
    var comparisons = 0

    for (first, second) in group.pairCombinations() {
      totalSimilarity += CloneDetectionUtilities.jaccardSimilarity(
        first.originalTokens,
        second.originalTokens
      )
      comparisons += 1
    }

    return comparisons > 0 ? totalSimilarity / Double(comparisons) : 0
  }
}
