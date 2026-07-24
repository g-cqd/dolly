//  NLContextualSemanticEmbeddingProvider.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  The default `--semantic` provider: Apple's on-device NLContextualEmbedding
//  (macOS 14+). Produces dense, contextual, sentence-level embeddings with
//  ZERO model download — the NL framework's English contextual-embedding
//  asset is system-provided. Token vectors are mean-pooled to one
//  fixed-dimension vector per snippet.
//
//  Honest recall note: this is an English natural-language model, NOT trained
//  on code. It recovers Type-2 (renames, comment edits) and partial Type-3/4
//  clones, but its recall on idiom-level clones is materially lower than a
//  code-trained model — use `--embedding-bundle` with a CodeBERT/MiniLM-class
//  bundle (HFSemanticEmbeddingProvider) for higher recall.

#if canImport(NaturalLanguage)
  import Foundation
  import NaturalLanguage

  @available(macOS 14.0, *)
  struct NLContextualSemanticEmbeddingProvider: SemanticEmbeddingProvider {
    /// Dimension of every embedding this provider returns.
    let embeddingDimension: Int
    /// Language the underlying contextual embedding was trained on.
    let language: NLLanguage
    var providerName: String { "NLContextualEmbedding (on-device, zero-download)" }

    /// Load the contextual-embedding asset eagerly so a later
    /// `embed(snippet:)` failure surfaces here at construction time.
    init(language: NLLanguage = .english) throws {
      guard let probe = NLContextualEmbedding(language: language) else {
        throw SemanticEmbeddingError.modelLoadFailed(
          underlying: NLContextualEmbeddingError.unsupportedLanguage(language))
      }
      guard probe.hasAvailableAssets else {
        throw SemanticEmbeddingError.modelLoadFailed(
          underlying: NLContextualEmbeddingError.assetsUnavailable)
      }
      do {
        try probe.load()
      } catch {
        throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
      }
      self.embeddingDimension = probe.dimension
      self.language = language
    }

    func embed(snippet: String) async throws -> [Float] {
      guard let embedding = NLContextualEmbedding(language: language) else {
        throw SemanticEmbeddingError.modelLoadFailed(
          underlying: NLContextualEmbeddingError.unsupportedLanguage(language))
      }
      do {
        try embedding.load()
      } catch {
        throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
      }

      let result: NLContextualEmbeddingResult
      do {
        result = try embedding.embeddingResult(for: snippet, language: language)
      } catch {
        throw SemanticEmbeddingError.inferenceFailed(reason: "\(error)")
      }

      let dimension = embedding.dimension
      var pooled = [Float](repeating: 0, count: dimension)
      var tokenCount = 0
      result.enumerateTokenVectors(in: snippet.startIndex..<snippet.endIndex) { vector, _ in
        guard vector.count == dimension else { return true }
        for i in 0..<dimension {
          pooled[i] += Float(vector[i])
        }
        tokenCount += 1
        return true
      }

      if tokenCount > 0 {
        let scale = 1.0 / Float(tokenCount)
        for i in 0..<dimension {
          pooled[i] *= scale
        }
      }
      return pooled
    }
  }

  // MARK: - NLContextualEmbeddingError

  /// Provider-local error reasons, wrapped by
  /// `SemanticEmbeddingError.modelLoadFailed(underlying:)`.
  enum NLContextualEmbeddingError: Error, CustomStringConvertible {
    /// No `NLContextualEmbedding` for the requested language.
    case unsupportedLanguage(NLLanguage)
    /// Model assets aren't downloaded and aren't reachable (offline, sandbox).
    case assetsUnavailable

    var description: String {
      switch self {
      case .unsupportedLanguage(let language):
        "NLContextualEmbedding does not support language: \(language.rawValue)"
      case .assetsUnavailable:
        "NLContextualEmbedding model assets are not available locally; "
          + "download them first via NLContextualEmbedding.requestEmbeddingAssets(...)."
      }
    }
  }
#endif
