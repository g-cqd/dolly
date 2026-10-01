#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Identifies the executable that extracted cached facts. If its file identity
/// cannot be read, the cache is disabled rather than shared between builds.
enum BuildIdentity {
  static let current: String? = identity(ofExecutableAt: executablePath)

  /// Hashes the executable's resolved path and file metadata. Replacing or
  /// rebuilding an executable changes its identity even at the same version.
  static func identity(ofExecutableAt path: String?) -> String? {
    guard let path else { return nil }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
      let device = FileAttributeNumber.read(attributes[.systemNumber]),
      let inode = FileAttributeNumber.read(attributes[.systemFileNumber]),
      let size = FileAttributeNumber.read(attributes[.size]),
      let modified = attributes[.modificationDate] as? Date
    else { return nil }

    let fields = [
      resolved, String(device), String(inode), String(size),
      String(modified.timeIntervalSince1970),
    ]
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in fields.joined(separator: "\0").utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  private static var executablePath: String? {
    #if os(Linux)
      try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
    #else
      Bundle.main.executablePath
    #endif
  }
}
