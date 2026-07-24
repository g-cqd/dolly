//  DeterministicEmbeddingProvider.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  A deterministic, dependency-free embedding provider for smoke-tests and
//  CI without model bundles. Produces a stable `[Float]` by hashing
//  character n-grams into bucketed counts. NOT semantically meaningful —
//  code that differs only by renamed identifiers hashes to distinct buckets.
//  Use a real provider (NLContextual / HF) for production semantic detection.

import Foundation

struct DeterministicEmbeddingProvider: SemanticEmbeddingProvider {
  let embeddingDimension: Int
  let ngramSize: Int
  var providerName: String { "deterministic (n-gram hash, CI/smoke)" }

  init(dimension: Int = 128, ngramSize: Int = 3) {
    precondition(dimension > 0, "dimension must be > 0")
    precondition(ngramSize > 0, "ngramSize must be > 0")
    self.embeddingDimension = dimension
    self.ngramSize = ngramSize
  }

  func embed(snippet: String) async throws -> [Float] {
    var buckets = [Float](repeating: 0, count: embeddingDimension)
    let chars = Array(snippet.unicodeScalars)
    guard chars.count >= ngramSize else { return buckets }

    for i in 0...(chars.count - ngramSize) {
      var hash: UInt64 = 0xCBF2_9CE4_8422_2325  // FNV-1a offset basis
      for j in 0..<ngramSize {
        hash ^= UInt64(chars[i + j].value)
        hash = hash &* 0x0000_0100_0000_01B3  // FNV-1a prime
      }
      let bucket = Int(hash % UInt64(embeddingDimension))
      buckets[bucket] += 1
    }
    return buckets
  }
}
