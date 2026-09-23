//  LCPArray.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - LCPArray

/// Longest Common Prefix array for efficient repeat detection.
///
/// The LCP array `lcp[i]` contains the length of the longest common prefix
/// between `suffixArray[i-1]` and `suffixArray[i]`. This enables finding
/// all repeated substrings by scanning for values >= threshold.
struct LCPArray: Sendable {
  // MARK: Lifecycle

  /// Creates an LCP array from a suffix array and the original tokens.
  ///
  /// Uses Kasai's algorithm for O(n) construction.
  ///
  /// - Parameters:
  ///   - suffixArray: The suffix array.
  ///   - tokens: The original token array (as integers).
  init(suffixArray: SuffixArray, tokens: [Int]) {
    self.suffixArray = suffixArray
    array = LCPArrayBuilder.build(suffixArray: suffixArray, tokens: tokens)
  }

  // MARK: Public

  /// The LCP values. `lcp[i]` = LCP of SA[i-1] and SA[i]. lcp[0] is always 0.
  let array: [Int]

  /// The suffix array this LCP array corresponds to.
  let suffixArray: SuffixArray
}

// MARK: - LCPArrayBuilder

/// Builder for LCP arrays using Kasai's algorithm.
///
/// Kasai's algorithm computes the LCP array in O(n) time by exploiting
/// the property that LCP values decrease by at most 1 when moving to
/// the next suffix in text order.
enum LCPArrayBuilder {
  /// Build LCP array using Kasai's algorithm.
  static func build(suffixArray: SuffixArray, tokens: [Int]) -> [Int] {
    let n = tokens.count
    guard n > 0 else { return [] }
    guard suffixArray.array.count == n else { return [] }

    let sa = suffixArray.array

    // Build inverse suffix array (rank array)
    // rank[i] = position of suffix starting at i in the sorted suffix array
    var rank = [Int](repeating: 0, count: n)
    for i in 0..<n {
      rank[sa[i]] = i
    }

    // Build LCP array using Kasai's algorithm
    var lcp = [Int](repeating: 0, count: n)
    var h = 0  // Current LCP length

    for i in 0..<n {
      let r = rank[i]  // Position of suffix[i] in SA

      if r > 0 {
        // Get the suffix that comes just before in sorted order
        let j = sa[r - 1]

        // Compare suffix[i] and suffix[j] starting from position h
        while i + h < n, j + h < n, tokens[i + h] == tokens[j + h] {
          h += 1
        }

        lcp[r] = h

        // Key insight: LCP can decrease by at most 1
        if h > 0 {
          h -= 1
        }
      }
    }

    return lcp
  }
}

extension LCPArray {
  /// Find all repeat groups with enhanced position information.
  ///
  /// This groups repeats that share positions into clone groups,
  /// finding the longest common substring for each group.
  ///
  /// - Parameter minLength: Minimum length of repeats to find.
  /// - Returns: Array of repeat groups.
  func findRepeatGroups(minLength: Int) -> [RepeatGroup] {
    let sa = suffixArray.array
    let n = array.count
    guard n > 1 else { return [] }

    var groups: [RepeatGroup] = []

    // Use a stack-based approach to find all repeat intervals
    // This is more efficient for finding all maximal repeat groups

    var i = 1
    while i < n {
      if array[i] < minLength {
        i += 1
        continue
      }

      // Found start of a repeat region
      var positions: [Int] = [sa[i - 1], sa[i]]
      var minLcp = array[i]
      var j = i + 1

      // Extend while in same or higher LCP region
      while j < n, array[j] >= minLength {
        positions.append(sa[j])
        minLcp = min(minLcp, array[j])
        j += 1
      }

      // Create group with the minimum LCP as the shared length
      groups.append(RepeatGroup(positions: positions, length: minLcp))

      i = j
    }

    return mergeOverlappingGroups(groups)
  }

  /// Merge groups that represent the same underlying repeat.
  ///
  /// A repeat of length L produces shifted sub-repeats at every offset
  /// (positions p+1, p+2, … with lengths L-1, L-2, …), each forming its
  /// own LCP region. Comparing exact position sets misses them entirely
  /// (the shifted positions differ), so redundancy is judged by token-
  /// range overlap: a group is dropped when every occurrence lies at
  /// least half inside some longer, already-kept occurrence.
  private func mergeOverlappingGroups(_ groups: [RepeatGroup]) -> [RepeatGroup] {
    guard !groups.isEmpty else { return [] }

    // Sort by length descending to prefer longer repeats; tie-break on
    // first position for deterministic output.
    let sorted = groups.sorted { lhs, rhs in
      if lhs.length != rhs.length { return lhs.length > rhs.length }
      return (lhs.positions.first ?? 0) < (rhs.positions.first ?? 0)
    }

    var result: [RepeatGroup] = []
    var claimed: [Range<Int>] = []  // Token-stream ranges of kept occurrences.

    for group in sorted {
      let ranges = group.positions.map { $0..<($0 + group.length) }
      let redundant = ranges.allSatisfy { range in
        claimed.contains { existing in
          let overlap =
            min(range.upperBound, existing.upperBound)
            - max(range.lowerBound, existing.lowerBound)
          return overlap * 2 >= range.count
        }
      }
      if redundant { continue }
      result.append(group)
      claimed.append(contentsOf: ranges)
    }

    return result
  }
}

// MARK: - RepeatGroup

/// A group of positions sharing a common repeated substring.
struct RepeatGroup: Sendable {
  // MARK: Lifecycle

  init(positions: [Int], length: Int) {
    self.positions = positions.sorted()
    self.length = length
  }

  // MARK: Public

  /// Starting positions of all occurrences.
  let positions: [Int]

  /// Length of the common repeated substring.
  let length: Int

  /// Number of occurrences.
  var occurrences: Int { positions.count }
}
