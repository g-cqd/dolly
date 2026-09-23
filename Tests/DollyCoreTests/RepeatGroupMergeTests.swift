//  RepeatGroupMergeTests.swift
//  dolly
//
//  `LCPArray.mergeOverlappingGroups` used to judge each occurrence against
//  every kept occurrence in turn, which was quadratic on clone-heavy corpora.
//  It now answers the same question from a per-token coverage array. These
//  tests hold it to the old scan's exact output, on random group lists and on
//  groups found in random token streams.

import Testing

@testable import DollyCore

@Suite("Repeat group merge") struct RepeatGroupMergeTests {
  /// The merge as it was: every occurrence of a group checked against every
  /// kept occurrence, the group dropped when each of its occurrences overlaps
  /// some kept one by half or more.
  static func referenceMerge(_ groups: [RepeatGroup]) -> [RepeatGroup] {
    let sorted = groups.sorted { lhs, rhs in
      if lhs.length != rhs.length { return lhs.length > rhs.length }
      return (lhs.positions.first ?? 0) < (rhs.positions.first ?? 0)
    }
    var result: [RepeatGroup] = []
    var claimed: [Range<Int>] = []
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

  static func summary(_ groups: [RepeatGroup]) -> [String] {
    groups.map { "\($0.length)@\($0.positions)" }
  }

  @Test("Random groups merge exactly as the pairwise scan did", arguments: 0..<200)
  func randomGroupsMatchReference(seed: Int) {
    var rng = SAISDifferentialTests.LCG(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
    let streamLength = 40 + rng.next(160)
    var groups: [RepeatGroup] = []
    // Disjoint position sets, as LCP regions produce: each position in at
    // most one group.
    var free = Array(0..<streamLength)
    for _ in 0..<(1 + rng.next(30)) {
      let length = 1 + rng.next(24)
      var positions: [Int] = []
      for _ in 0..<(2 + rng.next(4)) {
        let candidates = free.filter { $0 + length <= streamLength }
        guard !candidates.isEmpty else { break }
        let position = candidates[rng.next(candidates.count)]
        positions.append(position)
        free.removeAll { $0 == position }
      }
      guard positions.count >= 2 else { continue }
      groups.append(RepeatGroup(positions: positions, length: length))
    }

    let merged = LCPArray<Int32>.mergeOverlappingGroups(groups, streamLength: streamLength)
    #expect(Self.summary(merged) == Self.summary(Self.referenceMerge(groups)))
  }

  @Test("Groups found in repetitive streams merge exactly as the pairwise scan did")
  func streamGroupsMatchReference() {
    var rng = SAISDifferentialTests.LCG(state: 0xD011)
    for _ in 0..<60 {
      // A few blocks copied around with small edits: the shape that makes
      // many shifted, nested and partially overlapping repeat regions.
      let blocks = (0..<(2 + rng.next(4))).map { _ in
        (0..<(8 + rng.next(40))).map { _ in 1 + rng.next(6) }
      }
      var tokens: [Int] = []
      for _ in 0..<(4 + rng.next(12)) {
        var block = blocks[rng.next(blocks.count)]
        if rng.next(3) == 0 { block[rng.next(block.count)] = 7 + rng.next(3) }
        tokens += block
      }
      let lcp = LCPArray(suffixArray: SuffixArray(tokens: tokens), tokens: tokens)
      let unmerged = lcp.repeatRegions(minLength: 3)
      #expect(!unmerged.isEmpty)

      let merged = lcp.findRepeatGroups(minLength: 3)
      #expect(Self.summary(merged) == Self.summary(Self.referenceMerge(unmerged)))
    }
  }
}
