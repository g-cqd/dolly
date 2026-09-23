//  FingerprintPortabilityTests.swift
//  dolly
//
//  A baseline is only useful if the same finding fingerprints identically
//  wherever it is computed. Before fingerprints were anchored to the
//  repository, a run with --relative-to and one without shared zero
//  fingerprints, so a baseline written locally suppressed nothing in CI —
//  silently, because a fingerprint matching nothing is indistinguishable from a
//  genuinely new finding.

import Foundation
import Testing

@testable import DollyCore

@Suite struct FingerprintPortabilityTests {
  /// The default 50-token floor sits above a compact fixture, so the pair below
  /// only registers as a clone under a lowered threshold.
  private static let sensitive = Configuration(
    duplication: Configuration.DuplicationSettings(minimumTokens: 20))

  private static let clonePair = """
    func alphaOne(_ a: Int, _ b: Int) -> Int {
      let x = a + b
      let y = x * 2
      let z = y - a
      let w = z + b
      let v = w * 3
      return v - x
    }
    func alphaTwo(_ c: Int, _ d: Int) -> Int {
      let x = c + d
      let y = x * 2
      let z = y - c
      let w = z + d
      let v = w * 3
      return v - x
    }
    """

  private func makeCheckout(named name: String) throws -> (
    owner: TemporaryTestDirectory, files: [String]
  ) {
    let owner = try TemporaryTestDirectory(prefix: "dolly-fp-\(name)")
    let root = owner.url
    // A `.git` entry is what marks the anchor; its contents are irrelevant.
    try Data().write(to: root.appendingPathComponent(".git"))
    let file = root.appendingPathComponent("Sample.swift")
    try Self.clonePair.write(to: file, atomically: true, encoding: .utf8)
    return (owner, [file.path])
  }

  @Test("The same code in two checkouts fingerprints identically")
  func portableAcrossCheckouts() async throws {
    let firstCheckout = try makeCheckout(named: "here")
    let secondCheckout = try makeCheckout(named: "there")
    defer {
      withExtendedLifetime(firstCheckout.owner) {}
      withExtendedLifetime(secondCheckout.owner) {}
    }
    let here = await Analyzer(configuration: Self.sensitive)
      .analyze(files: firstCheckout.files)
    let there = await Analyzer(configuration: Self.sensitive)
      .analyze(files: secondCheckout.files)
    #expect(!here.findings.isEmpty)
    #expect(here.findings.map(\.fingerprint) == there.findings.map(\.fingerprint))
    let firstHere = try #require(here.findings.first)
    let firstThere = try #require(there.findings.first)
    #expect(firstHere.path != firstThere.path)
  }

  @Test("Fingerprints hash the repository-relative path")
  func anchoredToRepositoryRoot() async throws {
    let checkout = try makeCheckout(named: "anchor")
    defer { withExtendedLifetime(checkout.owner) {} }
    let report = await Analyzer(configuration: Self.sensitive)
      .analyze(files: checkout.files)
    let finding = try #require(report.findings.first)
    #expect(finding.fingerprintPath == "Sample.swift")
  }
}
