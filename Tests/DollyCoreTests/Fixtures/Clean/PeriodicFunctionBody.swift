// swift-format-ignore-file
// Uniform periodic literal run INSIDE one function: self-similar content,
// not duplication. The 8-statement run is ~64 tokens, so its shifted
// self-matches clear the 50-token near-clone floor — top-level boundary
// separators must not break the within-declaration periodic protection
// that keeps this silent.
func checksumTable(_ values: [Int]) -> Int {
    var total = 0
    total += values[0] &* 3
    total += values[1] &* 3
    total += values[2] &* 3
    total += values[3] &* 3
    total += values[4] &* 3
    total += values[5] &* 3
    total += values[6] &* 3
    total += values[7] &* 3
    return total
}
