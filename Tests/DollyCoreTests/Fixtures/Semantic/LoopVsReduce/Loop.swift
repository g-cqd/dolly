// A Type-4 (semantic) clone fixture: same behavior, imperative idiom.
// The token, near, and structural detectors miss this against Reduce.swift
// (different token shapes, both below the 50-token floor); the semantic pass
// with NLContextualEmbedding recovers it. Never formatted (fixture resource).
enum LoopMath {
  func totalOfValues(_ values: [Int]) -> Int {
    var total = 0
    for value in values {
      total += value
    }
    return total
  }
}
