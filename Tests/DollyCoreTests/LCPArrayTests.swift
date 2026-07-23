//  LCPArrayTests.swift
//  dolly — ported from SwiftStaticAnalysis DuplicationDetectorTests (MIT)

import Testing

@testable import DollyCore

@Suite("LCP array")
struct LCPArrayTests {
    @Test("Empty LCP array")
    func emptyLCP() {
        let sa = SuffixArray(tokens: [])
        let lcp = LCPArray(suffixArray: sa, tokens: [])
        #expect(lcp.array.isEmpty)
    }

    @Test("Single element LCP array")
    func singleElementLCP() {
        let tokens = [1]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)
        #expect(lcp.array == [0])
    }

    @Test("LCP array with repeated sequence")
    func lcpRepeatedSequence() {
        // "abcabc" - has repeat of length 3
        let tokens = [1, 2, 3, 1, 2, 3]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)
        #expect((lcp.array.max() ?? 0) >= 3)
    }

    @Test("Find repeats above threshold")
    func findRepeatsAboveThreshold() {
        let tokens = [1, 2, 3, 1, 2, 3, 4, 1, 2, 3]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)
        #expect(!lcp.findRepeatsAboveThreshold(3).isEmpty)
    }

    @Test("Find maximal repeats")
    func findMaximalRepeats() {
        let tokens = [1, 2, 3, 4, 5, 1, 2, 3, 4, 5]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        let repeats = lcp.findMaximalRepeats(minLength: 3)

        // Should find the repeated [1,2,3,4,5] pattern
        #expect(!repeats.isEmpty)
        let maxRepeat = repeats.max { $0.length < $1.length }
        #expect(maxRepeat?.length == 5)
        #expect(maxRepeat?.occurrences == 2)
    }

    @Test("Find repeat groups")
    func findRepeatGroups() {
        let tokens = [1, 2, 3, 1, 2, 3]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        let groups = lcp.findRepeatGroups(minLength: 3)

        #expect(!groups.isEmpty)
        if let group = groups.first {
            #expect(group.length >= 3)
            #expect(group.occurrences >= 2)
        }
    }

    @Test("Shifted sub-repeats collapse into one group")
    func shiftedSubRepeatsMerge() {
        // One long repeat of length 6 at two positions. The shifted
        // sub-repeats (length 5 at +1, length 4 at +2, ...) must not
        // surface as separate groups.
        let tokens = [1, 2, 3, 4, 5, 6, 9, 1, 2, 3, 4, 5, 6]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        let groups = lcp.findRepeatGroups(minLength: 3)
        #expect(groups.count == 1)
        #expect(groups.first?.length == 6)
        #expect(groups.first?.positions == [0, 7])
    }
}

@Suite("LCP correctness")
struct LCPCorrectnessTests {
    @Test("LCP values are correct")
    func lcpValuesCorrect() {
        let tokens = [1, 2, 1, 2, 1]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        // Verify LCP values by computing them directly
        for i in 1..<lcp.array.count {
            let pos1 = sa.array[i - 1]
            let pos2 = sa.array[i]

            var expectedLCP = 0
            while pos1 + expectedLCP < tokens.count,
                pos2 + expectedLCP < tokens.count,
                tokens[pos1 + expectedLCP] == tokens[pos2 + expectedLCP]
            {
                expectedLCP += 1
            }

            #expect(
                lcp.array[i] == expectedLCP,
                "LCP[\(i)] should be \(expectedLCP) but got \(lcp.array[i])")
        }
    }

    @Test("LCP with no common prefixes")
    func lcpNoCommonPrefixes() {
        let tokens = [5, 4, 3, 2, 1]  // Strictly descending
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)

        for i in 1..<lcp.array.count {
            #expect(lcp.array[i] == 0)
        }
    }

    @Test("LCP with long common prefix")
    func lcpLongCommonPrefix() {
        // "abcabcabc" has long common prefixes
        let tokens = [1, 2, 3, 1, 2, 3, 1, 2, 3]
        let sa = SuffixArray(tokens: tokens)
        let lcp = LCPArray(suffixArray: sa, tokens: tokens)
        #expect((lcp.array.max() ?? 0) >= 6)  // "abcabc" appears twice
    }
}
