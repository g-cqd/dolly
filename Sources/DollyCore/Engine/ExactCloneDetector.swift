//  ExactCloneDetector.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  D2: a thin policy over `RollingWindows.detect` — raw id lane, always
//  similarity 1.0. Windows are views into the file's record storage.

/// Detects exact code clones using rolling hash over the raw id lane.
struct ExactCloneDetector: Sendable {
  /// Minimum number of tokens to consider.
  let minimumTokens: Int

  init(minimumTokens: Int = 50) {
    self.minimumTokens = minimumTokens
  }

  /// Detect exact clones across the corpus.
  func detect(in corpus: TokenCorpus) -> [CloneGroup] {
    RollingWindows.detect(in: corpus, windowSize: minimumTokens, lane: .raw) { group, hash in
      CloneGroup(
        type: .exact,
        clones: group.map { $0.clone(tokenCount: minimumTokens) },
        similarity: 1.0,
        fingerprint: String(hash)
      )
    }
  }
}
