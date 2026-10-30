import AnalyzerCLI
import AnalyzerConfiguration
public import ArgumentParser
import CorpusScan
import DollyCore
import ProjectModel
import ReportSupport
import SourceCorpus
import SystemPackage

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Writes `message` to stderr, so stdout stays machine-parseable.
///
/// `SystemPackage.FileDescriptor` rather than Foundation's `FileHandle`:
/// FileHandle lives in corelibs Foundation, which re-links ~50 MiB of ICU into
/// every Linux binary. Writing to fd 2 through libc directly would work too,
/// but needs three separate unsafe/concurrency escapes (`fputs` is a pointer
/// API and Glibc's `stderr` is a mutable global); this stays fully safe.
private func writeStandardError(_ message: String) {
  _ = try? FileDescriptor.standardError.writeAll(message.utf8)
}

@main
struct DollyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: ToolInfo.name,
    abstract: "Duplicate-code detection for Swift: exact, near, and structural clones.",
    version: ToolInfo.version,
    subcommands: [Analyze.self, Rules.self],
    defaultSubcommand: Analyze.self
  )
}

extension OutputFormat {
  init(_ format: OutputOptions.Format) {
    switch format {
    case .xcode: self = .xcode
    case .json: self = .json
    case .sarif: self = .sarif
    }
  }
}

extension SemanticPreset: ExpressibleByArgument {}

struct Analyze: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Analyze Swift files or directories (default: current directory)."
  )

  // analyzerkit's shared option groups (ADR-0019), in order; dolly's own options after them.
  @OptionGroup(title: OptionGroupTitle.input) var input: InputOptions
  @OptionGroup(title: OptionGroupTitle.output) var output: OutputOptions
  @OptionGroup(title: OptionGroupTitle.rules) var rules: RuleOptions
  @OptionGroup(title: OptionGroupTitle.cache) var cache: CacheOptions

  @Flag(
    name: .long,
    help: ArgumentHelp(
      "Semantic (Type-4) clone detection: embed function snippets and report idiom-level clones "
        + "the token detectors miss. Opt-in and macOS-only (CoreML/NaturalLanguage); degrades to "
        + "structural-only elsewhere."))
  var semantic = false

  @Option(
    name: .customLong("embedding-bundle"),
    help: ArgumentHelp(
      "Directory with a HuggingFace tokenizer + Core ML model to use for --semantic (higher "
        + "recall). Default: Apple's on-device NLContextualEmbedding (zero download, macOS 14+)."))
  var embeddingBundle: String?

  @Option(
    name: .customLong("embedding-preset"),
    help: ArgumentHelp("Threshold preset for --semantic: balanced (default), strict, or loose."))
  var embeddingPreset: SemanticPreset = .balanced

  @Option(
    name: .customLong("semantic-max-group"),
    help: ArgumentHelp(
      "Drop any --semantic clone group larger than this many members (default 25). Huge groups "
        + "are the embedding-collapse pathology of the zero-download NLContextual model, not real "
        + "clone families. Set 0 to disable the cap."))
  var semanticMaxGroup: Int = 25

  func run() async throws {
    for deprecation in input.deprecations { note(deprecation.message(tool: ToolInfo.name)) }
    if !input.defines.isEmpty {
      note("dolly: note: --define has no effect: dolly compares the tokens of every #if clause")
    }
    // Read before the analysis, so a bad path fails with 78 without the analysis cost.
    var newSinceBaseline: Baseline?
    if let path = output.reportNewSince {
      newSinceBaseline = try baselineOrExit { try Baseline.load(path: path) }
    }
    var configuration = try loadConfiguration()
    if let include = input.includeRegions {
      configuration.includeRegions = include
    }
    if let exclude = input.excludeRegions {
      configuration.excludeRegions = exclude
    }
    do {
      _ = try configuration.regionSelection()
    } catch {
      throw ValidationError(error.description)
    }
    if let wanted = rules.rules {
      var settings = configuration.rules
      for name in wanted where RuleID(rawValue: name) == nil {
        let known = RuleID.allCases.map(\.rawValue).joined(separator: ", ")
        throw ValidationError("unknown rule \"\(name)\" — known rules: \(known)")
      }
      for rule in RuleID.allCases where !wanted.contains(rule.rawValue) {
        settings[rule.rawValue, default: Configuration.RuleSettings()].enabled = false
      }
      configuration.rules = settings
    }
    let reportScope = try resolveReportScope()
    let files = try discoverSwiftFiles(configuration: configuration)
    guard !files.isEmpty else { throw ValidationError(DollyError.noInputs.description) }
    // A non-empty scope that intersects zero corpus files is almost always a
    // misconfiguration (paths relative to the wrong directory, wrong workdir),
    // and it silently reports nothing. Warn loudly; an *empty* scope stays
    // silent — "no Swift changed" is legitimate. The corpus is canonicalized
    // the way the scope is, so a path spelled through a symlink still matches.
    // Skipped under --report-new-since: a change that only deletes a file names it in --only.
    if output.reportNewSince == nil, let scope = reportScope, !scope.files.isEmpty,
      ReportScope(files: files).files.isDisjoint(with: scope.files)
    {
      writeStandardError(
        "dolly: warning: --only scope matches no analyzed file — check that scope paths are relative to the right directory\n"
      )
    }

    let semanticOptions: SemanticOptions? =
      semantic
      ? SemanticOptions(
        bundlePath: embeddingBundle, preset: embeddingPreset, maxGroupSize: semanticMaxGroup)
      : nil
    var report = await Analyzer(
      configuration: configuration, cache: cache.noCache ? nil : cacheLocation(),
      semantic: semanticOptions, reportScope: reportScope
    ).analyze(files: files)
    let relativeTo = output.relativeTo

    // A cancelled run analysed a partial corpus and therefore reports nothing.
    // That must never read as a clean gate — exit as an internal failure,
    // with nothing on stdout.
    if report.wasCancelled {
      writeStandardError(
        "dolly: run cancelled before the corpus was complete; no findings reported\n")
      throw ExitCode(ExitStatus.internalFailure.rawValue)
    }

    // A corpus where EVERY file degraded analyzed nothing; exiting 0 would be
    // a green gate over unscanned code. Partial degradation stays a warning —
    // single unreadable files are reported per-file — but total failure is a
    // broken gate. The report is still printed: it names every skipped file
    // and why, and its SARIF marks the run failed. So exit 70 with a report
    // means "nothing analyzed", and exit 70 with empty stdout means the run
    // itself failed.
    if report.everyFileSkipped {
      if let relativeTo {
        report = report.relativized(to: relativeTo)
      }
      let text = ReportFormatter.format(
        report, as: OutputFormat(output.format), relativeTo: relativeTo, verbose: output.verbose,
        timings: output.timings)
      if !text.isEmpty {
        print(text)
      }
      writeStandardError(
        "dolly: every file in the corpus was skipped (unreadable, non-UTF8, or over the size cap); nothing was analyzed\n"
      )
      throw ExitCode(ExitStatus.internalFailure.rawValue)
    }

    // Before anything reads a path: baselines, SARIF and the formatted output
    // must all agree on one spelling, and the fingerprint is derived from it.
    if let relativeTo {
      report = report.relativized(to: relativeTo)
    }

    // Semantic-pass status / graceful-fallback note goes to stderr so stdout
    // stays machine-parseable.
    if let semanticNote = report.semanticNote {
      note(ToolInfo.name + ": " + semanticNote)
    }
    if let contextNote = report.contextNote {
      note(ToolInfo.name + ": " + contextNote)
    }
    if let cacheNote = report.cacheNote {
      note(ToolInfo.name + ": " + cacheNote)
    }
    for issue in report.classificationIssues {
      note("dolly: note: \(issue.message)")
      if output.verbose { for path in issue.paths { note("    \(path)") } }
    }

    var promoted: Set<String> = []
    var baselineMatchesNothing = false
    if let newSinceBaseline {
      let known = Set(newSinceBaseline.fingerprints)
      baselineMatchesNothing = NewSince.matchesNothing(
        report.findings + report.outOfScope, in: known, fingerprint: \.fingerprint)
      let promotion = NewSince.promote(
        inScope: report.findings, outOfScope: report.outOfScope, notIn: known,
        fingerprint: \.fingerprint)
      report.findings = promotion.reported.sorted()
      report.outOfScope = promotion.outOfScope
      promoted = promotion.promoted
    }

    if let writeBaseline = output.writeBaseline {
      // Guarded in validate(): a baseline is whole-corpus debt by definition,
      // so it can never be written from a scoped run.
      try outputOrExit { try Baseline(findings: report.findings).write(path: writeBaseline) }
      note("\(ToolInfo.name): wrote baseline with \(report.findings.count) fingerprint(s)")
      return
    }
    var baselinedCount = 0
    if let baseline = output.baseline {
      let loaded = try baselineOrExit { try Baseline.load(path: baseline) }
      let (kept, baselined) = loaded.filter(report.findings)
      report.findings = kept
      baselinedCount = baselined.count
    }
    var extraNotes: [RunNote] = []
    if let path = output.reportNewSince {
      // Counted after --baseline, so the note states what the report shows.
      let count = report.findings.count(where: { promoted.contains($0.fingerprint) })
      for message in NewSince.notes(
        promoted: count, matchesNothing: baselineMatchesNothing, baseline: path)
      {
        extraNotes.append(RunNote(code: "report-new-since", severity: "note", message: message))
        note(message)
      }
    }

    let text = ReportFormatter.format(
      report, as: OutputFormat(output.format), relativeTo: relativeTo, runNotes: extraNotes,
      verbose: output.verbose, timings: output.timings)
    if !text.isEmpty {
      print(text)
    }
    if output.timings {
      for (phase, seconds) in report.timings.sorted(by: { $0.key < $1.key }) {
        note("dolly: timing: \(phase) \(Int((seconds * 1000).rounded())) ms")
      }
    }
    var summary = ReportFormatter.summary(report)
    if baselinedCount > 0 {
      summary += "; \(baselinedCount) baselined"
    }
    if !report.outOfScope.isEmpty {
      summary += "; \(report.outOfScope.count) out of scope"
    }
    note(summary)

    // Notes inform; they never fail a run, not even a strict one.
    let failed = RunOutcome.fails(report.findings.map(\.severity), strict: output.strict)
    if failed {
      throw ExitCode(ExitStatus.findings.rawValue)
    }
  }

  /// A line on stderr, unless `--quiet`.
  private func note(_ line: String) {
    if !output.quiet { writeStandardError(line + "\n") }
  }

  /// The cache's root (`--cache-path`, or the user cache directory) and the workspace the run serves (ADR-0011).
  private func cacheLocation() -> CacheLocation {
    let environment = ProcessInfo.processInfo.environment
    let root =
      cache.cachePath.map { SourcePath.absolute($0) }
      ?? CacheLocation.defaultRoot(
        tool: ToolInfo.name, environment: environment, home: environment["HOME"] ?? "/tmp")
    let workspace =
      ProjectLayout.discover(paths: input.paths)?.root
      ?? SourcePath.absolute(input.paths.first ?? ".")
    return CacheLocation(root: root, workspace: workspace)
  }

  func validate() throws {
    // A baseline records the whole corpus's accepted debt. Writing one from a
    // scoped run would silently accept only the scoped subset and drop
    // everything else from the baseline, so refuse rather than surprise.
    if output.writeBaseline != nil, !input.only.isEmpty || input.onlyFrom != nil {
      throw ValidationError(
        "--write-baseline records whole-corpus debt and cannot be combined with "
          + "--only/--only-from. Write the baseline unscoped, then scope the runs that use it.")
    }
    // Without a scope every finding is already reported, so there is nothing to promote (ADR-0028).
    if output.reportNewSince != nil, input.only.isEmpty, input.onlyFrom == nil {
      throw ValidationError("--report-new-since requires --only or --only-from")
    }
    if input.onlyFrom == "-", input.paths == ["-"] {
      throw ValidationError("--only-from - reads stdin, so paths cannot also come from stdin.")
    }
  }

  /// A caller-supplied path list is trust-boundary input, so the read is
  /// bounded: 2600 absolute paths is ~310 KB, and anything past the cap is a
  /// mistake or an attack rather than a change set.
  private static let scopeByteCap = 4 * 1024 * 1024

  /// nil means "report everything". An *empty* scope is meaningful and
  /// distinct: `--only-from` pointed at a change set with no Swift files, so
  /// nothing should be reported.
  private func resolveReportScope() throws -> ReportScope? {
    guard !input.only.isEmpty || input.onlyFrom != nil else { return nil }
    var entries = input.only
    if let onlyFrom = input.onlyFrom {
      entries.append(contentsOf: try readScopeEntries(from: onlyFrom))
    }
    return ReportScope(files: entries)
  }

  private func readScopeEntries(from source: String) throws -> [String] {
    let text: String
    if source == "-" {
      var accumulated = ""
      while let line = readLine(strippingNewline: true) {
        accumulated += line + "\n"
        guard accumulated.utf8.count <= Self.scopeByteCap else {
          throw ValidationError("--only-from - exceeds the \(Self.scopeByteCap) byte cap")
        }
      }
      text = accumulated
    } else {
      let attributes = try? FileManager.default.attributesOfItem(atPath: source)
      guard (attributes?[.type] as? FileAttributeType) == .typeRegular else {
        throw ValidationError("--only-from: not a regular file: \(source)")
      }
      if let size = attributes?[.size] as? Int, size > Self.scopeByteCap {
        throw ValidationError("--only-from: \(source) exceeds the \(Self.scopeByteCap) byte cap")
      }
      guard let contents = try? String(contentsOfFile: source, encoding: .utf8) else {
        throw ValidationError("--only-from: unreadable: \(source)")
      }
      text = contents
    }
    // Every line end: "\r\n" is one Character, so splitting on "\n" alone kept a CRLF file one line (analyzerkit
    // roadmap 0057, fixed in deadwood and arcleak).
    return text.split(whereSeparator: \.isNewline)
      // Standard library rather than trimmingCharacters(in:), which is
      // corelibs-only: dolly builds against FoundationEssentials on Linux.
      .map { line -> String in
        // Spaces and tabs at either end; a stray \r too.
        let trimmable: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\r" }
        var entry = String(
          line.drop(while: trimmable).reversed().drop(while: trimmable).reversed())
        // git C-quotes paths with special bytes unless core.quotepath=false;
        // strip the quotes so plain quoted paths keep matching.
        if entry.hasPrefix("\"") && entry.hasSuffix("\"") && entry.count >= 2 {
          entry = String(entry.dropFirst().dropLast())
            .replacing("\\\"", with: "\"").replacing("\\\\", with: "\\")
        }
        return entry
      }
      .filter { !$0.isEmpty }
  }

  /// Exit codes, so CI can tell "the gate found problems" from "the gate broke".
  ///
  /// `1` means findings and nothing else: a script that posts a review comment
  /// on `1` must not also fire on a typo in the config file. `sysexits.h`
  /// supplies the rest — `64` usage (already used for bad paths), `70` an
  /// internal failure, `78` a bad configuration or baseline. `70` prints the
  /// report when every file was skipped, and nothing when the run was
  /// cancelled, so a caller tells the two apart by whether stdout is empty.

  /// A malformed config is a broken gate, not a finding — exit 78 so CI can
  /// tell the two apart instead of reporting a typo as analysis output.

  /// A missing or corrupt baseline is a broken gate, not a finding — exit 78
  /// so CI cannot mistake it for "findings found" (exit 1).
  /// An output the run was asked to write and could not is exit 74, not a configuration error (ADR-0018).
  private func outputOrExit<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      writeStandardError("dolly: \(error)\n")
      throw ExitCode(ExitStatus.outputFailure.rawValue)
    }
  }

  private func baselineOrExit<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      writeStandardError("dolly: \(error)\n")
      throw ExitCode(ExitStatus.badConfiguration.rawValue)
    }
  }

  private func loadConfiguration() throws -> Configuration {
    do {
      return try loadConfigurationUncaught()
    } catch let error as ExitCode {
      throw error
    } catch {
      writeStandardError("dolly: \(error)\n")
      throw ExitCode(ExitStatus.badConfiguration.rawValue)
    }
  }

  /// `--config`, or the configuration directory's shared and own files (ADR-0020).
  private func loadConfigurationUncaught() throws -> Configuration {
    let resolved = try Configuration.resolve(
      explicit: input.config, currentDirectory: FileManager.default.currentDirectoryPath,
      analyzedPaths: input.paths)
    if output.verbose {
      for line in resolved.sources.verboseLines(tool: ToolInfo.name) { note(line) }
    }
    return resolved.configuration
  }

  /// Deterministic discovery: directories are walked by `SourceDiscovery`,
  /// which skips build products and VCS internals and keeps symlinks from
  /// looping or leaving the directory. Every path — explicit file argument or
  /// walked entry — is normalized to absolute, because `Finding.path` feeds the
  /// fingerprint, and a fingerprint that depends on how the corpus was spelled
  /// on the command line makes baselines unusable across invocation styles.
  private func discoverSwiftFiles(configuration: Configuration) throws -> [String] {
    var files: Set<String> = []
    let fromFile = configuration.pathFilter
    let commandLine = PathFilter(input.excludePaths, root: FileManager.default.currentDirectoryPath)
    let isExcluded: @Sendable (String) -> Bool = {
      fromFile.excludes($0) || commandLine.excludes($0)
    }
    for path in input.paths {
      guard
        // Resolved first: attributesOfItem does not traverse a final symlink,
        // so a linked Sources/ would classify as a "file", degrade, and
        // exit 0 over zero analyzed code.
        let attributes = try? FileManager.default.attributesOfItem(
          atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
        let type = attributes[.type] as? FileAttributeType
      else {
        throw ValidationError("no such file or directory: \(path)")
      }
      if type == .typeDirectory {
        files.formUnion(
          SourceDiscovery.swiftFiles(under: path, isExcluded: isExcluded))
      } else if !isExcluded(URL(fileURLWithPath: path).path) {
        files.insert(URL(fileURLWithPath: path).path)
      }
    }
    return files.sorted()
  }
}

struct Rules: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List every rule, or explain one: `rules <id>` prints its rationale and fix."
  )

  @Argument(help: "Rule id to explain in full; omit to list all rules.")
  var rule: String?

  func run() throws {
    if let rule {
      guard let id = RuleID(rawValue: rule) else {
        let known = RuleID.allCases.map(\.rawValue).joined(separator: ", ")
        throw ValidationError("unknown rule \"\(rule)\" — known rules: \(known)")
      }
      print("\(id.rawValue)  [default: \(id.defaultSeverity.rawValue)]")
      print("")
      print(id.explanation)
      return
    }
    for rule in RuleID.allCases {
      print("\(rule.rawValue)  [\(rule.defaultSeverity.rawValue)]")
      print("    \(rule.summary)")
    }
    print(
      """

      Suppression:
        // @dl:accept -- <why this finding is intentional>
        // @dl:accept:this <rule|all> [-- reason]
        // @dl:accept:next <rule|all> [-- reason]
        // @dl:disable <rule|all> … // @dl:enable <rule|all>
      """)
  }
}
