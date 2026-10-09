// swift-format-ignore-file
// The other half of the cross-file exact clone.
import Foundation

struct ExportPipeline {
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
