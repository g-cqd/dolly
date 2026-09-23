//  CancellationTests.swift
//  dolly
//
//  A cancelled run must report nothing rather than something wrong:
//  a region is a clone because a match exists elsewhere in the corpus, so a
///   partial corpus both drops real clones and invents intra-subset ones.
//  Under a CI timeout that is the difference between a failed job and a
//  confidently wrong one.

import Foundation
import Testing

@testable import DollyCore

@Suite(.serialized) struct CancellationTests {
  private func makeWorkspace() throws -> (owner: TemporaryTestDirectory, files: [String]) {
    let owner = try TemporaryTestDirectory(prefix: "dolly-cancel")
    let root = owner.url
    var files: [String] = []
    for index in 0..<3 {
      let file = root.appendingPathComponent("File\(index).swift")
      try "private func unused\(index)() {}\nfinal class C\(index) {}\n"
        .write(to: file, atomically: true, encoding: .utf8)
      files.append(file.path)
    }
    return (owner, files)
  }

  @Test("A cancelled run reports nothing and says so")
  func cancelledRunReportsNothing() async throws {
    let workspace = try makeWorkspace()
    defer { withExtendedLifetime(workspace.owner) {} }
    let task = Task { await Analyzer().analyze(files: workspace.files) }
    task.cancel()
    let report = await task.value
    #expect(report.wasCancelled)
    #expect(report.findings.isEmpty)
    #expect(report.outOfScope.isEmpty)
  }

  @Test("An uncancelled run over the same corpus is unaffected")
  func uncancelledRunIsNormal() async throws {
    let workspace = try makeWorkspace()
    defer { withExtendedLifetime(workspace.owner) {} }
    let report = await Analyzer().analyze(files: workspace.files)
    #expect(!report.wasCancelled)
  }

  @Test func `workspace fixture is removed after use`() throws {
    let directory = NSTemporaryDirectory()
    let before = Set(
      try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasPrefix("dolly-cancel-") })
    _ = try makeWorkspace()
    let after = Set(
      try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasPrefix("dolly-cancel-") })
    #expect(after == before)
  }
}
