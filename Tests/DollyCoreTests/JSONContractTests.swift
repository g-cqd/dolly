import DollyCore
import Foundation
import ProjectModel
import Testing

/// The `--format json` report is a versioned contract: `schemaVersion` lets a
/// consumer detect a breaking change, and the key sets below pin the 1.x field
/// names, so a rename or removal fails here.
@Suite struct JSONContractTests {
  /// The top-level keys of a 1.x report, with every optional field absent.
  private static let topLevelKeys: Set<String> = [
    "schemaVersion",
    "findings",
    "suppressed",
    "outOfScope",
    "degradedFiles",
    "analyzedFileCount",
    "cacheHits",
    "cacheMisses",
    "wasCancelled",
  ]

  /// The keys of a finding that has a note and a related location.
  private static let findingKeys: Set<String> = [
    "rule", "severity", "path", "line", "column", "message", "note", "related", "fingerprint",
  ]

  private static let relatedLocationKeys: Set<String> = ["path", "line", "column"]

  @Test("the JSON report carries the shared schema version and the 1.x fields")
  func jsonReportCarriesSchemaVersionAndFields() throws {
    let report = AnalysisReport(
      findings: [
        Finding(
          rule: .exactClone, severity: .warning, path: "Sources/A.swift", line: 3, column: 5,
          message: "duplicated block", note: "same as Sources/B.swift",
          related: [RelatedLocation(path: "Sources/B.swift", line: 9, column: 1)])
      ],
      analyzedFileCount: 2)

    let json = ReportFormatter.format(report, as: .json)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(Set(object.keys) == Self.topLevelKeys)

    let finding = try #require((object["findings"] as? [[String: Any]])?.first)
    #expect(Set(finding.keys) == Self.findingKeys)

    let related = try #require((finding["related"] as? [[String: Any]])?.first)
    #expect(Set(related.keys) == Self.relatedLocationKeys)
  }

  @Test("Optional fields are omitted when unset and written when set, never as null")
  func optionalFieldsAreOmittedNotNull() throws {
    let bare = Finding(
      rule: .exactClone, severity: .warning, path: "Sources/A.swift", line: 3, column: 5,
      message: "duplicated block")
    var report = AnalysisReport(
      findings: [bare], suppressed: [.init(finding: bare, reason: nil)], analyzedFileCount: 1)

    let unset = try Self.jsonObject(report)
    let finding = try #require((unset["findings"] as? [[String: Any]])?.first)
    #expect(Set(finding.keys) == Self.findingKeys.subtracting(["note", "related"]))
    let suppressed = try #require((unset["suppressed"] as? [[String: Any]])?.first)
    #expect(Set(suppressed.keys) == ["finding"])
    #expect(!unset.keys.contains("semanticNote"))
    #expect(!unset.keys.contains("contextNote"))

    report.semanticNote = "semantic pass: 2 groups"
    report.contextNote = "1 generated file left out"
    let set = try Self.jsonObject(report)
    #expect(set["semanticNote"] as? String == "semantic pass: 2 groups")
    #expect(set["contextNote"] as? String == "1 generated file left out")
  }

  private static func jsonObject(_ report: AnalysisReport) throws -> [String: Any] {
    try #require(
      JSONSerialization.jsonObject(with: Data(ReportFormatter.format(report, as: .json).utf8))
        as? [String: Any])
  }
}
