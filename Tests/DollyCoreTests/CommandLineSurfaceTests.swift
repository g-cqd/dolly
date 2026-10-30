import Foundation
import Testing

/// dolly's `analyze` on analyzerkit's shared option groups (ADR-0019, roadmap 0020): every option of the Input, Output,
/// Rules and Cache groups works, `--include`/`--exclude` stay as deprecated aliases, and regions come from the project.
@Suite(.serialized) struct CommandLineSurfaceTests {
  private static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// A function long enough to clear the 50-token clone floor; two files holding it make one exact clone group.
  private static func body(_ name: String) -> String {
    """
    func \(name)(_ items: [Int], limit: Int) -> [String] {
      var output: [String] = []
      for item in items where item > limit {
        let doubled = item * 2 + limit
        if doubled % 3 == 0 {
          output.append("fizz \\(doubled)")
        } else if doubled % 5 == 0 {
          output.append("buzz \\(doubled)")
        } else {
          output.append(String(doubled))
        }
      }
      return output.sorted()
    }

    """
  }

  struct Run {
    let status: Int32
    let output: String
    let errors: String
  }

  private static func executable() throws -> URL {
    let build = packageRoot.appending(path: ".build")
    let candidates = ["debug", "release"].map { build.appending(path: "\($0)/dolly") }
      .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    func modified(_ url: URL) -> Date {
      (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[
        .modificationDate] as? Date ?? .distantPast
    }
    return try #require(candidates.max { modified($0) < modified($1) }, "build dolly first")
  }

  private static func run(_ arguments: [String], in root: URL) throws -> Run {
    let process = Process()
    process.executableURL = try executable()
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Run(
      status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
      errors: String(decoding: err, as: UTF8.self))
  }

  private static func workspace(_ files: [String: String], _ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "dolly-cli-\(UUID().uuidString)"
    )
    .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("gitdir: none\n".utf8).write(to: root.appending(path: ".git"))
    for (name, text) in files {
      let url = root.appending(path: name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    try body(root)
  }

  @Test func `the help lists every shared option and dolly's own after them`() throws {
    try Self.workspace([:]) { root in
      let help = try Self.run(["analyze", "--help"], in: root).output
      for option in [
        "--config", "--exclude-path", "--include-regions", "--exclude-regions", "--define",
        "--only",
        "--only-from", "--format", "--relative-to", "--strict", "--baseline", "--write-baseline",
        "--report-new-since", "--verbose", "--quiet", "--timings", "--rules", "--cache-path",
        "--no-cache",
        "--semantic", "--embedding-bundle", "--embedding-preset", "--semantic-max-group",
      ] {
        #expect(help.contains(option), "missing \(option)")
      }
    }
  }

  @Test func `include and exclude still work, with a note`() throws {
    try Self.workspace(["Sources/A.swift": Self.body("a"), "Sources/B.swift": Self.body("b")]) {
      root in
      let run = try Self.run(["analyze", ".", "--no-cache", "--include", "test"], in: root)
      #expect(run.errors.contains("dolly: note: --include is deprecated; use --include-regions"))
      #expect(run.status == 0)
    }
  }

  @Test func `exclude-path leaves a file out of the corpus`() throws {
    try Self.workspace(["Sources/A.swift": Self.body("a"), "Sources/B.swift": Self.body("b")]) {
      root in
      let run1 = try Self.run(["analyze", ".", "--no-cache"], in: root)
      #expect(run1.output.contains("clone"))
      let run = try Self.run(["analyze", ".", "--no-cache", "--exclude-path", "B.swift"], in: root)
      #expect(run.status == 0 && run.output.isEmpty)
    }
  }

  @Test func `rules chooses rules, and an unknown one is a usage error`() throws {
    try Self.workspace(["Sources/A.swift": Self.body("a"), "Sources/B.swift": Self.body("b")]) {
      root in
      let run101 = try Self.run(["analyze", ".", "--no-cache", "--rules", "near-clone"], in: root)
      #expect(run101.status == 0 && run101.output.isEmpty)
      let run102 = try Self.run(["analyze", ".", "--no-cache", "--rules", "nope"], in: root)
      #expect(run102.status==64)
    }
  }

  @Test func `quiet, verbose and timings`() throws {
    try Self.workspace(["Sources/A.swift": Self.body("a"), "Sources/B.swift": Self.body("b")]) {
      root in
      let run2 = try Self.run(["analyze", ".", "--no-cache", "--quiet"], in: root)
      #expect(run2.errors.isEmpty)
      let verbose = try Self.run(["analyze", ".", "--no-cache", "--verbose"], in: root)
      #expect(verbose.errors.contains("dolly: configuration: no file found; built-in defaults"))
      let timed = try Self.run(
        ["analyze", ".", "--no-cache", "--format", "json", "--timings"], in: root)
      #expect(timed.output.contains("\"timings\""))
    }
  }

  @Test func `define is accepted and says it has no effect`() throws {
    try Self.workspace(["Sources/A.swift": Self.body("a")]) { root in
      let run = try Self.run(["analyze", ".", "--no-cache", "--define", "DEBUG"], in: root)
      #expect(
        run.errors.contains(
          "dolly: note: --define has no effect: dolly compares the tokens of every #if clause"))
    }
  }

  /// The base branch's baseline holds the A/B clone; the change adds C, a third copy, and touches only D.
  @Test func `report-new-since reports out-of-scope findings the base baseline lacks`() throws {
    try Self.workspace([
      "Sources/A.swift": Self.body("a"), "Sources/B.swift": Self.body("b"),
      "Sources/D.swift": "let d = 1\n",
    ]) { root in
      let run103 = try Self.run(["analyze", ".", "--no-cache", "--write-baseline", "base.json"], in: root)
      #expect(run103.status==0)
      try Data(("struct C {}\n\n" + Self.body("c")).utf8).write(
        to: root.appending(path: "Sources/C.swift"))
      let run = try Self.run(
        [
          "analyze", ".", "--no-cache", "--only", "Sources/D.swift", "--report-new-since",
          "base.json",
        ], in: root)
      #expect(run.errors.contains("outside --only are new since base.json"))
      #expect(!run.output.isEmpty)
      let run104 = try Self.run(["analyze", ".", "--no-cache", "--report-new-since", "base.json"], in: root)
      #expect(run104.status==64)
    }
  }

  /// `--cache-path` names the cache's root directory (ADR-0011); a second run reuses every file.
  @Test func `a cache under cache-path is reused`() throws {
    try Self.workspace(["Sources/A.swift": Self.body("a"), "Sources/B.swift": Self.body("b")]) {
      root in
      let cache = root.appending(path: "cache").path
      _ = try Self.run(["analyze", ".", "--cache-path", cache], in: root)
      let type = (try? FileManager.default.attributesOfItem(atPath: cache))?[.type] as? FileAttributeType
      #expect(type == .typeDirectory)
      let warm = try Self.run(
        ["analyze", ".", "--cache-path", cache, "--format", "json"], in: root)
      #expect(warm.output.contains(#""cacheHits" : 2"#))
      #expect(
        try Self.run(["analyze", ".", "--cache-path", cache], in: root).output.contains("clone"))
    }
  }

  /// A clone whose members are all in a test target the manifest declares outside `Tests/` is test code: a note.
  @Test func `a test target outside Tests is test code`() throws {
    let manifest = """
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(name: "P", targets: [
        .target(name: "Lib", path: "Lib"), .testTarget(name: "Checks", dependencies: ["Lib"], path: "Checks"),
      ])
      """
    try Self.workspace([
      "Package.swift": manifest, "Checks/A.swift": Self.body("a"), "Checks/B.swift": Self.body("b"),
      "Lib/L.swift": "let l = 1\n",
    ]) { root in
      let run = try Self.run(["analyze", ".", "--no-cache"], in: root)
      #expect(run.output.contains(": note: "), "\(run.output)")
    }
  }
}
