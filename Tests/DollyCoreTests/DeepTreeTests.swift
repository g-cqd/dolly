import DollyCore
import Foundation
import Testing

/// A deeply nested file never crashes the run: files nested within reason are analysed on the large stack, clones
/// between them included, and one nested past the limit is listed as skipped (analyzerkit roadmap 0041).
@Suite struct DeepTreeTests {
  private static func chain(_ name: String, _ links: Int) -> String {
    "func \(name)() {\n  let v = view" + String(repeating: ".m(1)", count: links)
      + "\n  print(v)\n}\n"
  }

  @Test func `deep files are analysed or listed as skipped, and the corpus still reports`()
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "dolly-deep-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var paths: [String] = []
    let files = [
      ("Deep", Self.chain("f", 3_000)), ("DeepCopy", Self.chain("g", 3_000)),
      ("Deeper", Self.chain("h", 15_000)),
    ]
    for (name, text) in files {
      let url = root.appending(path: "\(name).swift")
      try text.write(to: url, atomically: true, encoding: .utf8)
      paths.append(url.path)
    }
    let report = await Analyzer().analyze(files: paths)
    let cloned = Set(report.findings.map { ($0.path as NSString).lastPathComponent })
    #expect(
      cloned == ["Deep.swift", "DeepCopy.swift"], "the two deep copies are reported as clones")
    #expect(
      report.degradedFiles.map { ($0.path as NSString).lastPathComponent } == ["Deeper.swift"])
    #expect(report.degradedFiles.first?.detail.contains("nested") == true)
  }
}
