//  SemanticDiscovery.swift
//  dolly
//
//  Orchestration for the opt-in `--semantic` pass: provider selection
//  (relocated + adapted from SwiftStaticAnalysis' EmbeddingOptions) and the
//  embedding-discovery driver (relocated + adapted from the executable's
//  `runUmbrellaEmbeddingDiscovery`). Both lived in the SSA `swa` executable;
//  here they live in the library so `Analyzer` can drive them directly.
//
//  Provider selection is the only platform-gated surface. On Linux (no
//  CoreML / NaturalLanguage) every branch returns `.unavailable`, so
//  `--semantic` degrades to structural-only with a note and never fails.

import Foundation

// MARK: - SemanticOptions

/// CLI-facing configuration for the `--semantic` pass. Passed to
/// `Analyzer(configuration:cacheURL:semantic:)`; `nil` there means the pass is
/// off and analysis is byte-identical to the structural-only default.
public struct SemanticOptions: Sendable {
  /// Directory holding an HF tokenizer + Core ML model. When set, selects the
  /// `HFSemanticEmbeddingProvider`; when `nil`, the default on-device
  /// NLContextualEmbedding provider is used.
  public var bundlePath: String?
  /// Threshold preset (cosine / Jaccard floors).
  public var preset: SemanticPreset
  /// Max tokens per snippet for bundle providers. Defaults to 128 — the
  /// MiniLM-class context window and a safe cap for fixed-shape Core ML
  /// exports (a larger value overflows a `[1, 128]` model input). Snippets
  /// past this are truncated.
  public var maxLength: Int
  /// Top-k neighbors per HNSW query.
  public var k: Int

  public init(
    bundlePath: String? = nil,
    preset: SemanticPreset = .balanced,
    maxLength: Int = 128,
    k: Int = 10
  ) {
    self.bundlePath = bundlePath
    self.preset = preset
    self.maxLength = maxLength
    self.k = k
  }
}

// MARK: - SemanticProviderResolution

/// The outcome of resolving an embedding provider for the current platform
/// and options: either a ready provider or a human-readable note explaining
/// why the pass degraded to structural-only.
enum SemanticProviderResolution {
  case ready(any SemanticEmbeddingProvider)
  case unavailable(note: String)
}

// MARK: - SemanticDiscovery

enum SemanticDiscovery {
  /// Select an embedding provider. Order: explicit `--embedding-bundle`
  /// (HF/CoreML) → default on-device NLContextualEmbedding (macOS 14+, zero
  /// download) → `.unavailable` with a clear note.
  static func resolveProvider(_ options: SemanticOptions) async -> SemanticProviderResolution {
    if let bundlePath = options.bundlePath, !bundlePath.isEmpty {
      #if canImport(CoreML)
        do {
          let provider = try await HFSemanticEmbeddingProvider(
            bundleDir: URL(fileURLWithPath: bundlePath), maxLength: options.maxLength)
          return .ready(provider)
        } catch {
          return .unavailable(
            note: "semantic: could not load --embedding-bundle at \(bundlePath) "
              + "(\(error)); running structural only")
        }
      #else
        return .unavailable(
          note: "semantic: --embedding-bundle requires macOS (CoreML); running structural only")
      #endif
    }

    #if canImport(NaturalLanguage)
      if #available(macOS 14.0, *) {
        do {
          let provider = try NLContextualSemanticEmbeddingProvider()
          return .ready(provider)
        } catch {
          return .unavailable(
            note: "semantic: on-device NLContextualEmbedding unavailable (\(error)); "
              + "pass --embedding-bundle for a code model; running structural only")
        }
      } else {
        return .unavailable(
          note: "semantic: the default provider needs macOS 14+; pass --embedding-bundle; "
            + "running structural only")
      }
    #else
      return .unavailable(
        note: "semantic mode requires macOS (CoreML/NaturalLanguage); running structural only")
    #endif
  }

  /// Embedding-clone discovery over `snippets`. Adapted from SSA's
  /// `runUmbrellaEmbeddingDiscovery`: kNN over embeddings + token-Jaccard
  /// fusion. The late-interaction rerankers (MaxSim / AST-shape / APTED / PDG)
  /// are intentionally NOT lifted in 0.3.0 — PDG shells out to `swiftc` and
  /// the tree-edit rerankers are heavy. Seam: reintroduce them here after the
  /// cosine+Jaccard stage, gated on their (deferred) threshold fields.
  static func discover(
    snippets: [EmbeddingSnippet],
    provider: any SemanticEmbeddingProvider,
    options: SemanticOptions
  ) async throws -> [CloneGroup] {
    guard snippets.count >= 2 else { return [] }
    let thresholds = options.preset.thresholds
    return try await EmbeddingCloneDiscovery().discover(
      snippets: snippets,
      provider: provider,
      k: options.k,
      similarityThreshold: thresholds.cosine,
      minTokenOverlap: thresholds.jaccard
    )
  }
}
