//  ExactCloneDetector.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - TokenWindow

/// A window of tokens with its hash and location.
struct TokenWindow: Sendable, GroupableWindow {
  let file: String
  let hash: UInt64
  let startIndex: Int
  let endIndex: Int
  let startLine: Int
  let startColumn: Int
  let endLine: Int
  let tokens: [String]

  func matches(_ other: Self) -> Bool {
    tokens == other.tokens
  }
}

// MARK: - ExactCloneDetector

/// Detects exact code clones using rolling hash.
struct ExactCloneDetector: Sendable {
  /// Minimum number of tokens to consider.
  let minimumTokens: Int

  init(minimumTokens: Int = 50) {
    self.minimumTokens = minimumTokens
  }

  /// Detect exact clones across multiple token sequences.
  func detect(in sequences: [TokenSequence]) -> [CloneGroup] {
    guard minimumTokens > 0 else { return [] }

    var windows: [TokenWindow] = []
    for sequence in sequences {
      let tokens = sequence.tokens
      guard tokens.count >= minimumTokens else { continue }
      let texts = tokens.map(\.text)
      windows += RollingWindows.scan(texts: texts, windowSize: minimumTokens) { start, hash in
        TokenWindow(
          file: sequence.file,
          hash: hash,
          startIndex: start,
          endIndex: start + minimumTokens - 1,
          startLine: tokens[start].line,
          startColumn: tokens[start].column,
          endLine: tokens[start + minimumTokens - 1].line,
          tokens: Array(texts[start..<(start + minimumTokens)])
        )
      }
    }

    return RollingWindows.detectGroups(
      windows: windows, overlapThreshold: minimumTokens / 2
    ) { group, hash in
      CloneGroup(
        type: .exact,
        clones: group.map { $0.clone(tokenCount: minimumTokens) },
        similarity: 1.0,
        fingerprint: String(hash)
      )
    }
  }
}
