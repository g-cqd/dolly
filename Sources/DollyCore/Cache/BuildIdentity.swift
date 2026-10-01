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
      let device = number(attributes[.systemNumber]),
      let inode = number(attributes[.systemFileNumber]),
      let size = number(attributes[.size]),
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

  /// Foundation boxes file attributes as `NSNumber` on Darwin, and as `UInt` or
  /// `UInt64` in FoundationEssentials, which has no `NSNumber` on Linux.
  private static func number(_ value: Any?) -> UInt64? {
    switch value {
    case let number as UInt64: number
    case let number as UInt: UInt64(number)
    case let number as Int: UInt64(exactly: number)
    default: nil
    }
  }

  private static var executablePath: String? {
    #if os(Linux)
      try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
    #else
      Bundle.main.executablePath
    #endif
  }
}
