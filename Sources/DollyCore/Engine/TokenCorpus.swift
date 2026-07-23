//  TokenCorpus.swift
//  dolly
//
//  The interned token pipeline (D2). Extraction interns every token text
//  into a per-file table and emits 16-byte `TokenRecord`s; corpus assembly
//  merges the per-file tables into one corpus interner and remaps ids. All
//  downstream stages operate on integer ids — token strings materialize
//  only at reporting time (fingerprints, snippets).

// MARK: - TokenRecord

/// One token as the engine sees it: 16 bytes, no strings.
///
/// `rawID` is the corpus-interned id of the token text; `normID` is the
/// corpus-interned id of its normalized form (`TokenNormalizer.default`
/// semantics: non-preserved identifiers share the `$ID` id, string literals
/// `$STR`, numbers `$NUM`, closure shorthands `$PARAM`; everything else
/// normalizes to itself, so `normID == rawID`).
struct TokenRecord: Sendable, Hashable {
  var rawID: UInt32
  var normID: UInt32
  var line: Int32
  var column: Int32
}

// MARK: - SourceText

/// Source text with precomputed line-start offsets. Line content — snippets,
/// directive scans — materializes lazily from the offsets; nothing splits
/// the source into per-line strings up front.
struct SourceText: Sendable {
  /// The full source.
  let source: String

  /// UTF-8 offset of the first byte of each line (line 1 starts at 0).
  /// `\n`, `\r`, and `\r\n` terminate lines (Swift sources are not split
  /// on the exotic Unicode separators the old `.newlines` split honored).
  let lineStartOffsets: [Int]

  init(source: String) {
    self.source = source
    var offsets: [Int] = [0]
    let utf8 = source.utf8
    var index = utf8.startIndex
    var offset = 0
    while index < utf8.endIndex {
      let byte = utf8[index]
      index = utf8.index(after: index)
      offset += 1
      if byte == 0x0A {  // \n
        offsets.append(offset)
      } else if byte == 0x0D {  // \r or \r\n
        if index < utf8.endIndex, utf8[index] == 0x0A {
          index = utf8.index(after: index)
          offset += 1
        }
        offsets.append(offset)
      }
    }
    lineStartOffsets = offsets
  }

  var lineCount: Int { lineStartOffsets.count }

  /// The text of the 1-based line, excluding its terminator.
  func line(_ number: Int) -> Substring {
    guard number >= 1, number <= lineStartOffsets.count else { return "" }
    let utf8 = source.utf8
    let start = utf8.index(utf8.startIndex, offsetBy: lineStartOffsets[number - 1])
    let end =
      number < lineStartOffsets.count
      ? utf8.index(utf8.startIndex, offsetBy: lineStartOffsets[number])
      : utf8.endIndex
    var slice = source[start..<end]
    while slice.last == "\n" || slice.last == "\r" {
      slice = slice.dropLast()
    }
    return slice
  }

  /// Materialize a snippet for a 1-based inclusive line range.
  func snippet(startLine: Int, endLine: Int) -> String {
    let start = max(1, startLine)
    let end = min(lineStartOffsets.count, endLine)
    guard start <= end else { return "" }
    return (start...end).map { String(line($0)) }.joined(separator: "\n")
  }

  /// `true` when any line starts (after space/tab indentation) with
  /// `#sourceLocation` — the marker the Swift compiler emits at the top of
  /// macro-expansion files. Conservative: any occurrence counts. One byte
  /// pass; UTF8View indexing is not random-access so per-line slicing
  /// would be quadratic.
  var containsSourceLocationDirective: Bool {
    let marker = Array("#sourceLocation".utf8)
    // -2 = rest of line disqualified, -1 = in indentation, k >= 0 = matched
    // the first k marker bytes.
    var progress = -1
    for byte in source.utf8 {
      if byte == 0x0A || byte == 0x0D {
        progress = -1
        continue
      }
      switch progress {
      case -2:
        continue
      case -1:
        if byte == 0x20 || byte == 0x09 { continue }
        progress = byte == marker[0] ? 1 : -2
      default:
        if byte == marker[progress] {
          progress += 1
        } else {
          progress = -2
        }
      }
      if progress == marker.count {
        return true
      }
    }
    return false
  }
}

// MARK: - FileTokens

/// Extraction output for one file: records with FILE-LOCAL intern ids plus
/// the file's local intern table. Extraction stays parallel-safe because
/// nothing here touches shared state; `CorpusAssembler` remaps the local
/// ids into the corpus interner afterwards.
struct FileTokens: Sendable {
  let file: String
  /// Records whose `rawID`/`normID` index into `strings`.
  let records: [TokenRecord]
  /// File-local intern table: id -> token text.
  let strings: [String]
  /// Token kind lane (1 byte/token), used by the structural shingler.
  let kinds: [TokenKind]
  /// Indices of tokens that begin a new top-level declaration (ascending).
  let boundaries: [Int]
  /// Macro-expansion marker (see `SourceText.containsSourceLocationDirective`).
  let hasSourceLocationDirective: Bool
  /// Lazy text provider for snippets and directive context.
  let text: SourceText
}

// MARK: - TokenSequence

/// One file inside an assembled corpus: identical layout to `FileTokens`
/// but ids index the corpus intern table.
struct TokenSequence: Sendable {
  let file: String
  let records: [TokenRecord]
  let kinds: [TokenKind]
  let boundaries: [Int]
  let hasSourceLocationDirective: Bool
  let text: SourceText

  var tokenCount: Int { records.count }
}

// MARK: - TokenCorpus

/// The whole corpus: per-file records over one shared intern table. The
/// intern table IS the suffix-array alphabet — ids map to stream symbols
/// directly, separators live above `strings.count`.
struct TokenCorpus: Sendable {
  let sequences: [TokenSequence]
  /// Corpus intern table: id -> token text (raw and normalized forms).
  let strings: [String]

  /// The text for a corpus id — reporting-time only.
  func text(of id: UInt32) -> String {
    strings[Int(id)]
  }
}

// MARK: - CorpusAssembler

/// Merges per-file intern tables into the corpus interner and remaps every
/// record. One serial pass over all tokens; the per-file tables are small
/// (distinct texts, not tokens), so the dictionary stays compact.
enum CorpusAssembler {
  static func assemble(files: [FileTokens]) -> TokenCorpus {
    var table: [String: UInt32] = [:]
    var strings: [String] = []
    var sequences: [TokenSequence] = []
    sequences.reserveCapacity(files.count)

    for file in files {
      // Local id -> corpus id.
      var remap = [UInt32](repeating: 0, count: file.strings.count)
      for (localID, string) in file.strings.enumerated() {
        if let existing = table[string] {
          remap[localID] = existing
        } else {
          let id = UInt32(strings.count)
          table[string] = id
          strings.append(string)
          remap[localID] = id
        }
      }

      var records = file.records
      for index in records.indices {
        records[index].rawID = remap[Int(records[index].rawID)]
        records[index].normID = remap[Int(records[index].normID)]
      }

      sequences.append(
        TokenSequence(
          file: file.file,
          records: records,
          kinds: file.kinds,
          boundaries: file.boundaries,
          hasSourceLocationDirective: file.hasSourceLocationDirective,
          text: file.text
        ))
    }

    return TokenCorpus(sequences: sequences, strings: strings)
  }
}
