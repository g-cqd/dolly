import DollyCore
import Foundation
import Testing

@Suite struct SuppressionTests {
  @Test func parsesAccept() {
    let directive = SuppressionDirective.parse(
      comment: "// @dl:accept -- reviewed", line: 3)
    #expect(directive?.kind == .accept)
    #expect(directive?.reason == "reviewed")
    #expect(directive?.rules.isEmpty == true)
  }

  @Test func longNamespaceIsSynonym() {
    let directive = SuppressionDirective.parse(
      comment: "// @dolly:accept:next exact-clone", line: 1)
    #expect(directive?.kind == .acceptNext)
    #expect(directive?.rules == [RuleID(rawValue: "exact-clone")!])
  }

  @Test func rejectsMissingSigil() {
    #expect(SuppressionDirective.parse(comment: "// dl:accept", line: 1) == nil)
  }

  @Test func rejectsExpectationSigil() {
    #expect(SuppressionDirective.parse(comment: "// #dl:expect exact-clone", line: 1) == nil)
  }

  @Test func unknownOnlyRulesSuppressNothing() {
    #expect(SuppressionDirective.parse(comment: "// @dl:accept:this bogus-rule", line: 1) == nil)
  }

  @Test func regionPairScopesSuppression() {
    let table = SuppressionTable(directives: [
      SuppressionDirective(rules: [], kind: .regionDisable, line: 2, reason: "generated"),
      SuppressionDirective(rules: [], kind: .regionEnable, line: 8, reason: nil),
    ])
    let rule = RuleID.allCases.first!
    #expect(table.suppression(for: rule, line: 5) == .some("generated"))
    #expect(table.suppression(for: rule, line: 9) == nil)
  }

  @Test func acceptOnAnchorLineSuppressesCloneGroup() async {
    let clone = """
      func stitchBannerRow(cells: [Int]) -> String {
          var text = ""
          for cell in cells {
              if cell > 4 {
                  text += "<\\(cell)>"
              } else {
                  text += "(\\(cell))"
              }
              text += ", "
          }
          return text
      }
      """
    let copy = clone.replacingOccurrences(of: "stitchBannerRow", with: "stitchFooterRow")
    let source = clone + "\n\n" + copy + "\n"

    // Calibrate: find the anchor line the engine reports...
    let plain = await Analyzer().analyze(source: source, path: "banner.swift")
    let anchor = plain.findings.first { $0.rule == .exactClone }
    #expect(anchor != nil, "the pair must produce an exact-clone before suppression")
    guard let anchor else { return }

    // ...then accept it right there with a trailing directive.
    var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    lines[anchor.line - 1] += "  // @dl:accept exact-clone -- generated"
    let accepted = lines.joined(separator: "\n")

    let report = await Analyzer().analyze(source: accepted, path: "banner.swift")
    #expect(!report.findings.contains { $0.rule == .exactClone })
    let suppressed = report.suppressed.first { $0.finding.rule == .exactClone }
    #expect(suppressed != nil, "the group must move into report.suppressed")
    #expect(suppressed?.reason == "generated")
    #expect(suppressed?.finding.line == anchor.line)
  }
}
