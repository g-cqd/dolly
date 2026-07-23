//  TokenSequenceVisitor.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

import Foundation
import SwiftSyntax

// MARK: - TokenInfo

/// Represents a token with its location information.
struct TokenInfo: Sendable, Hashable {
  // MARK: Lifecycle

  // MARK: Public

  /// The token kind.
  let kind: TokenKind

  /// The token text.
  let text: String

  /// Line number (1-based).
  let line: Int

  /// Column number (1-based).
  let column: Int
}

// MARK: - TokenKind

/// Simplified token kinds for clone detection.
enum TokenKind: String, Sendable, Hashable {
  case keyword
  case identifier
  case literal
  case `operator`
  case punctuation
  case unknown
}

// MARK: - TokenSequenceProtocol

/// Protocol for token sequences used in stream building.
protocol TokenSequenceProtocol: Sendable {
  /// The source file path.
  var file: String { get }
  /// Number of tokens in the sequence.
  var tokenCount: Int { get }
}

// MARK: - TokenSequenceOf

/// A sequence of tokens from a source file, generic over the token payload
/// so the raw (`TokenInfo`) and normalized (`NormalizedToken`) forms share
/// one implementation.
struct TokenSequenceOf<Token: Sendable & Hashable>: Sendable, TokenSequenceProtocol {
  /// The source file path.
  let file: String

  /// The tokens in order.
  let tokens: [Token]

  /// Source lines for snippet extraction.
  let sourceLines: [String]

  /// Number of tokens in the sequence.
  var tokenCount: Int { tokens.count }

  /// Extract a code snippet for the given line range.
  func snippet(startLine: Int, endLine: Int) -> String {
    let start = max(0, startLine - 1)
    let end = min(sourceLines.count, endLine)
    guard start < end else { return "" }
    return sourceLines[start..<end].joined(separator: "\n")
  }
}

/// A sequence of raw source tokens.
typealias TokenSequence = TokenSequenceOf<TokenInfo>

// MARK: - TokenSequenceExtractor

/// Extracts tokens from Swift source files.
struct TokenSequenceExtractor: Sendable {
  /// Extract token sequence from a parsed syntax tree.
  func extract(from tree: SourceFileSyntax, file: String, source: String) -> TokenSequence {
    let sourceLines = source.components(separatedBy: .newlines)
    let converter = SourceLocationConverter(fileName: file, tree: tree)
    var tokens: [TokenInfo] = []

    for token in tree.tokens(viewMode: .sourceAccurate) {
      // Skip trivia (whitespace, comments)
      let kind = classifyToken(token)
      let location = converter.location(for: token.positionAfterSkippingLeadingTrivia)

      tokens.append(
        TokenInfo(
          kind: kind,
          text: token.text,
          line: location.line,
          column: location.column,
        ))
    }

    return TokenSequence(file: file, tokens: tokens, sourceLines: sourceLines)
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
