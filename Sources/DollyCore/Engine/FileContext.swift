//  FileContext.swift
//  dolly
//
//  Where a file sits in the project, from analyzerkit's project model:
//  generated or hand-written, test or production, and which lines are
//  previews. Duplication weighs differently in each.

import ProjectModel
import SwiftSyntax

/// The project context of one file.
struct FileContext: Sendable, Codable, Equatable {
  /// Inclusive line span.
  struct LineSpan: Sendable, Codable, Equatable {
    let start: Int
    let end: Int
  }

  /// A generator wrote the file.
  let isGenerated: Bool
  /// The file is test code (imports a test framework, or a test path).
  let isTestCode: Bool
  /// `#Preview` bodies and `PreviewProvider` types.
  let previewSpans: [LineSpan]

  static let production = FileContext(isGenerated: false, isTestCode: false, previewSpans: [])

  init(isGenerated: Bool, isTestCode: Bool, previewSpans: [LineSpan]) {
    self.isGenerated = isGenerated
    self.isTestCode = isTestCode
    self.previewSpans = previewSpans
  }

  init(path: String, tree: SourceFileSyntax, converter: SourceLocationConverter) {
    isGenerated = GeneratedCode.isGenerated(path: path, tree: tree)
    isTestCode = TestConventions.isTestFile(path: path, tree: tree)
    previewSpans = CodeRegionScanner.scan(tree, converter: converter)
      .filter { $0.region.contains(.preview) }
      .map { LineSpan(start: $0.startLine, end: $0.endLine) }
  }

  /// Whether the lines `start...end` lie mostly (half or more) inside
  /// previews: a clone region often starts a line or two before a
  /// `#Preview`, at its imports.
  func isPreview(start: Int, end: Int) -> Bool {
    guard end >= start, !previewSpans.isEmpty else { return false }
    let covered = previewSpans.reduce(0) { total, span in
      total + max(0, min(end, span.end) - max(start, span.start) + 1)
    }
    return Double(covered) >= Double(end - start + 1) * 0.5
  }
}
