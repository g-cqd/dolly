import DollyCore
import Foundation
import Testing

/// Report scoping narrows what a run *reports*, never what it analyzes. These
/// pin the two properties CI depends on: the corpus stays whole (so findings
/// are the same ones an unscoped run would produce, fingerprints included),
/// and a clone group counts as in scope when *any* member is, not just the
/// arbitrary anchor.
@Suite struct ReportScopeTests {
  private static let corpusRoot = Bundle.module.resourceURL!
    .appending(path: "Fixtures/Corpus")

  private func files(in unit: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      at: Self.corpusRoot.appending(path: unit), includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" }
    .map(\.path)
    .sorted()
  }

  @Test("No scope reports everything and leaves outOfScope empty")
  func unscopedIsUnchanged() async throws {
    let report = await Analyzer().analyze(files: try files(in: "CrossFileExact"))
    #expect(!report.findings.isEmpty)
    #expect(report.outOfScope.isEmpty)
  }

  @Test("Scoping the anchor's file keeps the finding")
  func anchorInScope() async throws {
    let corpus = try files(in: "CrossFileExact")
    let unscoped = await Analyzer().analyze(files: corpus)
    let anchor = try #require(unscoped.findings.first).path

    let report = await Analyzer(reportScope: ReportScope(files: [anchor]))
      .analyze(files: corpus)
    #expect(report.findings.map(\.fingerprint) == unscoped.findings.map(\.fingerprint))
    #expect(report.outOfScope.isEmpty)
  }

  @Test("Scoping only a non-anchor group member still reports the clone")
  func relatedMemberInScope() async throws {
    // The regression this exists for: a clone group anchors at its
    // lexicographically smallest member, which has nothing to do with which
    // file a pull request touched. Scoping to the *other* member must still
    // surface it — that is code in a changed file duplicating older code.
    let corpus = try files(in: "CrossFileExact")
    let unscoped = await Analyzer().analyze(files: corpus)
    let finding = try #require(unscoped.findings.first)
    let partner = try #require(finding.related.first).path
    #expect(partner != finding.path, "fixture must be a genuine cross-file clone")

    let report = await Analyzer(reportScope: ReportScope(files: [partner]))
      .analyze(files: corpus)
    #expect(report.findings.map(\.fingerprint) == [finding.fingerprint])
  }

  @Test("A file with no findings scopes everything else out, corpus intact")
  func unrelatedScopeReportsNothing() async throws {
    let corpus = try files(in: "CrossFileExact")
    let unscoped = await Analyzer().analyze(files: corpus)

    let report = await Analyzer(reportScope: ReportScope(files: ["/nowhere/Absent.swift"]))
      .analyze(files: corpus)
    #expect(report.findings.isEmpty)
    // Nothing is lost: out-of-scope findings are retained, and the corpus is
    // still the whole corpus.
    #expect(report.outOfScope.count == unscoped.findings.count)
    #expect(report.analyzedFileCount == unscoped.analyzedFileCount)
  }

  @Test("An empty scope reports nothing rather than everything")
  func emptyScopeIsNotAbsentScope() async throws {
    // `--only-from` pointed at a change set with no Swift files must report
    // nothing. Treating that as "no scope" would report the entire corpus on
    // exactly the pull requests that touched no code.
    let corpus = try files(in: "CrossFileExact")
    let report = await Analyzer(reportScope: ReportScope(files: [] as [String]))
      .analyze(files: corpus)
    #expect(report.findings.isEmpty)
    #expect(!report.outOfScope.isEmpty)
  }

  @Test("Scope entries are canonicalized, so relative paths match")
  func scopeAcceptsUncanonicalPaths() async throws {
    let corpus = try files(in: "CrossFileExact")
    let unscoped = await Analyzer().analyze(files: corpus)
    let anchor = try #require(unscoped.findings.first).path
    // What a caller piping `git diff --name-only` might hand us.
    let awkward = URL(fileURLWithPath: anchor).deletingLastPathComponent()
      .appending(path: ".")
      .appending(path: URL(fileURLWithPath: anchor).lastPathComponent).path

    let report = await Analyzer(reportScope: ReportScope(files: [awkward]))
      .analyze(files: corpus)
    #expect(report.findings.map(\.fingerprint) == unscoped.findings.map(\.fingerprint))
  }

  @Test("Scoping never invents or moves a finding relative to an unscoped run")
  func scopedFindingsAreASubsetOfUnscoped() async throws {
    let corpus = try files(in: "StructuralPair")
    let unscoped = await Analyzer().analyze(files: corpus)
    let everything = ReportScope(files: corpus)

    let report = await Analyzer(reportScope: everything).analyze(files: corpus)
    // Scoping to the entire corpus must be a no-op, fingerprints included —
    // this is what lets a scoped CI run share a baseline with an unscoped one.
    #expect(report.findings.map(\.fingerprint) == unscoped.findings.map(\.fingerprint))
    #expect(report.outOfScope.isEmpty)
  }
}
