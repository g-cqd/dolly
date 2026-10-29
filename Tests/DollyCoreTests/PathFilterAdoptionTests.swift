import DollyCore
import Foundation
import Testing

/// `exclude` follows ADR-0008, the rule every tool shares: substrings as before, globs relative to the configuration
/// file's directory (analyzerkit roadmap 0005).
@Suite struct PathFilterAdoptionTests {
  @Test func `globs are relative to the configuration file and substrings keep their meaning`()
    throws
  {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "dolly-exclude-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: ".dolly.json")
    try JSONSerialization.data(withJSONObject: [
      "exclude": ["Sources/*/Internal", "/*.swift", "Generated/"]
    ])
    .write(to: file)
    let config = try Configuration.load(path: file.path)
    let base = root.path
    #expect(config.isExcluded(path: base + "/Sources/App/Internal/Secret.swift"))
    #expect(config.isExcluded(path: base + "/Package.swift"))
    #expect(config.isExcluded(path: base + "/Sources/Generated/API.swift"))
    #expect(!config.isExcluded(path: base + "/Sources/App/Internal.swift"))
    #expect(!config.isExcluded(path: base + "/Sources/App/App.swift"))
  }
}
