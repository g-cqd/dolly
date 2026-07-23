//  StructuralVerification.swift
//  dolly
//
//  NIL-style order-sensitive verification (Nakagawa, Higo, Kusumoto —
//  "NIL: Large-Scale Detection of Large-Variance Clones", ESEC/FSE 2021):
//  bag-of-shingles Jaccard is order-blind, so scrambled statements can
//  score as clones. A token-LCS similarity over the normalized id lanes
//  restores order sensitivity: candidates must share a long common
//  SUBSEQUENCE, not just a token bag.

enum StructuralVerification {
  /// Minimum LCS similarity for a structural candidate to be accepted.
  static let minimumSequenceSimilarity = 0.7

  /// Exact Jaccard similarity, or nil as soon as the threshold is out of
  /// reach. Allocation-free (no intersection/union sets) with an early
  /// abort: after `|smaller| - required` misses the pair cannot qualify,
  /// so template-similar false candidates cost a handful of set lookups.
  static func jaccardIfAtLeast(
    _ threshold: Double, _ first: Set<UInt64>, _ second: Set<UInt64>
  ) -> Double? {
    guard !first.isEmpty || !second.isEmpty else { return nil }
    let (smaller, larger) = first.count <= second.count ? (first, second) : (second, first)

    // J >= θ requires |∩| >= θ/(1+θ)·(|A|+|B|); epsilon keeps floating
    // error from over-requiring (only ever admits borderline pairs).
    let required = Int(
      (threshold / (1 + threshold) * Double(first.count + second.count) - 1e-9).rounded(.up))
    let allowedMisses = smaller.count - required

    var intersection = 0
    var misses = 0
    for feature in smaller {
      if larger.contains(feature) {
        intersection += 1
      } else {
        misses += 1
        if misses > allowedMisses { return nil }
      }
    }

    let union = first.count + second.count - intersection
    let similarity = union > 0 ? Double(intersection) / Double(union) : 0
    return similarity >= threshold ? similarity : nil
  }

  /// LCS length over the shorter sequence's length.
  ///
  /// Rolling two-row DP: O(|a|·|b|) time, O(min) space — blocks are at
  /// most a few hundred tokens, so a band is unnecessary (the full DP of
  /// a 200-token pair is 40k cells).
  static func sequenceSimilarity(_ a: [UInt32], _ b: [UInt32]) -> Double {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    let (short, long) = a.count <= b.count ? (a, b) : (b, a)

    var previous = [Int](repeating: 0, count: short.count + 1)
    var current = previous
    for element in long {
      for (index, candidate) in short.enumerated() {
        current[index + 1] =
          element == candidate
          ? previous[index] + 1
          : max(previous[index + 1], current[index])
      }
      swap(&previous, &current)
    }

    return Double(previous[short.count]) / Double(short.count)
  }
}
