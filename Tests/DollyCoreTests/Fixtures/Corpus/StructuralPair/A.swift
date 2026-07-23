// swift-format-ignore-file
// Uniform accumulator folds differing in sparse operators: below near-clone
// window identity, above the structural similarity threshold.
struct ChecksumA {
    func fold(_ values: [Int]) -> Int {
        var total = 0
        total += values[0] &* 1
        total += values[1] &* 2
        total += values[2] &* 3
        total += values[3] &* 4
        total += values[4] &* 5
        total += values[5] &* 6
        total += values[6] &* 7
        total += values[7] &* 8
        total += values[8] &* 9
        total += values[9] &* 10
        total += values[10] &* 11
        total += values[11] &* 12
        total += values[12] &* 13
        total += values[13] &* 14
        total += values[14] &* 15
        total += values[15] &* 16
        total += values[16] &* 17
        total += values[17] &* 18
        total += values[18] &* 19
        total += values[19] &* 20
        total += values[20] &* 21
        total += values[21] &* 22
        total += values[22] &* 23
        total += values[23] &* 24
        total += values[24] &* 25
        total += values[25] &* 26
        total += values[26] &* 27
        total += values[27] &* 28
        total += values[28] &* 29
        total += values[29] &* 30
        total += values[30] &* 31
        total += values[31] &* 32
        total += values[32] &* 33
        total += values[33] &* 34
        total += values[34] &* 35
        total += values[35] &* 36
        return total
    }
}
