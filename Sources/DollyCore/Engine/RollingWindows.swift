//  RollingWindows.swift
//  dolly
//
//  Shared machinery for the rolling-hash clone detectors: window scanning,
//  hash-bucket grouping, and the full detect pipeline, parameterized by the
//  id lane and the group policy, so the exact and near detectors carry only
//  their genuinely distinct parts. Since D2 the hash rolls over interned
//  UInt32 ids — no per-token string hashing.

// MARK: - RollingHash

/// Rabin-Karp rolling hash over interned token ids.
struct RollingHash: Sendable {
  /// Large prime for modulo operations.
  private static let prime: UInt64 = 1_000_000_007

  /// Base for polynomial rolling hash.
  private static let base: UInt64 = 31

  /// Precomputed power of base^windowSize mod prime.
  private let highestPower: UInt64

  /// Window size (number of tokens).
  private let windowSize: Int

  init(windowSize: Int) {
    self.windowSize = windowSize

    // Precompute base^(windowSize-1) mod prime
    var power: UInt64 = 1
    for _ in 0..<(windowSize - 1) {
      power = (power &* Self.base) % Self.prime
    }
    highestPower = power
  }

  /// Compute the initial hash for the window `ids[0..<windowSize]`.
  func initialHash(count: Int, idAt: (Int) -> UInt32) -> UInt64 {
    var hash: UInt64 = 0
    for index in 0..<min(windowSize, count) {
      hash = (hash &* Self.base &+ tokenHash(idAt(index))) % Self.prime
    }
    return hash
  }

  /// Roll the hash forward by removing `outgoing` and adding `incoming`.
  func roll(hash: UInt64, outgoing: UInt32, incoming: UInt32) -> UInt64 {
    let outHash = tokenHash(outgoing)
    let inHash = tokenHash(incoming)

    // Remove outgoing token's contribution
    var newHash = hash
    let outContrib = (outHash &* highestPower) % Self.prime
    if newHash >= outContrib {
      newHash -= outContrib
    } else {
      newHash = Self.prime - (outContrib - newHash)
    }

    // Shift and add incoming
    newHash = ((newHash &* Self.base) + inHash) % Self.prime
    return newHash
  }

  /// Hash a single interned id. `+1` keeps id 0 from being transparent to
  /// the polynomial.
  private func tokenHash(_ id: UInt32) -> UInt64 {
    (UInt64(id) &+ 1) % Self.prime
  }
}

// MARK: - RecordLane

/// Which id lane of a record a detector reads: raw ids give Type-1
/// identity, normalized ids give Type-2 identity.
enum RecordLane: Sendable {
  case raw
  case norm

  func id(of record: TokenRecord) -> UInt32 {
    switch self {
    case .raw: record.rawID
    case .norm: record.normID
    }
  }
}

// MARK: - RecordWindow

/// A fixed-size window over a file's interned records — a view into the
/// owning file's storage, never a copy. Hashing and verification both run
/// on the window's lane.
struct RecordWindow: Sendable, GroupableWindow {
  let file: String
  let hash: UInt64
  let startIndex: Int
  let endIndex: Int
  let startLine: Int
  let startColumn: Int
  let endLine: Int
  let records: ArraySlice<TokenRecord>
  let lane: RecordLane

  func matches(_ other: Self) -> Bool {
    records.count == other.records.count
      && zip(records, other.records).allSatisfy { lane.id(of: $0) == lane.id(of: $1) }
  }

  /// The window's raw ids, for similarity scoring over original tokens.
  var rawIDs: some Sequence<UInt32> {
    records.lazy.map(\.rawID)
  }
}

// MARK: - RollingWindows

enum RollingWindows {
  /// The full rolling-hash detect pipeline: scan every sequence into
  /// fixed-size windows on the given lane, bucket by hash, verify, and
  /// build groups via `makeGroup` (return nil to drop a group, e.g.
  /// below a similarity threshold).
  static func detect(
    in corpus: TokenCorpus,
    windowSize: Int,
    lane: RecordLane,
    makeGroup: (_ group: [RecordWindow], _ hash: UInt64) -> CloneGroup?
  ) -> [CloneGroup] {
    guard windowSize > 0 else { return [] }

    var windows: [RecordWindow] = []
    for sequence in corpus.sequences {
      let records = sequence.records
      guard records.count >= windowSize else { continue }
      windows += scan(
        count: records.count,
        windowSize: windowSize,
        idAt: { lane.id(of: records[$0]) },
        makeWindow: { start, hash in
          let end = start + windowSize
          return RecordWindow(
            file: sequence.file,
            hash: hash,
            startIndex: start,
            endIndex: end - 1,
            startLine: Int(records[start].line),
            startColumn: Int(records[start].column),
            endLine: Int(records[end - 1].line),
            records: records[start..<end],
            lane: lane
          )
        })
    }

    return detectGroups(windows: windows, overlapThreshold: windowSize / 2, makeGroup: makeGroup)
  }

  /// Slide a `windowSize` window over `count` interned ids, invoking
  /// `makeWindow` with each start index and its rolled hash.
  static func scan<Window>(
    count: Int,
    windowSize: Int,
    idAt: (Int) -> UInt32,
    makeWindow: (_ startIndex: Int, _ hash: UInt64) -> Window
  ) -> [Window] {
    guard windowSize > 0, count >= windowSize else { return [] }

    let rollingHash = RollingHash(windowSize: windowSize)
    var windows: [Window] = []
    windows.reserveCapacity(count - windowSize + 1)

    var hash = rollingHash.initialHash(count: count, idAt: idAt)
    windows.append(makeWindow(0, hash))

    let maxStartIndex = count - windowSize
    guard maxStartIndex >= 1 else { return windows }
    for i in 1...maxStartIndex {
      hash = rollingHash.roll(
        hash: hash, outgoing: idAt(i - 1), incoming: idAt(i + windowSize - 1))
      windows.append(makeWindow(i, hash))
    }

    return windows
  }

  /// Bucket windows by hash, verify real matches within each bucket, and
  /// build deduplicated clone groups via `makeGroup`.
  static func detectGroups<Window: GroupableWindow>(
    windows: [Window],
    overlapThreshold: Int,
    makeGroup: (_ group: [Window], _ hash: UInt64) -> CloneGroup?
  ) -> [CloneGroup] {
    var hashTable: [UInt64: [Window]] = [:]
    for window in windows {
      hashTable[window.hash, default: []].append(window)
    }

    var cloneGroups: [CloneGroup] = []
    for (hash, bucket) in hashTable where bucket.count >= 2 {
      // Verify actual matches (handle hash collisions)
      let verified = CloneDetectionUtilities.groupMatchingWindows(
        bucket, overlapThreshold: overlapThreshold)
      for group in verified where group.count >= 2 {
        if let cloneGroup = makeGroup(group, hash) {
          cloneGroups.append(cloneGroup)
        }
      }
    }

    return cloneGroups.deduplicated()
  }
}
