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
    #expect(object["schemaVersion"] as? Int == ReportSchema.version)
    #expect(Set(object.keys) == Self.topLevelKeys)

    let finding = try #require((object["findings"] as? [[String: Any]])?.first)
    #expect(Set(finding.keys) == Self.findingKeys)

    let related = try #require((finding["related"] as? [[String: Any]])?.first)
    #expect(Set(related.keys) == Self.relatedLocationKeys)
  }
}
