// swift-format-ignore-file
// Uniform accumulator folds differing in sparse operators: below near-clone
// window identity, above the structural similarity threshold.
struct ChecksumB {
    func fold(_ values: [Int]) -> Int {
        var acc = 0
        acc += values[0] &* 1
        acc += values[1] &* 2
        acc += values[2] &* 3
        acc += values[3] &+ 4
        acc += values[4] &* 5
        acc += values[5] &* 6
        acc += values[6] &* 7
        acc += values[7] &* 8
        acc += values[8] &* 9
        acc += values[9] &+ 10
        acc += values[10] &* 11
        acc += values[11] &* 12
        acc += values[12] &* 13
        acc += values[13] &* 14
        acc += values[14] &* 15
        acc += values[15] &+ 16
        acc += values[16] &* 17
        acc += values[17] &* 18
        acc += values[18] &* 19
        acc += values[19] &* 20
        acc += values[20] &* 21
        acc += values[21] &+ 22
        acc += values[22] &* 23
        acc += values[23] &* 24
        acc += values[24] &* 25
        acc += values[25] &* 26
        acc += values[26] &* 27
        acc += values[27] &+ 28
        acc += values[28] &* 29
        acc += values[29] &* 30
        acc += values[30] &* 31
        acc += values[31] &* 32
        acc += values[32] &* 33
        acc += values[33] &+ 34
        acc += values[34] &* 35
        acc += values[35] &* 36
        return acc
    }
}
