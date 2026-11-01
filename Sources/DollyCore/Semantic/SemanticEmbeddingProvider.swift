//  SemanticEmbeddingProvider.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  Produces dense vector embeddings of code snippets for semantic (Type-4)
//  clone detection. The discovery driver pipes a snippet through
//  `embed(snippet:)`, then groups functionally equivalent code via cosine
//  similarity in embedding space — recovering idiom-level clones (for-loop
//  vs reduce, iteration vs recursion) that the token and structural
//  detectors cannot reach.

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// MARK: - SemanticEmbeddingProvider

/// A source of fixed-dimension embeddings for code snippets. Conformers wrap
/// a concrete model: Apple's on-device `NLContextualEmbedding`
/// (`NLContextualSemanticEmbeddingProvider`, the default), a HuggingFace
/// tokenizer + Core ML bundle (`HFSemanticEmbeddingProvider`), or the
/// dependency-free `DeterministicEmbeddingProvider` used for tests.
protocol SemanticEmbeddingProvider: Sendable {
  /// Dimension of every embedding this provider returns. Callers validate
  /// dimension equality before computing similarity.
  var embeddingDimension: Int { get }

  /// Human-readable identity of the model actually running, surfaced in the
  /// semantic-pass status note so a run makes clear whether it used a bundled
  /// code model or the zero-download on-device default.
  var providerName: String { get }

  /// Embed a code snippet into a dense vector. Throws if the snippet
  /// exceeds the provider's context window or the model fails to load.
  func embed(snippet: String) async throws -> [Float]

  /// Batch embedding for throughput. The default runs `embed(snippet:)`
  /// serially; providers backed by the GPU / Neural Engine should override
  /// to batch into a single inference call.
  func embed(snippets: [String]) async throws -> [[Float]]
}

extension SemanticEmbeddingProvider {
  var providerName: String { "embedding" }

  func embed(snippets: [String]) async throws -> [[Float]] {
    var results: [[Float]] = []
    results.reserveCapacity(snippets.count)
    for snippet in snippets {
      results.append(try await embed(snippet: snippet))
    }
    return results
  }
}

// MARK: - SemanticEmbeddingError

enum SemanticEmbeddingError: Error, Sendable, CustomStringConvertible {
  case modelLoadFailed(underlying: any Error)
  case inferenceFailed(reason: String)

  var description: String {
    switch self {
    case .modelLoadFailed(let underlying):
      "Failed to load embedding model: \(underlying)"
    case .inferenceFailed(let reason):
      "Embedding inference failed: \(reason)"
    }
  }
}
