//  CloneReporting.swift
//  dolly
//
//  Converts engine `CloneGroup`s into pipeline `Finding`s: one finding per
//  group, anchored at the group's first member in deterministic order, with
//  every other member listed in the note.

enum CloneReporting {
    /// Precedence order between clone types: an exact clone is also a near
    /// clone, and both trip the structural detector. Reporting all three
    /// for the same region would triple the noise, so lower-precedence
    /// groups fully covered by higher-precedence claims are dropped.
    private static let precedence: [CloneType] = [.exact, .near, .structural]

    /// A member counts as covered when at least this fraction of its lines
    /// is claimed by higher-precedence groups.
    private static let coverageThreshold = 0.5

    static func rule(for type: CloneType) -> RuleID {
        switch type {
        case .exact: .exactClone
        case .near: .nearClone
        case .structural: .structuralClone
        }
    }

    static func cloneType(for rule: RuleID) -> CloneType {
        switch rule {
        case .exactClone: .exact
        case .nearClone: .near
        case .structuralClone: .structural
        }
    }

    /// Convert clone groups into findings: precedence-filter, then emit one
    /// finding per surviving group.
    static func findings(from groups: [CloneGroup], configuration: Configuration) -> [Finding] {
        filterByPrecedence(normalize(groups)).map { group in
            let members = group.clones
            let anchor = members[0]
            let rule = Self.rule(for: group.type)
            let tokens = members.map(\.tokenCount).min() ?? anchor.tokenCount
            let similarity = formattedSimilarity(group.similarity)
            let others = members.dropFirst()
                .map { "\($0.file):\($0.startLine)" }
                .joined(separator: ", ")
            return Finding(
                rule: rule,
                severity: configuration.severity(for: rule),
                path: anchor.file,
                line: anchor.startLine,
                column: anchor.startColumn,
                message:
                    "\(members.count) duplicated regions of ~\(tokens) tokens (similarity \(similarity))",
                note: "duplicates: \(others)"
            )
        }
    }

    /// Two-decimal similarity, locale-free (`String(format:)` is variadic
    /// C interop, which strict memory safety rejects; number formatters are
    /// locale-dependent).
    private static func formattedSimilarity(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        let whole = hundredths / 100
        let fraction = hundredths % 100
        return "\(whole)." + (fraction < 10 ? "0\(fraction)" : "\(fraction)")
    }

    // MARK: - Normalization

    /// Deterministic member and group order. Detector output order can vary
    /// (hash-table and task-group iteration); membership cannot. Sorting
    /// makes the anchor — and therefore suppression and golden expectations
    /// — stable across runs.
    private static func normalize(_ groups: [CloneGroup]) -> [CloneGroup] {
        groups.map { group in
            CloneGroup(
                type: group.type,
                clones: group.clones.sorted { lhs, rhs in
                    if lhs.file != rhs.file { return lhs.file < rhs.file }
                    if lhs.startLine != rhs.startLine { return lhs.startLine < rhs.startLine }
                    if lhs.startColumn != rhs.startColumn {
                        return lhs.startColumn < rhs.startColumn
                    }
                    return lhs.endLine < rhs.endLine
                },
                similarity: group.similarity,
                fingerprint: group.fingerprint
            )
        }
        .sorted { lhs, rhs in
            guard let l = lhs.clones.first, let r = rhs.clones.first else {
                return lhs.fingerprint < rhs.fingerprint
            }
            if l.file != r.file { return l.file < r.file }
            if l.startLine != r.startLine { return l.startLine < r.startLine }
            return lhs.fingerprint < rhs.fingerprint
        }
    }

    // MARK: - Precedence filtering

    /// Drop a group when every member is mostly covered, line-wise, by the
    /// regions of higher-precedence groups. Groups of the same type never
    /// suppress each other.
    private static func filterByPrecedence(_ groups: [CloneGroup]) -> [CloneGroup] {
        var claimed: [String: [ClosedRange<Int>]] = [:]
        var kept: [CloneGroup] = []

        for type in precedence {
            let level = groups.filter { $0.type == type }.deduplicated()
            var levelClaims: [String: [ClosedRange<Int>]] = [:]
            for group in level {
                let allCovered = group.clones.allSatisfy { member in
                    coverage(of: member, in: claimed) >= coverageThreshold
                }
                if allCovered { continue }
                kept.append(group)
                for member in group.clones {
                    levelClaims[member.file, default: []].append(member.startLine...member.endLine)
                }
            }
            // Merge this level's claims after the level completes so groups
            // of equal precedence don't suppress one another.
            for (file, ranges) in levelClaims {
                claimed[file] = mergedRanges(claimed[file, default: []] + ranges)
            }
        }

        return kept
    }

    /// Fraction of the member's lines already claimed.
    private static func coverage(of member: Clone, in claimed: [String: [ClosedRange<Int>]]) -> Double {
        guard let ranges = claimed[member.file] else { return 0 }
        let span = member.startLine...member.endLine
        var covered = 0
        for range in ranges {
            let low = max(range.lowerBound, span.lowerBound)
            let high = min(range.upperBound, span.upperBound)
            if low <= high { covered += high - low + 1 }
        }
        return Double(covered) / Double(span.count)
    }

    /// Merge into sorted, disjoint ranges so coverage never double-counts.
    private static func mergedRanges(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
