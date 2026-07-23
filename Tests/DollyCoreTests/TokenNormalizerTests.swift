//  TokenNormalizerTests.swift
//  dolly — ported from SwiftStaticAnalysis DuplicationDetectorTests (MIT)
//
//  Since D2 normalization happens at intern time: each test extracts real
//  source and inspects the normalized id lane, so the assertions pin the
//  exact semantics the engine consumes.

import SwiftParser
import Testing

@testable import DollyCore

@Suite("Token normalizer")
struct TokenNormalizerTests {
  private func fileTokens(from source: String) -> FileTokens {
    let tree = Parser.parse(source: source)
    return TokenSequenceExtractor().extract(from: tree, file: "test.swift", source: source)
  }

  /// The normalized text of every token, materialized from the intern table.
  private func normalizedTexts(from source: String) -> [String] {
    let tokens = fileTokens(from: source)
    return tokens.records.map { tokens.strings[Int($0.normID)] }
  }

  @Test("Normalizer replaces identifiers with placeholder")
  func normalizeIdentifiers() {
    let normalizedTexts = normalizedTexts(from: "let userName = value")

    // Identifiers should be normalized to $ID (except preserved ones)
    #expect(normalizedTexts.contains(TokenNormalizer.identifierPlaceholder))
    // Keywords should remain unchanged
    #expect(normalizedTexts.contains("let"))
  }

  @Test("Normalizer replaces literals with placeholder")
  func normalizeLiterals() {
    let normalizer = TokenNormalizer(normalizeLiterals: true)
    #expect(
      normalizer.normalizedText(kind: .literal, text: "42")
        == TokenNormalizer.numberPlaceholder)

    // And through the interned pipeline:
    let normalizedTexts = normalizedTexts(from: "let x = 42")
    #expect(normalizedTexts.contains(TokenNormalizer.numberPlaceholder))
  }

  @Test("String literals normalize to the string placeholder")
  func normalizeStringLiterals() {
    let normalizedTexts = normalizedTexts(from: #"let s = "hello there""#)
    #expect(normalizedTexts.contains(TokenNormalizer.stringPlaceholder))
  }

  @Test("Preserved identifiers are not normalized")
  func preservedIdentifiers() {
    let normalizedTexts = normalizedTexts(from: "let s: String = value")

    // String is a preserved identifier
    #expect(normalizedTexts.contains("String"))
  }

  @Test("Closure shorthand parameters normalize to one placeholder")
  func shorthandParameters() {
    let normalizedTexts = normalizedTexts(from: "let f = { $0 + $1 }")
    #expect(
      normalizedTexts.filter { $0 == TokenNormalizer.shorthandParamPlaceholder }.count == 2)
  }

  @Test("Renamed sources normalize to identical token streams")
  func renamedSourcesNormalizeIdentically() {
    // Corpus assembly remaps both files into one interner, so equal
    // normID lanes mean equal normalized streams — the property the
    // near-clone suffix array depends on.
    let corpus = CorpusAssembler.assemble(files: [
      fileTokens(from: "func alpha(a: Int) -> Int { a + 10 }"),
      fileTokens(from: "func beta(b: Int) -> Int { b + 99 }"),
    ])
    #expect(
      corpus.sequences[0].records.map(\.normID) == corpus.sequences[1].records.map(\.normID))
    #expect(
      corpus.sequences[0].records.map(\.rawID) != corpus.sequences[1].records.map(\.rawID))
  }
}
