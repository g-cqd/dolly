public import Suppression

/// One parsed `@dl:` / `@dolly:` directive comment.
///
/// The `@` sigil marks an instruction to the analyzer; `dl` and `dolly` are
/// interchangeable namespaces. Grammar (whitespace-tolerant, rule ids comma-
/// or space-separated; `all` or no rule = every rule):
///
///     // @dl:accept [rules] [-- reason]        accept the finding here AND on
///                                              the next line (works trailing
///                                              or on the line above the code)
///     // @dl:accept:this [rules] [-- reason]   this line only
///     // @dl:accept:next [rules] [-- reason]   next line only
///     // @dl:disable [rules|all]               region start (to EOF if unbalanced)
///     // @dl:enable  [rules|all]               region end
///
/// `@dolly:` is an exact synonym for `@dl:`.
public typealias SuppressionDirective = Suppression.Directive<RuleID>

extension Suppression.Directive where Rule == RuleID {
  /// The accepted namespace prefixes after the `@` sigil.
  public static var namespaces: [String] { dollyDirectiveNamespaces }

  /// Parses one comment. Returns nil when it isn't an `@dl:`/`@dolly:`
  /// directive. Unknown rule ids inside a directive are ignored (they may
  /// belong to a future version) — but if a rule-scoped verb names *only*
  /// unknown rules, the directive suppresses nothing rather than everything.
  public static func parse(comment: String, line: Int) -> Self? {
    grammar.parse(comment: comment, line: line, rule: RuleID.init(rawValue:))
  }

  static var grammar: DirectiveGrammar { dollyDirectiveGrammar }
}

// Stored once: a generic type cannot hold a static stored property.
private let dollyDirectiveNamespaces = ["dl:", "dolly:"]
private let dollyDirectiveGrammar = DirectiveGrammar(namespaces: dollyDirectiveNamespaces)
