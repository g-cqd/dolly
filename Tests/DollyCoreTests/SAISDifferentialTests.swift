//  SAISDifferentialTests.swift
//  dolly
//
//  Root-cause regression guards for the SA-IS suffix-array bug. The builder
//  skipped its mandatory second induction pass whenever every LMS substring
//  received a unique name (`name + 1 == lmsCount`), returning the first-pass
//  buffer — which only sorts LMS *substrings* for naming, not the full
//  suffixes. The result was a MISORDERED suffix array on large, lexically
//  sparse inputs (the corpus shape: many distinct token ids plus one unique
//  separator per top-level declaration). A misordered SA silently breaks the
//  min-LCP nesting property, and `findRepeatGroups` then reports a repeat
//  region whose claimed length exceeds what its members actually share — the
//  exact-clone false positives seen across the HTTP corpus.
//
//  Two independent guards: (1) the SA itself must equal a brute-force sort;
//  (2) no repeat group may over-claim its shared length. Either catches a
//  reintroduction.

import Testing

@testable import DollyCore

@Suite("SA-IS differential") struct SAISDifferentialTests {
  /// Small deterministic PRNG so any failure is reproducible from its seed.
  struct LCG {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
  }

  /// O(n² log n) reference suffix sort.
  static func bruteForceSA(_ tokens: [Int]) -> [Int] {
    let n = tokens.count
    var sa = Array(0..<n)
    sa.sort { i, j in
      var pi = i
      var pj = j
      while pi < n, pj < n {
        if tokens[pi] != tokens[pj] { return tokens[pi] < tokens[pj] }
        pi += 1
        pj += 1
      }
      return pi >= n && pj < n  // the shorter suffix sorts first
    }
    return sa
  }

  /// Corpus-like token streams: mostly a small dense alphabet, sprinkled with
  /// unique high ids that mimic the per-declaration separators. This is the
  /// regime that produced all-unique LMS names and tripped the skipped pass.
  private static func corpusLikeStream(_ rng: inout LCG, n: Int, alpha: Int) -> [Int] {
    var tokens: [Int] = []
    tokens.reserveCapacity(n)
    for _ in 0..<n {
      if rng.next(12) == 0 {
        tokens.append(10_000 + rng.next(5_000))  // unique-ish separator
      } else {
        tokens.append(1 + rng.next(alpha))
      }
    }
    return tokens
  }

  @Test("Suffix array matches brute force over corpus-like alphabets")
  func differentialVsBruteForce() {
    var rng = LCG(state: 0x1234_5678)
    for trial in 0..<1500 {
      let n = 33 + rng.next(400)  // past the 32-token direct-sort cutoff
      let alpha = 1 + rng.next(35)
      let tokens = Self.corpusLikeStream(&rng, n: n, alpha: alpha)
      let got = SuffixArray(tokens: tokens).array
      let want = Self.bruteForceSA(tokens)
      #expect(got == want, "trial \(trial) n=\(n) alpha=\(alpha) tokens=\(tokens)")
      if got != want { return }  // one dump is enough
    }
  }

  @Test("Repeat groups never over-claim their shared token length")
  func repeatGroupsRespectTrueSharedPrefix() {
    var rng = LCG(state: 0x0BAD_F00D)
    for trial in 0..<1500 {
      let n = 60 + rng.next(400)
      let alpha = 2 + rng.next(25)
      let tokens = Self.corpusLikeStream(&rng, n: n, alpha: alpha)

      let sa = SuffixArray(tokens: tokens)
      let lcp = LCPArray(suffixArray: sa, tokens: tokens)
      let groups = lcp.findRepeatGroups(minLength: 5)

      for group in groups {
        guard let anchor = group.positions.first else { continue }
        for position in group.positions {
          // Every member must share the FULL claimed prefix with the anchor;
          // a misordered SA is exactly what lets this fail.
          var matches = true
          for offset in 0..<group.length {
            let a = anchor + offset
            let b = position + offset
            if a >= tokens.count || b >= tokens.count || tokens[a] != tokens[b] {
              matches = false
              break
            }
          }
          #expect(
            matches,
            "trial \(trial): group length \(group.length) over-claims for positions \(anchor) vs \(position)"
          )
          if !matches { return }
        }
      }
    }
  }
}
