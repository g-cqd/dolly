//  FactsCache.swift
//  dolly — modeled on arcleak's FactsCache (fail-open, version-gated)
//
//  Per-file facts cache for the interned token pipeline. Parsing +
//  extraction dominate runtime; detection is corpus-level and always
//  re-runs, so only per-file extraction facts are cached — findings never
//  go stale relative to engine or configuration changes.
//
//  The cache is an optimization, so unlike configuration it FAILS OPEN: an
//  unreadable, corrupt, or version-mismatched cache behaves as empty and is
//  overwritten on persist. Entries are keyed by absolute path and validated
//  by a content fingerprint (FNV-1a 64 over bytes + length — identity, not
//  security; a collision merely serves stale facts for one file until its
//  next real change). A tool-version mismatch discards the whole cache, so
//  a facts-schema change can never deserialize into wrong shapes.

import Foundation

struct FactsCache: Sendable {
  // MARK: - Entry

  /// One file's cached extraction facts, with FILE-LOCAL intern ids —
  /// `CorpusAssembler` remaps them into the corpus interner on every run
  /// exactly as it does for freshly extracted files.
  ///
  /// The per-token lanes ride as `Data` blobs (base64 in the JSON):
  /// `JSONDecoder` walks numeric arrays one unkeyed-container element at a
  /// time, which is slower than re-parsing the Swift source — a blob is
  /// one base64 pass regardless of token count.
  struct Entry: Sendable, Codable {
    let fingerprint: String
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

    init(fingerprint: String, tokens: FileTokens, directives: [SuppressionDirective]) {
      self.fingerprint = fingerprint
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

    private static func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
      bytes.append(UInt8(truncatingIfNeeded: value))
      bytes.append(UInt8(truncatingIfNeeded: value >> 8))
      bytes.append(UInt8(truncatingIfNeeded: value >> 16))
      bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
      UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
    }
  }

  private struct Payload: Codable {
    var tool: String
    var version: String
    var entries: [String: Entry]
  }

  // MARK: - State

  private(set) var entries: [String: Entry]

  init(entries: [String: Entry] = [:]) {
    self.entries = entries
  }

  // MARK: - Fingerprint

  /// FNV-1a 64 over the raw bytes plus the length suffix. Ported from
  /// arcleak: `withUnsafeBytes` is the only fast path — `Data`'s element
  /// iterator is O(n) with per-byte bridging overhead, and this runs on
  /// every file on every run (even cache hits).
  /// Invariant: the buffer never escapes the closure; `unsafe` is confined
  /// here and covered by the fingerprint stability tests.
  static func fingerprint(of data: Data) -> String {
    let prime: UInt64 = 0x0000_0100_0000_01b3
    let hash: UInt64 = unsafe data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt64 in
      var h: UInt64 = 0xcbf2_9ce4_8422_2325
      let count = raw.count
      var i = 0
      while i < count {
        h ^= UInt64(unsafe raw[i])
        h &*= prime
        i += 1
      }
      return h
    }
    return "\(String(hash, radix: 16))-\(data.count)"
  }

  // MARK: - Access

  /// The cached entry when the path is present AND the fingerprint still
  /// matches; nil otherwise.
  func entry(for path: String, fingerprint: String) -> Entry? {
    guard let entry = entries[path], entry.fingerprint == fingerprint else { return nil }
    return entry
  }

  mutating func update(path: String, entry: Entry) {
    entries[path] = entry
  }

  /// Drop entries for files absent from the current run.
  mutating func prune(keeping paths: Set<String>) {
    entries = entries.filter { paths.contains($0.key) }
  }

  // MARK: - Load / Persist

  /// Interned token payloads are an order of magnitude denser than config
  /// JSON; the cap only guards against pathological files.
  static let maxCacheBytes = 256 * 1024 * 1024

  /// Fail-open load: any failure — unreadable, over-cap, corrupt JSON, or
  /// a tool/version mismatch — returns an empty cache (the cache is an
  /// optimization, never a trust boundary).
  static func load(url: URL) -> FactsCache {
    guard
      let data = try? BoundedFileReader.read(path: url.path, cap: maxCacheBytes),
      let payload = try? JSONDecoder().decode(Payload.self, from: data),
      payload.tool == ToolInfo.name,
      payload.version == ToolInfo.version
    else {
      return FactsCache()
    }
    return FactsCache(entries: payload.entries)
  }

  /// Best-effort persist: creates the directory, writes atomically, and
  /// swallows failures — a read-only cache location must never fail a run.
  func persist(url: URL) {
    let payload = Payload(tool: ToolInfo.name, version: ToolInfo.version, entries: entries)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(payload) else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: url, options: .atomic)
  }
}
