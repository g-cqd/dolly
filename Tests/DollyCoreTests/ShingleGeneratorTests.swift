//  ShingleGeneratorTests.swift
//  dolly — ported from SwiftStaticAnalysis DuplicationDetectorTests (MIT)
//
//  Since D2 shingles carry only (hash, position) over interned records;
//  the assertions pin the equalities the structural stage depends on
//  instead of materialized token arrays.

import Testing

@testable import DollyCore

@Suite("Shingle generator")
struct ShingleGeneratorTests {
  /// Shared interner mimicking corpus assembly, so records built from
  /// several token lists live in one id space like real sequences do.
  private struct TestInterner {
    private var table: [String: UInt32] = [:]

    mutating func records(_ texts: [String]) -> [TokenRecord] {
      texts.enumerated().map { index, text in
        let id: UInt32
        if let existing = table[text] {
          id = existing
        } else {
          id = UInt32(table.count)
          table[text] = id
        }
        return TokenRecord(rawID: id, normID: id, line: Int32(index + 1), column: 3)
      }
    }
  }

  private func shingles(
    _ texts: [String],
    kinds: [TokenKind]? = nil,
    size: Int,
    normalize: Bool,
    interner: inout TestInterner
  ) -> [Shingle] {
    let records = interner.records(texts)
    let kindLane = kinds ?? Array(repeating: .identifier, count: texts.count)
    return ShingleGenerator(shingleSize: size, normalize: normalize)
      .generate(records: records[...], kinds: kindLane[...])
  }

  @Test("Basic shingle generation")
  func basicShingleGeneration() {
    var interner = TestInterner()
    let shingles = shingles(
      ["a", "b", "c", "a", "b", "c"], size: 3, normalize: false, interner: &interner)

    #expect(shingles.count == 4)  // 6 tokens - 3 + 1
    // Identical windows hash equal; distinct windows hash apart.
    #expect(shingles[0].hash == shingles[3].hash)  // abc == abc
    #expect(shingles[0].hash != shingles[1].hash)  // abc != bca
    #expect(shingles[1].hash != shingles[2].hash)  // bca != cab
  }

  @Test("Shingle positions are correct")
  func shinglePositions() {
    var interner = TestInterner()
    let shingles = shingles(["x", "y", "z", "w"], size: 2, normalize: false, interner: &interner)

    #expect(shingles.count == 3)
    #expect(shingles[0].position == 0)
    #expect(shingles[1].position == 1)
    #expect(shingles[2].position == 2)
  }

  @Test("Normalization of identifiers")
  func normalizationOfIdentifiers() {
    var interner = TestInterner()
    let kinds: [TokenKind] = [.keyword, .identifier, .punctuation, .identifier, .punctuation]
    let shingles1 = shingles(
      ["func", "foo", "(", "bar", ")"], kinds: kinds, size: 2, normalize: true,
      interner: &interner)
    let shingles2 = shingles(
      ["func", "baz", "(", "qux", ")"], kinds: kinds, size: 2, normalize: true,
      interner: &interner)

    // After normalization, both should produce same shingle hashes
    #expect(Set(shingles1.map(\.hash)) == Set(shingles2.map(\.hash)))
  }

  @Test("Normalization of literals")
  func normalizationOfLiterals() {
    var interner = TestInterner()
    let shingles1 = shingles(
      ["return", "42"], kinds: [.keyword, .literal], size: 2, normalize: true,
      interner: &interner)
    let shingles2 = shingles(
      ["return", "100"], kinds: [.keyword, .literal], size: 2, normalize: true,
      interner: &interner)

    #expect(shingles1.count == 1)
    #expect(shingles2.count == 1)
    #expect(shingles1[0].hash == shingles2[0].hash)
  }

  @Test("Distinct identifiers within a window stay distinguishable")
  func distinctIdentifiersStayDistinct() {
    // Positional ordinals: (foo, foo) and (foo, bar) must differ even
    // though all identifiers normalize.
    var interner = TestInterner()
    let repeated = shingles(
      ["foo", "foo"], kinds: [.identifier, .identifier], size: 2, normalize: true,
      interner: &interner)
    let distinct = shingles(
      ["foo", "bar"], kinds: [.identifier, .identifier], size: 2, normalize: true,
      interner: &interner)
    #expect(repeated[0].hash != distinct[0].hash)
  }

  @Test("Empty input returns empty shingles")
  func emptyInput() {
    var interner = TestInterner()
    #expect(shingles([], size: 3, normalize: false, interner: &interner).isEmpty)
  }

  @Test("Input smaller than shingle size returns empty")
  func inputSmallerThanShingleSize() {
    var interner = TestInterner()
    #expect(shingles(["a", "b"], size: 5, normalize: false, interner: &interner).isEmpty)
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
    let texts = ["a", "b", "c", "d", "e", "f"]

    for size in 1...5 {
      var interner = TestInterner()
      let result = shingles(texts, size: size, normalize: false, interner: &interner)
      #expect(result.count == texts.count - size + 1)
    }
  }

  @Test("Block documents carry location and stride")
  func blockDocuments() {
    var interner = TestInterner()
    let records = interner.records((0..<40).map { "t\($0)" })
    let sequence = TokenSequence(
      file: "block.swift",
      records: records,
      kinds: Array(repeating: .identifier, count: records.count),
      boundaries: [],
      hasSourceLocationDirective: false,
      text: SourceText(source: "")
    )
    let generator = ShingleGenerator(shingleSize: 3, normalize: true)

    let documents = generator.generateBlockDocuments(
      from: sequence, sequenceIndex: 0, blockSize: 20, startId: 5)

    // Stride is blockSize/2 = 10: windows at 0, 10, 20 -> 3 documents.
    #expect(documents.count == 3)
    #expect(documents.map(\.id) == [5, 6, 7])
    #expect(documents.map(\.tokenRange) == [0..<20, 10..<30, 20..<40])
    #expect(documents[0].startLine == 1)
    #expect(documents[0].startColumn == 3)
    #expect(documents[0].endLine == 20)
    #expect(documents[1].startLine == 11)
  }
}
