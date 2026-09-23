import Foundation
import Testing

@testable import DollyCore

/// The walk behind `dolly analyze <directory>`. A symlinked subtree is analyzed
/// like any other, but no link may send the walk round a loop or out of the
/// directory it was given: two links back to an ancestor used to make it
/// exponential, and a link to `/` made it read the whole disk.
@Suite struct SourceDiscoveryTests {
  /// A scratch directory holding `root/A.swift` and `root/Sources/B.swift`,
  /// plus an `outside/Shared.swift` beside the root. The caller removes it.
  private func makeScratch() throws -> (scratch: URL, root: URL) {
    let scratch = FileManager.default.temporaryDirectory
      .appending(path: "dolly-walk-\(UUID().uuidString)")
    let root = scratch.appending(path: "root")
    try write("A.swift", in: root)
    try write("Sources/B.swift", in: root)
    try write("outside/Shared.swift", in: scratch)
    return (scratch, root)
  }

  private func write(_ path: String, in directory: URL) throws {
    let file = directory.appending(path: path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
  }

  private func link(_ path: String, to destination: String, in directory: URL) throws {
    try FileManager.default.createSymbolicLink(
      atPath: directory.appending(path: path).path, withDestinationPath: destination)
  }

  /// The files a walk of `root` must list when no link adds anything.
  private func realFiles(under root: URL) -> [String] {
    [root.path + "/A.swift", root.path + "/Sources/B.swift"]
  }

  @Test("A link back to an ancestor does not walk the tree again")
  func ancestorLinkIsNotReentered() throws {
    let (scratch, root) = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    try link("Sources/Loop", to: "..", in: root)

    #expect(SourceDiscovery.swiftFiles(in: root.path) == realFiles(under: root))
  }

  @Test("Two links back to an ancestor finish and list each file once")
  func twoAncestorLinksFinish() throws {
    let (scratch, root) = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    try link("Sources/Loop1", to: "..", in: root)
    try link("Sources/Loop2", to: "..", in: root)

    #expect(SourceDiscovery.swiftFiles(in: root.path) == realFiles(under: root))
  }

  @Test(
    "A link out of the root is not followed",
    arguments: [
      ("Shared", "../outside"),
      ("Linked.swift", "../outside/Shared.swift"),
      ("FileSystem", "/"),
    ])
  func outsideLinkIsNotFollowed(name: String, destination: String) throws {
    let (scratch, root) = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    try link(name, to: destination, in: root)

    #expect(SourceDiscovery.swiftFiles(in: root.path) == realFiles(under: root))
  }

  @Test("A link inside the root is followed, and its files are listed once")
  func insideLinkIsFollowedOnce() throws {
    let (scratch, root) = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    try link("Alias", to: "Sources", in: root)

    let files = SourceDiscovery.swiftFiles(in: root.path)
    #expect(files.count == 2)
    #expect(
      Set(SourcePath.canonicalized(files))
        == Set(SourcePath.canonicalized(realFiles(under: root))))
  }

  @Test("A root named through a link keeps its spelling and its containment")
  func linkedRootIsContained() throws {
    let (scratch, root) = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    try link("Sources/Loop", to: "..", in: root)
    try link("Linked", to: "root", in: scratch)
    let linked = scratch.appending(path: "Linked")

    #expect(SourceDiscovery.swiftFiles(in: linked.path) == realFiles(under: linked))
  }

  @Test(
    "A dangling link stays listed, so the analyzer reports it degraded", arguments: [false, true])
  func danglingLinkIsListed(rootThroughLink: Bool) throws {
    let (scratch, root) = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    try link("Sources/Broken.swift", to: "Missing.swift", in: root)
    try link("Linked", to: "root", in: scratch)
    let walked = rootThroughLink ? scratch.appending(path: "Linked") : root

    #expect(
      SourceDiscovery.swiftFiles(in: walked.path)
        == realFiles(under: walked) + [walked.path + "/Sources/Broken.swift"])
  }

  /// Exclusion matches the spelling a file is reached by. A link named like an
  /// exclude pattern, queued before the directory it points to, must not claim
  /// that directory, or its files vanish with the link's.
  @Test("An excluded link does not hide the directory it points to")
  func excludedLinkDoesNotHideItsTarget() throws {
    let (scratch, root) = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    try write("Sources/Sub/C.swift", in: root)
    try link("Vendor", to: "Sources/Sub", in: root)

    let files = SourceDiscovery.swiftFiles(in: root.path) { $0.contains("/Vendor/") }
    #expect(files == realFiles(under: root) + [root.path + "/Sources/Sub/C.swift"])
  }

  @Test("Hidden entries, build products and excluded paths are skipped")
  func skippedEntries() throws {
    let (scratch, root) = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    for skipped in [".hidden", ".build", "DerivedData", ".swiftpm", "checkouts", "Generated"] {
      try write("\(skipped)/X.swift", in: root)
    }
    try write("Sources/Notes.md", in: root)

    let files = SourceDiscovery.swiftFiles(in: root.path) { $0.contains("/Generated/") }
    #expect(files == realFiles(under: root))
  }
}
