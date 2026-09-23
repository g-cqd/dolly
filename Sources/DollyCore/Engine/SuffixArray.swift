//  SuffixArray.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - SuffixArrayIndex

/// The integer the suffix-array stages store positions and token ids in.
///
/// Each stage holds arrays as long as the token stream, so their width sets
/// the engine's memory: `SuffixArrayCloneDetector` picks `Int32` whenever the
/// stream fits, which halves those arrays against `Int`, and `Int` beyond.
typealias SuffixArrayIndex = FixedWidthInteger & SignedInteger & Sendable

// MARK: - SuffixArray

/// A suffix array data structure for efficient substring matching.
///
/// The suffix array is an integer array containing the starting indices of all
/// lexicographically sorted suffixes of the input. Combined with the LCP array,
/// it enables linear-time detection of all repeated substrings.
struct SuffixArray<Index: SuffixArrayIndex>: Sendable {
  /// The suffix array - indices of sorted suffixes.
  let array: [Index]

  /// Creates a suffix array from an array of integers (token IDs).
  ///
  /// - Parameter tokens: Array of integer token IDs.
  /// - Note: Token IDs should be in range [0, alphabetSize).
  /// - Precondition: `Index` holds `tokens.count` and the largest id plus one.
  init(tokens: [Index]) {
    var tokens = tokens
    self.init(borrowing: &tokens)
  }

  /// Builds while temporarily appending the SA-IS sentinel to the caller's
  /// buffer. The input is restored before this initializer returns. A shared
  /// array may still trigger copy-on-write when the sentinel is appended.
  init(borrowing tokens: inout [Index]) {
    if tokens.isEmpty {
      array = []
    } else {
      array = SuffixArrayBuilder.build(&tokens)
    }
  }
}

// MARK: - SuffixArrayBuilder

/// Builder for suffix arrays using the SA-IS (Suffix Array Induced Sorting) algorithm.
///
/// SA-IS achieves O(n) time complexity for suffix array construction.
/// Reference: Nong, Zhang, Chan - "Two Efficient Algorithms for Linear Time Suffix Array Construction" (2009)
enum SuffixArrayBuilder {
  /// Build suffix array using SA-IS algorithm.
  static func build<Index: SuffixArrayIndex>(_ input: inout [Index]) -> [Index] {
    let n = input.count
    guard n > 0 else { return [] }

    // Handle single element
    if n == 1 {
      return [0]
    }

    // Find alphabet size
    let alphabetSize = Int(input.max() ?? 0) + 2  // +1 for max value, +1 for sentinel

    // Append sentinel (smaller than all other characters)
    input.append(0)  // Sentinel; caller reserved this slot.
    defer { input.removeLast() }

    // Build suffix array using SA-IS
    var sa = SAIS.build(input, alphabetSize: alphabetSize)

    // The sentinel is appended at position `n` and 0 is the smallest
    // character — SA-IS sorts that suffix to position 0. Drop it via
    // `removeFirst()`, an in-place O(n) memmove.
    let sentinel = Index(n)
    if !sa.isEmpty, sa[0] == sentinel {
      sa.removeFirst()
    } else if let sentinelIndex = sa.firstIndex(of: sentinel) {
      // Defensive: handle any future SA-IS variant that doesn't
      // pin the sentinel to position 0.
      sa.remove(at: sentinelIndex)
    }
    return sa
  }
}

// MARK: - SAIS

/// Implementation of the SA-IS (Suffix Array Induced Sorting) algorithm.
/// Achieves O(n) time complexity for suffix array construction.
///
/// The working suffix array is reused across induction passes, and one bucket
/// cursor is shared across recursion levels.
enum SAIS {
  // MARK: Internal

  /// Build suffix array using SA-IS algorithm.
  ///
  /// - Parameters:
  ///   - text: Input text as array of integers (must end with unique smallest character).
  ///   - alphabetSize: Size of the alphabet (max value + 1).
  /// - Returns: Suffix array.
  static func build<Index: SuffixArrayIndex>(_ text: [Index], alphabetSize: Int) -> [Index] {
    var bucketCursor: [Int] = []
    return build(text, alphabetSize: alphabetSize, bucketCursor: &bucketCursor)
  }

  private static func build<Index: SuffixArrayIndex>(
    _ text: [Index], alphabetSize: Int, bucketCursor: inout [Int]
  ) -> [Index] {
    let n = text.count
    guard n > 1 else { return n == 1 ? [0] : [] }

    // For small inputs, use simple sorting
    if n <= 32 {
      return buildSimple(text)
    }

    // Classify suffixes and find LMS positions
    let types = classifyTypes(text)
    let lmsPositions: [Index] = findLMSPositions(types)

    // Compute bucket boundaries
    let (bucketHeads, bucketTails) = computeBucketBoundaries(text, alphabetSize: alphabetSize)

    // The working SA buffer. All subsequent SA-IS phases write into
    // this single buffer; the second induction pass reuses it via
    // in-place reset.
    var sa = [Index](repeating: -1, count: n)
    if bucketCursor.count < alphabetSize {
      bucketCursor.append(contentsOf: repeatElement(0, count: alphabetSize - bucketCursor.count))
    }

    // First induction: LMS suffixes placed in text order. This sorts the
    // LMS *substrings* well enough to name them, but it does NOT sort the
    // full suffixes — the second induction below (LMS in true sorted order)
    // is what yields the final suffix array and must ALWAYS run.
    placeAndInduce(
      into: &sa, text: text, types: types, lmsPositions: lmsPositions,
      orderedBy: nil, bucketHeads: bucketHeads, bucketTails: bucketTails,
      bucketCursor: &bucketCursor)

    // Assign names to the sorted LMS substrings, then form the reduced
    // string (one name per LMS position, in text order).
    let (lmsNames, name) = assignLMSNames(sa: sa, text: text, types: types)
    let reducedString = buildReducedString(lmsNames: lmsNames)
    let lmsCount = lmsPositions.count

    // `reducedSA[r]` = index into `lmsPositions` of the r-th smallest LMS
    // suffix — i.e. the suffix array of the reduced string.
    let reducedSA: [Index]
    if name + 1 < lmsCount {
      // Duplicate names: the LMS-substring order is ambiguous, so recurse on
      // the reduced string to resolve the true LMS-suffix order.
      if reducedString.count <= 32 {
        reducedSA = buildSimple(reducedString)
      } else {
        reducedSA = build(reducedString, alphabetSize: name + 1, bucketCursor: &bucketCursor)
      }
    } else {
      // Every LMS substring is unique, so the LMS suffixes sort exactly by
      // name. `reducedSA` is then the inverse of the (bijective) name
      // permutation: no recursion needed, but the second induction below
      // still MUST run to place the L/S suffixes around the sorted LMS set.
      var inverse = [Index](repeating: 0, count: reducedString.count)
      for (position, assignedName) in reducedString.enumerated() {
        inverse[Int(assignedName)] = Index(position)
      }
      reducedSA = inverse
    }

    // Second induction: LMS suffixes placed at bucket tails in their true
    // sorted order, then L- and S-type suffixes induced around them.
    for index in 0..<n { sa[index] = -1 }
    placeAndInduce(
      into: &sa, text: text, types: types, lmsPositions: lmsPositions,
      orderedBy: reducedSA, bucketHeads: bucketHeads, bucketTails: bucketTails,
      bucketCursor: &bucketCursor)

    return sa
  }

  /// One full induction pass: place the LMS suffixes (in given or index
  /// order), then induce-sort the L-type and S-type suffixes.
  private static func placeAndInduce<Index: SuffixArrayIndex>(
    into sa: inout [Index],
    text: [Index],
    types: [Bool],
    lmsPositions: [Index],
    orderedBy reducedSA: [Index]?,
    bucketHeads: [Int],
    bucketTails: [Int],
    bucketCursor: inout [Int]
  ) {
    for i in bucketTails.indices { bucketCursor[i] = bucketTails[i] }
    placeLMSSuffixes(
      into: &sa, text: text, lmsPositions: lmsPositions,
      orderedBy: reducedSA, bucketCursor: &bucketCursor)
    for i in bucketHeads.indices { bucketCursor[i] = bucketHeads[i] }
    inducedSortLType(sa: &sa, text: text, types: types, bucketCursor: &bucketCursor)
    for i in bucketTails.indices { bucketCursor[i] = bucketTails[i] }
    inducedSortSType(sa: &sa, text: text, types: types, bucketCursor: &bucketCursor)
  }

  // MARK: Private

  /// Classify each suffix as S-type (`true`) or L-type (`false`).
  private static func classifyTypes<Index: SuffixArrayIndex>(_ text: [Index]) -> [Bool] {
    let n = text.count
    var types = [Bool](repeating: false, count: n)
    types[n - 1] = true  // Last suffix is always S-type (sentinel)

    for i in stride(from: n - 2, through: 0, by: -1) {
      if text[i] < text[i + 1] {
        types[i] = true
      } else if text[i] == text[i + 1], types[i + 1] {
        types[i] = true
      }
    }
    return types
  }

  /// Find LMS (Leftmost S-type) positions.
  private static func findLMSPositions<Index: SuffixArrayIndex>(_ types: [Bool]) -> [Index] {
    var positions: [Index] = []
    for i in 1..<types.count where types[i] && !types[i - 1] {
      positions.append(Index(i))
    }
    return positions
  }

  /// Compute bucket head and tail positions.
  private static func computeBucketBoundaries<Index: SuffixArrayIndex>(
    _ text: [Index], alphabetSize: Int
  ) -> (heads: [Int], tails: [Int]) {
    var heads = [Int](repeating: 0, count: alphabetSize)
    for c in text {
      heads[Int(c)] += 1
    }

    var tails = [Int](repeating: 0, count: alphabetSize)
    var sum = 0
    for i in 0..<alphabetSize {
      let count = heads[i]
      heads[i] = sum
      sum += count
      tails[i] = sum - 1
    }
    return (heads, tails)
  }

  /// Place LMS suffixes at bucket tails into the supplied (already
  /// `-1`-cleared) buffer. When `reducedSA` is given, LMS suffixes are
  /// placed in the order it determines; otherwise in index order.
  private static func placeLMSSuffixes<Index: SuffixArrayIndex>(
    into sa: inout [Index],
    text: [Index],
    lmsPositions: [Index],
    orderedBy reducedSA: [Index]?,
    bucketCursor: inout [Int]
  ) {
    for i in stride(from: lmsPositions.count - 1, through: 0, by: -1) {
      let pos = lmsPositions[reducedSA.map { Int($0[i]) } ?? i]
      let c = Int(text[Int(pos)])
      sa[bucketCursor[c]] = pos
      bucketCursor[c] -= 1
    }
  }

  /// Induced sort L-type suffixes (left to right).
  private static func inducedSortLType<Index: SuffixArrayIndex>(
    sa: inout [Index],
    text: [Index],
    types: [Bool],
    bucketCursor: inout [Int]
  ) {
    for i in 0..<sa.count where sa[i] > 0 && !types[Int(sa[i]) - 1] {
      let j = sa[i] - 1
      let c = Int(text[Int(j)])
      sa[bucketCursor[c]] = j
      bucketCursor[c] += 1
    }
  }

  /// Induced sort S-type suffixes (right to left).
  private static func inducedSortSType<Index: SuffixArrayIndex>(
    sa: inout [Index],
    text: [Index],
    types: [Bool],
    bucketCursor: inout [Int]
  ) {
    for i in stride(from: sa.count - 1, through: 0, by: -1)
    where sa[i] > 0 && types[Int(sa[i]) - 1] {
      let j = sa[i] - 1
      let c = Int(text[Int(j)])
      sa[bucketCursor[c]] = j
      bucketCursor[c] -= 1
    }
  }

  /// Assign names to sorted LMS substrings.
  private static func assignLMSNames<Index: SuffixArrayIndex>(
    sa: [Index],
    text: [Index],
    types: [Bool]
  ) -> (names: [Index], maxName: Int) {
    let n = text.count
    var lmsNames = [Index](repeating: -1, count: n)
    var name = 0
    var prevLMS = -1

    for i in 0..<n {
      let pos = Int(sa[i])
      guard pos > 0, types[pos], !types[pos - 1] else { continue }

      if prevLMS >= 0, !lmsSubstringsEqual(text: text, types: types, i: prevLMS, j: pos) {
        name += 1
      }
      lmsNames[pos] = Index(name)
      prevLMS = pos
    }

    return (lmsNames, name)
  }

  /// Build reduced string from LMS names.
  private static func buildReducedString<Index: SuffixArrayIndex>(lmsNames: [Index]) -> [Index] {
    lmsNames.filter { $0 >= 0 }
  }

  /// Check if two LMS substrings are equal.
  private static func lmsSubstringsEqual<Index: SuffixArrayIndex>(
    text: [Index], types: [Bool], i: Int, j: Int
  ) -> Bool {
    let n = text.count
    var pi = i
    var pj = j

    while true {
      if text[pi] != text[pj] {
        return false
      }
      if types[pi] != types[pj] {
        return false
      }

      pi += 1
      pj += 1

      if pi >= n || pj >= n {
        return pi >= n && pj >= n
      }

      // Check if we've reached the end of both LMS substrings
      let endI = pi > 0 && types[pi] && !types[pi - 1]
      let endJ = pj > 0 && types[pj] && !types[pj - 1]

      if endI, endJ {
        return true
      }
      if endI != endJ {
        return false
      }
    }
  }

  /// Simple O(n log n) suffix array for small inputs.
  private static func buildSimple<Index: SuffixArrayIndex>(_ text: [Index]) -> [Index] {
    let n = text.count
    var sa = (0..<n).map { Index($0) }
    sa.sort { i, j in
      var pi = Int(i)
      var pj = Int(j)
      while pi < n, pj < n {
        if text[pi] < text[pj] { return true }
        if text[pi] > text[pj] { return false }
        pi += 1
        pj += 1
      }
      return pi >= n  // Shorter suffix comes first
    }
    return sa
  }
}
