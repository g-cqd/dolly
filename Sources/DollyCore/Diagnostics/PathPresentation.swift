#if canImport(FoundationEssentials)
  internal import FoundationEssentials
#else
  internal import Foundation
#endif

extension AnalysisReport {
  /// Rewrites every reported path to be relative to `root`.
  ///
  /// Analysis works in absolute paths — that is the only spelling that
  /// identifies a file unambiguously (see `SourcePath`). But *reporting* in
  /// absolute paths makes the output machine-specific, and two things depend
  /// on it not being:
  ///
  /// - `Finding.fingerprint` hashes the path, so a baseline written on a
  ///   developer's machine matches nothing in CI. Measured on a 73-file
  ///   module: analyzing the same code from a different directory moved 33 of
  ///   33 fingerprints.
  /// - GitHub code scanning resolves SARIF `uri` values against the repository
  ///   root, so absolute paths produce findings that link nowhere.
  ///
  /// Paths outside `root` are left absolute rather than escaped into `../..`
  /// chains, which no consumer resolves usefully.
  public func relativized(to root: String) -> AnalysisReport {
    let canonical = SourcePath.canonical(root)
    let prefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
    func strip(_ path: String) -> String {
      path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    var copy = self
    copy.findings = findings.map { $0.relativized(strip) }
    copy.outOfScope = outOfScope.map { $0.relativized(strip) }
    copy.suppressed = suppressed.map {
      SuppressedFinding(finding: $0.finding.relativized(strip), reason: $0.reason)
    }
    copy.degradedFiles = degradedFiles.map {
      DegradedFile(path: strip($0.path), detail: $0.detail)
    }
    return copy
  }
}

extension Finding {
  fileprivate func relativized(_ strip: (String) -> String) -> Finding {
    Finding(
      rule: rule,
      severity: severity,
      path: strip(path),
      line: line,
      column: column,
      message: message,
      // The note embeds member paths as text; rewrite them the same way so a
      // relative report never mixes both spellings.
      note: note.map { note in
        related.reduce(note) { $0.replacing($1.path, with: strip($1.path)) }
      },
      related: related.map {
        RelatedLocation(path: strip($0.path), line: $0.line, column: $0.column)
      },
      // An explicit --relative-to is an explicit anchor request, so it sets the
      // fingerprint spelling too; from the repository root it matches the
      // automatic anchor exactly.
      fingerprintPath: strip(path)
    )
  }
}

extension AnalysisReport {
  /// Rewrites every finding's `fingerprintPath` to be relative to `root`.
  ///
  /// Applied once, in the analyzer, before anything reads a fingerprint — so
  /// baselines, SARIF and the report agree, and agree across machines.
  func fingerprintsAnchored(to root: String) -> AnalysisReport {
    func anchor(_ finding: Finding) -> Finding {
      Finding(
        rule: finding.rule,
        severity: finding.severity,
        path: finding.path,
        line: finding.line,
        column: finding.column,
        message: finding.message,
        note: finding.note,
        related: finding.related,
        fingerprintPath: RepositoryRoot.relativize(finding.path, to: root)
      )
    }
    var copy = self
    copy.findings = findings.map(anchor)
    copy.outOfScope = outOfScope.map(anchor)
    copy.suppressed = suppressed.map {
      SuppressedFinding(finding: anchor($0.finding), reason: $0.reason)
    }
    return copy
  }
}
