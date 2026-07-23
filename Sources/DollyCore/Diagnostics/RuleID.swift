/// Every diagnostic the tool can emit. Raw values are the public rule ids
/// used in configuration, suppression directives, and SARIF.
public enum RuleID: String, CaseIterable, Sendable, Codable {
  case exactClone = "exact-clone"
  case nearClone = "near-clone"
  case structuralClone = "structural-clone"

  public var summary: String {
    switch self {
    case .exactClone:
      "identical token sequences (Type-1 clones) duplicated across the corpus"
    case .nearClone:
      "token sequences identical up to identifiers and literals (Type-2 clones)"
    case .structuralClone:
      "structurally similar regions above the similarity threshold (Type-3 clones)"
    }
  }

  public var explanation: String {
    switch self {
    case .exactClone:
      """
      Two or more regions contain the same token sequence verbatim. Exact \
      clones drift independently: a fix applied to one copy silently misses \
      the others. Extract the shared code into one function or type; if the \
      duplication is deliberate (generated code, performance specialization), \
      accept it with a directive so the decision is on record.
      """
    case .nearClone:
      """
      Two or more regions are identical after normalizing identifiers and \
      literals — the same logic under different names. Near clones are the \
      classic copy-paste-rename bug source. Extract the shared shape into a \
      generic function or protocol extension, parameterizing what differs.
      """
    case .structuralClone:
      """
      Regions whose token shingles are similar above the configured \
      threshold (default 0.8) without being line-for-line copies. These \
      usually mark a missing abstraction. Review whether the variation is \
      essential; extract the common structure when it is not.
      """
    }
  }

  public var defaultSeverity: Severity {
    .warning
  }

  public var enabledByDefault: Bool {
    true
  }
}
