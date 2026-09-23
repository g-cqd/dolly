import Foundation

/// Owns one test's scratch directory so cleanup also runs after a thrown test.
final class TemporaryTestDirectory: Sendable {
  let url: URL

  init(prefix: String) throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
