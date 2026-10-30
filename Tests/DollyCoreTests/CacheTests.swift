//  CacheTests.swift
//  dolly
//
//  The facts cache is an optimization and must NEVER change results: hit
//  and miss runs produce identical findings. The cache itself (shards,
//  corruption failing open, identity, pruning, the budget) is analyzerkit's
//  CorpusScanner, tested there (roadmap 0020).

import CorpusScan
import Foundation
import SourceCorpus
import Testing

@testable import DollyCore

@Suite struct CacheTests {
  private func makeWorkspace() throws -> (dir: URL, cache: CacheLocation, files: [String]) {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cache = CacheLocation(root: dir.appending(path: "cache").path, workspace: dir.path)

    let clone = """
      func aggregateScores(scores: [Double]) -> Double {
          var total = 0.0
          var compound = 1.0
          for element in scores {
              if element > 12.5 {
                  total += element * 1.75
              } else {
                  compound *= element + 3.25
              }
          }
          let combined = total + compound * 1.75
          return combined - 3.25
      }
      """
    let first = dir.appending(path: "a.swift")
    let second = dir.appending(path: "b.swift")
    try (clone + "\n").write(to: first, atomically: true, encoding: .utf8)
    try (clone + "\n// @dl:accept exact-clone -- test\n").write(
      to: second, atomically: true, encoding: .utf8)
    return (dir, cache, [first.path, second.path])
  }

  @Test("cold run misses, warm run hits, findings identical")
  func hitAndMiss() async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let analyzer = Analyzer(cache: cache)

    let cold = await analyzer.analyze(files: files)
    #expect(cold.cacheHits == 0)
    #expect(cold.cacheMisses == 2)

    let warm = await analyzer.analyze(files: files)
    #expect(warm.cacheHits == 2)
    #expect(warm.cacheMisses == 0)

    #expect(cold.findings == warm.findings)
    #expect(!warm.findings.isEmpty, "the cross-file clone must be found from cached facts")
    // Directives are cached too: the second file's accept must keep
    // suppressing on the warm run.
    #expect(cold.suppressed.count == warm.suppressed.count)
  }

  @Test("editing a file invalidates only its entry")
  func fingerprintInvalidation() async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let analyzer = Analyzer(cache: cache)
    _ = await analyzer.analyze(files: files)

    try "func changed() -> Int { 1 }\n".write(
      to: URL(fileURLWithPath: files[0]), atomically: true, encoding: .utf8)
    let rerun = await analyzer.analyze(files: files)
    #expect(rerun.cacheHits == 1)
    #expect(rerun.cacheMisses == 1)
  }

  /// Extraction (tokens, directives, content region, previews) depends on no configuration, so a changed
  /// configuration reuses every file's facts, and its findings are those a run without a cache finds.
  @Test(
    "a change of rules or configuration reuses the facts and finds what an uncached run finds",
    arguments: [
      Configuration(rules: [RuleID.structuralClone.rawValue: .init(enabled: false)]),
      Configuration(duplication: .init(minimumTokens: 40)),
      Configuration(exclude: ["never-matches-a-source"]),
    ])
  func configurationReusesFacts(configuration: Configuration) async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = await Analyzer(cache: cache).analyze(files: files)

    let rerun = await Analyzer(configuration: configuration, cache: cache).analyze(files: files)
    #expect(rerun.cacheHits == 2)
    let uncached = await Analyzer(configuration: configuration).analyze(files: files)
    #expect(rerun.findings == uncached.findings)
    #expect(rerun.suppressed.count == uncached.suppressed.count)
  }

  @Test("Replacing an executable changes its cache identity")
  func executableIdentityChanges() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-build-id-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let executable = dir.appending(path: "tool")
    try Data([1]).write(to: executable)
    let before = try #require(BuildIdentity.identity(ofExecutableAt: executable.path))
    try Data([1, 2]).write(to: executable)
    let after = try #require(BuildIdentity.identity(ofExecutableAt: executable.path))
    #expect(before != after)
  }

  @Test("no cache means no cache accounting")
  func disabledCache() async throws {
    let (dir, _, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let report = await Analyzer().analyze(files: files)
    #expect(report.cacheHits == 0)
    #expect(report.cacheMisses == 0)
  }
}
