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
  /// Hard ceiling on semantic-clone group membership. A group larger than
  /// this is dropped, not reported, because a group that big is the
  /// embedding-collapse pathology — an English-trained model (the zero-download
  /// NLContextual default) maps many small, structurally-plain declarations
  /// into one narrow cone of the vector space, so hundreds of unrelated
  /// snippets become mutually "similar" and union-find fuses them into one
  /// meaningless mega-group. Real clone families are small (a handful of
  /// members); code-trained bundle models already stay tight, so the cap is a
  /// no-op for them. `<= 0` disables the cap.
  public var maxGroupSize: Int

  public init(
    bundlePath: String? = nil,
    preset: SemanticPreset = .balanced,
    maxLength: Int = 128,
    k: Int = 10,
    maxGroupSize: Int = 25
  ) {
    self.bundlePath = bundlePath
    self.preset = preset
    self.maxLength = maxLength
    self.k = k
    self.maxGroupSize = maxGroupSize
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
  /// (HF/CoreML) → a model bundled next to the executable (the `dolly-full`
  /// release) → default on-device NLContextualEmbedding (macOS 14+, zero
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

    // No explicit bundle: prefer a model shipped alongside the executable (the
    // `dolly-full` release lays MiniLM out at `<exec-dir>/Models/MiniLM`), so a
    // bundled build uses a code-appropriate model with no flag. A load failure
    // here falls through to the NLContextual default rather than failing the
    // pass — the bundled model is an upgrade, never a hard requirement.
    #if canImport(CoreML)
      if let bundledDir = bundledModelDirectory() {
        if let provider = try? await HFSemanticEmbeddingProvider(
          bundleDir: bundledDir, maxLength: options.maxLength)
        {
          return .ready(provider)
        }
      }
    #endif

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

  #if canImport(CoreML)
    /// Locates a Core ML embedding bundle shipped alongside the executable.
    ///
    /// The `dolly-full` release archive lays the model out at
    /// `<executable-dir>/Models/MiniLM`, so a bundled build gets a
    /// code-appropriate model with no `--embedding-bundle` flag.
    /// `DOLLY_EMBEDDING_BUNDLE` overrides the location for installs that
    /// separate the binary from its resources (e.g. `bin/` + `share/`).
    /// Returns `nil` — the common case for the plain `dolly` binary and for
    /// dev/test builds, whose executable directory holds no model — which
    /// leaves the on-device NLContextual default in charge.
    static func bundledModelDirectory() -> URL? {
      let execURL =
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "dolly"))
        .resolvingSymlinksInPath()
      return bundledModelDirectory(
        executableDir: execURL.deletingLastPathComponent(),
        override: ProcessInfo.processInfo.environment["DOLLY_EMBEDDING_BUNDLE"])
    }

    /// Pure candidate search for `bundledModelDirectory()` — no process globals,
    /// so it is unit-testable. Search order: `override` (the
    /// `DOLLY_EMBEDDING_BUNDLE` value) → `<executableDir>/Models/MiniLM` →
    /// `<executableDir>/../share/dolly/Models/MiniLM`. The first candidate that
    /// contains a `.mlpackage`/`.mlmodelc` wins; `nil` when none do.
    static func bundledModelDirectory(executableDir: URL, override: String?) -> URL? {
      let fm = FileManager.default
      func hasModel(_ dir: URL) -> Bool {
        guard
          let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        return contents.contains {
          $0.pathExtension == "mlpackage" || $0.pathExtension == "mlmodelc"
        }
      }

      var candidates: [URL] = []
      if let override, !override.isEmpty {
        candidates.append(URL(fileURLWithPath: override))
      }
      candidates.append(executableDir.appendingPathComponent("Models/MiniLM"))
      // FHS / Homebrew-style `bin/dolly` next to `share/dolly/Models/MiniLM`.
      candidates.append(
        executableDir.deletingLastPathComponent().appendingPathComponent(
          "share/dolly/Models/MiniLM"))

      // Resolve each candidate so a symlinked model directory is handed to the
      // provider as its real path — `contentsOfDirectory` (here and in the
      // provider's own model lookup) does not traverse a URL that is itself a
      // symlink to a directory.
      return candidates.map { $0.resolvingSymlinksInPath() }.first(where: hasModel)
    }
  #endif

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
      minTokenOverlap: thresholds.jaccard,
      maxGroupSize: options.maxGroupSize
    )
  }
}
