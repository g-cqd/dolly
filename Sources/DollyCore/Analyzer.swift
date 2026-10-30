public import CorpusScan
public import ProjectModel
import SourceCorpus
import SwiftParser
import SwiftSyntax

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Entry point of the pipeline: reads each file with a bounded reader, scans
/// suppression directives, extracts token sequences, runs the duplication
/// engine across the whole corpus, and assembles the report.
///
/// Duplication is a corpus-level property, so findings are produced from the
/// full set of files at once; the single-source entry point runs the same
/// engine over a corpus of one so unit tests and golden fixtures exercise
/// the identical path.
public struct Analyzer: Sendable {
  /// Files above this cap are reported degraded rather than read into RAM.
  public static let sourceByteCap = 10 * 1024 * 1024

  public let configuration: Configuration

  /// Where the facts cache lives and which workspace it serves (ADR-0011); nil disables caching entirely.
  public let cache: CacheLocation?

  /// Opt-in semantic (Type-4) pass options; nil (the default) means the pass
  /// is off and analysis is byte-identical to the structural-only default.
  public let semantic: SemanticOptions?

  /// Narrows the *report* to a set of files; nil reports everything. The corpus
  /// is never scoped: analyzing only changed files loses real clones (the partner
  /// lives in an untouched file) and invents others the full corpus attributes
  /// elsewhere, so only the report is filtered. A finding is kept when its anchor
  /// or any clone-group member is in scope, since the anchor (the smallest member)
  /// is arbitrary against a diff. When the anchor is out of scope but a member is
  /// in scope, the reported location moves to that member (see
  /// `Finding.reanchored(in:)`), so a PR bot can comment on the changed file. The
  /// fingerprint stays on the original anchor (`Finding.fingerprintAnchor`), so
  /// scoped runs keep matching unscoped baselines.
  /// The contract is ``ProjectModel/ReportScope``.
  public let reportScope: ReportScope?

  public init(
    configuration: Configuration = .default,
    cache: CacheLocation? = nil,
    semantic: SemanticOptions? = nil,
    reportScope: ReportScope? = nil
  ) {
    self.configuration = configuration
    self.cache = cache
    self.semantic = semantic
    self.reportScope = reportScope
  }

  public func analyze(files: [String]) async -> AnalysisReport {
    // Canonicalize before anything reads a path: `Finding.path` feeds the
    // fingerprint, and the corpus must not contain the same file twice under
    // two spellings (it would clone-match against itself).
    let files = SourcePath.canonicalized(files)
    let started = ContinuousClock.now

    var report = AnalysisReport()
    report.analyzedFileCount = files.count
    // Regions come from the project first (ADR-0024); the project's part is joined per run to the content's part the
    // cache keeps, since a manifest can change without the file changing.
    let classification =
      ProjectLayout.discover(paths: files).map(ProjectClassification.load) ?? .conventionsOnly
    report.classificationIssues = classification.issues(for: files)

    let scan: CorpusScan<ExtractedFile>
    do {
      scan = try await CorpusScanner.scan(
        paths: files, cache: cache,
        identity: CacheIdentity.current(tool: ToolInfo.name, version: ToolInfo.version),
        width: ConcurrencyConfiguration.default.maxConcurrentFiles, keepingBytes: true
      ) { path, bytes in Self.extract(bytes: bytes, path: path) }
    } catch {
      var cancelled = AnalysisReport()
      cancelled.wasCancelled = true
      return cancelled
    }
    let scanned = ContinuousClock.now
    if let failure = scan.cacheLoadFailure { report.cacheNote = failure }

    var prepared: [PreparedFile] = []
    for file in scan.files {
      if let failure = file.failure {
        report.degradedFiles.append(
          .init(path: file.path, detail: "read failed or exceeds size cap: \(failure)"))
        continue
      }
      guard let extracted = file.facts, let bytes = file.bytes else { continue }
      if let reason = extracted.degraded {
        report.degradedFiles.append(.init(path: file.path, detail: reason))
        continue
      }
      guard let facts = extracted.facts,
        let tokens = facts.fileTokens(
          path: file.path, source: String(decoding: bytes, as: UTF8.self))
      else {
        report.degradedFiles.append(.init(path: file.path, detail: "cached facts did not rebuild"))
        continue
      }
      let region = classification.classify(
        file.path, content: CodeRegion(rawValue: facts.contentRegion)
      ).region
      prepared.append(
        PreparedFile(
          tokens: tokens, table: SuppressionTable(directives: facts.directives),
          context: FileContext(region: region, previewSpans: facts.previewSpans)))
      if cache != nil {
        if file.cacheHit { report.cacheHits += 1 } else { report.cacheMisses += 1 }
      }
    }

    // Clone detection is whole-corpus by construction: a region is a clone
    // because a match exists *elsewhere in the corpus*. Running the engine over
    // a partially-read corpus would drop real clones and surface intra-subset
    // ones the whole corpus attributes differently, so a cancelled run reports
    // nothing rather than something wrong.
    if Task.isCancelled {
      var cancelled = AnalysisReport()
      cancelled.wasCancelled = true
      return cancelled
    }

    await runEngine(over: prepared, into: &report)
    report.findings.sort()
    report.timings = [
      "scan": Self.seconds(scanned - started),
      "detect": Self.seconds(ContinuousClock.now - scanned),
    ]

    // Re-check AFTER the engine: cancellation landing mid-engine truncates
    // frontier expansion, so clone groups come back split or missing — a
    // partial report that would otherwise be emitted as a complete one.
    if Task.isCancelled {
      var cancelled = AnalysisReport()
      cancelled.wasCancelled = true
      return cancelled
    }

    // Anchor fingerprints to the repository, not to this machine's checkout path
    // or to whether the caller remembered --relative-to. Display is a separate
    // concern, handled by PathPresentation.
    if let root = RepositoryRoot.common(of: files) {
      report = report.fingerprintsAnchored(to: root)
    }
    return report
  }

  public func analyze(source: String, path: String) async -> AnalysisReport {
    var report = AnalysisReport()
    report.analyzedFileCount = 1
    guard
      let (tokens, directives, context) = await Self.extractOnLargeStack(source: source, path: path)
    else {
      report.degradedFiles = [Self.tooDeep(path)]
      return report
    }
    let prepared = PreparedFile(
      tokens: tokens, table: SuppressionTable(directives: directives), context: context)
    await runEngine(over: [prepared], into: &report)
    report.findings.sort()
    return report
  }

  // MARK: - Pipeline stages

  /// Everything the corpus pass needs per file: the interned tokens for
  /// the engine and the suppression table for finding attribution.
  private struct PreparedFile: Sendable {
    let tokens: FileTokens
    let table: SuppressionTable
    let context: FileContext
  }

  private static func seconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) + Double(attoseconds) / 1e18
  }

  /// One file's extraction, as the cache stores it: not UTF-8, over the size cap, or nested too deeply is a reason
  /// instead of facts, so a cached file is never parsed again only to fail again.
  private static func extract(bytes: [UInt8], path: String) -> ExtractedFile {
    guard bytes.count <= sourceByteCap else {
      return ExtractedFile(
        facts: nil,
        degraded: "read failed or exceeds size cap: \(bytes.count) bytes, over \(sourceByteCap)")
    }
    // Swift sources are UTF-8. Repairing invalid bytes would analyze text
    // that is not in the file, and hide the file from the degraded count.
    guard let source = String(validating: bytes, as: UTF8.self) else {
      return ExtractedFile(facts: nil, degraded: "not valid UTF-8")
    }
    let tree = Parser.parse(source: source)
    if SyntaxDepth.exceeds(tree) {
      return ExtractedFile(facts: nil, degraded: tooDeep(path).detail)
    }
    let converter = SourceLocationConverter(fileName: path, tree: tree)
    let tokens = TokenSequenceExtractor().extract(from: tree, file: path, source: source)
    return ExtractedFile(
      facts: CachedFileFacts(
        tokens: tokens, directives: DirectiveScanner.scan(tree: tree, converter: converter),
        contentRegion: ProjectClassification.contentRegion(path: path, tree: tree),
        previewSpans: FileContext.previewSpans(tree, converter: converter)),
      degraded: nil)
  }

  /// Parse once; derive directives and the interned tokens from that tree.
  /// Interning stays per-file here so preparation remains parallel-safe;
  /// `runEngine` merges the tables corpus-side.
  /// The skipped-file entry for a tree nested past ``SyntaxDepth/defaultLimit``.
  private static func tooDeep(_ path: String) -> AnalysisReport.DegradedFile {
    .init(path: path, detail: "nested deeper than \(SyntaxDepth.defaultLimit) levels; not analysed")
  }

  /// ``extractFacts(source:path:)`` on a large stack: parsing and every walk of the tree recurse once per level
  /// (analyzerkit roadmap 0041).
  private static func extractOnLargeStack(
    source: String, path: String
  ) async -> (FileTokens, [SuppressionDirective], FileContext)? {
    await LargeStack.run { extractFacts(source: source, path: path) }
  }

  /// The uncached extraction path: parse, scan directives, intern tokens. Nil when the tree nests past
  /// ``SyntaxDepth/defaultLimit``, which no walk below can take.
  private static func extractFacts(
    source: String, path: String
  ) -> (FileTokens, [SuppressionDirective], FileContext)? {
    let tree = Parser.parse(source: source)
    if SyntaxDepth.exceeds(tree) { return nil }
    let converter = SourceLocationConverter(fileName: path, tree: tree)
    let directives = DirectiveScanner.scan(tree: tree, converter: converter)
    let tokens = TokenSequenceExtractor().extract(from: tree, file: path, source: source)
    return (tokens, directives, FileContext(path: path, tree: tree, converter: converter))
  }

  /// The parsed `--include`/`--exclude` selection; `Configuration.load`
  /// already validated it, so this can only fail for a `Configuration`
  /// built by hand with a bogus region name, and it fails open rather than
  /// making a rejected name analyze nothing.
  private var regionSelection: RegionSelection {
    (try? configuration.regionSelection()) ?? .none
  }

  /// Run the duplication engine across the corpus and partition results
  /// into findings and suppressed findings.
  private func runEngine(over allPrepared: [PreparedFile], into report: inout AnalysisReport) async
  {
    // Nobody edits a generated file, and generators repeat themselves by
    // design: generated files are left out of the corpus — unless
    // `--include generated` asks for them checked like any other.
    let regionSelection = self.regionSelection
    let prepared =
      regionSelection.isIncluded(.generated)
      ? allPrepared : allPrepared.filter { !$0.context.isGenerated }
    let generatedCount = allPrepared.count - prepared.count
    var previewGroupCount = 0
    defer {
      report.contextNote = ProjectWeighting.note(
        generatedFileCount: generatedCount, previewGroupCount: previewGroupCount)
    }
    guard !prepared.isEmpty else { return }
    // The token/suffix-array engine handles exact/near/structural; the
    // semantic (Type-4) type is produced only by the opt-in embedding pass,
    // never by this detector, so it is excluded from the engine's requested
    // types.
    let structuralTypes = Set(
      RuleID.allCases.filter(configuration.isEnabled).map(CloneReporting.cloneType(for:))
    ).subtracting([.semantic])
    let semanticActive = semantic != nil && configuration.isEnabled(.semanticClone)
    guard !structuralTypes.isEmpty || semanticActive else { return }

    var groups: [CloneGroup] = []
    if !structuralTypes.isEmpty {
      let detector = DuplicationDetector(
        configuration: DuplicationConfiguration(
          minimumTokens: configuration.duplication?.minimumTokens ?? 50,
          cloneTypes: structuralTypes,
          minimumSimilarity: configuration.duplication?.minimumSimilarity ?? 0.8
        )
      )
      let corpus = CorpusAssembler.assemble(files: prepared.map(\.tokens))
      groups = await detector.detectClones(in: corpus)
    }

    // Semantic pass runs after the structural pass; CloneReporting's
    // precedence filter (semantic sits last) drops any semantic group the
    // token detectors already reported.
    if semanticActive, let semantic {
      groups.append(
        contentsOf: await runSemanticPass(over: prepared, options: semantic, into: &report))
    }

    let contexts = prepared.keyed(by: \.tokens.file).mapValues(\.context)
    let weighted = ProjectWeighting.withoutPreviews(
      groups, contexts: contexts, regionSelection: regionSelection)
    groups = weighted.groups
    previewGroupCount = weighted.droppedGroupCount

    let tables = prepared.keyed(by: \.tokens.file).mapValues(\.table)
    let findings = CloneReporting.findings(
      from: groups, configuration: configuration, contexts: contexts,
      regionSelection: regionSelection
    )
    .map { ProjectWeighting.weighted($0, contexts: contexts, regionSelection: regionSelection) }
    for finding in findings {
      // A finding is suppressed when the anchor file's directives
      // cover the anchor line.
      if let reason = tables[finding.path]?.suppression(for: finding.rule, line: finding.line) {
        report.suppressed.append(.init(finding: finding, reason: reason))
      } else if let reportScope, !reportScope.contains(finding) {
        // Kept, not dropped: the count stays visible in the summary, and
        // `--format json` still carries them for anyone who wants the whole
        // picture from a scoped run. Scope is applied after suppression so
        // suppression debt keeps counting the whole corpus.
        report.outOfScope.append(finding)
      } else {
        // An in-scope group whose anchor is out of scope is shown at its first
        // in-scope member, the location a PR bot can comment on.
        report.findings.append(reportScope.map { finding.reanchored(in: $0) } ?? finding)
      }
    }
  }

  /// Resolve an embedding provider, extract function/initializer snippets from
  /// the (already in-memory) sources, and run embedding-clone discovery.
  /// Records a status/fallback note in the report; returns the discovered
  /// semantic groups (empty when a provider is unavailable — the macOS-only
  /// capability degrades gracefully rather than failing).
  private func runSemanticPass(
    over prepared: [PreparedFile], options: SemanticOptions, into report: inout AnalysisReport
  ) async -> [CloneGroup] {
    switch await SemanticDiscovery.resolveProvider(options) {
    case .unavailable(let note):
      report.semanticNote = note
      return []
    case .ready(let provider):
      var snippets: [EmbeddingSnippet] = []
      for file in prepared {
        snippets.append(
          contentsOf: FunctionSnippetExtractor.extract(
            source: file.tokens.text.source, file: file.tokens.file))
      }
      do {
        let groups = try await SemanticDiscovery.discover(
          snippets: snippets, provider: provider, options: options)
        let capLabel = options.maxGroupSize > 0 ? "\(options.maxGroupSize)/group" : "off"
        report.semanticNote =
          "semantic: embedded \(snippets.count) snippet(s) via \(provider.providerName), "
          + "\(groups.count) candidate group(s) before precedence filtering "
          + "(group-size cap \(capLabel))"
        return groups
      } catch {
        report.semanticNote = "semantic: embedding discovery failed (\(error)); structural only"
        return []
      }
    }
  }
}
