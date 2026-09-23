import Foundation
import Testing

/// What a host sees when it runs the `dolly` executable: the SARIF on standard
/// output. GitHub code scanning and diagnostics hosts consume exactly this, so
/// it is checked on the built executable, not inferred from the library.
@Suite struct CommandLineContractTests {
  /// Long enough to clear the default 50-token floor, so two copies make one
  /// exact-clone finding anchored at one copy with the other as its related
  /// location.
  private static let clone = """
    func aggregateScores(scores: [Double]) -> Double {
        var total = 0.0
        var compound = 1.0
        for element in scores {
            if element > 12.5 {
                total += element * 1.75
            } else {
                compound *= element + 3.25
            }
        }
        let combined = total + compound * 1.75
        return combined - 3.25
    }
    """

  // MARK: - SARIF artifact locations

  @Test("Locations under --relative-to are relative to a base the log declares")
  func relativeLocationsDeclareTheirBase() throws {
    let root = try Workspace.make(["Sources/A.swift": Self.clone, "Sources/B.swift": Self.clone])
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try BuiltTool.sarif(analyzing: root.path, relativeTo: root.path, in: root)

    let locations = log.artifactLocations
    #expect(Set(locations.map(\.uri)) == ["Sources/A.swift", "Sources/B.swift"])
    #expect(log.relatedLocationCount > 0, "the clone must carry a related location")
    for location in locations {
      #expect(location.uriBaseId == "SRCROOT", "\(location.uri) names no base")
    }
    let base = try #require(log.originalUriBaseIds["SRCROOT"])
    #expect(base.hasPrefix("file:///"))
    #expect(base.hasSuffix("/"), "a base uri must end with a slash (SARIF 2.1.0 §3.14.14)")
    #expect(URL(string: String(base.dropLast()))?.path == Workspace.canonical(root))
  }

  @Test("A path a relative reference cannot carry unescaped is an absolute file URI")
  func unsafePathsBecomeFileURIs() throws {
    let special = "Sources/Sub Dir/Résumé+Clone#1.swift"
    let root = try Workspace.make([special: Self.clone, "Sources/Plain.swift": Self.clone])
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = try BuiltTool.sarif(analyzing: root.path, relativeTo: root.path, in: root)
      .artifactLocations

    let plain = try #require(locations.first { $0.uri == "Sources/Plain.swift" })
    #expect(plain.uriBaseId == "SRCROOT")
    let escaped = try #require(locations.first { $0.uri != "Sources/Plain.swift" })
    #expect(escaped.uri.hasPrefix("file:///"))
    #expect(escaped.uriBaseId == nil, "an absolute URI must not name a base (SARIF 2.1.0 §3.4.4)")
    #expect(Workspace.isURIReference(escaped.uri), "not a valid URI reference: \(escaped.uri)")
    #expect(URL(string: escaped.uri)?.path == Workspace.canonical(root) + "/" + special)
  }

  @Test("Without --relative-to every location is an absolute file URI")
  func absoluteLocationsAreFileURIs() throws {
    let root = try Workspace.make([
      "My Sources/A.swift": Self.clone, "My Sources/B.swift": Self.clone,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let log = try BuiltTool.sarif(analyzing: root.path, relativeTo: nil, in: root)

    #expect(log.originalUriBaseIds.isEmpty)
    let expected = Set(
      ["A.swift", "B.swift"].map { Workspace.canonical(root) + "/My Sources/" + $0 })
    #expect(Set(log.artifactLocations.compactMap { URL(string: $0.uri)?.path }) == expected)
    for location in log.artifactLocations {
      #expect(location.uri.hasPrefix("file:///"))
      #expect(location.uriBaseId == nil)
      #expect(Workspace.isURIReference(location.uri), "not a valid URI reference: \(location.uri)")
    }
  }

  /// One directory has several spellings: through a symlink, and on macOS
  /// with or without `/private` (`realpath(3)` keeps it, Foundation strips
  /// it). The analyzed path and `--relative-to` may each use any of them.
  @Test("Every spelling of the root gives the same locations")
  func rootSpellingsAgree() throws {
    let root = try Workspace.make(["Sources/A.swift": Self.clone, "Sources/B.swift": Self.clone])
    let link = root.deletingLastPathComponent().appending(path: root.lastPathComponent + "-link")
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    var spellings = [root.path, link.path]
    let physical = "/private" + Workspace.canonical(root)
    if FileManager.default.fileExists(atPath: physical) { spellings.append(physical) }

    func locations(analyzing analyzed: String, relativeTo base: String) throws -> Set<String> {
      let log = try BuiltTool.sarif(analyzing: analyzed, relativeTo: base, in: root)
      return Set(log.artifactLocations.map { "\($0.uriBaseId ?? "-") \($0.uri)" })
    }
    let expected = try locations(analyzing: root.path, relativeTo: root.path)
    #expect(expected == ["SRCROOT Sources/A.swift", "SRCROOT Sources/B.swift"])
    for analyzed in spellings {
      for base in spellings {
        #expect(
          try locations(analyzing: analyzed, relativeTo: base) == expected, "\(analyzed) vs \(base)"
        )
      }
    }
  }

  @Test("A degraded file is named relative to the root, in its location and its message")
  func degradedFilesAreRelative() throws {
    let root = try Workspace.make(["Sources/A.swift": Self.clone])
    defer { try? FileManager.default.removeItem(at: root) }
    // A dangling link is listed like any `.swift` entry, then fails the read.
    try FileManager.default.createSymbolicLink(
      atPath: root.path + "/Sources/Broken.swift", withDestinationPath: "Missing.swift")
    let log = try BuiltTool.sarif(analyzing: root.path, relativeTo: root.path, in: root)

    let degraded = log.results.filter { $0.ruleId == "dolly/degraded-file" }
    #expect(degraded.count == 1)
    for result in degraded {
      #expect(
        result.locations.map(\.physicalLocation.artifactLocation.uri) == ["Sources/Broken.swift"])
      #expect(result.locations.map(\.physicalLocation.artifactLocation.uriBaseId) == ["SRCROOT"])
      #expect(!result.message.text.contains(Workspace.canonical(root)), "\(result.message.text)")
      #expect(!result.message.text.contains(root.path), "\(result.message.text)")
    }
  }
}

// MARK: - Harness

/// Runs the `dolly` executable that `swift build` and `swift test` place next
/// to this test bundle.
enum BuiltTool {
  /// SwiftPM puts every product of a build in one directory. The test
  /// resources sit in that directory on Linux and inside the `.xctest` bundle
  /// on macOS, so the executable is found among their ancestors.
  static let executable: URL? = {
    var directory = Bundle.module.bundleURL.deletingLastPathComponent()
    for _ in 0..<4 {
      let candidate = directory.appending(path: "dolly")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      directory = directory.deletingLastPathComponent()
    }
    return nil
  }()

  /// The SARIF log `dolly analyze` prints for `analyzed`, relativized to `base`
  /// when one is given, run from `directory` with the facts cache off.
  static func sarif(
    analyzing analyzed: String, relativeTo base: String?, in directory: URL
  ) throws -> SarifLog {
    var arguments = ["analyze", analyzed, "--format", "sarif", "--no-cache"]
    if let base { arguments += ["--relative-to", base] }
    return try JSONDecoder().decode(SarifLog.self, from: run(arguments, in: directory))
  }

  /// Standard output of the executable. Output goes to a file rather than a
  /// pipe, so a large report cannot fill a pipe buffer and stall the child
  /// while the test waits for it to exit.
  static func run(_ arguments: [String], in directory: URL) throws -> Data {
    let executable = try #require(
      executable,
      "no dolly executable near \(Bundle.module.bundleURL.path); build the package first")
    let scratch = FileManager.default.temporaryDirectory
      .appending(path: "dolly-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let outputURL = scratch.appending(path: "stdout")
    try Data().write(to: outputURL)
    let output = try FileHandle(forWritingTo: outputURL)

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try output.close()
    return try Data(contentsOf: outputURL)
  }
}

/// A scratch directory of source files.
enum Workspace {
  /// Writes each `relative path: contents` pair under a fresh directory.
  static func make(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "dolly-cli-\(UUID().uuidString)")
    for (path, contents) in files {
      // fileURLWithPath, not appending(path:): the names under test carry `#`
      // and spaces, which must stay part of the file name.
      let url = URL(fileURLWithPath: root.path + "/" + path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
  }

  /// The spelling dolly reports a path under: absolute, symlinks resolved, and
  /// on macOS without `/private`.
  static func canonical(_ url: URL) -> String {
    URL(fileURLWithPath: url.path).standardized.resolvingSymlinksInPath().path
  }

  /// Whether `uri` is made only of what RFC 3986 allows in a URI reference with
  /// no query or fragment: unreserved and reserved characters (less `?`, `#`,
  /// `[` and `]`) and well-formed percent escapes.
  static func isURIReference(_ uri: String) -> Bool {
    let allowed = Set(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/".utf8)
    let hex = Set("0123456789ABCDEFabcdef".utf8)
    let bytes = Array(uri.utf8)
    var index = 0
    while index < bytes.count {
      if bytes[index] == UInt8(ascii: "%") {
        guard index + 2 < bytes.count, hex.contains(bytes[index + 1]),
          hex.contains(bytes[index + 2])
        else { return false }
        index += 3
      } else {
        guard allowed.contains(bytes[index]) else { return false }
        index += 1
      }
    }
    return true
  }
}

/// The parts of a SARIF 2.1.0 log these tests read, decoded independently of
/// the formatter that wrote it.
struct SarifLog: Decodable {
  struct Run: Decodable {
    let originalUriBaseIds: [String: ArtifactLocation]?
    let results: [Result]
  }

  struct Result: Decodable {
    let ruleId: String
    let message: Message
    let locations: [Location]
    let relatedLocations: [Location]?
  }

  struct Message: Decodable {
    let text: String
  }

  struct Location: Decodable {
    let physicalLocation: PhysicalLocation
  }

  struct PhysicalLocation: Decodable {
    let artifactLocation: ArtifactLocation
  }

  struct ArtifactLocation: Decodable {
    let uri: String
    let uriBaseId: String?
  }

  let runs: [Run]

  var results: [Result] { runs.first?.results ?? [] }

  /// Every location a result points at: its own, then its related ones.
  var artifactLocations: [ArtifactLocation] {
    results.flatMap { result in
      (result.locations + (result.relatedLocations ?? [])).map(\.physicalLocation.artifactLocation)
    }
  }

  var relatedLocationCount: Int {
    results.reduce(0) { $0 + ($1.relatedLocations?.count ?? 0) }
  }

  /// Each declared base id and the `uri` it stands for.
  var originalUriBaseIds: [String: String] {
    (runs.first?.originalUriBaseIds ?? [:]).mapValues(\.uri)
  }
}
