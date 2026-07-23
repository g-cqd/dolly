//  BenchmarkEntry.swift
//  dolly
//
//  Stage-level entry points for the local `Benchmarks/` package, SPI-gated so
//  they never surface in the public API. Each function pins one pipeline
//  stage in isolation, mirroring the Analyzer's wiring exactly, so stage
//  benchmarks measure the same code the production path runs.

import SwiftParser
import SwiftSyntax

/// Opaque corpus handle passed between benchmark stages so per-stage
/// benchmarks can share one extraction pass without exposing engine types.
@_spi(Benchmark) public struct BenchmarkTokenCorpus: Sendable {
  let corpus: TokenCorpus
}

/// Namespace for the SPI benchmark hooks.
@_spi(Benchmark) public enum BenchmarkEntry {
  /// Extraction stage: parse + per-file interned extraction + corpus
  /// assembly (the one corpus-level intern pass).
  public static func extract(files: [(path: String, source: String)]) -> BenchmarkTokenCorpus {
    let extractor = TokenSequenceExtractor()
    let fileTokens = files.map { file in
      let tree = Parser.parse(source: file.source)
      return extractor.extract(from: tree, file: file.path, source: file.source)
    }
    return BenchmarkTokenCorpus(corpus: CorpusAssembler.assemble(files: fileTokens))
  }

  /// Exact + near suffix-array stage over a prepared corpus (the serial
  /// engine the default configuration runs).
  public static func exactNearGroupCount(
    _ corpus: BenchmarkTokenCorpus, minimumTokens: Int
  ) -> Int {
    let engine = DuplicationEngine(
      configuration: DuplicationConfiguration(minimumTokens: minimumTokens))
    return engine.detectClones(in: corpus.corpus, types: [.exact, .near]).count
  }

  /// Structural stage: block shingling, candidate generation, verification,
  /// and grouping — the same detector `DuplicationDetector` dispatches to.
  public static func structuralGroupCount(
    _ corpus: BenchmarkTokenCorpus, minimumTokens: Int, minimumSimilarity: Double
  ) async -> Int {
    let detector = StructuralCloneDetector(
      minimumTokens: minimumTokens,
      shingleSize: 5,
      minimumSimilarity: minimumSimilarity
    )
    return await detector.detect(in: corpus.corpus.sequences).count
  }
}
