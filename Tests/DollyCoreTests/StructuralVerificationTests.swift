//  StructuralVerificationTests.swift
//  dolly
//
//  NIL-style order-sensitive verification: bag-of-shingles Jaccard alone
//  accepts scrambled statements; the token-LCS gate must reject
//  high-Jaccard/low-LCS pairs and keep gapped-but-ordered ones.

import Testing

@testable import DollyCore

@Suite("NIL order-sensitive verification")
struct StructuralVerificationTests {
  // MARK: - LCS similarity unit tests

  @Test("identical sequences score 1.0")
  func identicalSequences() {
    let ids: [UInt32] = Array(1...40)
    #expect(StructuralVerification.sequenceSimilarity(ids, ids) == 1.0)
  }

  @Test("disjoint sequences score 0.0")
  func disjointSequences() {
    let a: [UInt32] = Array(1...30)
    let b: [UInt32] = Array(100...129)
    #expect(StructuralVerification.sequenceSimilarity(a, b) == 0.0)
  }

  @Test("swapped halves score 0.5")
  func swappedHalves() {
    let first: [UInt32] = Array(1...25)
    let second: [UInt32] = Array(26...50)
    let ordered = first + second
    let swapped = second + first
    #expect(StructuralVerification.sequenceSimilarity(ordered, swapped) == 0.5)
  }

  @Test("small gaps barely dent the score")
  func gappedSequence() {
    let ids: [UInt32] = Array(1...50)
    var gapped = ids
    gapped[25] = 999  // one substitution
    #expect(StructuralVerification.sequenceSimilarity(ids, gapped) == 49.0 / 50.0)
  }

  @Test("empty input scores 0.0")
  func emptyInput() {
    #expect(StructuralVerification.sequenceSimilarity([], [1, 2, 3]) == 0.0)
  }

  // MARK: - Detector-level accept/reject

  /// A 50-token synthetic sequence of pass-through tokens (keyword kind:
  /// no per-block ordinal renaming), so chunk permutations keep shingle
  /// sets comparable and the arithmetic below is exact.
  private func sequence(file: String, ids: [UInt32]) -> TokenSequence {
    let records = ids.enumerated().map { index, id in
      TokenRecord(rawID: id, normID: id, line: Int32(index + 1), column: 1)
    }
    return TokenSequence(
      file: file,
      records: records,
      kinds: Array(repeating: .keyword, count: ids.count),
      boundaries: [],
      hasSourceLocationDirective: false,
      text: SourceText(source: "")
    )
  }

  @Test("scrambled halves: high Jaccard, low LCS — REJECTED")
  func scrambledBlocksRejected() async {
    // A = X+Y, B = Y+X with 25-token chunks: only the seam shingles differ
    // (5-gram shingles: 42 of 46 shared, Jaccard 42/50 = 0.84 >= 0.8) but
    // the LCS is one chunk (25/50 = 0.5 < 0.7).
    let first: [UInt32] = Array(1...25)
    let second: [UInt32] = Array(26...50)
    let detector = StructuralCloneDetector(minimumTokens: 50, minimumSimilarity: 0.8)

    let groups = await detector.detect(in: [
      sequence(file: "ordered.swift", ids: first + second),
      sequence(file: "scrambled.swift", ids: second + first),
    ])
    #expect(groups.isEmpty, "scrambled statement order must not verify as a structural clone")
  }

  @Test("gapped but ordered: passes Jaccard and LCS — ACCEPTED")
  func gappedOrderedAccepted() async {
    // One substitution mid-block: Jaccard 41/51 ≈ 0.804 >= 0.8 and
    // LCS 49/50 = 0.98 >= 0.7.
    let ids: [UInt32] = Array(1...50)
    var gapped = ids
    gapped[25] = 999
    let detector = StructuralCloneDetector(minimumTokens: 50, minimumSimilarity: 0.8)

    let groups = await detector.detect(in: [
      sequence(file: "original.swift", ids: ids),
      sequence(file: "gapped.swift", ids: gapped),
    ])
    #expect(groups.count == 1, "an ordered near-copy must survive both gates: \(groups)")
    #expect(groups.first?.clones.count == 2)
  }
}
