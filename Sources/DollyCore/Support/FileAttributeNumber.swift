/// Reads the numeric file attributes (device, inode, size) that Foundation boxes as `NSNumber`
/// on Darwin, and as `UInt` or `UInt64` in FoundationEssentials, which has no `NSNumber` on Linux.
enum FileAttributeNumber {
  static func read(_ value: Any?) -> UInt64? {
    switch value {
    case let number as UInt64: number
    case let number as UInt: UInt64(number)
    case let number as Int: UInt64(exactly: number)
    default: nil
    }
  }
}
