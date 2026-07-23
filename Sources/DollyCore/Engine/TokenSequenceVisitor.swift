//  TokenSequenceVisitor.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT), reshaped for the
//  interned pipeline (D2): extraction emits 16-byte `TokenRecord`s over a
//  per-file intern table instead of per-token strings. Normalization
//  happens at intern time with `TokenNormalizer.default` semantics.

import Foundation
import SwiftSyntax

// MARK: - TokenKind

/// Simplified token kinds for clone detection. UInt8-backed so the facts
/// cache serializes kind lanes as byte arrays; raw values are part of the
/// cache format (the cache is version-gated, but keep them stable anyway).
enum TokenKind: UInt8, Sendable, Hashable {
  case keyword = 0
  case identifier = 1
  case literal = 2
  case `operator` = 3
  case punctuation = 4
  case unknown = 5
}

// MARK: - TokenSequenceExtractor

/// Extracts interned token records from Swift source files.
struct TokenSequenceExtractor: Sendable {
  private let normalizer = TokenNormalizer.default

  /// Extract the interned token records from a parsed syntax tree.
  ///
  /// Ids in the result are FILE-LOCAL; `CorpusAssembler.assemble` remaps
  /// them into the corpus interner. Keeping the intern pass per-file keeps
  /// extraction parallel-safe.
  func extract(from tree: SourceFileSyntax, file: String, source: String) -> FileTokens {
    let text = SourceText(source: source)
    let converter = SourceLocationConverter(fileName: file, tree: tree)

    var table: [String: UInt32] = [:]
    var strings: [String] = []
    func intern(_ string: String) -> UInt32 {
      if let existing = table[string] { return existing }
      let id = UInt32(strings.count)
      table[string] = id
      strings.append(string)
      return id
    }

    // Start positions of every top-level item. Each becomes a stream
    // boundary so the suffix-array stage treats same-file declarations
    // like separate files. Boundaries stay at the top level only:
    // separators inside a type would sever legitimate clone regions that
    // span several members (whole-type copies, boilerplate families).
    let boundaryPositions = Set(tree.statements.map(\.positionAfterSkippingLeadingTrivia))
    var boundaries: [Int] = []
    boundaries.reserveCapacity(boundaryPositions.count)

    var records: [TokenRecord] = []
    var kinds: [TokenKind] = []

    for token in tree.tokens(viewMode: .sourceAccurate) {
      // Trivia (whitespace, comments) never reaches the stream.
      let kind = classifyToken(token)
      let position = token.positionAfterSkippingLeadingTrivia
      if boundaryPositions.contains(position) {
        boundaries.append(records.count)
      }
      let location = converter.location(for: position)

      let rawID = intern(token.text)
      let normID: UInt32
      if let normalized = normalizer.normalizedText(kind: kind, text: token.text) {
        normID = intern(normalized)
      } else {
        normID = rawID
      }

      records.append(
        TokenRecord(
          rawID: rawID,
          normID: normID,
          line: Int32(clamping: location.line),
          column: Int32(clamping: location.column)
        ))
      kinds.append(kind)
    }

    return FileTokens(
      file: file,
      records: records,
      strings: strings,
      kinds: kinds,
      boundaries: boundaries,
      hasSourceLocationDirective: text.containsSourceLocationDirective,
      text: text
    )
  }

  // MARK: Private

  // swa:ignore-duplicates - Token classification is structurally similar across parsers by design
  /// Classify a Swift syntax token into our simplified categories.
  private func classifyToken(_ token: TokenSyntax) -> TokenKind {
    switch token.tokenKind {
    // Keywords
    case .keyword:
      .keyword

    // Identifiers
    case .dollarIdentifier,
      .identifier:
      .identifier

    // Literals
    case .floatLiteral,
      .integerLiteral,
      .regexLiteralPattern,
      .regexSlash,
      .stringSegment:
      .literal

    // Operators
    case .arrow,
      .binaryOperator,
      .equal,
      .exclamationMark,
      .infixQuestionMark,
      .postfixOperator,
      .postfixQuestionMark,
      .prefixOperator:
      .operator

    // Punctuation
    case .atSign,
      .backslash,
      .backtick,
      .colon,
      .comma,
      .ellipsis,
      .leftAngle,
      .leftBrace,
      .leftParen,
      .leftSquare,
      .period,
      .pound,
      .rightAngle,
      .rightBrace,
      .rightParen,
      .rightSquare,
      .semicolon:
      .punctuation

    default:
      .unknown
    }
  }
}
