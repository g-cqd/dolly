/// Every diagnostic the tool can emit. Raw values are the public rule ids
/// used in configuration, suppression directives, and SARIF.
public enum RuleID: String, CaseIterable, Sendable, Codable {
  case exactClone = "exact-clone"
  case nearClone = "near-clone"
  case structuralClone = "structural-clone"
  case semanticClone = "semantic-clone"

  public var summary: String {
    switch self {
    case .exactClone:
      "identical token sequences (Type-1 clones) duplicated across the corpus"
    case .nearClone:
      "token sequences identical up to identifiers and literals (Type-2 clones)"
    case .structuralClone:
      "structurally similar regions above the similarity threshold (Type-3 clones)"
    case .semanticClone:
      "behaviorally equivalent regions in different idioms (Type-4 clones), by embedding similarity"
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
    case .semanticClone:
      """
      Two or more regions compute the same result through different token \
      shapes — a `for` loop versus `reduce`, iteration versus recursion — so \
      the token, near, and structural detectors, which compare token \
      sequences, miss them. This rule embeds each function/type snippet with \
      a semantic model and groups regions whose embeddings are close (cosine) \
      and whose identifier vocabularies overlap (Jaccard). It is reported \
      only for groups the token detectors did not already claim. It runs \
      only under `--semantic` and is macOS-only (CoreML / NaturalLanguage); \
      on other platforms `--semantic` degrades to structural-only with a note.

      The default provider is Apple's on-device NLContextualEmbedding (zero \
      model download, macOS 14+). That is an English natural-language model, \
      NOT code-trained, so its recall on idiom-level clones is materially \
      lower than a code-embedding model — pass `--embedding-bundle <dir>` \
      with a CodeBERT/MiniLM-class Core ML + tokenizer bundle for higher \
      recall. Review each group: extract the shared behavior into one \
      implementation when the duplication is real; accept it with a \
      directive when it is not.
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
