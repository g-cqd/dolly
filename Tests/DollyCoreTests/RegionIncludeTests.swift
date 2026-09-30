import DollyCore
import Foundation
import Testing

/// `--include`/`--exclude`: a clone group found only in preview or generated
/// code is reported like any other once the region is included, tagged so
/// it stays filterable; one found only in test code keeps its rule's normal
/// severity instead of becoming a note. `debug`, `mock`, and `script` name
/// no region dolly weighs today, so including them changes nothing.
@Suite struct RegionIncludeTests {
  /// A function long enough to clear the 50-token clone floor.
  private static func body(named name: String) -> String {
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

  private func analyze(
    _ files: [String: String],
    configuration: Configuration = .default
  ) async throws -> AnalysisReport {
    let scratch = try TemporaryTestDirectory(prefix: "dolly-include")
    defer { withExtendedLifetime(scratch) {} }
    var paths: [String] = []
    for (relativePath, contents) in files {
      let url = scratch.url.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
      paths.append(url.path)
    }
    return await Analyzer(configuration: configuration).analyze(files: paths.sorted())
  }

  // MARK: - Generated

  private static let generatedFiles: [String: String] = [
    "Sources/Report.swift": body(named: "buildReport"),
    "Sources/Generated/Accessors.swift": "// Generated using a template — DO NOT EDIT\n"
      + body(named: "generatedReport"),
  ]

  @Test func `including generated reports the clone it would otherwise leave out, tagged`()
    async throws
  {
    let configuration = Configuration(includeRegions: "generated")
    let report = try await analyze(Self.generatedFiles, configuration: configuration)

    let finding = try #require(report.findings.first)
    #expect(finding.note?.contains("region: generated") == true)
  }

  @Test func `excluding generated wins over including everything`() async throws {
    let configuration = Configuration(includeRegions: "all", excludeRegions: "generated")
    let report = try await analyze(Self.generatedFiles, configuration: configuration)

    #expect(report.findings.isEmpty)
    #expect(report.contextNote == "1 generated file(s) left out")
  }

  // MARK: - Preview

  private static func previewFile(_ name: String) -> String {
    """
    import SwiftUI

    #Preview {
      let rows = \(name)([1, 2, 3, 4, 5, 6], limit: 2)
      return VStack {
        ForEach(rows, id: \\.self) { row in
          Text(row).font(.caption).padding(.horizontal, 8).foregroundStyle(.secondary)
        }
      }
      .padding(16)
      .background(Color.gray.opacity(0.1))
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    """
  }

  private static let previewFiles: [String: String] = [
    "Sources/FirstView.swift": previewFile("firstRows"),
    "Sources/SecondView.swift": previewFile("secondRows"),
  ]

  @Test func `including preview reports the clone it would otherwise drop, tagged`() async throws {
    let configuration = Configuration(includeRegions: "preview")
    let report = try await analyze(Self.previewFiles, configuration: configuration)

    let finding = try #require(report.findings.first)
    #expect(finding.note?.contains("region: preview") == true)
  }

  // MARK: - Test

  private static let testOnlyFiles: [String: String] = [
    "Tests/SampleTests/FirstTests.swift": "import Testing\n" + body(named: "firstFixture"),
    "Tests/SampleTests/SecondTests.swift": "import Testing\n" + body(named: "secondFixture"),
  ]

  @Test func `test code only is a note by default`() async throws {
    let report = try await analyze(Self.testOnlyFiles)

    let finding = try #require(report.findings.first)
    #expect(finding.severity == .note)
  }

  @Test func `including test keeps the rule's normal severity`() async throws {
    let configuration = Configuration(includeRegions: "test")
    let report = try await analyze(Self.testOnlyFiles, configuration: configuration)

    let finding = try #require(report.findings.first)
    #expect(finding.severity == .warning)
    #expect(finding.note?.contains("test code only") != true)
  }

  // MARK: - No region to toggle

  @Test func `including debug, mock and script changes nothing: dolly weighs none of them`()
    async throws
  {
    let files: [String: String] = [
      "Sources/First.swift": Self.body(named: "firstReport"),
      "Sources/Second.swift": Self.body(named: "secondReport"),
    ]
    let defaultReport = try await analyze(files)
    let included = try await analyze(
      files, configuration: Configuration(includeRegions: "debug,mock,script"))

    // Two different temporary roots, so findings compare by shape (rule,
    // severity, whether a region tag was added) rather than by their
    // (necessarily different) absolute paths.
    let shape = { (report: AnalysisReport) in
      report.findings.map { "\($0.rule)/\($0.severity)/\($0.note?.contains("region:") ?? false)" }
    }
    #expect(shape(defaultReport) == shape(included))
    #expect(defaultReport.contextNote == included.contextNote)
  }

  // MARK: - Unknown region name

  @Test func `an unknown region name fails the config, not silently`() {
    #expect(throws: (any Error).self) {
      try Configuration(includeRegions: "bogus").regionSelection()
    }
  }
}
