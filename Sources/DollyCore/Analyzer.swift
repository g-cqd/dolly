import Foundation
import SwiftParser
import SwiftSyntax

/// Entry point of the pipeline: reads each file with a bounded reader, scans
/// suppression directives, extracts token sequences, runs the duplication
/// engine across the whole corpus, and assembles the report.
///
/// Duplication is a corpus-level property, so findings are produced from the
/// full set of files at once; the single-source entry point runs the same
/// engine over a corpus of one so unit tests and golden fixtures exercise
/// the identical path.
public struct Analyzer: Sendable {
    /// Files above this cap are reported degraded rather than read into RAM.
    public static let sourceByteCap = 10 * 1024 * 1024

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public func analyze(files: [String]) async -> AnalysisReport {
        var report = AnalysisReport()
        report.analyzedFileCount = files.count

        var prepared: [PreparedFile] = []
        do {
            let outcomes = try await ParallelProcessor.map(
                files,
                maxConcurrency: ConcurrencyConfiguration.default.maxConcurrentFiles
            ) { path -> FileOutcome in
                let data: Data
                do {
                    data = try BoundedFileReader.read(path: path, cap: Self.sourceByteCap)
                } catch {
                    return .degraded(
                        .init(path: path, detail: "read failed or exceeds size cap: \(error)"))
                }
                let source = String(decoding: data, as: UTF8.self)
                return .prepared(Self.prepare(source: source, path: path))
            }
            for outcome in outcomes {
                switch outcome {
                case .prepared(let file): prepared.append(file)
                case .degraded(let degraded): report.degradedFiles.append(degraded)
                }
            }
        } catch {
            // The per-file operation handles its own failures; only a
            // cancelled or torn-down task group lands here. Mark the run
            // degraded rather than pretending it completed.
            report.degradedFiles.append(
                .init(path: "<corpus>", detail: "analysis interrupted: \(error)"))
            return report
        }

        await runEngine(over: prepared, into: &report)
        report.findings.sort()
        return report
    }

    public func analyze(source: String, path: String) async -> AnalysisReport {
        var report = AnalysisReport()
        report.analyzedFileCount = 1
        await runEngine(over: [Self.prepare(source: source, path: path)], into: &report)
        report.findings.sort()
        return report
    }

    // MARK: - Pipeline stages

    /// Everything the corpus pass needs per file: the token sequence for the
    /// engine and the suppression table for finding attribution.
    private struct PreparedFile: Sendable {
        let sequence: TokenSequence
        let table: SuppressionTable
    }

    private enum FileOutcome: Sendable {
        case prepared(PreparedFile)
        case degraded(AnalysisReport.DegradedFile)
    }

    /// Parse once; derive directives and the token sequence from that tree.
    private static func prepare(source: String, path: String) -> PreparedFile {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let directives = DirectiveScanner.scan(tree: tree, converter: converter)
        let sequence = TokenSequenceExtractor().extract(from: tree, file: path, source: source)
        return PreparedFile(sequence: sequence, table: SuppressionTable(directives: directives))
    }

    /// Run the duplication engine across the corpus and partition results
    /// into findings and suppressed findings.
    private func runEngine(over prepared: [PreparedFile], into report: inout AnalysisReport) async {
        let enabledTypes = Set(
            RuleID.allCases.filter(configuration.isEnabled).map(CloneReporting.cloneType(for:)))
        guard !enabledTypes.isEmpty, !prepared.isEmpty else { return }

        let detector = DuplicationDetector(
            configuration: DuplicationConfiguration(
                minimumTokens: configuration.duplication?.minimumTokens ?? 50,
                cloneTypes: enabledTypes,
                minimumSimilarity: configuration.duplication?.minimumSimilarity ?? 0.8
            )
        )
        let groups = await detector.detectClones(in: prepared.map(\.sequence))
        let tables = prepared.keyed(by: \.sequence.file).mapValues(\.table)

        for finding in CloneReporting.findings(from: groups, configuration: configuration) {
            // A finding is suppressed when the anchor file's directives
            // cover the anchor line.
            if let reason = tables[finding.path]?.suppression(for: finding.rule, line: finding.line)
            {
                report.suppressed.append(.init(finding: finding, reason: reason))
            } else {
                report.findings.append(finding)
            }
        }
    }
}
