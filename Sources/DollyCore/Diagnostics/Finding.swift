public import ProjectModel

/// A location related to a finding — for clone groups, one per group
/// member beyond the anchor.
public struct RelatedLocation: Sendable, Equatable, Codable {
  public let path: String
  public let line: Int
  public let column: Int

  public init(path: String, line: Int, column: Int) {
    self.path = path
    self.line = line
    self.column = column
  }
}

/// A single diagnostic produced by a rule.
public struct Finding: Sendable, Equatable {
  public let rule: RuleID
  public let severity: Severity
  public let path: String
  public let line: Int
  public let column: Int
  public let message: String
  /// Optional secondary context (retention path, doc citation, fix hint).
  public let note: String?
  /// Structured locations of the other clone-group members (the note
  /// carries the same information as text). Not part of the fingerprint:
  /// membership can shift without moving the anchor.
  public let related: [RelatedLocation]
  /// The path spelling the fingerprint hashes, when it must differ from the
  /// one shown.
  ///
  /// Set to the repository-relative path so a baseline is portable by
  /// construction: `--relative-to` then changes only what is *displayed*, and
  /// forgetting it can no longer silently invalidate a baseline. nil outside a
  /// repository, where `path` is hashed as before.
  public let fingerprintPath: String?
  /// The original anchor when the reported location was moved into the report
  /// scope; the fingerprint hashes it instead of the reported location. nil when
  /// unmoved.
  ///
  /// A clone group anchors at its smallest member, which a scoped run may not
  /// report. Hashing the original anchor keeps the fingerprint what the group
  /// gets in an unscoped run, so scoped runs keep matching unscoped baselines.
  public let fingerprintAnchor: RelatedLocation?

  public init(
    rule: RuleID,
    severity: Severity,
    path: String,
    line: Int,
    column: Int,
    message: String,
    note: String? = nil,
    related: [RelatedLocation] = [],
    fingerprintPath: String? = nil,
    fingerprintAnchor: RelatedLocation? = nil
  ) {  // @dl:accept -- a plain memberwise initializer, one assignment per stored property
    self.rule = rule
    self.severity = severity
    self.path = path
    self.line = line
    self.column = column
    self.message = message
    self.note = note
    self.related = related
    self.fingerprintPath = fingerprintPath
    self.fingerprintAnchor = fingerprintAnchor
  }

  /// The location the fingerprint hashes: the original anchor when the reported
  /// location was moved, otherwise the reported location itself.
  var fingerprintLocation: RelatedLocation {
    fingerprintAnchor ?? RelatedLocation(path: path, line: line, column: column)
  }

  /// The finding as a report scoped to `scope` shows it.
  ///
  /// When the anchor is out of scope but a related member is in scope, the
  /// reported location moves to the first such member, so an inline comment
  /// lands on a changed file. The old anchor becomes the first related location,
  /// the other members keep their order, and the note's duplicates list is
  /// rebuilt to match; any region tag after it is kept. The fingerprint stays on
  /// the original anchor (`fingerprintAnchor`). Any other finding is returned
  /// unchanged.
  /// - Complexity: O(m) for m related locations.
  func reanchored(in scope: ReportScope) -> Finding {
    guard !scope.files.contains(path),
      let index = related.firstIndex(where: { scope.files.contains($0.path) })
    else { return self }
    let original = RelatedLocation(path: path, line: line, column: column)
    let primary = related[index]
    var members = related
    members.remove(at: index)
    let reanchored = [original] + members

    // CloneReporting wrote the list from `related`. Anything else is left as it is.
    let previousList = CloneReporting.duplicatesList(related)
    let newList = CloneReporting.duplicatesList(reanchored)
    var rebuilt = note
    if let text = note, text.hasPrefix(previousList) {
      rebuilt = newList + text.dropFirst(previousList.count)
    }
    return Finding(
      rule: rule,
      severity: severity,
      path: primary.path,
      line: primary.line,
      column: primary.column,
      message: message,
      note: rebuilt,
      related: reanchored,
      fingerprintPath: fingerprintPath,
      fingerprintAnchor: fingerprintAnchor ?? original
    )
  }
}

extension Finding: ScopedFinding {
  /// The paths of the other clone-group members, so a scope matches by any member.
  public var relatedPaths: [String] { related.map(\.path) }
}

extension Finding: Comparable {
  /// Deterministic report ordering: path, then position, then rule.
  public static func < (lhs: Finding, rhs: Finding) -> Bool {
    if lhs.path != rhs.path { return lhs.path < rhs.path }
    if lhs.line != rhs.line { return lhs.line < rhs.line }
    if lhs.column != rhs.column { return lhs.column < rhs.column }
    return lhs.rule.rawValue < rhs.rule.rawValue
  }
}

extension Finding: Codable {
  private enum CodingKeys: String, CodingKey {
    case rule, severity, path, line, column, message, note, related, fingerprintPath
    case fingerprintAnchor, fingerprint
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      rule: try container.decode(RuleID.self, forKey: .rule),
      severity: try container.decode(Severity.self, forKey: .severity),
      path: try container.decode(String.self, forKey: .path),
      line: try container.decode(Int.self, forKey: .line),
      column: try container.decode(Int.self, forKey: .column),
      message: try container.decode(String.self, forKey: .message),
      note: try container.decodeIfPresent(String.self, forKey: .note),
      related: try container.decodeIfPresent([RelatedLocation].self, forKey: .related) ?? [],
      fingerprintPath: try container.decodeIfPresent(String.self, forKey: .fingerprintPath),
      fingerprintAnchor: try container.decodeIfPresent(
        RelatedLocation.self, forKey: .fingerprintAnchor)
    )
    // fingerprint is derived — ignored on decode, recomputed on access.
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rule, forKey: .rule)
    try container.encode(severity, forKey: .severity)
    try container.encode(path, forKey: .path)
    try container.encode(line, forKey: .line)
    try container.encode(column, forKey: .column)
    try container.encode(message, forKey: .message)
    try container.encodeIfPresent(note, forKey: .note)
    if !related.isEmpty {
      try container.encode(related, forKey: .related)
    }
    try container.encodeIfPresent(fingerprintAnchor, forKey: .fingerprintAnchor)
    try container.encode(fingerprint, forKey: .fingerprint)
  }
}
