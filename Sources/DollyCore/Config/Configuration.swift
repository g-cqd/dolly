import Foundation

/// Analyzer configuration, loadable from `.dolly.json`.
///
/// Malformed configuration is a hard, typed failure — the analyzer fails
/// closed rather than running with rules silently dropped.
public struct Configuration: Sendable, Codable, Equatable {
  public struct RuleSettings: Sendable, Codable, Equatable {
    public var enabled: Bool?
    public var severity: Severity?

    public init(enabled: Bool? = nil, severity: Severity? = nil) {
      self.enabled = enabled
      self.severity = severity
    }
  }

  /// Tuning for the duplication engine. Absent values fall back to the
  /// engine defaults (50 tokens, 0.8 similarity).
  public struct DuplicationSettings: Sendable, Codable, Equatable {
    /// Minimum tokens for a region to count as a clone (1...10000).
    public var minimumTokens: Int?
    /// Minimum similarity for near/structural clones (0.0...1.0).
    public var minimumSimilarity: Double?

    public init(minimumTokens: Int? = nil, minimumSimilarity: Double? = nil) {
      self.minimumTokens = minimumTokens
      self.minimumSimilarity = minimumSimilarity
    }
  }

  /// Keyed by `RuleID` raw value. Unknown keys are rejected at load time so
  /// a typo can't silently disable nothing.
  public var rules: [String: RuleSettings]
  /// Path substrings to exclude (matched against the file path).
  public var exclude: [String]
  /// Optional duplication-engine tuning block.
  public var duplication: DuplicationSettings?

  public init(
    rules: [String: RuleSettings] = [:],
    exclude: [String] = [],
    duplication: DuplicationSettings? = nil
  ) {
    self.rules = rules
    self.exclude = exclude
    self.duplication = duplication
  }

  public static let `default` = Configuration()

  public static func load(path: String) throws(DollyError) -> Configuration {
    let config = try BoundedFileReader.readJSON(Configuration.self, path: path)
    if let bogus = config.rules.keys.first(where: { RuleID(rawValue: $0) == nil }) {
      throw .configurationInvalid(path: path, detail: "unknown rule id \"\(bogus)\"")
    }
    if let tokens = config.duplication?.minimumTokens, !(1...10000).contains(tokens) {
      throw .configurationInvalid(
        path: path, detail: "duplication.minimumTokens must be in 1...10000")
    }
    if let similarity = config.duplication?.minimumSimilarity,
      !(0.0...1.0).contains(similarity)
    {
      throw .configurationInvalid(
        path: path, detail: "duplication.minimumSimilarity must be in 0.0...1.0")
    }
    return config
  }

  public func isEnabled(_ rule: RuleID) -> Bool {
    rules[rule.rawValue]?.enabled ?? rule.enabledByDefault
  }

  public func severity(for rule: RuleID) -> Severity {
    rules[rule.rawValue]?.severity ?? rule.defaultSeverity
  }

  public func isExcluded(path: String) -> Bool {
    exclude.contains { !$0.isEmpty && path.contains($0) }
  }
}
