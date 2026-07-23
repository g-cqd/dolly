//  SuffixArrayCloneDetector.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - TokenAccessorResult

/// Result from the token accessor closure.
struct TokenAccessorResult: Sendable {
  let text: String
  let original: String
  let line: Int
  let column: Int
}

// MARK: - TokenStreamResult

/// Result of building a concatenated token stream.
struct TokenStreamResult: Sendable {
  let tokens: [Int]
  let infos: [TokenStreamInfo]
}

// MARK: - SuffixArrayCloneDetector

/// Detects code clones using suffix array and LCP array analysis.
///
/// This detector provides deterministic, exhaustive detection of repeated
/// code sequences. Unlike hash-based approaches, it cannot produce false
/// positives and finds ALL repeats above the minimum threshold.
struct SuffixArrayCloneDetector: Sendable {
  /// Minimum number of tokens to consider as a clone.
  let minimumTokens: Int

  /// Whether to normalize tokens for Type-2 detection.
  let normalizeForType2: Bool

  /// Token normalizer for Type-2 detection.
  private let normalizer: TokenNormalizer

  init(minimumTokens: Int = 50, normalizeForType2: Bool = false) {
    self.minimumTokens = minimumTokens
    self.normalizeForType2 = normalizeForType2
    normalizer = .default
  }

  /// Detect exact (Type-1) clones across multiple token sequences.
  ///
  /// - Parameter sequences: Token sequences from parsed files.
  /// - Returns: Array of detected clone groups.
  func detect(in sequences: [TokenSequence]) -> [CloneGroup] {
    run(sequences, normalized: false)
  }

  /// Detect clones with normalized tokens for Type-2 detection.
  ///
  /// - Parameter sequences: Token sequences from parsed files.
  /// - Returns: Array of detected clone groups.
  func detectWithNormalization(in sequences: [TokenSequence]) -> [CloneGroup] {
    run(sequences, normalized: true)
  }

  // MARK: - Shared pipeline

  /// The single suffix-array pipeline: build the concatenated stream
  /// (raw or normalized), find maximal repeat groups via the LCP array,
  /// and convert them to clone groups.
  private func run(_ sequences: [TokenSequence], normalized: Bool) -> [CloneGroup] {
    // Safety: ensure minimumTokens is valid
    guard !sequences.isEmpty, minimumTokens > 0 else { return [] }

    // Drop macro-expansion sources from the input. Sequences whose
    // file contains a `#sourceLocation(...)` directive are typically
    // the output of Swift macros expanded into synthesised files;
    // clone groups spanning a macro's definition and its expansion
    // are expected, not actionable.
    let filteredSequences = sequences.filter { !Self.containsSourceLocationDirective($0) }
    guard !filteredSequences.isEmpty else { return [] }

    if normalized {
      return detectStream(
        sequences: filteredSequences.map { normalizer.normalize($0) },
        cloneType: .near
      ) { token in
        TokenAccessorResult(
          text: token.normalized, original: token.original,
          line: token.line, column: token.column)
      }
    }
    return detectStream(sequences: filteredSequences, cloneType: .exact) { token in
      TokenAccessorResult(
        text: token.text, original: token.text,
        line: token.line, column: token.column)
    }
  }

  /// Suffix-array detection over one concatenated stream, generic over
  /// the token payload so the raw and normalized passes share every step.
  private func detectStream<Token: Sendable & Hashable>(
    sequences: [TokenSequenceOf<Token>],
    cloneType: CloneType,
    accessor: (Token) -> TokenAccessorResult
  ) -> [CloneGroup] {
    let streamResult = buildStream(from: sequences) { seq, index in
      accessor(seq.tokens[index])
    }
    guard streamResult.tokens.count >= minimumTokens else { return [] }

    let suffixArray = SuffixArray(tokens: streamResult.tokens)
    let lcpArray = LCPArray(suffixArray: suffixArray, tokens: streamResult.tokens)
    let repeatGroups = lcpArray.findRepeatGroups(minLength: minimumTokens)

    return buildCloneGroups(
      repeatGroups: repeatGroups,
      tokenInfos: streamResult.infos,
      cloneType: cloneType
    ) { position, length in
      createCloneLocation(
        position: position, length: length,
        tokenInfos: streamResult.infos, sequences: sequences)
    }
  }

  /// Return `true` when the sequence's source lines contain a
  /// `#sourceLocation(...)` directive — the marker the Swift compiler
  /// emits at the top of macro-expansion files. Conservative: any
  /// occurrence is treated as a macro-expansion signal.
  static func containsSourceLocationDirective(_ sequence: TokenSequence) -> Bool {
    for line in sequence.sourceLines {
      // Skip leading whitespace.
      let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
      if trimmed.hasPrefix("#sourceLocation") {
        return true
      }
    }
    return false
  }

  // MARK: - Stream Building

  /// Build a concatenated token stream from multiple sequences.
  ///
  /// Tokens are converted to integers, and unique sentinel values are
  /// inserted between files AND at every top-level declaration boundary.
  /// The boundary separators make same-file declaration pairs isomorphic
  /// to cross-file pairs: without them, 3+ normalized-identical adjacent
  /// declarations form one periodic run whose overlapping shifted repeats
  /// (length 2L-p) outrank the true group (length L) in
  /// `mergeOverlappingGroups`, after which `filterOverlappingClones`
  /// reduces the survivor to a single location and the group is dropped.
  /// Periodic content inside ONE declaration still self-overlaps and is
  /// still filtered — that protection is intentional and unchanged.
  private func buildStream<S: Collection>(
    from sequences: S,
    tokenAccessor: (S.Element, Int) -> TokenAccessorResult
  ) -> TokenStreamResult where S.Element: TokenSequenceProtocol {
    var tokens: [Int] = []
    var infos: [TokenStreamInfo] = []
    var tokenIdMap: [String: Int] = [:]
    var nextTokenId = 1  // 0 reserved for the SA-IS sentinel

    func appendSeparator(fileIndex: Int) {
      tokens.append(nextTokenId)
      nextTokenId += 1
      infos.append(
        TokenStreamInfo(
          fileIndex: fileIndex,
          line: -1,
          column: -1,
          originalText: "<SEP>"
        ))
    }

    for (fileIndex, sequence) in sequences.enumerated() {
      let boundaries = sequence.boundaries
      var nextBoundary = 0

      for tokenIdx in 0..<sequence.tokenCount {
        while nextBoundary < boundaries.count, boundaries[nextBoundary] < tokenIdx {
          nextBoundary += 1
        }
        if nextBoundary < boundaries.count, boundaries[nextBoundary] == tokenIdx {
          nextBoundary += 1
          // The file separator already guards the head of the file.
          if tokenIdx > 0 {
            appendSeparator(fileIndex: fileIndex)
          }
        }

        let accessor = tokenAccessor(sequence, tokenIdx)
        let tokenId: Int
        if let existingId = tokenIdMap[accessor.text] {
          tokenId = existingId
        } else {
          tokenId = nextTokenId
          tokenIdMap[accessor.text] = tokenId
          nextTokenId += 1
        }

        tokens.append(tokenId)
        infos.append(
          TokenStreamInfo(
            fileIndex: fileIndex,
            line: accessor.line,
            column: accessor.column,
            originalText: accessor.original
          ))
      }

      // Separator between files (unique sentinel).
      appendSeparator(fileIndex: fileIndex)
    }

    return TokenStreamResult(tokens: tokens, infos: infos)
  }

  // MARK: - Clone Group Conversion

  /// Common clone group building logic.
  private func buildCloneGroups(
    repeatGroups: [RepeatGroup],
    tokenInfos: [TokenStreamInfo],
    cloneType: CloneType,
    locationCreator: (Int, Int) -> CloneLocation?
  ) -> [CloneGroup] {
    var cloneGroups: [CloneGroup] = []

    for group in repeatGroups {
      let validPositions = group.positions.filter { pos in
        isValidPosition(pos, length: group.length, tokenInfos: tokenInfos)
      }

      guard validPositions.count >= 2 else { continue }

      let cloneLocations = validPositions.compactMap { pos in
        locationCreator(pos, group.length)
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
        tokenInfos: tokenInfos
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
  private func isValidPosition(_ pos: Int, length: Int, tokenInfos: [TokenStreamInfo]) -> Bool {
    guard pos >= 0, pos + length <= tokenInfos.count else { return false }

    let startInfo = tokenInfos[pos]
    let endInfo = tokenInfos[pos + length - 1]

    // Check if start and end are in the same file
    return startInfo.fileIndex == endInfo.fileIndex && startInfo.line >= 0
  }

  /// Create a clone location from a position.
  ///
  /// Generic over any sequence type conforming to TokenSequenceProtocol,
  /// eliminating duplication between regular and normalized sequence handling.
  private func createCloneLocation<S: TokenSequenceProtocol>(
    position: Int,
    length: Int,
    tokenInfos: [TokenStreamInfo],
    sequences: [S]
  ) -> CloneLocation? {
    guard isValidPosition(position, length: length, tokenInfos: tokenInfos) else { return nil }

    let startInfo = tokenInfos[position]
    let endInfo = tokenInfos[position + length - 1]
    let file = sequences[startInfo.fileIndex].file

    return CloneLocation(
      file: file,
      fileIndex: startInfo.fileIndex,
      startLine: startInfo.line,
      startColumn: startInfo.column,
      endLine: endInfo.line,
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

  /// Generate a fingerprint for a clone.
  private func generateFingerprint(
    position: Int,
    length: Int,
    tokenInfos: [TokenStreamInfo]
  ) -> String {
    var parts: [String] = []
    for i in position..<min(position + length, tokenInfos.count) {
      parts.append(tokenInfos[i].originalText)
    }
    return String(FNV1a.hash(parts.joined(separator: " ")))
  }
}

// MARK: - TokenStreamInfo

/// Information about a token in the concatenated stream.
struct TokenStreamInfo: Sendable {
  let fileIndex: Int
  let line: Int
  let column: Int
  let originalText: String
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
