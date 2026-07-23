//  ShingleGenerator.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  D2: shingles hash interned ids with integer FNV — no per-token string
//  materialization, no per-window token copies. A shingle is a hash plus
//  its position, nothing else.

// MARK: - Shingle

/// A shingle (n-gram) of tokens: its hash and starting position.
struct Shingle: Sendable, Hashable {
  /// Hash value of the shingle.
  let hash: UInt64

  /// Starting position in the token sequence.
  let position: Int
}

// MARK: - ShingledDocument

/// A document (code block) represented as a set of shingles.
struct ShingledDocument: Sendable {
  // MARK: Lifecycle

  init(
    file: String,
    startLine: Int,
    startColumn: Int = 1,
    endLine: Int,
    tokenCount: Int,
    shingleHashes: Set<UInt64>,
    shingles: [Shingle],
    id: Int
  ) {
    self.file = file
    self.startLine = startLine
    self.startColumn = startColumn
    self.endLine = endLine
    self.tokenCount = tokenCount
    self.shingleHashes = shingleHashes
    self.shingles = shingles
    self.id = id
  }

  // MARK: Public

  /// Source file path.
  let file: String

  /// Starting line in the file.
  let startLine: Int

  /// Column of the first token (1-based).
  let startColumn: Int

  /// Ending line in the file.
  let endLine: Int

  /// Token count.
  let tokenCount: Int

  /// Set of shingle hashes (for MinHash).
  let shingleHashes: Set<UInt64>

  /// All shingles with position info (for alignment).
  let shingles: [Shingle]

  /// Unique identifier for this document.
  let id: Int
}

// MARK: - ShingleGenerator

/// Generates shingles from interned token records.
struct ShingleGenerator: Sendable {
  // MARK: Lifecycle

  init(shingleSize: Int = 5, normalize: Bool = true) {
    self.shingleSize = max(1, shingleSize)
    self.normalize = normalize
  }

  // MARK: Public

  /// Size of each shingle (number of tokens).
  let shingleSize: Int

  /// Whether to normalize identifiers/literals.
  let normalize: Bool

  /// Tag bits distinguishing normalized ordinal codes from raw ids.
  /// Raw corpus ids are < 2^32, so codes with either tag can never
  /// collide with them (or with each other).
  private static let identifierTag: UInt64 = 1 &<< 33
  private static let literalTag: UInt64 = 1 &<< 34

  /// Generate shingles from a slice of interned records.
  ///
  /// Normalization assigns positional first-occurrence ordinals to
  /// identifiers and literals over the WHOLE slice (rawID-keyed — text
  /// and rawID are bijective corpus-wide), so renamed identifiers and
  /// changed literals compare equal while distinct names stay
  /// distinguishable within the block. This mirrors the pre-D2 string
  /// placeholders (`$ID0`, `$LIT0`, ...) exactly; deliberately NOT the
  /// corpus-uniform `normID` lane, which would conflate all identifiers
  /// and loosen the structural stage's precision.
  func generate(
    records: ArraySlice<TokenRecord>, kinds: ArraySlice<TokenKind>
  ) -> [Shingle] {
    guard records.count >= shingleSize else { return [] }

    var codes: [UInt64] = []
    codes.reserveCapacity(records.count)
    if normalize {
      var identifierOrdinals: [UInt32: UInt64] = [:]
      var literalOrdinals: [UInt32: UInt64] = [:]
      for (record, kind) in zip(records, kinds) {
        switch kind {
        case .identifier:
          if let ordinal = identifierOrdinals[record.rawID] {
            codes.append(Self.identifierTag | ordinal)
          } else {
            let ordinal = UInt64(identifierOrdinals.count)
            identifierOrdinals[record.rawID] = ordinal
            codes.append(Self.identifierTag | ordinal)
          }
        case .literal:
          if let ordinal = literalOrdinals[record.rawID] {
            codes.append(Self.literalTag | ordinal)
          } else {
            let ordinal = UInt64(literalOrdinals.count)
            literalOrdinals[record.rawID] = ordinal
            codes.append(Self.literalTag | ordinal)
          }
        case .keyword, .operator, .punctuation, .unknown:
          codes.append(UInt64(record.rawID))
        }
      }
    } else {
      for record in records {
        codes.append(UInt64(record.rawID))
      }
    }

    var shingles: [Shingle] = []
    shingles.reserveCapacity(codes.count - shingleSize + 1)

    let windowCount = codes.count - shingleSize + 1
    for i in 0..<windowCount {
      let hash = Self.computeShingleHash(codes[i..<(i + shingleSize)])
      shingles.append(Shingle(hash: hash, position: i))
    }

    return shingles
  }

  /// Generate shingled documents from code blocks within a file.
  ///
  /// This breaks the file into logical blocks (50%-overlap windows) for
  /// comparison.
  ///
  /// - Parameters:
  ///   - sequence: The full file token sequence.
  ///   - blockSize: Minimum tokens per block.
  ///   - startId: Starting ID for documents.
  /// - Returns: Array of shingled documents.
  func generateBlockDocuments(
    from sequence: TokenSequence,
    blockSize: Int,
    startId: Int,
  ) -> [ShingledDocument] {
    let records = sequence.records
    guard records.count >= blockSize else { return [] }

    let stride = max(1, blockSize / 2)  // 50% overlap

    var documents: [ShingledDocument] = []
    documents.reserveCapacity((records.count - blockSize) / stride + 1)
    var currentId = startId

    var i = 0
    while i + blockSize <= records.count {
      let shingles = generate(
        records: records[i..<(i + blockSize)],
        kinds: sequence.kinds[i..<(i + blockSize)]
      )

      documents.append(
        ShingledDocument(
          file: sequence.file,
          startLine: Int(records[i].line),
          startColumn: Int(records[i].column),
          endLine: Int(records[i + blockSize - 1].line),
          tokenCount: blockSize,
          shingleHashes: shingleHashSet(from: shingles),
          shingles: shingles,
          id: currentId,
        ))

      currentId += 1
      i += stride
    }

    return documents
  }

  /// Build the `Set<UInt64>` of shingle hashes without the intermediate
  /// `[UInt64]` that `Set(shingles.map(\.hash))` would allocate. Reserves
  /// up to `shingles.count` slots since hash collisions are negligible.
  private func shingleHashSet(from shingles: [Shingle]) -> Set<UInt64> {
    var hashes = Set<UInt64>()
    hashes.reserveCapacity(shingles.count)
    for shingle in shingles {
      hashes.insert(shingle.hash)
    }
    return hashes
  }

  // MARK: Private

  /// Integer FNV-1a over the window's codes: each 64-bit code is mixed
  /// as one word. Replaces the per-string UTF-8 byte loops; equality of
  /// code streams — the property the structural stage depends on — is
  /// preserved because the code encoding is injective.
  private static func computeShingleHash(_ codes: ArraySlice<UInt64>) -> UInt64 {
    var hash = FNV1a.offsetBasis
    for code in codes {
      hash ^= code
      hash = hash &* FNV1a.prime
    }
    return hash
  }
}

// MARK: - Character Shingles

extension ShingleGenerator {
  /// Generate character-level shingles (k-grams of characters).
  ///
  /// This is useful for detecting clones with minor textual differences.
  ///
  /// - Parameters:
  ///   - text: The source text.
  ///   - k: The shingle size in characters.
  /// - Returns: Set of shingle hashes.
  func generateCharacterShingles(from text: String, k: Int = 9) -> Set<UInt64> {
    let chars = Array(text)
    guard chars.count >= k else { return [] }

    var hashes = Set<UInt64>()

    for i in 0...(chars.count - k) {
      let shingle = String(chars[i..<(i + k)])
      hashes.insert(FNV1a.hash(shingle))
    }

    return hashes
  }
}
