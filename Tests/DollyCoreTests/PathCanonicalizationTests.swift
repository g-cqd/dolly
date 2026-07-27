import DollyCore
import Foundation
import Testing

/// `Finding.path` is hashed into `Finding.fingerprint`, which `--baseline`
/// matches on. So the corpus must be identified by *file*, never by the string
/// the caller happened to use: CI passes an explicit changed-file list while
/// baselines are written from a directory walk, and those two must agree.
@Suite struct PathCanonicalizationTests {
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

  @Test("Spelling the corpus differently does not move a single fingerprint")
  func spellingDoesNotAffectFingerprints() async throws {
    let canonical = try files(in: "CrossFileExact")
    // The same files, reached through a redundant `.` and a `..` round-trip —
    // what a naive changed-file list or a relative CI path produces.
    let awkward = canonical.map { path -> String in
      let url = URL(fileURLWithPath: path)
      let parent = url.deletingLastPathComponent()
      return parent.appending(path: ".").appending(path: "..")
        .appending(path: parent.lastPathComponent)
        .appending(path: url.lastPathComponent).path
    }
    #expect(awkward != canonical, "the awkward spelling must actually differ")

    let plain = await Analyzer().analyze(files: canonical)
    let scenic = await Analyzer().analyze(files: awkward)

    #expect(!plain.findings.isEmpty, "fixture must produce findings to compare")
    #expect(plain.findings.map(\.path) == scenic.findings.map(\.path))
    #expect(plain.findings.map(\.fingerprint) == scenic.findings.map(\.fingerprint))

    // The property that actually matters downstream: a baseline written from
    // one spelling suppresses every finding produced by the other.
    #expect(Baseline(findings: plain.findings).filter(scenic.findings).kept.isEmpty)
  }

  @Test("The same file named twice is one corpus entry, not a clone of itself")
  func duplicateSpellingsCollapse() async throws {
    let file = try #require(try files(in: "CrossFileExact").first)
    let alias = URL(fileURLWithPath: file).deletingLastPathComponent()
      .appending(path: ".")
      .appending(path: URL(fileURLWithPath: file).lastPathComponent).path

    let once = await Analyzer().analyze(files: [file])
    let twice = await Analyzer().analyze(files: [file, alias])

    #expect(twice.analyzedFileCount == 1)
    // Before canonicalization the duplicate entry made the file an exact clone
    // of itself, fabricating findings a PR gate would fail on.
    #expect(twice.findings.map(\.fingerprint) == once.findings.map(\.fingerprint))
  }
}
