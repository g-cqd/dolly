import DollyCore
import Foundation
import Testing

/// The benchmark package's only failure mode is dependency drift against the
/// parent — prove the graph is intact with one real cross-file analysis
/// round-trip that must produce an exact-clone finding.
@Suite struct BenchmarksSmokeTests {
  @Test func parentProductIsUsable() async throws {
    let body = """
      func compute(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Int {
        let sum = a + b + c + d
        let product = a * b * c * d
        let mixed = sum - product + a - b + c - d
        let folded = mixed * 2 + sum - product
        return folded + sum + product + a + b + c + d
      }
      """
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-smoke-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["A", "B"] {
      try "// smoke\nenum Host\(name) {\n\(body)\n}\n"
        .write(to: dir.appending(path: "\(name).swift"), atomically: true, encoding: .utf8)
    }

    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }.map(\.path).sorted()
    let report = await Analyzer().analyze(files: files)
    #expect(report.findings.contains { $0.rule == .exactClone })
  }
}
