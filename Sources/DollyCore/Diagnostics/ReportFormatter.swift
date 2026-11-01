import ProjectModel
public import ReportSupport

public typealias OutputFormat = ReportOutputFormat

/// dolly's reports in the shared formats; the renderers are analyzerkit's `ToolReportFormat`.
public enum ReportFormatter: ToolReportFormat {
  public typealias Report = AnalysisReport

  public static let toolName = ToolInfo.name
  public static let toolVersion = ToolInfo.version
  public static let informationURI = ToolInfo.informationURI
  public static let byteOrderMark = SarifColumns.ByteOrderMark.parsed
  public static let readCap = Analyzer.sourceByteCap

  public static var sarifRules: [Sarif.Rule] {
    RuleID.allCases.map {
      Sarif.Rule(
        id: $0.rawValue,
        shortDescription: Sarif.Text($0.summary),
        help: Sarif.Text($0.explanation)
      )
    }
  }
}

extension Finding: ReportedFinding {
  public var severityName: String { severity.rawValue }
  public var ruleName: String { rule.rawValue }
  public var displayMessage: String { note.map { "\(message) — \($0)" } ?? message }
  // One location per clone-group member beyond the anchor, so a consumer can jump to every duplicate.
  public var relatedLocations: [ReportedLocation] {
    related.map {
      ReportedLocation(path: $0.path, line: $0.line, column: $0.column, message: "duplicate region")
    }
  }
}

extension AnalysisReport.DegradedFile: ReportedDegradedFile {
  public var displayText: String { "file skipped: \(detail)" }
}

extension AnalysisReport: ToolReport {
  public var suppressedCount: Int { suppressed.count }

  public var leadingRunNotes: [RunNote] {
    var notes: [RunNote] = []
    if let note = contextNote {
      notes.append(RunNote(code: "context", severity: "note", message: note))
    }
    if let note = cacheNote {
      notes.append(RunNote(code: "cache", severity: "note", message: note))
    }
    return notes
  }
}
