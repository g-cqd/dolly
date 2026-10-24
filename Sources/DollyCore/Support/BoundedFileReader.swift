import SourceCorpus

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Reads a small configuration-class file with a stat-first size cap, so a hostile or accidental giant JSON
/// can't be pulled into RAM. Fails closed with a typed error. The read is analyzerkit's; this maps its two
/// failures onto this tool's errors.
enum BoundedFileReader {
  /// 1 MB is generous for config/baseline JSON and cheap to reject above.
  static let configByteCap = SourceCorpus.BoundedFileReader.configByteCap

  static func read(
    path: String,
    cap: Int = configByteCap
  ) throws(DollyError) -> Data {
    do {
      return try SourceCorpus.BoundedFileReader.readConfiguration(path: path, cap: cap)
    } catch {
      if let detail = error.invalidDetail {
        throw .configurationInvalid(path: path, detail: detail)
      }
      guard case .unreadable(let underlying) = error else {
        throw .configurationInvalid(path: path, detail: "\(error)")
      }
      throw .configurationUnreadable(path: path, underlying: underlying)
    }
  }

  /// Bounded read plus JSON decode with the same fail-closed behavior:
  /// malformed content is a typed error, never a silently-empty value.
  static func readJSON<Value: Decodable>(
    _ type: Value.Type,
    path: String,
    cap: Int = configByteCap
  ) throws(DollyError) -> Value {
    let data = try read(path: path, cap: cap)
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw .configurationInvalid(path: path, detail: String(describing: error))
    }
  }
}
