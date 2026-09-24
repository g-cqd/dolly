//  CacheTests.swift
//  dolly
//
//  The facts cache is an optimization and must NEVER change results:
//  hit and miss runs produce identical findings, corruption fails open,
//  and entries for absent files are pruned.

import Foundation
import Testing

@testable import DollyCore

@Suite struct CacheTests {
  private func makeWorkspace() throws -> (dir: URL, cache: URL, files: [String]) {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cache = dir.appending(path: "facts.json")

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
    let analyzer = Analyzer(cacheURL: cache)

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
    let analyzer = Analyzer(cacheURL: cache)
    _ = await analyzer.analyze(files: files)

    try "func changed() -> Int { 1 }\n".write(
      to: URL(fileURLWithPath: files[0]), atomically: true, encoding: .utf8)
    let rerun = await analyzer.analyze(files: files)
    #expect(rerun.cacheHits == 1)
    #expect(rerun.cacheMisses == 1)
  }

  @Test("corrupt cache fails open and is rewritten")
  func corruptCacheFailsOpen() async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{ not json ]]".utf8).write(to: cache)

    let analyzer = Analyzer(cacheURL: cache)
    let report = await analyzer.analyze(files: files)
    #expect(report.cacheHits == 0)
    #expect(report.cacheMisses == 2)
    #expect(!report.findings.isEmpty)

    // The bad cache was replaced by a working one.
    let warm = await analyzer.analyze(files: files)
    #expect(warm.cacheHits == 2)
  }

  @Test("version mismatch discards the whole cache")
  func versionGate() async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let analyzer = Analyzer(cacheURL: cache)
    _ = await analyzer.analyze(files: files)

    // Rewrite the checked header with a bogus version.
    var text = try String(contentsOf: cache, encoding: .utf8)
    text = text.replacingOccurrences(
      of: "facts \(ToolInfo.version) ", with: "facts 0.0.0-old ")
    try text.write(to: cache, atomically: true, encoding: .utf8)

    let report = await analyzer.analyze(files: files)
    #expect(report.cacheHits == 0)
    #expect(report.cacheMisses == 2)
  }

  @Test("a cache written by another build is a miss at the same tool version")
  func buildIdentityGate() async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let analyzer = Analyzer(cacheURL: cache)
    _ = await analyzer.analyze(files: files)
    let snapshot = FactsCache.load(url: cache)
    #expect(snapshot.entries.count == 2)
    snapshot.persist(url: cache, build: "another-build")

    let rerun = await analyzer.analyze(files: files)
    #expect(rerun.cacheHits == 0)
    #expect(rerun.cacheMisses == 2)
    #expect((await analyzer.analyze(files: files)).cacheHits == 2)
  }

  @Test(
    "a change to rules or configuration invalidates cached facts",
    arguments: [
      Configuration(rules: [RuleID.structuralClone.rawValue: .init(enabled: false)]),
      Configuration(duplication: .init(minimumTokens: 40)),
      Configuration(exclude: ["never-matches-a-source"]),
    ])
  func configurationGate(configuration: Configuration) async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = Analyzer(cacheURL: cache)
    _ = await original.analyze(files: files)

    let changed = Analyzer(configuration: configuration, cacheURL: cache)
    let rerun = await changed.analyze(files: files)
    #expect(rerun.cacheHits == 0)
    #expect(rerun.cacheMisses == 2)
    #expect((await changed.analyze(files: files)).cacheHits == 2)
  }

  @Test("a matching cache header with malformed contents is a miss")
  func malformedMatchingCache() async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let build = try #require(BuildIdentity.current)
    let header = try #require(FactsCache.header(build: build, configuration: .default))
    try Data("\(header)\n{ invalid json".utf8).write(to: cache)

    let analyzer = Analyzer(cacheURL: cache)
    let rerun = await analyzer.analyze(files: files)
    #expect(rerun.cacheHits == 0)
    #expect(rerun.cacheMisses == 2)
    #expect((await analyzer.analyze(files: files)).cacheHits == 2)
  }

  /// load refuses a cache over its size cap, so persist must not write one:
  /// past the cap, every run would write a file no run can read.
  @Test("persist never writes a cache load would refuse")
  func persistHoldsToTheLoadCap() async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = await Analyzer(cacheURL: cache).analyze(files: files)
    let snapshot = FactsCache.load(url: cache)
    #expect(snapshot.entries.count == 2)

    // A cap of one byte stands in for a corpus that outgrew the real one.
    snapshot.persist(url: cache, cap: 1)
    // Neither the oversized cache nor the one it would have replaced.
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    #expect(FactsCache.load(url: cache).entries.isEmpty)
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

  @Test("entries for absent files are pruned on persist")
  func pruneAbsentFiles() async throws {
    let (dir, cache, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let analyzer = Analyzer(cacheURL: cache)
    _ = await analyzer.analyze(files: files)
    #expect(Set(FactsCache.load(url: cache).entries.keys) == Set(files))

    _ = await analyzer.analyze(files: [files[0]])
    #expect(Set(FactsCache.load(url: cache).entries.keys) == [files[0]])
  }

  @Test("fingerprint is stable and length-suffixed")
  func fingerprintStability() {
    let data = Data([1, 2, 3, 4, 5])
    let first = FactsCache.fingerprint(of: data)
    #expect(first == FactsCache.fingerprint(of: data))
    #expect(first.hasSuffix("-5"))
    #expect(first != FactsCache.fingerprint(of: Data([1, 2, 3, 4, 6])))
    #expect(FactsCache.fingerprint(of: Data()) != FactsCache.fingerprint(of: Data([0])))
  }

  @Test("no cache URL means no cache accounting")
  func disabledCache() async throws {
    let (dir, _, files) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: dir) }
    let report = await Analyzer().analyze(files: files)
    #expect(report.cacheHits == 0)
    #expect(report.cacheMisses == 0)
  }
}
