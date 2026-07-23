//  ParallelMode.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

/// Parallel execution mode for analysis operations.
///
/// - `none`: Sequential execution, deterministic, lowest memory usage.
/// - `safe`: Default parallel behaviour (TaskGroup-based); callers sort
///   results at boundaries for determinism.
/// - `maximum`: Streaming expansion on the LSH candidate pass, trading
///   strict buffering for memory headroom on very large corpora.
enum ParallelMode: String, Codable, Sendable, CaseIterable {
    /// Sequential execution. No parallelism. Deterministic.
    case none

    /// TaskGroup-based parallelism. Recommended default.
    case safe

    /// Streaming candidate expansion for memory-bounded large runs.
    case maximum

    /// Whether any parallelism is engaged.
    var isParallel: Bool {
        switch self {
        case .none: false
        case .safe, .maximum: true
        }
    }
}
