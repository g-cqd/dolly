public import ProjectModel

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Analyzer configuration, loadable from `.dolly.json`.
///
/// Malformed configuration is a hard, typed failure — the analyzer fails
/// closed rather than running with rules silently dropped.
public struct Configuration: Sendable, Codable, Equatable {
  // @dl:accept -- RuleSettings and DuplicationSettings are separate Codable blocks that happen to share the memberwise shape
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
    /// Minimum similarity for structural clones (0.0...1.0). The default
    /// engine's near-clone pass ignores it.
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
  /// Regions (comma-separated: `preview,debug,test,mock,generated,script`,
  /// or `all`) to treat as first-class code: a clone found only in preview
  /// or generated code is reported like any other, tagged with its region;
  /// one found only in test code stays at its rule's normal severity
  /// instead of becoming a note. The same key, with the same values, in
  /// deadwood, arcleak and dolly.
  public var includeRegions: String?
  /// Regions to keep out of scope even if `includeRegions` (or `all`)
  /// names them; wins where the two disagree about the same region.
  public var excludeRegions: String?

  /// Decodes a partial configuration.
  ///
  /// `rules` and `exclude` are non-optional with memberwise defaults, so the
  /// synthesized `Codable` conformance made both *required* on the wire: a
  /// config supplying only `exclude` was rejected with
  /// `keyNotFound: "rules"`. Every key is optional here, matching what the
  /// memberwise initializer already implies — which is what a CI config
  /// setting nothing but an exclude list needs.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.rules =
      try container.decodeIfPresent([String: RuleSettings].self, forKey: .rules) ?? [:]
    self.exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
    self.duplication = try container.decodeIfPresent(DuplicationSettings.self, forKey: .duplication)
    self.includeRegions = try container.decodeIfPresent(String.self, forKey: .includeRegions)
    self.excludeRegions = try container.decodeIfPresent(String.self, forKey: .excludeRegions)
  }

  public init(
    rules: [String: RuleSettings] = [:],
    exclude: [String] = [],
    duplication: DuplicationSettings? = nil,
    includeRegions: String? = nil,
    excludeRegions: String? = nil
  ) {
    self.rules = rules
    self.exclude = exclude
    self.duplication = duplication
    self.includeRegions = includeRegions
    self.excludeRegions = excludeRegions
  }

  public static let `default` = Configuration()

  /// The parsed region selection; throws on an unknown region name from
  /// either key.
  public func regionSelection() throws(UnknownRegionName) -> RegionSelection {
    try RegionSelection(include: includeRegions, exclude: excludeRegions)
  }

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
    do {
      _ = try config.regionSelection()
    } catch {
      throw .configurationInvalid(path: path, detail: error.description)
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
