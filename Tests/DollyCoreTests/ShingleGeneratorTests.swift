//  ShingleGeneratorTests.swift
//  dolly — ported from SwiftStaticAnalysis DuplicationDetectorTests (MIT)

import Testing

@testable import DollyCore

@Suite("Shingle generator")
struct ShingleGeneratorTests {
  @Test("Basic shingle generation")
  func basicShingleGeneration() {
    let generator = ShingleGenerator(shingleSize: 3, normalize: false)
    let shingles = generator.generate(tokens: ["a", "b", "c", "d", "e"], kinds: nil)

    #expect(shingles.count == 3)  // 5 tokens - 3 + 1 = 3 shingles
    #expect(shingles[0].tokens == ["a", "b", "c"])
    #expect(shingles[1].tokens == ["b", "c", "d"])
    #expect(shingles[2].tokens == ["c", "d", "e"])
  }

  @Test("Shingle positions are correct")
  func shinglePositions() {
    let generator = ShingleGenerator(shingleSize: 2, normalize: false)
    let shingles = generator.generate(tokens: ["x", "y", "z", "w"], kinds: nil)

    #expect(shingles.count == 3)
    #expect(shingles[0].position == 0)
    #expect(shingles[1].position == 1)
    #expect(shingles[2].position == 2)
  }

  @Test("Normalization of identifiers")
  func normalizationOfIdentifiers() {
    let generator = ShingleGenerator(shingleSize: 2, normalize: true)
    let tokens1 = ["func", "foo", "(", "bar", ")"]
    let kinds1: [TokenKind] = [.keyword, .identifier, .punctuation, .identifier, .punctuation]
    let tokens2 = ["func", "baz", "(", "qux", ")"]
    let kinds2: [TokenKind] = [.keyword, .identifier, .punctuation, .identifier, .punctuation]

    let shingles1 = generator.generate(tokens: tokens1, kinds: kinds1)
    let shingles2 = generator.generate(tokens: tokens2, kinds: kinds2)

    // After normalization, both should produce same shingle hashes
    #expect(Set(shingles1.map(\.hash)) == Set(shingles2.map(\.hash)))
  }

  @Test("Normalization of literals")
  func normalizationOfLiterals() {
    let generator = ShingleGenerator(shingleSize: 2, normalize: true)
    let shingles1 = generator.generate(tokens: ["return", "42"], kinds: [.keyword, .literal])
    let shingles2 = generator.generate(tokens: ["return", "100"], kinds: [.keyword, .literal])

    #expect(shingles1.count == 1)
    #expect(shingles2.count == 1)
    #expect(shingles1[0].hash == shingles2[0].hash)
  }

  @Test("Empty input returns empty shingles")
  func emptyInput() {
    let generator = ShingleGenerator(shingleSize: 3, normalize: false)
    #expect(generator.generate(tokens: [], kinds: nil).isEmpty)
  }

  @Test("Input smaller than shingle size returns empty")
  func inputSmallerThanShingleSize() {
    let generator = ShingleGenerator(shingleSize: 5, normalize: false)
    #expect(generator.generate(tokens: ["a", "b"], kinds: nil).isEmpty)
  }

  @Test("Character shingles generation")
  func characterShingles() {
    let generator = ShingleGenerator()
    let shingles = generator.generateCharacterShingles(from: "hello world", k: 3)

    // "hel", "ell", "llo", "lo ", "o w", " wo", "wor", "orl", "rld"
    #expect(shingles.count == 9)
  }

  @Test("Different shingle sizes")
  func differentShingleSizes() {
    let tokens = ["a", "b", "c", "d", "e", "f"]

    for size in 1...5 {
      let generator = ShingleGenerator(shingleSize: size, normalize: false)
      let shingles = generator.generate(tokens: tokens, kinds: nil)
      #expect(shingles.count == tokens.count - size + 1)
    }
  }

  @Test("Block documents carry location and stride")
  func blockDocuments() {
    let tokens = (0..<40).map { index in
      TokenInfo(kind: .identifier, text: "t\(index)", line: index + 1, column: 3)
    }
    let sequence = TokenSequence(file: "block.swift", tokens: tokens, sourceLines: [])
    let generator = ShingleGenerator(shingleSize: 3, normalize: true)

    let documents = generator.generateBlockDocuments(from: sequence, blockSize: 20, startId: 5)

    // Stride is blockSize/2 = 10: windows at 0, 10, 20 -> 3 documents.
    #expect(documents.count == 3)
    #expect(documents.map(\.id) == [5, 6, 7])
    #expect(documents[0].startLine == 1)
    #expect(documents[0].startColumn == 3)
    #expect(documents[0].endLine == 20)
    #expect(documents[1].startLine == 11)
  }
}
