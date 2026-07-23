//  DuplicationDetector.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  Trimmed for dolly: the semantic-embedding pipeline, incremental cache,
//  streaming/backpressure verifier, and file-IO entry points are excised.
//  The detector operates on pre-extracted `TokenSequence` values; the
//  Analyzer owns file reading and parsing.

// MARK: - CloneType

/// Types of code clones.
enum CloneType: String, Sendable, Codable, CaseIterable {
  /// Exact clones - identical code except whitespace/comments (Type-1).
  case exact

  /// Near clones - similar code with renamed identifiers (Type-2).
  case near

  /// Structural clones - similar token shingles above the similarity
  /// threshold without being line-for-line copies (Type-3).
  case structural
}

// MARK: - Clone

/// Represents a detected code clone.
struct Clone: Sendable, Codable {
  /// File containing the clone.
  let file: String

  /// Starting line number.
  let startLine: Int

  /// Column of the first token of the clone (1-based).
  let startColumn: Int

  /// Ending line number.
  let endLine: Int

  /// Number of tokens in the clone.
  let tokenCount: Int

  /// The actual code snippet.
  let codeSnippet: String

  init(
    file: String,
    startLine: Int,
    startColumn: Int = 1,
    endLine: Int,
    tokenCount: Int,
    codeSnippet: String
  ) {
    self.file = file
    self.startLine = startLine
    self.startColumn = startColumn
    self.endLine = endLine
    self.tokenCount = tokenCount
    self.codeSnippet = codeSnippet
  }
}

// MARK: - CloneGroup

/// A group of related clones.
struct CloneGroup: Sendable, Codable {
  /// Type of clone.
  let type: CloneType

  /// Clones in this group.
  let clones: [Clone]

  /// Similarity score (1.0 for exact, lower for near/structural).
  let similarity: Double

  /// Hash or fingerprint identifying this clone group.
  let fingerprint: String

  init(
    type: CloneType,
    clones: [Clone],
    similarity: Double,
    fingerprint: String
  ) {
    self.type = type
    self.clones = clones
    self.similarity = similarity
    self.fingerprint = fingerprint
  }

  /// Number of occurrences.
  var occurrences: Int { clones.count }

  /// Total duplicated lines.
  var duplicatedLines: Int {
    clones.reduce(0) { $0 + ($1.endLine - $1.startLine + 1) }
  }
}

// MARK: - DetectionAlgorithm

/// Algorithm used for clone detection.
enum DetectionAlgorithm: String, Sendable, Codable, CaseIterable {
  /// Rolling hash (Rabin-Karp) - fast, may have false positives.
  case rollingHash

  /// Suffix array (SA-IS) - deterministic, exhaustive, no false positives.
  case suffixArray

  /// MinHash + LSH - probabilistic, O(n) complexity for Type-3 clones.
  case minHashLSH
}

// MARK: - DuplicationConfiguration

/// Configuration for duplication detection.
struct DuplicationConfiguration: Sendable {
  /// Default configuration: exhaustive suffix-array detection for
  /// exact/near clones plus MinHash+LSH structural detection.
  static let `default` = Self()

  /// Minimum tokens to consider as a clone. Clamped to [1, 10000].
  var minimumTokens: Int

  /// Types of clones to detect.
  var cloneTypes: Set<CloneType>

  /// Minimum similarity for near/structural clones (0.0-1.0).
  var minimumSimilarity: Double

  /// Detection algorithm for exact/near clones.
  var algorithm: DetectionAlgorithm

  init(
    minimumTokens: Int = 50,
    cloneTypes: Set<CloneType> = [.exact, .near, .structural],
    minimumSimilarity: Double = 0.8,
    algorithm: DetectionAlgorithm = .suffixArray
  ) {
    // Validate and clamp to safe ranges.
    self.minimumTokens = min(max(minimumTokens, 1), 10000)
    self.cloneTypes = cloneTypes
    self.minimumSimilarity = min(max(minimumSimilarity, 0.0), 1.0)
    self.algorithm = algorithm
  }
}

// MARK: - DuplicationDetector

/// Detects code duplication across pre-extracted token sequences.
struct DuplicationDetector: Sendable {
  /// Configuration for detection.
  let configuration: DuplicationConfiguration

  /// Concurrency configuration.
  let concurrency: ConcurrencyConfiguration

  init(
    configuration: DuplicationConfiguration = .default,
    concurrency: ConcurrencyConfiguration = .default
  ) {
    self.configuration = configuration
    self.concurrency = concurrency
  }

  /// Detect clones in the given corpus.
  ///
  /// The structural stage is independent of the serial exact+near
  /// suffix-array work, so it runs concurrently (`async let`) and joins
  /// before reporting; group order in the result is unchanged.
  ///
  /// - Parameter corpus: Assembled token corpus from parsed files.
  /// - Returns: Array of clone groups found.
  func detectClones(in corpus: TokenCorpus) async -> [CloneGroup] {
    // When near clones are requested under the minHashLSH algorithm,
    // route them through the structural detector rather than the
    // token-window engine — and relabel its inherently structural
    // output as `.near` to match the requested clone type.
    let routeNearThroughStructural =
      configuration.cloneTypes.contains(.near)
      && configuration.algorithm == .minHashLSH
    var engineTypes = configuration.cloneTypes.intersection([.exact, .near])
    if routeNearThroughStructural {
      engineTypes.remove(.near)
    }

    async let structuralClones = structuralGroups(in: corpus)

    var cloneGroups: [CloneGroup] = []
    if !engineTypes.isEmpty {
      let engine = DuplicationEngine(configuration: configuration)
      cloneGroups.append(contentsOf: engine.detectClones(in: corpus, types: engineTypes))
    }

    if routeNearThroughStructural {
      let nearClones = await detectStructuralClones(in: corpus.sequences, labelledAs: .near)
      cloneGroups.append(contentsOf: nearClones)
    }

    cloneGroups.append(contentsOf: await structuralClones)

    return cloneGroups
  }

  /// The structural stage, hopped onto the concurrent executor so it
  /// genuinely overlaps the caller's serial suffix-array work.
  @concurrent private func structuralGroups(in corpus: TokenCorpus) async -> [CloneGroup] {
    guard configuration.cloneTypes.contains(.structural) else { return [] }
    return await detectStructuralClones(in: corpus.sequences, labelledAs: .structural)
  }

  /// Run structural clone detection and relabel its inherently
  /// structural output to the requested clone type.
  private func detectStructuralClones(
    in sequences: [TokenSequence],
    labelledAs label: CloneType
  ) async -> [CloneGroup] {
    let detector = StructuralCloneDetector(
      minimumTokens: configuration.minimumTokens,
      shingleSize: 5,
      minimumSimilarity: configuration.minimumSimilarity,
      parallelConfig: ParallelCloneConfiguration(
        maxConcurrency: concurrency.maxConcurrentTasks
      )
    )
    let groups = await detector.detect(in: sequences)
    guard label != .structural else { return groups }
    return groups.map { group in
      CloneGroup(
        type: label,
        clones: group.clones,
        similarity: group.similarity,
        fingerprint: group.fingerprint
      )
    }
  }
}

// MARK: - Clone Group Utilities

extension [CloneGroup] {
  /// Remove duplicate clone groups based on their location fingerprints.
  ///
  /// Two clone groups are considered duplicates if they contain clones
  /// at the exact same file locations.
  func deduplicated() -> [CloneGroup] {
    uniquedBy { group in
      group.clones
        .map { "\($0.file):\($0.startLine)-\($0.endLine)" }
        .sorted()
        .joined(separator: "|")
    }
  }
}

// MARK: - GroupableWindow

/// Protocol for windows that can be grouped by the clone detection algorithm.
protocol GroupableWindow {
  /// The file this window is from.
  var file: String { get }
  /// The window's content hash (bucket key).
  var hash: UInt64 { get }
  /// Start index in the file.
  var startIndex: Int { get }
  /// End index in the file.
  var endIndex: Int { get }
  /// First line of the window (1-based).
  var startLine: Int { get }
  /// Column of the window's first token (1-based).
  var startColumn: Int { get }
  /// Last line of the window (1-based).
  var endLine: Int { get }
  /// Check if this window matches another for grouping purposes.
  func matches(_ other: Self) -> Bool
}

extension GroupableWindow {
  /// Clone record at this window's location.
  func clone(tokenCount: Int) -> Clone {
    Clone(
      file: file,
      startLine: startLine,
      startColumn: startColumn,
      endLine: endLine,
      tokenCount: tokenCount,
      codeSnippet: ""
    )
  }
}

// MARK: - CloneDetectionUtilities

/// Shared utilities for clone detection algorithms.
enum CloneDetectionUtilities {
  /// Check if two code windows overlap significantly.
  ///
  /// - Parameters:
  ///   - start1: Start index of first window.
  ///   - end1: End index of first window.
  ///   - start2: Start index of second window.
  ///   - end2: End index of second window.
  ///   - threshold: Minimum overlap to be considered significant.
  /// - Returns: True if the windows overlap more than the threshold.
  static func hasSignificantOverlap(
    start1: Int,
    end1: Int,
    start2: Int,
    end2: Int,
    threshold: Int
  ) -> Bool {
    let overlap = max(0, min(end1, end2) - max(start1, start2) + 1)
    return overlap > threshold
  }

  /// Calculate Jaccard similarity between two token sequences (interned
  /// ids or any other hashable token representation).
  ///
  /// - Parameters:
  ///   - tokens1: First token sequence.
  ///   - tokens2: Second token sequence.
  /// - Returns: Jaccard similarity coefficient (0.0 to 1.0).
  static func jaccardSimilarity<Token: Hashable>(
    _ tokens1: some Sequence<Token>, _ tokens2: some Sequence<Token>
  ) -> Double {
    let set1 = Set(tokens1)
    let set2 = Set(tokens2)

    let intersection = set1.intersection(set2).count
    let union = set1.union(set2).count

    return union > 0 ? Double(intersection) / Double(union) : 0
  }

  /// Group matching windows, skipping overlapping windows in the same file.
  ///
  /// - Parameters:
  ///   - windows: Array of windows to group.
  ///   - overlapThreshold: Minimum overlap to skip (typically minimumTokens / 2).
  /// - Returns: Groups of matching windows (groups with < 2 windows are excluded).
  static func groupMatchingWindows<W: GroupableWindow>(
    _ windows: [W],
    overlapThreshold: Int
  ) -> [[W]] {
    var groups: [[W]] = []
    var used = Set<Int>()

    for (i, window1) in windows.enumerated() {
      guard !used.contains(i) else { continue }

      var group = [window1]
      used.insert(i)

      for (j, window2) in windows.enumerated() where j > i && !used.contains(j) {
        // Skip if same file and overlapping
        if window1.file == window2.file {
          if hasSignificantOverlap(
            start1: window1.startIndex,
            end1: window1.endIndex,
            start2: window2.startIndex,
            end2: window2.endIndex,
            threshold: overlapThreshold
          ) {
            continue
          }
        }

        // Verify windows match
        if window1.matches(window2) {
          group.append(window2)
          used.insert(j)
        }
      }

      if group.count >= 2 {
        groups.append(group)
      }
    }

    return groups
  }
}
