//  DollyBenchmarks.swift
//  dolly Benchmarks — local-only, never in CI.
//
//  Four benchmarks over one deterministic synthetic corpus:
//    (a) end-to-end `Analyzer.analyze(files:)`, cold, from disk
//    (b) extraction stage only (parse + token extraction)
//    (c) exact+near suffix-array stage
//    (d) structural stage
//  The corpus is generated in-benchmark from fixed constants (no Date, no
//  random seeds) so numbers are comparable across runs and stages.

import Benchmark
import Foundation

@_spi(Benchmark) import DollyCore

// MARK: - Deterministic PRNG

/// SplitMix64 with a fixed seed — the corpus must be bit-identical run to run.
private struct SplitMix64 {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value &>> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value &>> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value &>> 31)
  }

  /// Uniform value in 0..<bound.
  mutating func below(_ bound: Int) -> Int {
    Int(next() % UInt64(bound))
  }
}

// MARK: - Synthetic corpus

/// ~200 files of ~2000 tokens each with planted exact / near / structural
/// clone pairs at fixed file indices.
private enum SyntheticCorpus {
  static let fileCount = 200
  static let functionsPerFile = 12
  static let seed: UInt64 = 0xD011_BE9C_0FFE_E001

  /// Planted exact pairs: the identical body text appears in both files.
  static let exactPairs: [(Int, Int)] = [(10, 47), (60, 97), (110, 147), (160, 197)]
  /// Planted near pairs: identical shape, all identifiers/literals renamed.
  static let nearPairs: [(Int, Int)] = [(20, 57), (70, 107), (120, 157), (3, 170)]
  /// Planted structural pairs: shared shape with ~25% edited statements.
  static let structuralPairs: [(Int, Int)] = [(30, 67), (80, 117), (5, 180)]

  static func makeFiles() -> [(path: String, source: String)] {
    var rng = SplitMix64(state: seed)
    var files: [(path: String, source: String)] = []
    files.reserveCapacity(fileCount)

    for fileIndex in 0..<fileCount {
      var chunks: [String] = ["import Foundation\n"]
      for functionIndex in 0..<functionsPerFile {
        chunks.append(fillerFunction(file: fileIndex, index: functionIndex, rng: &rng))
      }
      for (planted, tag) in plantedFunctions(for: fileIndex) {
        chunks.append(planted)
        _ = tag
      }
      files.append(("Bench\(fileIndex).swift", chunks.joined(separator: "\n")))
    }
    return files
  }

  /// A filler function of ~160 tokens whose statement-kind sequence is drawn
  /// from the seeded PRNG, so structures rarely collide across the corpus.
  private static func fillerFunction(file: Int, index: Int, rng: inout SplitMix64) -> String {
    let name = "worker\(file)x\(index)"
    let suffix = "\(file)_\(index)"
    var lines: [String] = [
      "func \(name)(alpha\(suffix): Int, beta\(suffix): Int) -> Int {",
      "    var acc\(suffix) = alpha\(suffix) &+ \(rng.below(90) + 1)",
    ]
    let statementCount = 8 + rng.below(6)
    for statement in 0..<statementCount {
      let k1 = rng.below(500) + 2
      let k2 = rng.below(50) + 1
      let v = "v\(suffix)x\(statement)"
      switch rng.below(8) {
      case 0:
        lines.append("    let \(v) = alpha\(suffix) &+ beta\(suffix) &* \(k1)")
        lines.append("    acc\(suffix) &+= \(v)")
      case 1:
        lines.append("    if acc\(suffix) > \(k1) { acc\(suffix) &-= \(k2) } else { acc\(suffix) &+= \(k2) }")
      case 2:
        lines.append("    for step\(statement) in 0..<\(k2) { acc\(suffix) &+= step\(statement) &* \(k1) }")
      case 3:
        lines.append("    let \(v) = min(max(acc\(suffix), \(k2)), \(k1))")
        lines.append("    acc\(suffix) &+= \(v) &* 2")
      case 4:
        lines.append("    let \(v) = \"tag-\(k1)\" + String(acc\(suffix))")
        lines.append("    acc\(suffix) &+= \(v).count")
      case 5:
        lines.append("    while acc\(suffix) < \(k1) { acc\(suffix) &+= \(k2) }")
      case 6:
        lines.append("    let \(v) = [\(k1), \(k2), \(k1 + k2)].reduce(0, &+)")
        lines.append("    acc\(suffix) &+= \(v)")
      default:
        lines.append("    acc\(suffix) = (acc\(suffix) &* \(k2)) % \(k1)")
      }
    }
    lines.append("    return acc\(suffix) &- beta\(suffix)")
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  /// The planted-clone bodies for a file, all built from fixed constants.
  private static func plantedFunctions(for fileIndex: Int) -> [(String, String)] {
    var planted: [(String, String)] = []
    for (pairIndex, pair) in exactPairs.enumerated() where pair.0 == fileIndex || pair.1 == fileIndex {
      // Same body text on both sides; only the name differs, so the run
      // from the parameter list on is raw-identical (Type-1).
      let side = pair.0 == fileIndex ? 0 : 1
      planted.append((plantedExactBody(pairIndex: pairIndex, side: side), "exact"))
    }
    for (pairIndex, pair) in nearPairs.enumerated() where pair.0 == fileIndex || pair.1 == fileIndex {
      let side = pair.0 == fileIndex ? 0 : 1
      planted.append((plantedNearBody(pairIndex: pairIndex, side: side), "near"))
    }
    for (pairIndex, pair) in structuralPairs.enumerated()
    where pair.0 == fileIndex || pair.1 == fileIndex {
      let side = pair.0 == fileIndex ? 0 : 1
      planted.append((plantedStructuralBody(pairIndex: pairIndex, side: side), "structural"))
    }
    return planted
  }

  private static func plantedExactBody(pairIndex: Int, side: Int) -> String {
    """
    func plantedExact\(pairIndex)side\(side)(records: [String], limit: Int) -> [String] {
        var seenKeys: Set<String> = []
        var keptRecords: [String] = []
        for record in records {
            let trimmed = record.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)
            if keptRecords.count < limit {
                keptRecords.append(trimmed)
            }
        }
        return keptRecords.sorted()
    }
    """
  }

  private static func plantedNearBody(pairIndex: Int, side: Int) -> String {
    let n = { (a: String, b: String) in side == 0 ? a : b }
    return """
      func \(n("collectMetrics", "gatherSamples"))\(pairIndex)(\(n("inputs", "values")): [Double]) -> Double {
          var \(n("total", "sum")) = \(n("0.0", "1.0"))
          var \(n("peak", "high")) = \(n("0.5", "2.5"))
          for \(n("item", "entry")) in \(n("inputs", "values")) {
              \(n("total", "sum")) += \(n("item", "entry")) * \(n("1.25", "3.75"))
              if \(n("item", "entry")) > \(n("peak", "high")) {
                  \(n("peak", "high")) = \(n("item", "entry")) + \(n("0.125", "0.875"))
              } else {
                  \(n("total", "sum")) -= \(n("0.25", "0.5"))
              }
          }
          let \(n("blended", "merged")) = \(n("total", "sum")) + \(n("peak", "high")) * \(n("2.0", "4.0"))
          return \(n("blended", "merged")) - \(n("1.0", "3.0"))
      }
      """
  }

  private static func plantedStructuralBody(pairIndex: Int, side: Int) -> String {
    let shared = """
          var counter\(pairIndex) = 0
          var running\(pairIndex) = 1
          for element in payload {
              counter\(pairIndex) += element.count
              running\(pairIndex) += counter\(pairIndex) % 7
          }
          let scaled\(pairIndex) = running\(pairIndex) * 3 + counter\(pairIndex)
      """
    let tailA = """
          let capped\(pairIndex) = min(scaled\(pairIndex), 4096)
          return capped\(pairIndex) + payload.count
      """
    let tailB = """
          let floored\(pairIndex) = max(scaled\(pairIndex), 16)
          return floored\(pairIndex) - payload.count
      """
    return """
      func structural\(pairIndex)side\(side)(payload: [String]) -> Int {
      \(shared)
      \(side == 0 ? tailA : tailB)
      }
      """
  }
}

// MARK: - Corpus on disk (for the cold end-to-end benchmark)

private func writeCorpusToDisk(_ files: [(path: String, source: String)]) -> [String] {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "dolly-bench-corpus", directoryHint: .isDirectory)
  try? FileManager.default.removeItem(at: root)
  try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return files.map { file in
    let url = root.appending(path: file.path)
    try! file.source.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }.sorted()
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
  let files = SyntheticCorpus.makeFiles()
  let paths = writeCorpusToDisk(files)
  let corpus = BenchmarkEntry.extract(files: files)

  Benchmark(
    "end-to-end analyze cold",
    configuration: .init(
      metrics: [.wallClock, .mallocCountTotal], maxDuration: .seconds(60), maxIterations: 5)
  ) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(await Analyzer().analyze(files: paths))
    }
  }

  // Warm run: the facts cache is primed by the warmup iteration (excluded
  // from samples), so measured iterations skip parse + extraction.
  let warmCache = FileManager.default.temporaryDirectory
    .appending(path: "dolly-bench-cache", directoryHint: .isDirectory)
    .appending(path: "facts.json")
  try? FileManager.default.removeItem(at: warmCache)

  Benchmark(
    "end-to-end analyze warm cache",
    configuration: .init(
      metrics: [.wallClock, .mallocCountTotal], warmupIterations: 1,
      maxDuration: .seconds(60), maxIterations: 5)
  ) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(await Analyzer(cacheURL: warmCache).analyze(files: paths))
    }
  }

  Benchmark(
    "extraction stage",
    configuration: .init(
      metrics: [.wallClock, .mallocCountTotal], maxDuration: .seconds(30), maxIterations: 10)
  ) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(BenchmarkEntry.extract(files: files))
    }
  }

  Benchmark(
    "exact+near stage",
    configuration: .init(
      metrics: [.wallClock, .mallocCountTotal], maxDuration: .seconds(30), maxIterations: 10)
  ) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(BenchmarkEntry.exactNearGroupCount(corpus, minimumTokens: 50))
    }
  }

  Benchmark(
    "structural stage",
    configuration: .init(
      metrics: [.wallClock, .mallocCountTotal], maxDuration: .seconds(60), maxIterations: 5)
  ) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(
        await BenchmarkEntry.structuralGroupCount(
          corpus, minimumTokens: 50, minimumSimilarity: 0.8))
    }
  }
}
