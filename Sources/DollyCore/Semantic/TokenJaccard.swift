//  TokenJaccard.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  Cheap token-set Jaccard similarity for Swift source strings. Used by
//  `EmbeddingCloneDiscovery` to drop cosine-positive but lexically disjoint
//  candidate pairs — the "shape-true, intent-false" failure mode that pooled
//  cosine misranks. Tokenize by identifier boundary, lowercase, drop Swift
//  syntax-noise keywords; what remains is the snippet's identifier + literal
//  vocabulary.

import Foundation

enum TokenJaccard {
  /// Stop-words filtered out before Jaccard: Swift control-flow + declaration
  /// keywords plus a few universal noise tokens. Deliberately small —
  /// over-filtering hides real signal. Held as one whitespace-separated
  /// string (not a literal array) so the keyword set is a single token, not a
  /// long string-literal run.
  static let stopWords: Set<String> = Set(
    """
    let var func return if else guard throws try await async private public
    internal fileprivate package static final class struct enum protocol actor
    extension case default where in for while do switch break continue self
    init deinit true false nil as is throw
    """
    .split(whereSeparator: \.isWhitespace).map(String.init)
  )

  /// Tokenize source by identifier boundary. Returns lowercased identifiers
  /// with `stopWords` removed.
  static func tokenSet(_ source: String) -> Set<String> {
    var result: Set<String> = []
    var current = ""
    for scalar in source.unicodeScalars {
      if scalar.isSourceIdentifier {
        current.unicodeScalars.append(scalar)
      } else if !current.isEmpty {
        let lower = current.lowercased()
        if !stopWords.contains(lower) { result.insert(lower) }
        current = ""
      }
    }
    if !current.isEmpty {
      let lower = current.lowercased()
      if !stopWords.contains(lower) { result.insert(lower) }
    }
    return result
  }

  /// Jaccard similarity (intersection / union) between the two snippets'
  /// token sets. Returns `0.0` when both sets are empty.
  static func similarity(_ a: String, _ b: String) -> Double {
    let setA = tokenSet(a)
    let setB = tokenSet(b)
    if setA.isEmpty, setB.isEmpty { return 0 }
    let intersection = Double(setA.intersection(setB).count)
    let union = Double(setA.union(setB).count)
    return union == 0 ? 0 : intersection / union
  }
}

extension Unicode.Scalar {
  /// A letter, digit, or `_` — the character class that composes a Swift
  /// identifier for the coarse tokenizer above.
  fileprivate var isSourceIdentifier: Bool {
    (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
      || (value >= 0x30 && value <= 0x39) || value == 0x5F || properties.isAlphabetic
  }
}
