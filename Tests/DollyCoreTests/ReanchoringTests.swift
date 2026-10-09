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
}
