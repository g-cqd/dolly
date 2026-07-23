//  CollectionShims.swift
//  dolly
//
//  Minimal stand-ins for the swift-algorithms / swift-collections APIs the
//  lifted engine used (`chunks(ofCount:)`, `combinations(ofCount: 2)`,
//  `uniqued(on:)`, `keyed(by:)`, `Deque`), so the engine has zero external
//  dependencies beyond SwiftSyntax.

/// Splits `0..<totalCount` into consecutive ranges of at most `chunkSize`
/// elements. Replaces `chunks(ofCount:)` at call sites that slice arrays
/// or integer ranges.
func chunkedRanges(totalCount: Int, chunkSize: Int) -> [Range<Int>] {
  guard totalCount > 0 else { return [] }
  let size = max(1, chunkSize)
  var ranges: [Range<Int>] = []
  ranges.reserveCapacity((totalCount + size - 1) / size)
  var start = 0
  while start < totalCount {
    let end = min(start + size, totalCount)
    ranges.append(start..<end)
    start = end
  }
  return ranges
}

extension Array {
  /// All unordered pairs of distinct positions, in index order. Replaces
  /// `combinations(ofCount: 2)`.
  func pairCombinations() -> [(Element, Element)] {
    guard count >= 2 else { return [] }
    var pairs: [(Element, Element)] = []
    pairs.reserveCapacity(count * (count - 1) / 2)
    for i in 0..<(count - 1) {
      for j in (i + 1)..<count {
        pairs.append((self[i], self[j]))
      }
    }
    return pairs
  }

  /// First-occurrence-wins deduplication by a derived key. Replaces
  /// `uniqued(on:)`.
  func uniquedBy<Key: Hashable>(_ key: (Element) -> Key) -> [Element] {
    var seen = Set<Key>()
    seen.reserveCapacity(count)
    return filter { seen.insert(key($0)).inserted }
  }
}

extension Sequence {
  /// Dictionary keyed by a derived key; the latest element wins on
  /// duplicate keys. Replaces swift-algorithms `keyed(by:)`.
  func keyed<Key: Hashable>(by key: (Element) -> Key) -> [Key: Element] {
    var result: [Key: Element] = [:]
    for element in self {
      result[key(element)] = element
    }
    return result
  }
}

/// FIFO queue with amortized O(1) `popFirst` — an array plus a head index,
/// compacted when the dead prefix dominates. Replaces
/// `swift-collections.Deque` for BFS worklists.
struct ArrayQueue<Element> {
  private var storage: [Element]
  private var head = 0

  init(_ elements: [Element] = []) {
    storage = elements
  }

  var isEmpty: Bool { head >= storage.count }

  mutating func append(_ element: Element) {
    storage.append(element)
  }

  mutating func popFirst() -> Element? {
    guard head < storage.count else { return nil }
    let element = storage[head]
    head += 1
    // Compact once the consumed prefix is most of the buffer.
    if head > 64, head * 2 > storage.count {
      storage.removeFirst(head)
      head = 0
    }
    return element
  }
}
