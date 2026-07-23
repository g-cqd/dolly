//  AtomicBitmap.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

import Synchronization

// MARK: - AtomicWord

/// Heap-allocated wrapper around a single `Atomic<UInt64>`.
///
/// `Atomic` is `~Copyable`, so it can't sit directly in an Array. Wrapping it
/// in a small reference type gives the storage equivalent of swift-atomics'
/// `ManagedAtomic<UInt64>` while keeping the codebase on the stdlib
/// `Synchronization` module.
private final class AtomicWord: Sendable {
    let value: Atomic<UInt64>

    init(_ initial: UInt64 = 0) {
        self.value = Atomic<UInt64>(initial)
    }
}

// MARK: - AtomicBitmap

/// Thread-safe bitmap for parallel BFS visited tracking.
///
/// Uses stdlib `Atomic<UInt64>` (via `AtomicWord`) for lock-free concurrent
/// access. The class itself is plain `Sendable` because every stored
/// property is `let` and the wrapped atomic-word references are themselves
/// `Sendable`.
///
/// ## Performance Characteristics
///
/// - `testAndSet`: O(1) with atomic fetch-or
/// - `test`: O(1) atomic load
/// - Memory: ~n/8 bytes for n bits plus per-word reference overhead
final class AtomicBitmap: Sendable {
    /// Number of bits in the bitmap.
    let size: Int

    private let storage: [AtomicWord]
    private let wordCount: Int

    /// Create a bitmap with the given number of bits, all initially unset.
    init(size: Int) {
        precondition(size >= 0, "Bitmap size must be non-negative")
        self.size = size
        self.wordCount = (size + 63) / 64
        self.storage = (0..<wordCount).map { _ in AtomicWord() }
    }

    /// Atomically test and set a bit.
    ///
    /// - Parameter index: The bit index to set.
    /// - Returns: `true` if the bit was previously unset (and is now set),
    ///            `false` if it was already set.
    ///
    /// This operation is atomic and thread-safe using fetch-or.
    @inline(__always)
    func testAndSet(_ index: Int) -> Bool {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        // Atomic fetch-or: sets the bit and returns the OLD value
        let (oldValue, _) = storage[wordIndex].value.bitwiseOr(mask, ordering: .relaxed)

        // Return true if the bit was previously unset
        return (oldValue & mask) == 0
    }

    /// Check if a bit is set (atomic read).
    ///
    /// - Parameter index: The bit index to check.
    /// - Returns: `true` if the bit is set, `false` otherwise.
    @inline(__always)
    func test(_ index: Int) -> Bool {
        precondition(index >= 0 && index < size, "Bitmap index out of bounds")

        let wordIndex = index / 64
        let bitIndex = index % 64
        let mask: UInt64 = 1 << bitIndex

        return (storage[wordIndex].value.load(ordering: .relaxed) & mask) != 0
    }
}
