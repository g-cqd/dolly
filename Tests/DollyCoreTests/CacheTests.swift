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

    // Rewrite the payload with a bogus version.
    var text = try String(contentsOf: cache, encoding: .utf8)
    text = text.replacingOccurrences(
      of: "\"version\":\"\(ToolInfo.version)\"", with: "\"version\":\"0.0.0-old\"")
    try text.write(to: cache, atomically: true, encoding: .utf8)

    let report = await analyzer.analyze(files: files)
    #expect(report.cacheHits == 0)
    #expect(report.cacheMisses == 2)
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
