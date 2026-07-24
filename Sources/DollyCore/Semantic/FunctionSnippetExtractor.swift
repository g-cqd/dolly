//  FunctionSnippetExtractor.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  Extracts function- and initializer-shaped `EmbeddingSnippet`s from Swift
//  source: the input feeder for `EmbeddingCloneDiscovery`. Snippets shorter
//  than `minimumLines` (5) or longer than `maximumLines` (60) are skipped —
//  the same window the semantic pass calibrates against. Trivia (leading
//  comments, whitespace) is preserved so the tokenizer sees a reviewer's
//  context.
//
//  Trimmed for dolly: the disk-walking convenience overloads are dropped —
//  the Analyzer already holds every file's source in memory, so snippets are
//  extracted from those without a second read.

import Foundation
import SwiftParser
import SwiftSyntax

enum FunctionSnippetExtractor {
  static let minimumLines = 5
  static let maximumLines = 60

  /// Walk one source string and emit one `EmbeddingSnippet` per function /
  /// initializer body that fits inside the line window.
  static func extract(
    source: String,
    file: String,
    minimumLines: Int = minimumLines,
    maximumLines: Int = maximumLines
  ) -> [EmbeddingSnippet] {
    let tree = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: file, tree: tree)
    let visitor = SnippetVisitor(
      converter: converter,
      file: file,
      minimumLines: minimumLines,
      maximumLines: maximumLines
    )
    visitor.walk(tree)
    return visitor.snippets
  }
}

// MARK: - SnippetVisitor

private final class SnippetVisitor: SyntaxVisitor {
  var snippets: [EmbeddingSnippet] = []

  private let converter: SourceLocationConverter
  private let file: String
  private let minimumLines: Int
  private let maximumLines: Int

  init(converter: SourceLocationConverter, file: String, minimumLines: Int, maximumLines: Int) {
    self.converter = converter
    self.file = file
    self.minimumLines = minimumLines
    self.maximumLines = maximumLines
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    consider(node: Syntax(node))
    return .visitChildren
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    consider(node: Syntax(node))
    return .visitChildren
  }

  private func consider(node: Syntax) {
    let startLine = node.startLocation(converter: converter).line
    let endLine = node.endLocation(converter: converter).line
    let lineSpan = endLine - startLine + 1
    guard lineSpan >= minimumLines, lineSpan <= maximumLines else { return }
    let code = node.description
    // Cheap token estimate — real model tokenization happens in the
    // provider; this only fills the `EmbeddingSnippet` field.
    let approxTokenCount = max(1, code.count / 4)
    snippets.append(
      EmbeddingSnippet(
        file: file,
        startLine: startLine,
        endLine: endLine,
        tokenCount: approxTokenCount,
        code: code
      )
    )
  }
}
