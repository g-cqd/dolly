//  TokenNormalizer.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  Since D2 the normalizer is consulted once per token at intern time
//  (extraction); the interned `normID` lane carries its verdict through
//  the rest of the pipeline.

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

  /// The normalized text for one token, or nil when the token normalizes
  /// to itself (so the caller can reuse the raw intern id).
  func normalizedText(kind: TokenKind, text: String) -> String? {
    switch kind {
    case .identifier:
      // Check for closure shorthand parameters ($0, $1, etc.)
      if normalizeClosureParams, isShorthandParameter(text) {
        return Self.shorthandParamPlaceholder
      }
      if normalizeIdentifiers, !preservedIdentifiers.contains(text) {
        return Self.identifierPlaceholder
      }
      return nil

    case .literal:
      if normalizeLiterals {
        return classifyLiteral(text)
      }
      return nil

    case .keyword,
      .operator,
      .punctuation,
      .unknown:
      return nil
    }
  }

  // MARK: Private

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
