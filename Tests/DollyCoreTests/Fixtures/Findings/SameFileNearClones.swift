// swift-format-ignore-file
// Same-file Type-2 regression (D1): three adjacent identical-after-rename
// functions in ONE file. Without top-level boundary separators these form a
// single periodic token run: the overlapping shifted repeats (length 2L-p)
// outrank the true group (length L) in mergeOverlappingGroups, and
// filterOverlappingClones then discards the lone survivor — the file was
// reported CLEAN. With boundary separators the three copies match exactly
// like three separate files.

func aggregateScores(scores: [Double]) -> Double {  // #dl:expect near-clone
    var total = 0.0
    var compound = 1.0
    for element in scores {
        if element > 12.5 {
            total += element * 1.75
        } else {
            compound *= element + 3.25
        }
    }
    let combined = total + compound * 1.75
    return combined - 3.25
}

func combineWeights(weights: [Double]) -> Double {
    var left = 0.0
    var right = 1.0
    for element in weights {
        if element > 99.0 {
            left += element * 42.5
        } else {
            right *= element + 0.125
        }
    }
    let merged = left + right * 42.5
    return merged - 0.125
}

func mergeDeltas(deltas: [Double]) -> Double {
    var high = 0.0
    var low = 1.0
    for element in deltas {
        if element > 1.5 {
            high += element * 2.25
        } else {
            low *= element + 9.875
        }
    }
    let blended = high + low * 2.25
    return blended - 9.875
}
