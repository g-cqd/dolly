//  TokenNormalizer.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

// MARK: - NormalizedToken

/// A normalized token for near-clone detection.
struct NormalizedToken: Sendable, Hashable {
  // MARK: Lifecycle

  // MARK: Public

  /// The normalized representation.
  let normalized: String

  /// The original token text.
  let original: String

  /// The token kind.
  let kind: TokenKind

  /// Line number.
  let line: Int

  /// Column number.
  let column: Int
}

// MARK: - NormalizedSequence

/// A sequence of normalized tokens.
typealias NormalizedSequence = TokenSequenceOf<NormalizedToken>

extension TokenSequenceOf where Token == NormalizedToken {
  /// Get the normalized token texts for hashing.
  var normalizedTexts: [String] {
    tokens.map(\.normalized)
  }
}

// MARK: - TokenNormalizer

/// Normalizes tokens for near-clone detection.
struct TokenNormalizer: Sendable {
  // MARK: Lifecycle

  init(
    normalizeIdentifiers: Bool = true,
    normalizeLiterals: Bool = true,
    normalizeClosureParams: Bool = true,
    preservedIdentifiers: Set<String> = [],
  ) {
    self.normalizeIdentifiers = normalizeIdentifiers
    self.normalizeLiterals = normalizeLiterals
    self.normalizeClosureParams = normalizeClosureParams
    self.preservedIdentifiers = preservedIdentifiers
  }

  // MARK: Public

  /// Placeholder for identifiers.
  static let identifierPlaceholder = "$ID"

  /// Placeholder for string literals.
  static let stringPlaceholder = "$STR"

  /// Placeholder for numeric literals.
  static let numberPlaceholder = "$NUM"

  /// Placeholder for closure shorthand parameters ($0, $1, etc.).
  static let shorthandParamPlaceholder = "$PARAM"

  /// Default normalizer with common Swift keywords preserved.
  static let `default` = Self(
    preservedIdentifiers: [
      // Common type names
      "String", "Int", "Double", "Float", "Bool", "Array", "Dictionary",
      "Set", "Optional", "Result", "Error", "Void", "Any", "AnyObject",
      // Common identifiers
      "self", "Self", "super", "nil", "true", "false",
      // Common function names
      "print", "fatalError", "precondition", "assert",
    ],
  )

  /// Whether to normalize identifiers.
  var normalizeIdentifiers: Bool

  /// Whether to normalize literals.
  var normalizeLiterals: Bool

  /// Whether to normalize closure shorthand parameters.
  var normalizeClosureParams: Bool

  /// Identifiers to preserve (not normalize).
  var preservedIdentifiers: Set<String>

  /// Normalize a token sequence.
  func normalize(_ sequence: TokenSequence) -> NormalizedSequence {
    let normalizedTokens = sequence.tokens.map { token -> NormalizedToken in
      let normalized = normalizeToken(token)
      return NormalizedToken(
        normalized: normalized,
        original: token.text,
        kind: token.kind,
        line: token.line,
        column: token.column,
      )
    }

    return NormalizedSequence(
      file: sequence.file,
      tokens: normalizedTokens,
      sourceLines: sequence.sourceLines,
      boundaries: sequence.boundaries
    )
  }

  // MARK: Private

  /// Normalize a single token.
  private func normalizeToken(_ token: TokenInfo) -> String {
    switch token.kind {
    case .identifier:
      // Check for closure shorthand parameters ($0, $1, etc.)
      if normalizeClosureParams, isShorthandParameter(token.text) {
        return Self.shorthandParamPlaceholder
      }
      if normalizeIdentifiers, !preservedIdentifiers.contains(token.text) {
        return Self.identifierPlaceholder
      }
      return token.text

    case .literal:
      if normalizeLiterals {
        return classifyLiteral(token.text)
      }
      return token.text

    case .keyword,
      .operator,
      .punctuation,
      .unknown:
      return token.text
    }
  }

  /// Check if an identifier is a closure shorthand parameter.
  private func isShorthandParameter(_ text: String) -> Bool {
    guard text.hasPrefix("$") else { return false }
    let rest = text.dropFirst()
    return rest.allSatisfy(\.isNumber)
  }

  /// Classify a literal and return appropriate placeholder.
  private func classifyLiteral(_ text: String) -> String {
    // Check if it's a string literal
    if text.hasPrefix("\"") || text.hasPrefix("'") {
      return Self.stringPlaceholder
    }

    // Check if it's a number
    if text.first?.isNumber == true || text.hasPrefix("-") || text.hasPrefix(".") {
      return Self.numberPlaceholder
    }

    return Self.stringPlaceholder
  }
}
