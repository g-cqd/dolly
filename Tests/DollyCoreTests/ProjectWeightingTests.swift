import DollyCore
import Foundation
import Testing

/// Duplication weighs by where it lives: generated files are left out,
/// copies inside previews are dropped, and a group found only in test code
/// is a note. Production duplication, tests included, keeps its severity.
@Suite struct ProjectWeightingTests {
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

  private func analyze(_ files: [String: String]) async throws -> AnalysisReport {
    let scratch = try TemporaryTestDirectory(prefix: "dolly-weighting")
    defer { withExtendedLifetime(scratch) {} }
    var paths: [String] = []
    for (relativePath, contents) in files {
      let url = scratch.url.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
      paths.append(url.path)
    }
    return await Analyzer().analyze(files: paths.sorted())
  }

  @Test func `production duplication keeps its severity`() async throws {
    let report = try await analyze([
      "Sources/First.swift": Self.body(named: "firstReport"),
      "Sources/Second.swift": Self.body(named: "secondReport"),
    ])

    #expect(!report.findings.isEmpty)
    #expect(report.findings.allSatisfy { $0.severity == .warning })
    #expect(report.contextNote == nil)
  }

  @Test func `a group found only in test code is a note`() async throws {
    let report = try await analyze([
      "Tests/SampleTests/FirstTests.swift": "import Testing\n" + Self.body(named: "firstFixture"),
      "Tests/SampleTests/SecondTests.swift": "import Testing\n" + Self.body(named: "secondFixture"),
    ])

    #expect(!report.findings.isEmpty)
    #expect(report.findings.allSatisfy { $0.severity == .note })
    #expect(report.findings.first?.note?.contains("test code only") == true)
  }

  @Test func `a group spanning production and tests keeps its severity`() async throws {
    let report = try await analyze([
      "Sources/Report.swift": Self.body(named: "buildReport"),
      "Tests/SampleTests/ReportTests.swift": "import Testing\n" + Self.body(named: "expectedReport"),
    ])

    #expect(!report.findings.isEmpty)
    #expect(report.findings.allSatisfy { $0.severity == .warning })
  }

  @Test func `generated files are left out of the corpus`() async throws {
    let report = try await analyze([
      "Sources/Report.swift": Self.body(named: "buildReport"),
      "Sources/Generated/Accessors.swift": "// Generated using a template — DO NOT EDIT\n"
        + Self.body(named: "generatedReport"),
    ])

    #expect(report.findings.isEmpty)
    #expect(report.contextNote == "1 generated file(s) left out")
  }

  @Test func `copies inside previews are dropped`() async throws {
    let preview = { (name: String) in
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
    let report = try await analyze([
      "Sources/FirstView.swift": preview("firstRows"),
      "Sources/SecondView.swift": preview("secondRows"),
    ])

    #expect(report.findings.isEmpty)
    #expect(report.contextNote?.contains("found only in previews dropped") == true)
  }
}
