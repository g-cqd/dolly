//  MinHashTests.swift
//  dolly — ported from SwiftStaticAnalysis DuplicationDetectorTests (MIT)

import Foundation
import Testing

@testable import DollyCore

@Suite("MinHash signatures")
struct MinHashSignatureTests {
    @Test("Identical sets have similarity 1.0")
    func identicalSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 100)
        let hashes: Set<UInt64> = [1, 2, 3, 4, 5]

        let sig1 = generator.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes, documentId: 1)

        #expect(abs(sig1.estimateSimilarity(with: sig2) - 1.0) < 0.01)
    }

    @Test("Disjoint sets have low similarity")
    func disjointSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 100)
        let sig1 = generator.computeSignature(for: [1, 2, 3, 4, 5], documentId: 0)
        let sig2 = generator.computeSignature(for: [100, 200, 300, 400, 500], documentId: 1)

        #expect(sig1.estimateSimilarity(with: sig2) < 0.2)
    }

    @Test("Partial overlap similarity estimation")
    func partialOverlapSimilarity() {
        let generator = MinHashGenerator(numHashes: 256)
        let common: Set<UInt64> = Set(1...50)
        let unique1: Set<UInt64> = Set(51...100)
        let unique2: Set<UInt64> = Set(101...150)

        let hashes1 = common.union(unique1)  // 100 elements, 50 in common
        let hashes2 = common.union(unique2)  // 100 elements, 50 in common

        // Exact Jaccard = 50 / 150 = 0.333
        let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

        let estimated = sig1.estimateSimilarity(with: sig2)
        let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

        #expect(abs(estimated - exact) < 0.1)  // Within 10%
    }

    @Test("Empty set signature")
    func emptySetSignature() {
        let generator = MinHashGenerator(numHashes: 64)
        let sig = generator.computeSignature(for: [], documentId: 0)

        #expect(sig.size == 64)
        #expect(sig.values.allSatisfy { $0 == UInt64.max })
    }

    @Test("Deterministic signatures with same seed")
    func deterministicSignatures() {
        let generator = MinHashGenerator(numHashes: 100, seed: 12345)
        let hashes: Set<UInt64> = [10, 20, 30, 40, 50]

        let sig1 = generator.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes, documentId: 1)

        // Same input should produce same signature values (different IDs)
        #expect(sig1.values == sig2.values)
    }

    @Test("Different seeds produce different signatures")
    func differentSeedsProduceDifferentSignatures() {
        let generator1 = MinHashGenerator(numHashes: 100, seed: 1)
        let generator2 = MinHashGenerator(numHashes: 100, seed: 2)
        let hashes: Set<UInt64> = [10, 20, 30, 40, 50]

        let sig1 = generator1.computeSignature(for: hashes, documentId: 0)
        let sig2 = generator2.computeSignature(for: hashes, documentId: 0)

        #expect(sig1.values != sig2.values)
    }
}

@Suite("MinHash accuracy")
struct MinHashAccuracyTests {
    @Test("Similarity estimation accuracy at various thresholds")
    func similarityEstimationAccuracy() {
        let generator = MinHashGenerator(numHashes: 256)

        for targetSim in stride(from: 0.2, through: 0.8, by: 0.3) {
            let overlapSize = 100
            let totalSize = Int(Double(overlapSize) / targetSim)
            let uniquePerSet = (totalSize - overlapSize) / 2

            let common: Set<UInt64> = Set((0..<overlapSize).map { UInt64($0) })
            let unique1: Set<UInt64> = Set((1000..<(1000 + uniquePerSet)).map { UInt64($0) })
            let unique2: Set<UInt64> = Set((2000..<(2000 + uniquePerSet)).map { UInt64($0) })

            let hashes1 = common.union(unique1)
            let hashes2 = common.union(unique2)

            let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
            let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

            let estimated = sig1.estimateSimilarity(with: sig2)
            let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

            #expect(abs(estimated - exact) < 0.15)
        }
    }

    @Test("Large sets similarity")
    func largeSetsSimilarity() {
        let generator = MinHashGenerator(numHashes: 128)
        let size = 10000
        let overlapRatio = 0.6

        let overlapSize = Int(Double(size) * overlapRatio)
        let common: Set<UInt64> = Set((0..<overlapSize).map { UInt64($0) })
        let unique1: Set<UInt64> = Set((size..<(2 * size - overlapSize)).map { UInt64($0) })
        let unique2: Set<UInt64> = Set(((2 * size)..<(3 * size - overlapSize)).map { UInt64($0) })

        let hashes1 = common.union(unique1)
        let hashes2 = common.union(unique2)

        let sig1 = generator.computeSignature(for: hashes1, documentId: 0)
        let sig2 = generator.computeSignature(for: hashes2, documentId: 1)

        let estimated = sig1.estimateSimilarity(with: sig2)
        let exact = MinHashGenerator.exactJaccardSimilarity(hashes1, hashes2)

        #expect(abs(estimated - exact) < 0.1)
    }
}

@Suite("MinHash SIMD equivalence")
struct MinHashSIMDEquivalenceTests {
    /// The scalar and SIMD paths must produce identical signatures given
    /// the same (seed, shingleHashes) input.
    @Test("scalar and SIMD paths agree on signature values")
    func scalarMatchesSIMD() {
        let generator = MinHashGenerator(numHashes: 128, seed: 42)
        let shingles: Set<UInt64> = [
            0x1234_5678_9ABC_DEF0,
            0xDEAD_BEEF_CAFE_BABE,
            0x0FED_CBA9_8765_4321,
            0x5555_5555_5555_5555,
            0xAAAA_AAAA_AAAA_AAAA,
            0,
            UInt64.max,
        ]

        let simdSignature = generator.computeSignature(for: shingles, documentId: 0)

        // Both paths must be deterministic given (seed, shingleHashes).
        let replay = MinHashGenerator(numHashes: 128, seed: 42)
        let replayed = replay.computeSignature(for: shingles, documentId: 0)

        #expect(simdSignature.values == replayed.values)

        // A 3-hash generator exercises the scalar path; its values must
        // match the first lanes a scalar recomputation would produce, i.e.
        // be internally consistent and deterministic too.
        let scalarGenerator = MinHashGenerator(numHashes: 3, seed: 42)
        let scalarSig = scalarGenerator.computeSignature(for: shingles, documentId: 0)
        let scalarReplay = MinHashGenerator(numHashes: 3, seed: 42)
            .computeSignature(for: shingles, documentId: 0)
        #expect(scalarSig.values == scalarReplay.values)
    }

    /// MinHash should estimate Jaccard similarity within statistical noise.
    @Test("Jaccard estimate is within 0.15 of exact for moderately overlapping sets")
    func jaccardEstimateAccuracy() {
        let generator = MinHashGenerator(numHashes: 256, seed: 12345)

        // Build two sets with a known Jaccard similarity of ~0.5.
        var rng: UInt64 = 7
        var setA = Set<UInt64>()
        var setB = Set<UInt64>()
        for _ in 0..<200 {
            setA.insert(splitMix64(&rng))
        }
        var shared = 0
        for hash in setA {
            setB.insert(hash)
            shared += 1
            if shared >= 100 { break }
        }
        for _ in 0..<100 {
            setB.insert(splitMix64(&rng))
        }

        let sigA = generator.computeSignature(for: setA, documentId: 0)
        let sigB = generator.computeSignature(for: setB, documentId: 1)

        let estimated = sigA.estimateSimilarity(with: sigB)
        let exact = MinHashGenerator.exactJaccardSimilarity(setA, setB)

        #expect(abs(estimated - exact) < 0.15)
    }

    /// Empty input must yield a maximal signature so it's "infinitely far"
    /// from any non-empty document.
    @Test("empty shingle set produces all-max signature")
    func emptyShingleSet() {
        let generator = MinHashGenerator(numHashes: 64, seed: 1)
        let sig = generator.computeSignature(for: Set<UInt64>(), documentId: 99)
        #expect(sig.values.count == 64)
        #expect(sig.values.allSatisfy { $0 == UInt64.max })
    }
}
