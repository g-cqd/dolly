//  SemanticAlgorithmTests.swift
//  dolly
//
//  Cross-platform unit tests for the semantic pass's pure algorithms — the
//  deterministic (model-free) embedding provider, HNSW ANN index, TokenJaccard
//  fusion, and EmbeddingCloneDiscovery grouping. No CoreML / NaturalLanguage
//  model is involved, so these exercise the math on every platform (including
//  the required Linux CI lane).

import Foundation
import Testing

@testable import DollyCore

@Suite struct SemanticAlgorithmTests {
  // MARK: - DeterministicEmbeddingProvider

  @Test("Deterministic provider: right dimension, stable, zero for short input")
  func deterministicProvider() async throws {
    let provider = DeterministicEmbeddingProvider(dimension: 64, ngramSize: 3)
    #expect(provider.embeddingDimension == 64)

    let a = try await provider.embed(snippet: "let total = values.reduce(0, +)")
    let b = try await provider.embed(snippet: "let total = values.reduce(0, +)")
    #expect(a.count == 64)
    #expect(a == b, "same input must hash to the same vector")

    let different = try await provider.embed(snippet: "for value in values { total += value }")
    #expect(different != a, "different input must differ")

    // Shorter than the n-gram window → all-zero vector.
    let tiny = try await provider.embed(snippet: "ab")
    #expect(tiny.allSatisfy { $0 == 0 })
  }

  // MARK: - TokenJaccard

  @Test("TokenJaccard: identical=1, disjoint=0, partial overlap, stop-words dropped")
  func tokenJaccard() {
    #expect(TokenJaccard.similarity("apple banana", "apple banana") == 1.0)
    #expect(TokenJaccard.similarity("apple banana", "cherry date") == 0.0)
    // {apple, banana} vs {apple, cherry}: 1 / 3.
    let partial = TokenJaccard.similarity("apple banana", "apple cherry")
    #expect(abs(partial - (1.0 / 3.0)) < 1e-9)
    // Pure Swift keywords are all stop-words → empty vocabulary.
    #expect(TokenJaccard.tokenSet("func return if else guard").isEmpty)
    // Case-insensitive; `_` keeps identifiers together.
    #expect(TokenJaccard.tokenSet("Total_Count") == ["total_count"])
  }

  // MARK: - HNSWIndex

  @Test("HNSW returns the true nearest neighbor and is deterministic")
  func hnswNearestNeighbor() {
    func build() -> HNSWIndex<Int> {
      var index = HNSWIndex<Int>(dimension: 3)
      index.insert(id: 0, vector: [1, 0, 0])
      index.insert(id: 1, vector: [0, 1, 0])
      index.insert(id: 2, vector: [0.9, 0.1, 0])  // closest to id 0
      return index
    }
    let results = build().search(query: [1, 0, 0], k: 3)
    #expect(results.first?.id == 0)
    #expect(results.first.map { $0.similarity > 0.99 } == true)
    // id 2 (cosine ~0.99) must outrank the orthogonal id 1.
    let ranked = results.map(\.id)
    if let two = ranked.firstIndex(of: 2), let one = ranked.firstIndex(of: 1) {
      #expect(two < one)
    }
    // Deterministic: a rebuilt index yields identical results.
    let again = build().search(query: [1, 0, 0], k: 3)
    #expect(results.map(\.id) == again.map(\.id))
  }

  @Test("SeededPRNG is deterministic for a fixed seed")
  func seededPRNG() {
    var a = SeededPRNG(seed: 42)
    var b = SeededPRNG(seed: 42)
    #expect((0..<8).map { _ in a.next() } == (0..<8).map { _ in b.next() })
  }

  // MARK: - EmbeddingCloneDiscovery

  private func snippet(_ file: String, _ code: String) -> EmbeddingSnippet {
    EmbeddingSnippet(file: file, startLine: 1, endLine: 6, tokenCount: 20, code: code)
  }

  @Test("Discovery groups identical snippets across files, one semantic group")
  func discoveryGroupsIdentical() async throws {
    let code = "func total(_ values: [Int]) -> Int { values.reduce(0, +) }"
    let snippets = [snippet("A.swift", code), snippet("B.swift", code)]
    let groups = try await EmbeddingCloneDiscovery().discover(
      snippets: snippets,
      provider: DeterministicEmbeddingProvider(dimension: 128),
      k: 5,
      similarityThreshold: 0.9,
      minTokenOverlap: 0.2
    )
    #expect(groups.count == 1)
    #expect(groups.first?.type == .semantic)
    #expect(groups.first?.clones.count == 2)
    let files = Set((groups.first?.clones ?? []).map(\.file))
    #expect(files == ["A.swift", "B.swift"])
  }

  @Test("Discovery adds nothing when snippets are unrelated")
  func discoveryAddsNothingWithoutMatches() async throws {
    let snippets = [
      snippet("A.swift", "func alpha(_ x: Int) -> Int { x * 3 + 7 }"),
      snippet("B.swift", "let greeting = \"the quick brown fox jumps over\""),
      snippet("C.swift", "struct Point { var latitude: Double; var longitude: Double }"),
    ]
    let groups = try await EmbeddingCloneDiscovery().discover(
      snippets: snippets,
      provider: DeterministicEmbeddingProvider(dimension: 128),
      k: 5,
      similarityThreshold: 0.9,
      minTokenOverlap: 0.2
    )
    #expect(groups.isEmpty)
  }

  @Test("Discovery skips overlapping same-file ranges")
  func discoverySkipsSameFileOverlap() async throws {
    let code = "func total(_ values: [Int]) -> Int { values.reduce(0, +) }"
    let overlapping = [
      EmbeddingSnippet(file: "A.swift", startLine: 1, endLine: 6, tokenCount: 20, code: code),
      EmbeddingSnippet(file: "A.swift", startLine: 3, endLine: 8, tokenCount: 20, code: code),
    ]
    let groups = try await EmbeddingCloneDiscovery().discover(
      snippets: overlapping,
      provider: DeterministicEmbeddingProvider(dimension: 128),
      k: 5,
      similarityThreshold: 0.9,
      minTokenOverlap: 0.0
    )
    #expect(groups.isEmpty, "same-file overlapping ranges must not pair with themselves")
  }

  // MARK: - SemanticPreset

  @Test("Balanced preset is cosine 0.85 / Jaccard 0.20")
  func balancedPreset() {
    let t = SemanticPreset.balanced.thresholds
    #expect(t.cosine == 0.85)
    #expect(t.jaccard == 0.20)
    #expect(SemanticPreset.strict.thresholds.cosine == 0.90)
    #expect(SemanticPreset.loose.thresholds.cosine == 0.80)
  }
}
