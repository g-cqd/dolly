public import ArgumentParser
import DollyCore
import Foundation

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
    let files = try discoverSwiftFiles(configuration: configuration)
    guard !files.isEmpty else { throw ValidationError(DollyError.noInputs.description) }

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
      configuration: configuration, cacheURL: cacheURL, semantic: semanticOptions
    ).analyze(files: files)

    // Semantic-pass status / graceful-fallback note goes to stderr so stdout
    // stays machine-parseable.
    if let note = report.semanticNote {
      FileHandle.standardError.write(Data((ToolInfo.name + ": " + note + "\n").utf8))
    }

    if let writeBaseline {
      try Baseline(findings: report.findings).write(path: writeBaseline)
      FileHandle.standardError.write(
        Data("\(ToolInfo.name): wrote baseline with \(report.findings.count) fingerprint(s)\n".utf8)
      )
      return
    }
    var baselinedCount = 0
    if let baseline {
      let loaded = try Baseline.load(path: baseline)
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
    FileHandle.standardError.write(Data((summary + "\n").utf8))

    let failed = strict ? !report.findings.isEmpty : report.maxSeverity == .error
    if failed {
      throw ExitCode(1)
    }
  }

  private func loadConfiguration() throws -> Configuration {
    if let config {
      return try Configuration.load(path: config)
    }
    let implicit = FileManager.default.currentDirectoryPath + "/.dolly.json"
    if FileManager.default.fileExists(atPath: implicit) {
      return try Configuration.load(path: implicit)
    }
    return .default
  }

  /// Deterministic discovery: explicit files pass through; directories are
  /// walked recursively, skipping build products and VCS internals.
  private func discoverSwiftFiles(configuration: Configuration) throws -> [String] {
    let skippedComponents: Set<String> = [".build", ".git", "DerivedData", ".swiftpm", "checkouts"]
    var files: Set<String> = []
    let manager = FileManager.default

    for path in paths {
      guard
        let isDirectory = try? URL(fileURLWithPath: path)
          .resourceValues(forKeys: [.isDirectoryKey]).isDirectory
      else {
        throw ValidationError("no such file or directory: \(path)")
      }
      if !isDirectory {
        files.insert(path)
        continue
      }
      let root = URL(fileURLWithPath: path)
      guard
        let enumerator = manager.enumerator(
          at: root,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }
      for case let url as URL in enumerator {
        if skippedComponents.contains(url.lastPathComponent) {
          enumerator.skipDescendants()
          continue
        }
        guard url.pathExtension == "swift" else { continue }
        let filePath = url.path
        if !configuration.isExcluded(path: filePath) {
          files.insert(filePath)
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
