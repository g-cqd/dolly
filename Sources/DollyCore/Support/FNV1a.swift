//  FNV1a.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

/// FNV-1a 64-bit hash. Non-cryptographic; suitable for content
/// fingerprints, bucket selection (LSH), and stable document identifiers.
enum FNV1a {
  /// FNV-1a 64-bit offset basis.
  static let offsetBasis: UInt64 = 14_695_981_039_346_656_037

  /// FNV-1a 64-bit prime.
  static let prime: UInt64 = 1_099_511_628_211

  /// Compute FNV-1a hash of the UTF-8 view of a string.
  static func hash(_ string: String) -> UInt64 {
    var hash = offsetBasis
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* prime
    }
    return hash
  }
}
