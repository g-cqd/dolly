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

  /// Detect clones in the provided token sequences.
  /// Supports `.exact` and `.near` clone types.
  func detectClones(in sequences: [TokenSequence], types: Set<CloneType>) -> [CloneGroup] {
    var cloneGroups: [CloneGroup] = []

    if types.contains(.exact) {
      switch configuration.algorithm {
      case .minHashLSH,
        .rollingHash:
        // Rolling hash detection (minHashLSH uses this for Type-1 clones)
        let detector = ExactCloneDetector(minimumTokens: configuration.minimumTokens)
        cloneGroups.append(contentsOf: detector.detect(in: sequences))

      case .suffixArray:
        // High-performance suffix array detection
        let detector = SuffixArrayCloneDetector(
          minimumTokens: configuration.minimumTokens,
          normalizeForType2: false
        )
        cloneGroups.append(contentsOf: detector.detect(in: sequences))
      }
    }

    if types.contains(.near) {
      switch configuration.algorithm {
      case .minHashLSH,
        .rollingHash:
        // Near clone detection (minHashLSH uses this for Type-2 clones)
        let detector = NearCloneDetector(
          minimumTokens: configuration.minimumTokens,
          minimumSimilarity: configuration.minimumSimilarity
        )
        cloneGroups.append(contentsOf: detector.detect(in: sequences))

      case .suffixArray:
        // Suffix array with normalized tokens for Type-2 detection
        let detector = SuffixArrayCloneDetector(
          minimumTokens: configuration.minimumTokens,
          normalizeForType2: true
        )
        cloneGroups.append(contentsOf: detector.detectWithNormalization(in: sequences))
      }
    }

    return cloneGroups
  }
}
