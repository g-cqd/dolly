// swift-format-ignore-file
// Distinct small helpers, each below the 50-token clone threshold.

func clamp(_ value: Int, low: Int, high: Int) -> Int {
    min(max(value, low), high)
}

func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

func initials(from name: String) -> String {
    name.split(separator: " ").compactMap(\.first).map(String.init).joined()
}

func isPalindrome(_ word: String) -> Bool {
    let letters = Array(word.lowercased())
    return letters == letters.reversed()
}
