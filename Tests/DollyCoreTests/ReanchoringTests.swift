import Foundation
import ProjectModel
import Testing

@testable import DollyCore

/// Re-anchoring moves the reported location of a scoped clone group to an
/// in-scope member. These pin the pure rewrite of a finding on its own; the
/// pipeline tests in `ReportScopeTests` cover the same rewrite end to end.
@Suite struct ReanchoringTests {
  private static let threeWay = Finding(
    rule: .exactClone, severity: .warning, path: "/repo/A.swift", line: 1, column: 1,
    message: "duplicate",
    note: "duplicates: /repo/B.swift:4, /repo/C.swift:7, /repo/D.swift:9; region: test",
    related: [
      RelatedLocation(path: "/repo/B.swift", line: 4, column: 1),
      RelatedLocation(path: "/repo/C.swift", line: 7, column: 1),
      RelatedLocation(path: "/repo/D.swift", line: 9, column: 1),
    ])

  @Test("Re-anchoring keeps the other members in order, with the old anchor first")
  func otherMembersKeepTheirOrder() {
    let moved = Self.threeWay.reanchored(in: ReportScope(files: ["/repo/C.swift"]))
    #expect(moved.path == "/repo/C.swift")
    #expect(moved.line == 7)
    #expect(
      moved.related == [
        RelatedLocation(path: "/repo/A.swift", line: 1, column: 1),
        RelatedLocation(path: "/repo/B.swift", line: 4, column: 1),
        RelatedLocation(path: "/repo/D.swift", line: 9, column: 1),
      ])
    #expect(
      moved.note == "duplicates: /repo/A.swift:1, /repo/B.swift:4, /repo/D.swift:9; region: test")
  }

  @Test("A re-anchored finding keeps the fingerprint of its original anchor")
  func reanchoredFingerprintHashesOriginalAnchor() {
    let moved = Self.threeWay.reanchored(in: ReportScope(files: ["/repo/C.swift"]))
    #expect(moved.fingerprintAnchor == RelatedLocation(path: "/repo/A.swift", line: 1, column: 1))
    #expect(moved.fingerprint == Self.threeWay.fingerprint)
  }

  /// A two-member group anchored in a subdirectory, with the fingerprint path
  /// spelled relative to the repository root as the analyzer sets it.
  private static let subdirectoryPair = Finding(
    rule: .exactClone, severity: .warning, path: "/repo/x/A.swift", line: 1, column: 1,
    message: "m", note: "duplicates: /repo/B/y.swift:4",
    related: [RelatedLocation(path: "/repo/B/y.swift", line: 4, column: 1)],
    fingerprintPath: "x/A.swift")

  @Test("A re-anchored finding keeps the unscoped fingerprint under any --relative-to root")
  func subdirectoryRootKeepsUnscopedFingerprint() {
    // Scoped to a file outside the anchor's directory, so the moved finding is
    // only under `/repo/B` and the unscoped one only under `/repo/x`.
    let moved = Self.subdirectoryPair.reanchored(in: ReportScope(files: ["/repo/B/y.swift"]))
    #expect(moved.path == "/repo/B/y.swift")
    for root in ["/repo/B", "/repo/x", "/repo"] {
      let unscoped = AnalysisReport(findings: [Self.subdirectoryPair]).relativized(to: root)
      let scoped = AnalysisReport(findings: [moved]).relativized(to: root)
      #expect(scoped.findings[0].fingerprint == unscoped.findings[0].fingerprint)
    }
  }

  @Test("A re-anchored finding's JSON names its original anchor and the unscoped fingerprint")
  func movedFindingJSONNamesOriginalAnchor() throws {
    let moved = Self.subdirectoryPair.reanchored(in: ReportScope(files: ["/repo/B/y.swift"]))
    let json = ReportFormatter.format(AnalysisReport(findings: [moved]), as: .json)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let finding = try #require((object["findings"] as? [[String: Any]])?.first)
    let anchor = try #require(finding["fingerprintAnchor"] as? [String: Any])
    #expect(Set(anchor.keys) == ["path", "line", "column"])
    #expect(anchor["path"] as? String == "/repo/x/A.swift")
    #expect(anchor["line"] as? Int == 1)
    #expect(anchor["column"] as? Int == 1)
    #expect(finding["fingerprint"] as? String == Self.subdirectoryPair.fingerprint)
  }

  @Test("A re-anchored finding's SARIF result is at the moved member and relates the anchor")
  func movedFindingSARIFRelatesOriginalAnchor() throws {
    let moved = Self.subdirectoryPair.reanchored(in: ReportScope(files: ["/repo/B/y.swift"]))
    let sarif = ReportFormatter.format(AnalysisReport(findings: [moved]), as: .sarif)
    let result = try #require(
      JSONDecoder().decode(SarifEntries.self, from: Data(sarif.utf8)).runs.first?.results.first)

    let primary = try #require(result.locations.first?.physicalLocation)
    #expect(primary.artifactLocation.uri == "file:///repo/B/y.swift")
    #expect(primary.region.startLine == 4)
    #expect(primary.region.startColumn == 1)

    let related = try #require(result.relatedLocations)
    #expect(related.map(\.physicalLocation.artifactLocation.uri) == ["file:///repo/x/A.swift"])
    #expect(related.map(\.physicalLocation.region.startLine) == [1])
    #expect(related.map(\.physicalLocation.region.startColumn) == [1])

    #expect(result.partialFingerprints == ["dolly/v1": Self.subdirectoryPair.fingerprint])
  }

  /// The parts of a SARIF log these tests read. Decoded by hand because the
  /// shared `SarifLog` type does not carry `partialFingerprints`.
  private struct SarifEntries: Decodable {
    struct Run: Decodable {
      let results: [Entry]
    }

    struct Entry: Decodable {
      let locations: [SarifLog.Location]
      let relatedLocations: [SarifLog.Location]?
      let partialFingerprints: [String: String]
    }

    let runs: [Run]
  }
}
