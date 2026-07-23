//  TaskCooperation.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)

/// Cooperative cancellation helpers for CPU-bound async work.
enum TaskCooperation {
  /// Yield periodically and report whether the current task should stop.
  ///
  /// - Parameters:
  ///   - iteration: Current loop iteration counter, starting at 1.
  ///   - interval: Yield cadence. Defaults to 256 iterations.
  /// - Returns: `true` when the current task is cancelled and the caller should stop.
  static func checkpoint(
    iteration: Int,
    every interval: Int = 256
  ) async -> Bool {
    if Task.isCancelled {
      return true
    }

    guard interval > 0, iteration.isMultiple(of: interval) else {
      return false
    }

    await Task.yield()
    return Task.isCancelled
  }
}
