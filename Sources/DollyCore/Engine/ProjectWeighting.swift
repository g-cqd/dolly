//  ProjectWeighting.swift
//  dolly
//
//  Duplication weighs by where it lives. Previews repeat a view with small
//  variations by design, and never ship: their copies are dropped. Tests
//  are often deliberately repetitive (each test readable on its own): a
//  group found only in test code becomes a note. A group spanning
//  production and tests keeps its severity: tests re-implementing
//  production logic is worth knowing.

enum ProjectWeighting {
  /// The groups without their members that lie in previews; a group left
  /// with fewer than two members is dropped and counted.
  /// - Complexity: O(m · p) for m members and p preview spans per file.
  static func withoutPreviews(
    _ groups: [CloneGroup],
    contexts: [String: FileContext]
  ) -> (groups: [CloneGroup], droppedGroupCount: Int) {
    var kept: [CloneGroup] = []
    var dropped = 0
    for group in groups {
      let clones = group.clones.filter { clone in
        !(contexts[clone.file]?.isPreview(start: clone.startLine, end: clone.endLine) ?? false)
      }
      if clones.count < 2 {
        dropped += 1
      } else if clones.count == group.clones.count {
        kept.append(group)
      } else {
        kept.append(
          CloneGroup(
            type: group.type, clones: clones, similarity: group.similarity, fingerprint: group.fingerprint))
      }
    }
    return (kept, dropped)
  }

  /// The finding as a note when every region it names is test code.
  static func weighted(_ finding: Finding, contexts: [String: FileContext]) -> Finding {
    let paths = [finding.path] + finding.related.map(\.path)
    guard paths.allSatisfy({ contexts[$0]?.isTestCode == true }) else { return finding }
    return Finding(
      rule: finding.rule,
      severity: .note,
      path: finding.path,
      line: finding.line,
      column: finding.column,
      message: finding.message,
      note: (finding.note.map { $0 + " — " } ?? "")
        + "test code only: repetition keeps each test readable on its own; factor it out if it hides intent",
      related: finding.related,
      fingerprintPath: finding.fingerprintPath
    )
  }

  /// One line saying what the project model left out; nil when nothing.
  static func note(generatedFileCount: Int, previewGroupCount: Int) -> String? {
    var parts: [String] = []
    if generatedFileCount > 0 {
      parts.append("\(generatedFileCount) generated file(s) left out")
    }
    if previewGroupCount > 0 {
      parts.append("\(previewGroupCount) clone group(s) found only in previews dropped")
    }
    return parts.isEmpty ? nil : parts.joined(separator: "; ")
  }
}
