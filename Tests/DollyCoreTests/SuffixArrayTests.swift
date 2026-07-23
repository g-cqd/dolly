//  SuffixArrayTests.swift
//  dolly — ported from SwiftStaticAnalysis DuplicationDetectorTests (MIT)

import Testing

@testable import DollyCore

@Suite("SA-IS correctness")
struct SAISCorrectnessTests {
  @Test("Suffix array is a permutation")
  func suffixArrayPermutation() {
    let tokens = [3, 1, 4, 1, 5, 9, 2, 6]
    let sa = SuffixArray(tokens: tokens)

    // Check that SA is a permutation of [0, n-1]
    let sorted = sa.array.sorted()
    #expect(sorted == Array(0..<tokens.count))
  }

  @Test("Suffixes are lexicographically sorted")
  func suffixesSorted() {
    let tokens = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5]
    let sa = SuffixArray(tokens: tokens)

    // Verify each adjacent pair is in correct order
    for i in 0..<(sa.array.count - 1) {
      let suffix1 = Array(tokens[sa.array[i]...])
      let suffix2 = Array(tokens[sa.array[i + 1]...])

      let isOrdered =
        suffix1.lexicographicallyPrecedes(suffix2) || suffix1.starts(with: suffix2)
        || suffix2.starts(with: suffix1)
      #expect(isOrdered, "Suffixes at SA[\(i)] and SA[\(i + 1)] are not properly ordered")
    }
  }

  @Test("All ones input")
  func allOnesInput() {
    let tokens = [Int](repeating: 1, count: 10)
    let sa = SuffixArray(tokens: tokens)

    // For all-same elements, SA should be [9,8,...,0] (shortest suffix first)
    #expect(sa.array.count == 10)
    for i in 0..<10 {
      #expect(sa.array[i] == 9 - i)
    }
  }

  @Test("Descending input")
  func descendingInput() {
    let sa = SuffixArray(tokens: [5, 4, 3, 2, 1])
    #expect(sa.array == [4, 3, 2, 1, 0])
  }

  @Test("Ascending input")
  func ascendingInput() {
    let sa = SuffixArray(tokens: [1, 2, 3, 4, 5])
    #expect(sa.array == [0, 1, 2, 3, 4])
  }

  @Test("Recursive SA-IS path matches brute force")
  func recursiveCaseMatchesBruteForce() {
    // Long input with many repeated LMS substrings forces the
    // recursive reduction (n > 32, non-unique LMS names).
    var tokens: [Int] = []
    for i in 0..<200 {
      tokens.append(i % 7 + 1)
    }
    tokens.append(contentsOf: tokens)  // 400 tokens, heavy repetition

    let sa = SuffixArray(tokens: tokens)
    #expect(Set(sa.array) == Set(0..<tokens.count))
    for i in 0..<(sa.array.count - 1) {
      let suffix1 = Array(tokens[sa.array[i]...])
      let suffix2 = Array(tokens[sa.array[i + 1]...])
      #expect(
        suffix1.lexicographicallyPrecedes(suffix2) || suffix2.starts(with: suffix1),
        "misordered at \(i)")
    }
  }
}

@Suite("Suffix array construction")
struct SuffixArrayConstructionTests {
  @Test("Empty input produces empty suffix array")
  func emptyInput() {
    let sa = SuffixArray(tokens: [])
    #expect(sa.array.isEmpty)
    #expect(sa.length == 0)
  }

  @Test("Single element suffix array")
  func singleElement() {
    let sa = SuffixArray(tokens: [1])
    #expect(sa.array.count == 1)
    #expect(sa.array[0] == 0)
  }

  @Test("Two element suffix array")
  func twoElements() {
    // "ba" -> sorted suffixes: "a" (index 1), "ba" (index 0)
    let sa = SuffixArray(tokens: [2, 1])
    #expect(sa.array == [1, 0])
  }

  @Test("Repeated elements suffix array")
  func repeatedElements() {
    // "aaa" -> all suffixes are prefixes of each other
    let sa = SuffixArray(tokens: [1, 1, 1])
    #expect(sa.array == [2, 1, 0])
  }

  @Test("Banana-like pattern suffix array")
  func bananaPattern() {
    let tokens = [2, 1, 3, 1, 3, 1]  // b a n a n a
    let sa = SuffixArray(tokens: tokens)
    #expect(sa.array.count == 6)

    for i in 0..<(sa.array.count - 1) {
      let suffix1 = Array(tokens[sa.array[i]...])
      let suffix2 = Array(tokens[sa.array[i + 1]...])
      #expect(suffix1.lexicographicallyPrecedes(suffix2) || suffix1 == suffix2)
    }
  }

  @Test("Suffix array from strings")
  func fromStrings() {
    let strings = ["func", "hello", "func", "world"]
    let (sa, alphabet) = SuffixArray.fromStrings(strings)

    #expect(sa.length == 4)
    #expect(alphabet.count == 3)  // func, hello, world
    #expect(alphabet["func"] != nil)
    #expect(alphabet["hello"] != nil)
    #expect(alphabet["world"] != nil)
  }

  @Test("Large suffix array construction")
  func largeArray() {
    var tokens: [Int] = []
    for i in 0..<1000 {
      tokens.append(i % 100 + 1)
    }

    let sa = SuffixArray(tokens: tokens)
    #expect(sa.array.count == 1000)
    #expect(Set(sa.array).count == 1000)
  }
}

@Suite("Suffix array search")
struct SuffixArraySearchTests {
  @Test("Search finds exact pattern")
  func searchExactPattern() {
    let tokens = [1, 2, 3, 1, 2, 3, 4]
    let sa = SuffixArray(tokens: tokens)

    let occurrences = sa.findOccurrences(of: [1, 2, 3], in: tokens)
    #expect(occurrences.count == 2)
    #expect(occurrences.contains(0))
    #expect(occurrences.contains(3))
  }

  @Test("Search returns empty for non-existent pattern")
  func searchNonExistent() {
    let tokens = [1, 2, 3, 4, 5]
    let sa = SuffixArray(tokens: tokens)
    #expect(sa.findOccurrences(of: [6, 7], in: tokens).isEmpty)
  }

  @Test("Search finds single occurrence")
  func searchSingleOccurrence() {
    let tokens = [1, 2, 3, 4, 5]
    let sa = SuffixArray(tokens: tokens)

    let occurrences = sa.findOccurrences(of: [3, 4], in: tokens)
    #expect(occurrences == [2])
  }

  @Test("Search with overlapping occurrences")
  func searchOverlapping() {
    // "aaaa" has overlapping "aa" at positions 0, 1, 2
    let tokens = [1, 1, 1, 1]
    let sa = SuffixArray(tokens: tokens)
    #expect(sa.findOccurrences(of: [1, 1], in: tokens).count == 3)
  }
}
