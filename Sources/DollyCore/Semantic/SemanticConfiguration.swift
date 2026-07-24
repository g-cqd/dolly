//  SemanticConfiguration.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

import Foundation

// MARK: - SemanticPreset

/// Threshold preset for the semantic (`--semantic`) clone pass. The three
/// thresholds interact and the right combination is model-specific, so we
/// ship named intent (`balanced` / `strict` / `loose`) rather than magic
/// numbers.
///
/// Public so the `dolly` executable can add `ExpressibleByArgument`
/// conformance without pulling ArgumentParser into DollyCore.
public enum SemanticPreset: String, CaseIterable, Sendable {
  /// Good default: balanced precision/recall (cosine 0.85, Jaccard 0.20).
  case balanced
  /// High precision: tighter thresholds (cosine 0.90, Jaccard 0.30), fewer
  /// findings.
  case strict
  /// High recall: looser thresholds (cosine 0.80, Jaccard 0.10), more noise.
  case loose

  var thresholds: SemanticThresholds {
    switch self {
    case .balanced: SemanticThresholds(cosine: 0.85, jaccard: 0.20)
    case .strict: SemanticThresholds(cosine: 0.90, jaccard: 0.30)
    case .loose: SemanticThresholds(cosine: 0.80, jaccard: 0.10)
    }
  }
}

// MARK: - SemanticThresholds

/// Tunable thresholds for the embedding-driven clone-discovery pipeline.
/// `cosine` gates the kNN embedding-similarity stage; `jaccard` gates the
/// identifier-token-overlap stage that kills "shape-true, intent-false"
/// false positives (a snippet pair whose embeddings agree but whose
/// vocabularies are disjoint).
///
/// TODO(deferred rerankers): the late-interaction rerank gates from
/// SwiftStaticAnalysis (MaxSim, AST-shape, APTED, PDG) are intentionally not
/// lifted in 0.3.0 — PDG shells out to `swiftc`, and the tree-edit rerankers
/// are heavy. When they return, add their threshold fields here and consume
/// them in `EmbeddingCloneDiscovery` / the discovery driver. Until then
/// `strict` differs from `balanced` only in the cosine/Jaccard floors.
struct SemanticThresholds: Sendable {
  var cosine: Double
  var jaccard: Double
}
