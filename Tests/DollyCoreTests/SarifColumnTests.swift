import DollyCore
import Foundation
import Testing

/// SARIF regions count columns in UTF-16 code units, while dolly's own columns
/// are swift-syntax's 1-based UTF-8 byte offsets. Converting one to the other
/// must land on the line swift-syntax counted, whatever the line endings, and
/// must not count a byte-order mark (SARIF 2.1.0 §3.30.2).
@Suite struct SarifColumnTests {
  /// A clone whose first line starts with text UTF-8 and UTF-16 count
  /// differently.
  private static let cloneLines = [
    #"let marker = "😀é"; func aggregateScores(scores: [Double]) -> Double {"#,
    "    var total = 0.0",
    "    var compound = 1.0",
    "    for element in scores {",
    "        if element > 12.5 {",
    "            total += element * 1.75",
    "        } else {",
    "            compound *= element + 3.25",
    "        }",
    "    }",
    "    let combined = total + compound * 1.75",
    "    return combined - 3.25",
    "}",
    "",
  ]

  @Test("Line endings and a byte-order mark do not move a column")
  func lineEndingsAndByteOrderMark() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-columns-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sources = [
      "Crlf.swift": (["// CRLF"] + Self.cloneLines).joined(separator: "\r\n"),
      "Cr.swift": (["// CR"] + Self.cloneLines).joined(separator: "\r"),
      "Bom.swift": "\u{FEFF}" + Self.cloneLines.joined(separator: "\n"),
    ]
    for (name, source) in sources {
      try source.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
    }
    let report = await Analyzer().analyze(files: sources.keys.map { dir.appending(path: $0).path })
    let clone = try #require(report.findings.first { $0.rule == .exactClone })
    #expect(clone.related.count == 2)

    let log = try JSONDecoder().decode(
      SarifLog.self, from: Data(ReportFormatter.format(report, as: .sarif).utf8))
    let expected = try Workspace.utf16Column(of: "func", in: Self.cloneLines[0])
    let result = try #require(log.results.first { $0.ruleId == "exact-clone" })
    let columns = (result.locations + (result.relatedLocations ?? []))
      .map(\.physicalLocation.region.startColumn)
    #expect(columns == [expected, expected, expected])
  }

  @Test("A location whose file cannot be read keeps its byte column")
  func unreadableFileKeepsColumn() async throws {
    let source = (Self.cloneLines + Self.cloneLines).joined(separator: "\n")
    let report = await Analyzer().analyze(source: source, path: "Gone.swift")
    let finding = try #require(report.findings.first { $0.rule == .exactClone })
    #expect(finding.column > 1)

    let log = try JSONDecoder().decode(
      SarifLog.self, from: Data(ReportFormatter.format(report, as: .sarif).utf8))
    let result = try #require(log.results.first { $0.ruleId == "exact-clone" })
    #expect(result.locations.first?.physicalLocation.region.startColumn == finding.column)
  }
}
