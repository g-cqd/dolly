//  RollingWindows.swift
//  dolly
//
//  Shared machinery for the rolling-hash clone detectors: window scanning
//  and hash-bucket grouping, parameterized by the window representation, so
//  the exact and near detectors carry only their genuinely distinct parts.

// MARK: - RollingHash

/// Rabin-Karp rolling hash implementation.
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

  /// Compute initial hash for a window of tokens.
  func initialHash(_ tokens: [String]) -> UInt64 {
    var hash: UInt64 = 0
    for token in tokens.prefix(windowSize) {
      hash = (hash &* Self.base &+ tokenHash(token)) % Self.prime
    }
    return hash
  }

  /// Roll the hash forward by removing `outgoing` and adding `incoming`.
  func roll(hash: UInt64, outgoing: String, incoming: String) -> UInt64 {
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

  /// Hash a single token string.
  private func tokenHash(_ token: String) -> UInt64 {
    var hash: UInt64 = 0
    for char in token.utf8 {
      hash = (hash &* 31 &+ UInt64(char)) % Self.prime
    }
    return hash
  }
}

// MARK: - RollingWindows

enum RollingWindows {
  /// Slide a `windowSize` window over `texts`, invoking `makeWindow` with
  /// each start index and its rolled hash.
  static func scan<Window>(
    texts: [String],
    windowSize: Int,
    makeWindow: (_ startIndex: Int, _ hash: UInt64) -> Window
  ) -> [Window] {
    guard windowSize > 0, texts.count >= windowSize else { return [] }

    let rollingHash = RollingHash(windowSize: windowSize)
    var windows: [Window] = []
    windows.reserveCapacity(texts.count - windowSize + 1)

    var hash = rollingHash.initialHash(Array(texts.prefix(windowSize)))
    windows.append(makeWindow(0, hash))

    let maxStartIndex = texts.count - windowSize
    guard maxStartIndex >= 1 else { return windows }
    for i in 1...maxStartIndex {
      hash = rollingHash.roll(
        hash: hash, outgoing: texts[i - 1], incoming: texts[i + windowSize - 1])
      windows.append(makeWindow(i, hash))
    }

    return windows
  }

  /// Bucket windows by hash, verify real matches within each bucket, and
  /// build deduplicated clone groups via `makeGroup` (return nil to drop
  /// a group, e.g. below a similarity threshold).
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
