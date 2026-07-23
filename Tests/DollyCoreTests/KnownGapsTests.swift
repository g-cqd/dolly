//  KnownGapsTests.swift
//  dolly
//
//  Characterization tests for ACCEPTED detection gaps — each pins the
//  current miss so a future change that closes (or widens) a gap shows up
//  as a test delta, and Fixtures/KnownGaps.md can point at living code.
//  These are documentation of intent, not aspirations: if one fails
//  because a gap closed, update the catalogue and re-pin.

import Foundation
import Testing

@testable import DollyCore

@Suite struct KnownGapsTests {
  /// Gap 1: runs of 3+ identical-after-rename declarations INSIDE one
  /// type (depth >= 1). Boundary separators are top-level only — placing
  /// them between members would sever whole-type and boilerplate-family
  /// clones (verified against goldens and the arcleak dogfood corpus) —
  /// so in-type periodic runs are still discarded by the overlap filter.
  /// The same three methods split across files, or at the top level, are
  /// found (DuplicationPropertyTests.sameFileMatchesSplitFiles).
  @Test("three identical-after-rename methods inside ONE type are missed")
  func inTypeMethodRunsAreMissed() async {
    func method(_ name: String, _ v1: String, _ v2: String) -> String {
      """
          func \(name)(values: [Double]) -> Double {
              var \(v1) = 0.0
              var \(v2) = 1.0
              for element in values {
                  if element > 12.5 {
                      \(v1) += element * 1.75
                  } else {
                      \(v2) *= element + 3.25
                  }
              }
              let combined = \(v1) + \(v2) * 1.75
              return combined - 3.25
          }
      """
    }
    let source = """
      final class Worker {
      \(method("first", "totalA", "compoundA"))
      \(method("second", "totalB", "compoundB"))
      \(method("third", "totalC", "compoundC"))
      }
      """
    let report = await Analyzer().analyze(source: source, path: "worker.swift")
    #expect(
      !report.findings.contains { $0.rule == .nearClone },
      "gap closed? update Fixtures/KnownGaps.md and re-pin this test")
  }

  /// Gap 2: structural pairs with dense edits land below the 0.8 Jaccard
  /// threshold and stay silent — by design, the threshold is the noise
  /// floor. (StructuralPair's sparse-edit fixture sits ABOVE it.)
  @Test("dense-edit pair below the structural threshold is silent")
  func denseEditPairIsSilent() async {
    // Same skeleton, but half the statements differ: bag similarity of
    // the 50-token blocks falls well under 0.8.
    let first = """
      func transformBatchAlpha(values: [Int]) -> Int {
          var acc = 0
          acc += values[0] &* 3
          acc += values[1] &* 5
          acc -= values[2] &* 7
          acc += values[3] &* 11
          acc ^= values[4] &* 13
          acc += values[5] &* 17
          acc &= values[6] &* 19
          acc += values[7] &* 23
          return acc
      }
      """
    let second = """
      func transformBatchBeta(values: [Int]) -> Int {
          var acc = 1
          acc *= values[0] &+ 29
          acc -= values[1] &+ 31
          acc *= values[2] &+ 37
          acc |= values[3] &+ 41
          acc *= values[4] &+ 43
          acc ^= values[5] &+ 47
          acc *= values[6] &+ 53
          acc %= values[7] &+ 59
          return acc
      }
      """
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-gap-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appending(path: "a.swift")
    let b = dir.appending(path: "b.swift")
    try? first.write(to: a, atomically: true, encoding: .utf8)
    try? second.write(to: b, atomically: true, encoding: .utf8)

    let report = await Analyzer().analyze(files: [a.path, b.path])
    #expect(
      !report.findings.contains { $0.rule == .structuralClone },
      "gap closed? update Fixtures/KnownGaps.md and re-pin this test")
  }

  /// Gap 3: semantic (Type-4) clones — same behavior, different tokens —
  /// are out of scope for a token-based engine entirely.
  @Test("semantic clones (same behavior, different shape) are not detected")
  func semanticClonesAreMissed() async {
    let iterative = """
      func sumIterative(values: [Int], floor: Int, scale: Int) -> Int {
          var total = 0
          for value in values {
              if value > floor {
                  total += value * scale
              }
          }
          return total
      }
      """
    let functional = """
      func sumFunctional(values: [Int], floor: Int, scale: Int) -> Int {
          values.filter { $0 > floor }.map { $0 * scale }.reduce(0, +)
      }
      """
    let report = await Analyzer().analyze(
      source: iterative + "\n" + functional + "\n", path: "semantic.swift")
    #expect(report.findings.isEmpty)
  }
}
