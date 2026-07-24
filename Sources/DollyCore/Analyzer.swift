public import Foundation

import SwiftParser
import SwiftSyntax

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

  /// Facts-cache location; nil disables caching entirely.
  public let cacheURL: URL?

  public init(configuration: Configuration = .default, cacheURL: URL? = nil) {
    self.configuration = configuration
    self.cacheURL = cacheURL
  }

  /// The platform cache default: `~/Library/Caches/dolly/facts.json` on
  /// macOS; the XDG cache equivalent on Linux (both via FileManager's
  /// caches directory).
  public static func defaultCacheURL() -> URL? {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appending(path: "dolly", directoryHint: .isDirectory)
      .appending(path: "facts.json")
  }

  public func analyze(files: [String]) async -> AnalysisReport {
    var report = AnalysisReport()
    report.analyzedFileCount = files.count

    let cache = cacheURL.map(FactsCache.load(url:))

    let outcomes = await ParallelProcessor.map(
      files,
      maxConcurrency: ConcurrencyConfiguration.default.maxConcurrentFiles
    ) { path -> FileOutcome in
      let data: Data
      do {
        data = try BoundedFileReader.read(path: path, cap: Self.sourceByteCap)
      } catch {
        return .degraded(
          .init(path: path, detail: "read failed or exceeds size cap: \(error)"))
      }
      let source = String(decoding: data, as: UTF8.self)

      guard let cache else {
        return .prepared(Self.prepare(source: source, path: path), entry: nil, cached: false)
      }
      // Cache hit: fingerprint matches and the payload reconstructs
      // cleanly — parse and extraction are skipped. Anything else is a
      // miss (fail open) and refreshes the entry.
      let fingerprint = FactsCache.fingerprint(of: data)
      if let entry = cache.entry(for: path, fingerprint: fingerprint),
        let tokens = entry.fileTokens(path: path, source: source)
      {
        let prepared = PreparedFile(
          tokens: tokens, table: SuppressionTable(directives: entry.directives))
        return .prepared(prepared, entry: entry, cached: true)
      }
      let (tokens, directives) = Self.extractFacts(source: source, path: path)
      let prepared = PreparedFile(tokens: tokens, table: SuppressionTable(directives: directives))
      let entry = FactsCache.Entry(
        fingerprint: fingerprint, tokens: tokens, directives: directives)
      return .prepared(prepared, entry: entry, cached: false)
    }

    var prepared: [PreparedFile] = []
    var freshCache = FactsCache()
    for outcome in outcomes {
      switch outcome {
      case .prepared(let file, let entry, let cached):
        prepared.append(file)
        if cached { report.cacheHits += 1 } else if cache != nil { report.cacheMisses += 1 }
        if let entry {
          freshCache.update(path: file.tokens.file, entry: entry)
        }
      case .degraded(let degraded):
        report.degradedFiles.append(degraded)
      }
    }

    // Persist only when contents changed: fresh extractions happened, or
    // entries for absent files were pruned (the rebuilt cache only ever
    // contains this run's files).
    if let cacheURL, let cache,
      report.cacheMisses > 0 || Set(cache.entries.keys) != Set(freshCache.entries.keys)
    {
      freshCache.persist(url: cacheURL)
    }

    await runEngine(over: prepared, into: &report)
    report.findings.sort()
    return report
  }

  public func analyze(source: String, path: String) async -> AnalysisReport {
    var report = AnalysisReport()
    report.analyzedFileCount = 1
    await runEngine(over: [Self.prepare(source: source, path: path)], into: &report)
    report.findings.sort()
    return report
  }

  // MARK: - Pipeline stages

  /// Everything the corpus pass needs per file: the interned tokens for
  /// the engine and the suppression table for finding attribution.
  private struct PreparedFile: Sendable {
    let tokens: FileTokens
    let table: SuppressionTable
  }

  private enum FileOutcome: Sendable {
    case prepared(PreparedFile, entry: FactsCache.Entry?, cached: Bool)
    case degraded(AnalysisReport.DegradedFile)
  }

  /// Parse once; derive directives and the interned tokens from that tree.
  /// Interning stays per-file here so preparation remains parallel-safe;
  /// `runEngine` merges the tables corpus-side.
  private static func prepare(source: String, path: String) -> PreparedFile {
    let (tokens, directives) = extractFacts(source: source, path: path)
    return PreparedFile(tokens: tokens, table: SuppressionTable(directives: directives))
  }

  /// The uncached extraction path: parse, scan directives, intern tokens.
  private static func extractFacts(
    source: String, path: String
  ) -> (FileTokens, [SuppressionDirective]) {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: path, tree: tree)
    let directives = DirectiveScanner.scan(tree: tree, converter: converter)
    let tokens = TokenSequenceExtractor().extract(from: tree, file: path, source: source)
    return (tokens, directives)
  }

  /// Run the duplication engine across the corpus and partition results
  /// into findings and suppressed findings.
  private func runEngine(over prepared: [PreparedFile], into report: inout AnalysisReport) async {
    // The token/suffix-array engine handles exact/near/structural; the
    // semantic (Type-4) type is produced only by the opt-in embedding pass
    // (wired in `runSemanticDiscovery`), never by this detector, so it is
    // excluded from the engine's requested types.
    let structuralTypes = Set(
      RuleID.allCases.filter(configuration.isEnabled).map(CloneReporting.cloneType(for:))
    ).subtracting([.semantic])
    guard !structuralTypes.isEmpty, !prepared.isEmpty else { return }

    let detector = DuplicationDetector(
      configuration: DuplicationConfiguration(
        minimumTokens: configuration.duplication?.minimumTokens ?? 50,
        cloneTypes: structuralTypes,
        minimumSimilarity: configuration.duplication?.minimumSimilarity ?? 0.8
      )
    )
    let corpus = CorpusAssembler.assemble(files: prepared.map(\.tokens))
    let groups = await detector.detectClones(in: corpus)
    let tables = prepared.keyed(by: \.tokens.file).mapValues(\.table)

    for finding in CloneReporting.findings(from: groups, configuration: configuration) {
      // A finding is suppressed when the anchor file's directives
      // cover the anchor line.
      if let reason = tables[finding.path]?.suppression(for: finding.rule, line: finding.line) {
        report.suppressed.append(.init(finding: finding, reason: reason))
      } else {
        report.findings.append(finding)
      }
    }
  }
}
