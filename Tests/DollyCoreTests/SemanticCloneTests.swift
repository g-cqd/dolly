//  SemanticCloneTests.swift
//  dolly
//
//  End-to-end tests for the opt-in `--semantic` pass. The NL-default tests are
//  macOS-only (NaturalLanguage) and skip cleanly when the on-device asset is
//  absent; the HF-bundle test is local-only and skips when the model bundle
//  isn't present (models are gitignored, so CI skips it). The regression pin
//  is cross-platform: semantic detection is OFF by default.

import Foundation
import Testing

@testable import DollyCore

// MARK: - Shared corpus helpers

private enum SemanticCorpus {
  /// The committed loop-vs-reduce fixture pair (a Type-4 clone the token
  /// engine misses). Returned as file paths for `analyze(files:)`.
  static func loopVsReduceFixtureFiles() throws -> [String] {
    let root = Bundle.module.resourceURL!.appending(path: "Fixtures/Semantic/LoopVsReduce")
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
      .map(\.path)
      .sorted()
  }

  /// Write `sources` (name -> code) into a fresh temp directory; returns the
  /// sorted file paths. Caller removes `parent`.
  static func write(_ sources: [(name: String, code: String)]) throws -> (paths: [String], dir: URL)
  {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-semantic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var paths: [String] = []
    for (name, code) in sources {
      let url = dir.appending(path: name)
      try code.write(to: url, atomically: true, encoding: .utf8)
      paths.append(url.path)
    }
    return (paths.sorted(), dir)
  }
}

// MARK: - Regression pin (cross-platform)

@Suite struct SemanticDefaultRegressionTests {
  @Test("Default analysis never emits a semantic-clone and never runs the pass")
  func defaultIsSemanticFree() async throws {
    // The loop-vs-reduce fixture is a Type-4 clone; the default token engine
    // must stay silent about it (0.2.0 behavior), and the semantic pass must
    // not run at all (no note) unless explicitly requested.
    let files = try SemanticCorpus.loopVsReduceFixtureFiles()
    let report = await Analyzer().analyze(files: files)
    #expect(!report.findings.contains { $0.rule == .semanticClone })
    #expect(report.semanticNote == nil, "the semantic pass must be off by default")
  }

  @Test("Disabling the rule in config suppresses the pass even with options set")
  func configCanDisableSemantic() async throws {
    let files = try SemanticCorpus.loopVsReduceFixtureFiles()
    let config = Configuration(rules: ["semantic-clone": .init(enabled: false)])
    let report = await Analyzer(configuration: config, semantic: SemanticOptions())
      .analyze(files: files)
    #expect(!report.findings.contains { $0.rule == .semanticClone })
  }
}

// MARK: - NL default provider (macOS-only)

#if canImport(NaturalLanguage)
  import NaturalLanguage

  @Suite struct SemanticCloneNLTests {
    /// The on-device contextual-embedding asset ships with macOS but can be
    /// absent in a stripped sandbox; gate the NL tests on its presence so they
    /// skip (not fail) rather than error on a missing asset.
    static var nlAssetAvailable: Bool {
      guard let embedding = NLContextualEmbedding(language: .english) else { return false }
      return embedding.hasAvailableAssets
    }

    @Test(
      "NLContextual --semantic catches the loop-vs-reduce clone the token engine misses",
      .enabled(if: SemanticCloneNLTests.nlAssetAvailable))
    func catchesIdiomClone() async throws {
      let files = try SemanticCorpus.loopVsReduceFixtureFiles()

      // Default (token engine) misses it.
      let baseline = await Analyzer().analyze(files: files)
      #expect(!baseline.findings.contains { $0.rule == .semanticClone })

      // Semantic pass (NLContextual, balanced) recovers it.
      let report = await Analyzer(semantic: SemanticOptions()).analyze(files: files)
      let semantic = report.findings.filter { $0.rule == .semanticClone }
      #expect(semantic.count == 1, "expected one semantic-clone group: \(report.findings)")

      let finding = try #require(semantic.first)
      let spansBoth =
        (finding.path.hasSuffix("Loop.swift") || finding.note?.contains("Loop.swift") == true)
        && (finding.path.hasSuffix("Reduce.swift")
          || finding.note?.contains("Reduce.swift") == true)
      #expect(spansBoth, "semantic-clone must span both fixture files: \(finding)")
      #expect(finding.related.count == 1, "one related location (the other member)")
    }

    @Test(
      "NLContextual --semantic adds nothing to clearly unrelated functions",
      .enabled(if: SemanticCloneNLTests.nlAssetAvailable))
    func addsNothingForDistinctFunctions() async throws {
      let (paths, dir) = try SemanticCorpus.write([
        (
          "Geo.swift",
          """
          enum Geo {
            func haversineMeters(fromLat: Double, fromLon: Double, toLat: Double) -> Double {
              let earthRadius = 6_371_000.0
              let delta = (toLat - fromLat) * 3.14159 / 180.0
              let chord = earthRadius * delta
              return abs(chord)
            }
          }
          """
        ),
        (
          "Text.swift",
          """
          enum Text {
            func titleCased(_ sentence: String) -> String {
              sentence
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            }
          }
          """
        ),
      ])
      defer { try? FileManager.default.removeItem(at: dir) }

      let report = await Analyzer(semantic: SemanticOptions()).analyze(files: paths)
      #expect(!report.findings.contains { $0.rule == .semanticClone })
      #expect(report.semanticNote != nil, "the pass should have run and left a note")
    }
  }
#endif

// MARK: - Bundled-model auto-discovery (the `dolly-full` build)

#if canImport(CoreML)
  /// Pins the executable-adjacent model discovery that lets the `dolly-full`
  /// release run `--semantic` with no flag. Exercises the pure candidate search
  /// (no process globals, no CoreML load — dummy `.mlmodelc` directories), the
  /// path the release workflow depends on but nothing else would cover until a
  /// tag is cut.
  @Suite struct BundledModelDiscoveryTests {
    /// A throwaway tree with an optional model dir at each interesting location.
    /// Returns the root; caller removes it.
    private static func stage(
      adjacentModel: Bool = false, shareModel: Bool = false, overrideModel: Bool = false
    ) throws -> (root: URL, execDir: URL, overrideDir: URL) {
      let fm = FileManager.default
      let root = fm.temporaryDirectory.appending(path: "dolly-discovery-\(UUID().uuidString)")
      let execDir = root.appending(path: "bin")
      let overrideDir = root.appending(path: "custom")
      try fm.createDirectory(at: execDir, withIntermediateDirectories: true)
      func plantModel(in dir: URL) throws {
        try fm.createDirectory(
          at: dir.appending(path: "Model.mlmodelc"), withIntermediateDirectories: true)
      }
      if adjacentModel { try plantModel(in: execDir.appending(path: "Models/MiniLM")) }
      if shareModel { try plantModel(in: root.appending(path: "share/dolly/Models/MiniLM")) }
      if overrideModel { try plantModel(in: overrideDir) }
      return (root, execDir, overrideDir)
    }

    @Test("Discovers a model in Models/MiniLM next to the executable")
    func findsAdjacentModel() throws {
      let (root, execDir, _) = try Self.stage(adjacentModel: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let found = SemanticDiscovery.bundledModelDirectory(executableDir: execDir, override: nil)
      #expect(
        found?.resolvingSymlinksInPath().path
          == execDir.appending(path: "Models/MiniLM").resolvingSymlinksInPath().path)
    }

    @Test("Falls back to the FHS-style share/dolly layout")
    func findsShareLayoutModel() throws {
      let (root, execDir, _) = try Self.stage(shareModel: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let found = SemanticDiscovery.bundledModelDirectory(executableDir: execDir, override: nil)
      let expected = root.appending(path: "share/dolly/Models/MiniLM").resolvingSymlinksInPath()
        .path
      #expect(found?.resolvingSymlinksInPath().path == expected)
    }

    @Test("DOLLY_EMBEDDING_BUNDLE override wins over an adjacent model")
    func overrideTakesPrecedence() throws {
      let (root, execDir, overrideDir) = try Self.stage(adjacentModel: true, overrideModel: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let found = SemanticDiscovery.bundledModelDirectory(
        executableDir: execDir, override: overrideDir.path)
      #expect(found?.resolvingSymlinksInPath().path == overrideDir.resolvingSymlinksInPath().path)
    }

    @Test("No model anywhere returns nil (the plain dolly binary)")
    func noModelReturnsNil() throws {
      let (root, execDir, _) = try Self.stage()
      defer { try? FileManager.default.removeItem(at: root) }
      #expect(SemanticDiscovery.bundledModelDirectory(executableDir: execDir, override: nil) == nil)
      // An override pointing at a model-free directory is also nil, not a crash.
      #expect(
        SemanticDiscovery.bundledModelDirectory(executableDir: execDir, override: root.path) == nil)
    }
  }

  // MARK: - HF / Core ML bundle provider (local-only, models gitignored)

  @Suite struct SemanticCloneBundleTests {
    /// A code-trained MiniLM Core ML + tokenizer bundle, present only on the
    /// author's machine (models are gitignored). Absent in CI → the test skips.
    static let miniLMBundle =
      "/Users/gc/Developer/ongoing/swift/SwiftStaticAnalysis/Models/MiniLM"

    static var bundleAvailable: Bool {
      FileManager.default.fileExists(atPath: miniLMBundle)
    }

    @Test(
      "HF --embedding-bundle (MiniLM) catches the loop-vs-reduce clone",
      .enabled(if: SemanticCloneBundleTests.bundleAvailable))
    func bundleCatchesIdiomClone() async throws {
      let files = try SemanticCorpus.loopVsReduceFixtureFiles()
      let options = SemanticOptions(bundlePath: Self.miniLMBundle, preset: .balanced)
      let report = await Analyzer(semantic: options).analyze(files: files)
      #expect(
        report.findings.contains { $0.rule == .semanticClone },
        "MiniLM bundle should surface the semantic clone: \(report.semanticNote ?? "no note")")
    }
  }
#endif
