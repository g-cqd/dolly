import ProjectModel
import SourceCorpus

//  CachedFileFacts.swift
//  dolly — what analyzerkit's facts cache keeps for one file (roadmap 0020)
//
//  Parsing and extraction dominate runtime; detection is corpus-level and
//  always re-runs, so only per-file extraction facts are cached, through
//  analyzerkit's `CorpusScanner` (ADR-0011): sharded, keyed by content, gated
//  by the build. What a file's project says of its region changes without the
//  file changing, so only the content's part of the region is kept here; the
//  project's part is joined on every run.

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct CachedFileFacts: Sendable, Codable {
  /// Interleaved little-endian Int32 (rawID, normID, line, column) per
  /// token — 16 bytes per token, mirroring `TokenRecord`.
  let recordData: Data
  /// File-local intern table: id -> token text.
  let strings: [String]
  /// Token kind lane (`TokenKind` raw values, one byte per token).
  let kindData: Data
  /// Top-level declaration boundary token indices.
  let boundaries: [Int]
  /// Macro-expansion marker.
  let hasSourceLocationDirective: Bool
  /// Suppression directives scanned from the parse tree.
  let directives: [SuppressionDirective]
  /// What the content alone says of the file's region (`CodeRegion.rawValue`):
  /// a test-framework import, a generator's header.
  let contentRegion: UInt8
  /// `#Preview` bodies and `PreviewProvider` types.
  let previewSpans: [FileContext.LineSpan]

  init(
    tokens: FileTokens, directives: [SuppressionDirective], contentRegion: CodeRegion,
    previewSpans: [FileContext.LineSpan]
  ) {
    self.contentRegion = contentRegion.rawValue
    self.previewSpans = previewSpans
    var bytes = [UInt8]()
    bytes.reserveCapacity(tokens.records.count * 16)
    for record in tokens.records {
      Self.appendLittleEndian(UInt32(bitPattern: record.line), to: &bytes)
      Self.appendLittleEndian(UInt32(bitPattern: record.column), to: &bytes)
      Self.appendLittleEndian(record.rawID, to: &bytes)
      Self.appendLittleEndian(record.normID, to: &bytes)
    }
    recordData = Data(bytes)
    strings = tokens.strings
    kindData = Data(tokens.kinds.map(\.rawValue))
    boundaries = tokens.boundaries
    hasSourceLocationDirective = tokens.hasSourceLocationDirective
    self.directives = directives
  }

  /// The stored form, as the payload decoder rebuilds it.
  init(
    recordData: Data, strings: [String], kindData: Data, boundaries: [Int],
    hasSourceLocationDirective: Bool,
    directives: [SuppressionDirective], contentRegion: UInt8, previewSpans: [FileContext.LineSpan]
  ) {
    self.recordData = recordData
    self.strings = strings
    self.kindData = kindData
    self.boundaries = boundaries
    self.hasSourceLocationDirective = hasSourceLocationDirective
    self.directives = directives
    self.contentRegion = contentRegion
    self.previewSpans = previewSpans
  }

  /// Rebuild the extraction facts, re-deriving the lazy text provider
  /// from the just-read source. Nil on any internal inconsistency
  /// (truncated blobs, out-of-range ids) — the caller treats that as a
  /// miss, keeping the fail-open contract even for a corrupted-but-
  /// decodable payload.
  func fileTokens(path: String, source: String) -> FileTokens? {
    // One contiguous copy up front: Data's per-element subscript pays
    // bridging overhead the byte loop below must not.
    let bytes = [UInt8](recordData)
    guard bytes.count % 16 == 0 else { return nil }
    let tokenCount = bytes.count / 16
    let kindBytes = [UInt8](kindData)
    guard kindBytes.count == tokenCount else { return nil }

    let stringCount = UInt32(strings.count)
    var rebuilt = [TokenRecord]()
    rebuilt.reserveCapacity(tokenCount)
    for token in 0..<tokenCount {
      let base = token * 16
      let line = Self.littleEndianUInt32(bytes, at: base)
      let column = Self.littleEndianUInt32(bytes, at: base + 4)
      let rawID = Self.littleEndianUInt32(bytes, at: base + 8)
      let normID = Self.littleEndianUInt32(bytes, at: base + 12)
      guard rawID < stringCount, normID < stringCount else { return nil }
      rebuilt.append(
        TokenRecord(
          rawID: rawID,
          normID: normID,
          line: Int32(bitPattern: line),
          column: Int32(bitPattern: column)
        ))
    }

    var kindLane = [TokenKind]()
    kindLane.reserveCapacity(tokenCount)
    for raw in kindBytes {
      guard let kind = TokenKind(rawValue: raw) else { return nil }
      kindLane.append(kind)
    }

    return FileTokens(
      file: path,
      records: rebuilt,
      strings: strings,
      kinds: kindLane,
      boundaries: boundaries,
      hasSourceLocationDirective: hasSourceLocationDirective,
      text: SourceText(source: source)
    )
  }

  /// The record lane's words, little-endian; the protobuf payload rebuilds the same lane (FactsProtobufCoding).
  static func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8(truncatingIfNeeded: value))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    bytes.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}

/// One file's outcome of extraction, as the cache stores it.
struct ExtractedFile: Sendable, Codable {
  /// The facts; nil when the file was not analysed.
  let facts: CachedFileFacts?
  /// Why the file was not analysed: not UTF-8, over the size cap, nested too deeply.
  let degraded: String?
}
