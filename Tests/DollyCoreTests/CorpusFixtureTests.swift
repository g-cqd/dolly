import DollyCore
import Foundation
import Testing

/// Cross-file golden gates: clone detection's defining capability is corpus
/// scope, so each `Fixtures/Corpus/<unit>/` directory is analyzed as one
/// `analyze(files:)` run. Exact clones are pinned precisely; the structural
/// pair is asserted by rule and cross-file membership rather than line-pinned
/// markers — MinHash group boundaries are threshold-sensitive, and a golden
/// that breaks on a legitimate tuning change gates nothing.
@Suite struct CorpusFixtureTests {
  private static let corpusRoot = Bundle.module.resourceURL!
    .appending(path: "Fixtures/Corpus")

  private func analyzeUnit(_ name: String) async throws -> AnalysisReport {
    let dir = Self.corpusRoot.appending(path: name)
    let files = try FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" }
    .map(\.path)
    .sorted()
    #expect(files.count == 2)
    return await Analyzer().analyze(files: files)
  }

  @Test("Cross-file exact clone: one finding, anchored in A, naming B")
  func crossFileExactCloneIsPinned() async throws {
    let report = try await analyzeUnit("CrossFileExact")
    let exact = report.findings.filter { $0.rule == .exactClone }
    #expect(exact.count == 1)
    #expect(exact.first?.path.hasSuffix("A.swift") == true)
    #expect(exact.first?.note?.contains("B.swift") == true)
    #expect(!report.findings.contains { $0.rule == .nearClone })
  }

  @Test("Structural pair: structural-clone spans both files")
  func structuralPairSpansBothFiles() async throws {
    let report = try await analyzeUnit("StructuralPair")
    let structural = report.findings.filter { $0.rule == .structuralClone }
    #expect(!structural.isEmpty)
    let spansBoth = structural.contains { finding in
      let mentionsA = finding.path.hasSuffix("A.swift") || finding.note?.contains("A.swift") == true
      let mentionsB = finding.path.hasSuffix("B.swift") || finding.note?.contains("B.swift") == true
      return mentionsA && mentionsB
    }
    #expect(spansBoth, "expected a structural group with members in both files: \(structural)")
  }
}
