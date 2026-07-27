/// The set of files a report is narrowed to — typically a pull request's
/// changed files.
///
/// Scoping applies to the *report*, never to the corpus. Duplication is a
/// corpus-level property: analyzing only the changed files both loses real
/// clones (the partner region lives in an untouched file) and invents ones
/// that the full corpus attributes elsewhere. Measured on a 16-file pull
/// request against a 2603-file codebase, a changed-files-only run and a
/// whole-corpus run agreed on nothing — 8 findings each, disjoint. So the
/// engine keeps seeing everything and this filters what comes out.
///
/// A clone group anchors at its lexicographically smallest member
/// (`CloneReporting.normalize`), which is arbitrary with respect to a diff.
/// Matching only the anchor would therefore drop the most interesting case:
/// code added to a changed file that duplicates something older. Membership is
/// checked across the anchor *and* every related location — on that same pull
/// request, 8 findings anchored in changed files versus 19 with a member in
/// one.
///
/// The anchor is deliberately left where it is. Re-anchoring onto the changed
/// file would move `Finding.fingerprint`, and a scoped run's fingerprints have
/// to keep matching a baseline written from an unscoped one.
public struct ReportScope: Sendable, Equatable {
  /// Canonical absolute paths, matching `Finding.path`.
  public let files: Set<String>

  public var isEmpty: Bool { files.isEmpty }

  /// Paths are canonicalized on the way in, so callers can pass whatever
  /// `git diff --name-only` produced without worrying about spelling.
  public init(files: some Sequence<String>) {
    self.files = Set(files.lazy.map(SourcePath.canonical))
  }

  /// True when the finding's anchor or any of its clone-group members is in
  /// scope.
  public func contains(_ finding: Finding) -> Bool {
    files.contains(finding.path) || finding.related.contains { files.contains($0.path) }
  }

  /// Splits findings into (inScope, outOfScope), mirroring `Baseline.filter`.
  public func filter(_ findings: [Finding]) -> (inScope: [Finding], outOfScope: [Finding]) {
    let (outOfScope, inScope) = findings.partitioned(by: contains)
    return (inScope, outOfScope)
  }
}
