// swift-format-ignore-file
// Larger functions with genuinely different shapes: no clones here.

enum Shape {
    case circle(radius: Double)
    case rectangle(width: Double, height: Double)
    case triangle(base: Double, height: Double)
}

func area(of shape: Shape) -> Double {
    switch shape {
    case .circle(let radius):
        return Double.pi * radius * radius
    case .rectangle(let width, let height):
        return width * height
    case .triangle(let base, let height):
        return base * height / 2
    }
}

struct RingBuffer {
    private var storage: [Int?]
    private var head = 0
    private var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    mutating func push(_ element: Int) {
        let index = (head + count) % storage.count
        storage[index] = element
        if count == storage.count {
            head = (head + 1) % storage.count
        } else {
            count += 1
        }
    }

    mutating func pop() -> Int? {
        guard count > 0 else { return nil }
        defer {
            storage[head] = nil
            head = (head + 1) % storage.count
            count -= 1
        }
        return storage[head]
    }
}

func histogram(of words: [String]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for word in words where !word.isEmpty {
        counts[word.lowercased(), default: 0] += 1
    }
    return counts
}
