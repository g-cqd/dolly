//  TokenNormalizerTests.swift
//  dolly — ported from SwiftStaticAnalysis DuplicationDetectorTests (MIT)

import SwiftParser
import Testing

@testable import DollyCore

@Suite("Token normalizer")
struct TokenNormalizerTests {
  private func sequence(from source: String) -> TokenSequence {
    let tree = Parser.parse(source: source)
    return TokenSequenceExtractor().extract(from: tree, file: "test.swift", source: source)
  }

  @Test("Normalizer replaces identifiers with placeholder")
  func normalizeIdentifiers() {
    let normalized = TokenNormalizer.default.normalize(sequence(from: "let userName = value"))
    let normalizedTexts = normalized.tokens.map(\.normalized)

    // Identifiers should be normalized to $ID (except preserved ones)
    #expect(normalizedTexts.contains(TokenNormalizer.identifierPlaceholder))
    // Keywords should remain unchanged
    #expect(normalizedTexts.contains("let"))
  }

  @Test("Normalizer replaces literals with placeholder")
  func normalizeLiterals() {
    let normalizer = TokenNormalizer(normalizeLiterals: true)
    let normalized = normalizer.normalize(sequence(from: "let x = 42"))
    let normalizedTexts = normalized.tokens.map(\.normalized)

    // Numeric literal should be normalized
    #expect(normalizedTexts.contains(TokenNormalizer.numberPlaceholder))
  }

  @Test("String literals normalize to the string placeholder")
  func normalizeStringLiterals() {
    let normalized = TokenNormalizer.default.normalize(
      sequence(from: #"let s = "hello there""#))
    let normalizedTexts = normalized.tokens.map(\.normalized)
    #expect(normalizedTexts.contains(TokenNormalizer.stringPlaceholder))
  }

  @Test("Preserved identifiers are not normalized")
  func preservedIdentifiers() {
    let normalized = TokenNormalizer.default.normalize(
      sequence(from: "let s: String = value"))
    let normalizedTexts = normalized.tokens.map(\.normalized)

    // String is a preserved identifier
    #expect(normalizedTexts.contains("String"))
  }

  @Test("Closure shorthand parameters normalize to one placeholder")
  func shorthandParameters() {
    let normalized = TokenNormalizer.default.normalize(
      sequence(from: "let f = { $0 + $1 }"))
    let normalizedTexts = normalized.tokens.map(\.normalized)
    #expect(normalizedTexts.filter { $0 == TokenNormalizer.shorthandParamPlaceholder }.count == 2)
  }

  @Test("Renamed sources normalize to identical token streams")
  func renamedSourcesNormalizeIdentically() {
    let first = TokenNormalizer.default.normalize(
      sequence(from: "func alpha(a: Int) -> Int { a + 10 }"))
    let second = TokenNormalizer.default.normalize(
      sequence(from: "func beta(b: Int) -> Int { b + 99 }"))
    #expect(first.normalizedTexts == second.normalizedTexts)
  }
}
