public import ArgumentParser
import DollyCore
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

extension OutputFormat: ExpressibleByArgument {}
extension SemanticPreset: ExpressibleByArgument {}

struct Analyze: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Analyze Swift files or directories (default: current directory)."
  )

  @Argument(help: "Files or directories to analyze.")
  var paths: [String] = ["."]

  @Option(name: .long, help: "Output format: xcode, json, or sarif.")
  var format: OutputFormat = .xcode

  @Flag(name: .long, help: "Exit 1 on any finding, not just errors.")
  var strict = false

  @Option(name: .long, help: "Configuration file (default: ./.dolly.json when present).")
  var config: String?

  @Option(name: .long, help: "Baseline file: findings it contains are filtered out.")
  var baseline: String?

  @Option(name: .long, help: "Write the current findings as a new baseline, then exit 0.")
  var writeBaseline: String?

  @Option(
    name: .long,
    help: ArgumentHelp(
      "Report only findings touching this file; repeatable. The whole corpus is still analyzed "
        + "— duplication is a corpus property, so narrowing the input would fabricate and lose "
        + "clones alike. A clone group qualifies when any of its members is listed, not just the "
        + "one it happens to be anchored at."))
  var only: [String] = []

  // ArgumentParser option declarations are a fixed shape (@Option, name:,
  // help: ArgumentHelp(...), var); two of them in a row are token-identical by
  // construction, and collapsing them would mean generating the CLI surface
  // rather than declaring it.
  // @dl:accept near-clone -- declarative CLI surface, not copied logic
  @Option(
    name: .customLong("only-from"),
    help: ArgumentHelp(
      "Read --only paths from a file, one per line ('-' reads stdin). For CI: "
        + "`git diff --name-only ... | dolly analyze . --only-from -`."))
  var onlyFrom: String?

  @Option(
    name: .customLong("relative-to"),
    help: ArgumentHelp(
      "Report paths relative to this directory. Makes fingerprints (and so baselines) and SARIF "
        + "uris independent of where the repository is checked out; GitHub code scanning also "
        + "requires repo-relative uris to link findings. Use `--relative-to .` in CI."))
  var relativeTo: String?

  @Flag(name: .long, help: "Disable the facts cache for this run.")
  var noCache = false

  @Option(
    name: .long,
    help: "Facts cache file (default: the user caches directory, dolly/facts.json).")
  var cachePath: String?

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
    let configuration = try loadConfiguration()
    let reportScope = try resolveReportScope()
    let files = try discoverSwiftFiles(configuration: configuration)
    guard !files.isEmpty else { throw ValidationError(DollyError.noInputs.description) }
    // A non-empty scope that intersects zero corpus files is almost always a
    // misconfiguration (paths relative to the wrong directory, wrong workdir),
    // and it silently reports nothing. Warn loudly; an *empty* scope stays
    // silent — "no Swift changed" is legitimate.
    if let scope = reportScope, !scope.files.isEmpty, !files.contains(where: scope.files.contains) {
      writeStandardError(
        "dolly: warning: --only scope matches no analyzed file — check that scope paths are relative to the right directory\n"
      )
    }

    let cacheURL: URL? =
      noCache
      ? nil
      : cachePath.map { URL(fileURLWithPath: $0) } ?? Analyzer.defaultCacheURL()
    let semanticOptions: SemanticOptions? =
      semantic
      ? SemanticOptions(
        bundlePath: embeddingBundle, preset: embeddingPreset, maxGroupSize: semanticMaxGroup)
      : nil
    var report = await Analyzer(
      configuration: configuration, cacheURL: cacheURL, semantic: semanticOptions,
      reportScope: reportScope
    ).analyze(files: files)

    // A cancelled run analysed a partial corpus and therefore reports nothing.
    // That must never read as a clean gate — exit as an internal failure.
    if report.wasCancelled {
      writeStandardError(
        "dolly: run cancelled before the corpus was complete; no findings reported\n")
      throw ExitCode(ExitStatus.internalFailure)
    }

    // Before anything reads a path: baselines, SARIF and the formatted output
    // must all agree on one spelling, and the fingerprint is derived from it.
    if let relativeTo {
      report = report.relativized(to: relativeTo)
    }

    // Semantic-pass status / graceful-fallback note goes to stderr so stdout
    // stays machine-parseable.
    if let note = report.semanticNote {
      writeStandardError(ToolInfo.name + ": " + note + "\n")
    }

    if let writeBaseline {
      // Guarded in validate(): a baseline is whole-corpus debt by definition,
      // so it can never be written from a scoped run.
      try baselineOrExit { try Baseline(findings: report.findings).write(path: writeBaseline) }
      writeStandardError(
        "\(ToolInfo.name): wrote baseline with \(report.findings.count) fingerprint(s)\n")
      return
    }
    var baselinedCount = 0
    if let baseline {
      let loaded = try baselineOrExit { try Baseline.load(path: baseline) }
      let (kept, baselined) = loaded.filter(report.findings)
      report.findings = kept
      baselinedCount = baselined.count
    }

    let output = ReportFormatter.format(report, as: format)
    if !output.isEmpty {
      print(output)
    }
    var summary = ReportFormatter.summary(report)
    if baselinedCount > 0 {
      summary += "; \(baselinedCount) baselined"
    }
    if !report.outOfScope.isEmpty {
      summary += "; \(report.outOfScope.count) out of scope"
    }
    writeStandardError(summary + "\n")

    let failed = strict ? !report.findings.isEmpty : report.maxSeverity == .error
    if failed {
      throw ExitCode(1)
    }
  }

  func validate() throws {
    // A baseline records the whole corpus's accepted debt. Writing one from a
    // scoped run would silently accept only the scoped subset and drop
    // everything else from the baseline, so refuse rather than surprise.
    if writeBaseline != nil, !only.isEmpty || onlyFrom != nil {
      throw ValidationError(
        "--write-baseline records whole-corpus debt and cannot be combined with "
          + "--only/--only-from. Write the baseline unscoped, then scope the runs that use it.")
    }
    if onlyFrom == "-", paths == ["-"] {
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
    guard !only.isEmpty || onlyFrom != nil else { return nil }
    var entries = only
    if let onlyFrom {
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
    return text.split(separator: "\n")
      // Standard library rather than trimmingCharacters(in:), which is
      // corelibs-only: dolly builds against FoundationEssentials on Linux.
      .map { line -> String in
        // \r too: a CRLF scope file (Windows-authored diff, autocrlf) would
        // otherwise match nothing — every finding lands out of scope and the
        // gate silently passes.
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
  /// internal failure, `78` a bad configuration.
  enum ExitStatus {
    static let findings: Int32 = 1
    static let internalFailure: Int32 = 70
    static let badConfiguration: Int32 = 78
  }

  /// A malformed config is a broken gate, not a finding — exit 78 so CI can
  /// tell the two apart instead of reporting a typo as analysis output.

  /// A missing or corrupt baseline is a broken gate, not a finding — exit 78
  /// so CI cannot mistake it for "findings found" (exit 1).
  private func baselineOrExit<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      writeStandardError("dolly: \(error)\n")
      throw ExitCode(ExitStatus.badConfiguration)
    }
  }

  private func loadConfiguration() throws -> Configuration {
    do {
      return try loadConfigurationUncaught()
    } catch let error as ExitCode {
      throw error
    } catch {
      writeStandardError("dolly: \(error)\n")
      throw ExitCode(ExitStatus.badConfiguration)
    }
  }

  private func loadConfigurationUncaught() throws -> Configuration {
    if let config {
      return try Configuration.load(path: config)
    }
    let implicit = FileManager.default.currentDirectoryPath + "/.dolly.json"
    if FileManager.default.fileExists(atPath: implicit) {
      return try Configuration.load(path: implicit)
    }
    return .default
  }

  /// Deterministic discovery: directories are walked recursively, skipping
  /// build products and VCS internals. Every path — explicit file argument or
  /// walked entry — is normalized to absolute, because `Finding.path` feeds the
  /// fingerprint, and a fingerprint that depends on how the corpus was spelled
  /// on the command line makes baselines unusable across invocation styles.
  private func discoverSwiftFiles(configuration: Configuration) throws -> [String] {
    let skippedComponents: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "checkouts"]
    var files: Set<String> = []
    let manager = FileManager.default

    for path in paths {
      guard
        // Resolved first: attributesOfItem does not traverse a final symlink,
        // so a linked Sources/ would classify as a "file", degrade, and
        // exit 0 over zero analyzed code.
        let attributes = try? manager.attributesOfItem(
          atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
        let type = attributes[.type] as? FileAttributeType
      else {
        throw ValidationError("no such file or directory: \(path)")
      }
      let isDirectory = type == .typeDirectory
      if !isDirectory {
        files.insert(URL(fileURLWithPath: path).path)
        continue
      }
      // Absolute, matching what FileManager.enumerator(at:) produced:
      // finding paths are part of the output contract.
      var stack = [URL(fileURLWithPath: path).path]
      while let directory = stack.popLast() {
        guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }
        for entry in entries {
          // Matches the old enumerator's `.skipsHiddenFiles` plus the
          // `skipDescendants()` prune: a skipped directory is never descended.
          if entry.hasPrefix(".") { continue }
          if skippedComponents.contains(entry) { continue }
          let full = directory + "/" + entry
          let entryType =
            // Resolve so symlinked subtrees and files are walked too.
            (try? manager.attributesOfItem(
              atPath: URL(fileURLWithPath: full).resolvingSymlinksInPath().path))?[
              .type] as? FileAttributeType
          if entryType == .typeDirectory {
            stack.append(full)
          } else if full.hasSuffix(".swift"), !configuration.isExcluded(path: full) {
            files.insert(full)
          }
        }
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
