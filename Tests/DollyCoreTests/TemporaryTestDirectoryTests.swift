import Foundation
import Testing

@Suite("Temporary test directory") struct TemporaryTestDirectoryTests {
  @Test("The directory and its files are removed when the owner leaves scope")
  func cleanup() throws {
    let path: URL = try {
      let temporary = try TemporaryTestDirectory(prefix: "dolly-cleanup")
      try Data("fixture".utf8).write(to: temporary.url.appending(path: "fixture.swift"))
      withExtendedLifetime(temporary) {}
      return temporary.url
    }()

    #expect(!FileManager.default.fileExists(atPath: path.path))
  }
}
