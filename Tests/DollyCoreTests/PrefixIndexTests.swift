//  PrefixIndexTests.swift
//  dolly
//
//  The SourcererCC prefix+position filter is only allowed to over-generate:
//  its candidate set must contain every pair whose exact Jaccard clears the
//  threshold. The property test checks that against brute force on seeded
//  random corpora whose construction guarantees true pairs exist.

import Testing

@testable import DollyCore

@Suite("SourcererCC prefix index")
struct PrefixIndexTests {
  private func makeDocuments(seed: UInt64, count: Int) -> [ShingledDocument] {
    var rng = seed
    var documents: [ShingledDocument] = []
    var previous: Set<UInt64> = []

    for id in 0..<count {
      var features: Set<UInt64>
      if id % 3 == 0 || previous.isEmpty {
        // Fresh random set from a small universe so overlaps occur.
        features = []
        let size = 30 + Int(splitMix64(&rng) % 31)
        while features.count < size {
          features.insert(1000 + splitMix64(&rng) % 300)
        }
      } else {
        // Mutated copy of the previous set: near-duplicate documents,
        // many above and just below the threshold.
        features = previous
        let removals = Int(splitMix64(&rng) % 6)
        for _ in 0..<removals {
          if let victim = features.min(by: { _, _ in splitMix64(&rng) % 2 == 0 }) {
            features.remove(victim)
          }
        }
        let additions = Int(splitMix64(&rng) % 6)
        for _ in 0..<additions {
          features.insert(1000 + splitMix64(&rng) % 300)
        }
      }
      previous = features
      documents.append(
        ShingledDocument(
          file: "doc\(id).swift",
          startLine: 1,
          endLine: 2,
          tokenCount: features.count,
          shingleHashes: features,
          shingles: [],
          id: id
        ))
    }
    return documents
  }

  @Test(
    "candidates are a superset of brute-force Jaccard >= 0.8 pairs",
    arguments: [UInt64(0xD011_F00D), 7, 42, 0xBEEF])
  func candidatesCoverBruteForce(seed: UInt64) async {
    let documents = makeDocuments(seed: seed, count: 48)
    let candidates = await PrefixIndexCandidateGenerator(threshold: 0.8, maxConcurrency: 4)
      .candidatePairs(for: documents)

    var truePairCount = 0
    for (first, second) in documents.pairCombinations() {
      let jaccard = MinHashGenerator.exactJaccardSimilarity(
        first.shingleHashes, second.shingleHashes)
      guard jaccard >= 0.8 else { continue }
      truePairCount += 1
      #expect(
        candidates.contains(DocumentPair(id1: first.id, id2: second.id)),
        "missing true pair \(first.id)-\(second.id) with Jaccard \(jaccard)")
    }
    // The corpus construction (mutated near-copies) must actually produce
    // true pairs, or the superset property is vacuous.
    #expect(truePairCount > 0, "seed \(seed) produced no true pairs — corpus too sparse")
  }

  @Test("candidate generation is deterministic, serial or parallel")
  func deterministicCandidates() async {
    let documents = makeDocuments(seed: 99, count: 40)
    let serial = PrefixIndexCandidateGenerator(threshold: 0.8, maxConcurrency: 1)
    let parallel = PrefixIndexCandidateGenerator(threshold: 0.8, maxConcurrency: 8)
    let first = await serial.candidatePairs(for: documents)
    let second = await serial.candidatePairs(for: documents)
    let third = await parallel.candidatePairs(for: documents)
    #expect(first == second)
    #expect(first == third)
  }

  @Test("position filter prunes hopeless pairs without losing eligible ones")
  func positionFilterKeepsEligiblePairs() async {
    // Two documents sharing exactly 9 of 10 features: Jaccard 9/11 ≈ 0.82.
    let shared: Set<UInt64> = Set((0..<9).map { UInt64(100 + $0) })
    let first = ShingledDocument(
      file: "a.swift", startLine: 1, endLine: 2, tokenCount: 10,
      shingleHashes: shared.union([555]), shingles: [], id: 0)
    let second = ShingledDocument(
      file: "b.swift", startLine: 1, endLine: 2, tokenCount: 10,
      shingleHashes: shared.union([777]), shingles: [], id: 1)
    // And a third with disjoint features — never a candidate.
    let third = ShingledDocument(
      file: "c.swift", startLine: 1, endLine: 2, tokenCount: 10,
      shingleHashes: Set((0..<10).map { UInt64(9000 + $0) }), shingles: [], id: 2)

    let candidates = await PrefixIndexCandidateGenerator(threshold: 0.8)
      .candidatePairs(for: [first, second, third])
    #expect(candidates.contains(DocumentPair(id1: 0, id2: 1)))
    #expect(!candidates.contains(DocumentPair(id1: 0, id2: 2)))
    #expect(!candidates.contains(DocumentPair(id1: 1, id2: 2)))
  }
}
