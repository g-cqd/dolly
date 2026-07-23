// swift-format-ignore-file
// Exhaustive switch ladders over one enum: parallel case arms are the
// idiomatic shape, not copy-paste. Must stay silent.
enum Severity: String { case info, warning, error, critical }

func label(for severity: Severity) -> String {
    switch severity {
    case .info: "ℹ️ info"
    case .warning: "⚠️ warning"
    case .error: "⛔️ error"
    case .critical: "🔥 critical"
    }
}

func exitCode(for severity: Severity) -> Int {
    switch severity {
    case .info: 0
    case .warning: 0
    case .error: 1
    case .critical: 2
    }
}
