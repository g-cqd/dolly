// swift-format-ignore-file
// One half of a cross-file exact clone; the anchor (first member) is here.
import Foundation

struct ImportPipeline {
    func normalizeRecords(_ records: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for record in records {
            let trimmed = record.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            output.append(trimmed)
        }
        return output.sorted()
    }
}
