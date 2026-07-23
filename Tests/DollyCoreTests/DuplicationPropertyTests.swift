//  DuplicationPropertyTests.swift
//  dolly
//
//  Property-style checks over the wired pipeline: alpha-renaming preserves
//  near-clones, statement reordering destroys exact-clones, and groups span
//  files through `analyze(files:)`.

import Foundation
import Testing

@testable import DollyCore

@Suite struct DuplicationPropertyTests {
  /// A ~70-token function template whose every identifier and literal is
  /// substitutable.
  private static func function(
    name: String, input: String, sum: String, product: String,
    limit: String, factor: String, offset: String
  ) -> String {
    """
    func \(name)(\(input): [Double]) -> Double {
        var \(sum) = 0.0
        var \(product) = 1.0
        for element in \(input) {
            if element > \(limit) {
                \(sum) += element * \(factor)
            } else {
                \(product) *= element + \(offset)
            }
        }
        let combined = \(sum) + \(product) * \(factor)
        return combined - \(offset)
    }
    """
  }

  private static let baseFunction = function(
    name: "aggregateScores", input: "scores", sum: "total", product: "compound",
    limit: "12.5", factor: "1.75", offset: "3.25")

  /// Full alpha-renames of the base function: every identifier and every
  /// literal differs, so no 50-token run of raw tokens can survive.
  private static let renames: [(String, String)] = [
    (
      "rename set 1",
      function(
        name: "combineWeights", input: "weights", sum: "left", product: "right",
        limit: "99.0", factor: "42.5", offset: "0.125")
    ),
    (
      "rename set 2",
      function(
        name: "foldMeasurements", input: "samples", sum: "acc", product: "mult",
        limit: "7.75", factor: "88.25", offset: "654.5")
    ),
    (
      "rename set 3",
      function(
        name: "mergeDeltas", input: "deltas", sum: "high", product: "low",
        limit: "1.5", factor: "2.25", offset: "9.875")
    ),
  ]

  @Test(
    "Alpha-renaming a clone still yields a near-clone (never an exact-clone)", arguments: renames)
  func renamedCloneIsNearClone(_ variant: (label: String, source: String)) async {
    let source = Self.baseFunction + "\n\n" + variant.source + "\n"
    let report = await Analyzer().analyze(source: source, path: "renamed.swift")

    let rules = Set(report.findings.map(\.rule))
    #expect(rules.contains(.nearClone), "\(variant.label): expected a near-clone")
    #expect(!rules.contains(.exactClone), "\(variant.label): renames must break exact runs")
  }

  @Test("Reordering statements breaks the exact-clone")
  func reorderingBreaksExactClone() async {
    let original =
      Self.baseFunction + "\n\n"
      + Self.function(
        name: "aggregateScoresCopy", input: "scores", sum: "total", product: "compound",
        limit: "12.5", factor: "1.75", offset: "3.25") + "\n"
    let originalReport = await Analyzer().analyze(source: original, path: "pair.swift")
    #expect(
      originalReport.findings.contains { $0.rule == .exactClone },
      "identical pair must produce an exact-clone")

    // Swap the two branch statements in the copy: same tokens, new order.
    let reorderedCopy = Self.function(
      name: "aggregateScoresCopy", input: "scores", sum: "total", product: "compound",
      limit: "12.5", factor: "1.75", offset: "3.25"
    )
    .replacingOccurrences(of: "total += element * 1.75", with: "total *= element + 3.25")
    .replacingOccurrences(of: "compound *= element + 3.25", with: "compound += element * 1.75")
    let reordered = Self.baseFunction + "\n\n" + reorderedCopy + "\n"
    let reorderedReport = await Analyzer().analyze(source: reordered, path: "pair.swift")
    #expect(
      !reorderedReport.findings.contains { $0.rule == .exactClone },
      "reordered statements must not match as an exact clone")
  }

  @Test("Cross-file clone group is detected via analyze(files:)")
  func crossFileGroupDetected() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-xfile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = dir.appending(path: "a.swift")
    let second = dir.appending(path: "b.swift")
    try (Self.baseFunction + "\n").write(to: first, atomically: true, encoding: .utf8)
    try (Self.baseFunction + "\n").write(to: second, atomically: true, encoding: .utf8)

    let report = await Analyzer().analyze(files: [first.path, second.path])

    let exact = report.findings.filter { $0.rule == .exactClone }
    #expect(exact.count == 1, "one group spanning both files, reported once")
    let finding = try #require(exact.first)
    #expect(finding.path == first.path, "anchored at the first member")
    #expect(finding.note?.contains(second.path) == true, "note lists the other member")
    #expect(report.analyzedFileCount == 2)
  }

  @Test("Duplication settings plumb through from configuration")
  func duplicationSettingsRespected() async {
    // With the default 50-token floor this ~30-token pair is silent;
    // lowering minimumTokens through the config block surfaces it.
    let tiny = """
      func firstTiny(a: Int, b: Int) -> Int {
          let sum = a + b
          let doubled = sum * 2
          return doubled - 1
      }

      func secondTiny(a: Int, b: Int) -> Int {
          let sum = a + b
          let doubled = sum * 2
          return doubled - 1
      }
      """
    let silent = await Analyzer().analyze(source: tiny, path: "tiny.swift")
    #expect(silent.findings.isEmpty)

    let tuned = Configuration(
      duplication: .init(minimumTokens: 20, minimumSimilarity: 0.8))
    let loud = await Analyzer(configuration: tuned).analyze(source: tiny, path: "tiny.swift")
    #expect(loud.findings.contains { $0.rule == .exactClone })
  }
}
