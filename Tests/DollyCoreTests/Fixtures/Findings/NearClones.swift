// swift-format-ignore-file
// The same logic under different names and literals: a Type-2 clone.
// Identifiers and literals normalize away; the token shape is identical.

func summarizeQuarterlyRevenue(figures: [Double]) -> String {  // #dl:expect near-clone
    var runningTotal = 0.0
    var peakValue = 0.0
    for figure in figures {
        runningTotal += figure * 1.08
        if figure > peakValue {
            peakValue = figure
        }
    }
    let headline = "Q revenue: \(runningTotal) peak \(peakValue)"
    return headline
}

func describeAnnualHeadcount(counts: [Double]) -> String {
    var aggregateSum = 0.0
    var largestTeam = 0.0
    for count in counts {
        aggregateSum += count * 2.75
        if count > largestTeam {
            largestTeam = count
        }
    }
    let summary = "Yearly heads: \(aggregateSum) top \(largestTeam)"
    return summary
}
