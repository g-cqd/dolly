//  SuffixArrayCloneDetector.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT), reshaped for the
//  interned pipeline (D2): the corpus intern table IS the suffix-array
//  alphabet, so the stream is built by copying integer ids — no per-token
//  dictionary, no string re-materialization.

// MARK: - SuffixArrayCloneDetector

/// Detects code clones using suffix array and LCP array analysis.
///
/// This detector provides deterministic, exhaustive detection of repeated
/// code sequences. Unlike hash-based approaches, it cannot produce false
/// positives and finds ALL repeats above the minimum threshold.
struct SuffixArrayCloneDetector: Sendable {
  /// Minimum number of tokens to consider as a clone.
  let minimumTokens: Int

  init(minimumTokens: Int = 50) {
    self.minimumTokens = minimumTokens
  }

  /// Which id lane of the records feeds the stream.
  private enum Lane {
    case raw
    case norm
  }

  /// Detect exact (Type-1) clones across the corpus.
  func detect(in corpus: TokenCorpus) -> [CloneGroup] {
    run(corpus, lane: .raw, cloneType: .exact)
  }

  /// Detect near (Type-2) clones over the normalized id lane.
  func detectWithNormalization(in corpus: TokenCorpus) -> [CloneGroup] {
    run(corpus, lane: .norm, cloneType: .near)
  }

  // MARK: - Shared pipeline

  /// The single suffix-array pipeline: build the concatenated id stream,
  /// find maximal repeat groups via the LCP array, and convert them to
  /// clone groups.
  private func run(_ corpus: TokenCorpus, lane: Lane, cloneType: CloneType) -> [CloneGroup] {
    // Safety: ensure minimumTokens is valid
    guard !corpus.sequences.isEmpty, minimumTokens > 0 else { return [] }

    // Drop macro-expansion sources from the input. Sequences whose file
    // contains a `#sourceLocation(...)` directive are typically the
    // output of Swift macros expanded into synthesised files; clone
    // groups spanning a macro's definition and its expansion are
    // expected, not actionable.
    let sequences = corpus.sequences.filter { !$0.hasSourceLocationDirective }
    guard !sequences.isEmpty else { return [] }

    let (tokens, refs) = buildStream(
      sequences: sequences, internCount: corpus.strings.count, lane: lane)
    guard tokens.count >= minimumTokens else { return [] }

    let suffixArray = SuffixArray(tokens: tokens)
    let lcpArray = LCPArray(suffixArray: suffixArray, tokens: tokens)
    let repeatGroups = lcpArray.findRepeatGroups(minLength: minimumTokens)

    return buildCloneGroups(
      repeatGroups: repeatGroups,
      refs: refs,
      sequences: sequences,
      strings: corpus.strings,
      cloneType: cloneType
    )
  }

  // MARK: - Stream Building

  /// Position in the concatenated stream: which file and which token.
  /// `tokenIndex == -1` marks a separator.
  private struct StreamRef {
    let fileIndex: Int32
    let tokenIndex: Int32
  }

  /// Build the concatenated id stream.
  ///
  /// Ids are the corpus intern ids shifted by +1 (0 is the SA-IS
  /// sentinel); unique separator ids live above the intern range and are
  /// emitted between files AND at every top-level declaration boundary.
  /// The boundary separators make same-file declaration pairs isomorphic
  /// to cross-file pairs: without them, 3+ normalized-identical adjacent
  /// declarations form one periodic run whose overlapping shifted repeats
  /// (length 2L-p) outrank the true group (length L) in
  /// `mergeOverlappingGroups`, after which `filterOverlappingClones`
  /// reduces the survivor to a single location and the group is dropped.
  /// Periodic content inside ONE declaration still self-overlaps and is
  /// still filtered — that protection is intentional and unchanged.
  private func buildStream(
    sequences: [TokenSequence], internCount: Int, lane: Lane
  ) -> ([Int], [StreamRef]) {
    var tokens: [Int] = []
    var refs: [StreamRef] = []
    let capacity = sequences.reduce(0) { $0 + $1.records.count + $1.boundaries.count + 1 }
    tokens.reserveCapacity(capacity)
    refs.reserveCapacity(capacity)

    var nextSeparator = internCount + 1
    func appendSeparator(fileIndex: Int32) {
      tokens.append(nextSeparator)
      nextSeparator += 1
      refs.append(StreamRef(fileIndex: fileIndex, tokenIndex: -1))
    }

    for (fileIndex, sequence) in sequences.enumerated() {
      let fi = Int32(fileIndex)
      let boundaries = sequence.boundaries
      var nextBoundary = 0

      for (tokenIdx, record) in sequence.records.enumerated() {
        while nextBoundary < boundaries.count, boundaries[nextBoundary] < tokenIdx {
          nextBoundary += 1
        }
        if nextBoundary < boundaries.count, boundaries[nextBoundary] == tokenIdx {
          nextBoundary += 1
          // The file separator already guards the head of the file.
          if tokenIdx > 0 {
            appendSeparator(fileIndex: fi)
          }
        }

        let id = lane == .raw ? record.rawID : record.normID
        tokens.append(Int(id) + 1)
        refs.append(StreamRef(fileIndex: fi, tokenIndex: Int32(tokenIdx)))
      }

      // Separator between files (unique sentinel).
      appendSeparator(fileIndex: fi)
    }

    return (tokens, refs)
  }

  // MARK: - Clone Group Conversion

  /// Common clone group building logic.
  private func buildCloneGroups(
    repeatGroups: [RepeatGroup],
    refs: [StreamRef],
    sequences: [TokenSequence],
    strings: [String],
    cloneType: CloneType
  ) -> [CloneGroup] {
    var cloneGroups: [CloneGroup] = []

    for group in repeatGroups {
      let validPositions = group.positions.filter { pos in
        isValidPosition(pos, length: group.length, refs: refs)
      }

      guard validPositions.count >= 2 else { continue }

      let cloneLocations = validPositions.compactMap { pos in
        createCloneLocation(position: pos, length: group.length, refs: refs, sequences: sequences)
      }

      let filteredLocations = filterOverlappingClones(cloneLocations)

      guard filteredLocations.count >= 2 else { continue }

      let clones = filteredLocations.map { loc in
        Clone(
          file: loc.file,
          startLine: loc.startLine,
          startColumn: loc.startColumn,
          endLine: loc.endLine,
          tokenCount: group.length,
          codeSnippet: ""
        )
      }

      let fingerprint = generateFingerprint(
        position: validPositions[0],
        length: min(group.length, 20),
        refs: refs,
        sequences: sequences,
        strings: strings
      )

      cloneGroups.append(
        CloneGroup(
          type: cloneType,
          clones: clones,
          similarity: 1.0,
          fingerprint: fingerprint
        ))
    }

    return cloneGroups.deduplicated()
  }

  // MARK: - Helper Methods

  /// Check if a position is valid (doesn't cross file boundaries).
  ///
  /// A valid repeat can never CONTAIN a separator — separator ids are
  /// unique, so any range holding one occurs exactly once in the stream —
  /// which is why checking the endpoints suffices.
  private func isValidPosition(_ pos: Int, length: Int, refs: [StreamRef]) -> Bool {
    guard pos >= 0, pos + length <= refs.count else { return false }

    let start = refs[pos]
    let end = refs[pos + length - 1]
    return start.fileIndex == end.fileIndex && start.tokenIndex >= 0 && end.tokenIndex >= 0
  }

  /// Create a clone location from a stream position.
  private func createCloneLocation(
    position: Int,
    length: Int,
    refs: [StreamRef],
    sequences: [TokenSequence]
  ) -> CloneLocation? {
    guard isValidPosition(position, length: length, refs: refs) else { return nil }

    let start = refs[position]
    let end = refs[position + length - 1]
    let sequence = sequences[Int(start.fileIndex)]
    let startRecord = sequence.records[Int(start.tokenIndex)]
    let endRecord = sequence.records[Int(end.tokenIndex)]

    return CloneLocation(
      file: sequence.file,
      fileIndex: Int(start.fileIndex),
      startLine: Int(startRecord.line),
      startColumn: Int(startRecord.column),
      endLine: Int(endRecord.line),
      startPosition: position,
      endPosition: position + length - 1
    )
  }

  /// Filter same-file occurrences that overlap an already-kept one.
  ///
  /// Disjoint duplicated regions never overlap; overlapping occurrences
  /// only arise from periodic content (uniform literal lists, runs of
  /// near-identical statements) matching a shifted copy of itself. That
  /// is self-similarity, not duplication a caller could extract, so any
  /// overlap disqualifies the later occurrence.
  private func filterOverlappingClones(_ locations: [CloneLocation]) -> [CloneLocation] {
    guard locations.count > 1 else { return locations }

    // Sort by file then start position
    let sorted = locations.sorted { lhs, rhs in
      if lhs.fileIndex != rhs.fileIndex {
        return lhs.fileIndex < rhs.fileIndex
      }
      return lhs.startPosition < rhs.startPosition
    }

    var result: [CloneLocation] = []
    var lastByFile: [Int: CloneLocation] = [:]

    for loc in sorted {
      if let last = lastByFile[loc.fileIndex], loc.startPosition <= last.endPosition {
        continue
      }

      result.append(loc)
      lastByFile[loc.fileIndex] = loc
    }

    return result
  }

  /// Generate a fingerprint for a clone. Token text materializes here —
  /// at reporting time — from the corpus intern table.
  private func generateFingerprint(
    position: Int,
    length: Int,
    refs: [StreamRef],
    sequences: [TokenSequence],
    strings: [String]
  ) -> String {
    var parts: [String] = []
    for i in position..<min(position + length, refs.count) {
      let ref = refs[i]
      guard ref.tokenIndex >= 0 else { continue }
      let record = sequences[Int(ref.fileIndex)].records[Int(ref.tokenIndex)]
      parts.append(strings[Int(record.rawID)])
    }
    return String(FNV1a.hash(parts.joined(separator: " ")))
  }
}

// MARK: - CloneLocation

/// Location of a clone occurrence.
struct CloneLocation: Sendable {
  let file: String
  let fileIndex: Int
  let startLine: Int
  let startColumn: Int
  let endLine: Int
  let startPosition: Int
  let endPosition: Int
}
