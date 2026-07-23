//  DuplicationEngine.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT; original: _DuplicationEngine.swift)

/// Shared engine for executing exact/near duplication detection algorithms.
///
/// The requested clone types are passed explicitly rather than re-read from
/// the configuration so the orchestrator can carve `.near` out when it is
/// routed through the MinHash pipeline instead.
struct DuplicationEngine: Sendable {
  /// Configuration for detection.
  let configuration: DuplicationConfiguration

  /// Detect clones in the provided corpus.
  /// Supports `.exact` and `.near` clone types.
  func detectClones(in corpus: TokenCorpus, types: Set<CloneType>) -> [CloneGroup] {
    var cloneGroups: [CloneGroup] = []
    if types.contains(.exact) {
      cloneGroups += exactGroups(in: corpus)
    }
    if types.contains(.near) {
      cloneGroups += nearGroups(in: corpus)
    }
    return cloneGroups
  }

  /// Type-1 dispatch: rolling hash for the hash-based algorithms
  /// (minHashLSH uses it for Type-1), suffix array otherwise.
  private func exactGroups(in corpus: TokenCorpus) -> [CloneGroup] {
    switch configuration.algorithm {
    case .minHashLSH, .rollingHash:
      ExactCloneDetector(minimumTokens: configuration.minimumTokens)
        .detect(in: corpus)
    case .suffixArray:
      SuffixArrayCloneDetector(minimumTokens: configuration.minimumTokens)
        .detect(in: corpus)
    }
  }

  /// Type-2 dispatch: normalized rolling hash with a similarity gate, or
  /// the suffix array over the normalized id lane.
  private func nearGroups(in corpus: TokenCorpus) -> [CloneGroup] {
    switch configuration.algorithm {
    case .minHashLSH, .rollingHash:
      NearCloneDetector(
        minimumTokens: configuration.minimumTokens,
        minimumSimilarity: configuration.minimumSimilarity
      ).detect(in: corpus)
    case .suffixArray:
      SuffixArrayCloneDetector(minimumTokens: configuration.minimumTokens)
        .detectWithNormalization(in: corpus)
    }
  }
}
