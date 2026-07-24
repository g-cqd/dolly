// A Type-4 (semantic) clone fixture: same behavior, functional idiom.
// Pairs with Loop.swift — identical result (sum of the values), different
// token shape (reduce vs a for-loop). Never formatted (fixture resource).
enum ReduceMath {
  func totalOfValues(_ values: [Int]) -> Int {
    let total = values.reduce(0) { runningTotal, value in
      runningTotal + value
    }
    return total
  }
}
