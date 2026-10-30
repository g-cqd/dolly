//  InternerAdoptionTests.swift
//  dolly
//
//  Token tables on aemi's `AemiInterner` (analyzerkit roadmaps 0027, 0047):
//  each file fills an interner as it extracts, the cache keeps the interner's
//  serialized bytes, and the corpus is their parallel merge, whose symbols are
//  the ones one interner reading every file in order would give, so suffix
//  arrays and findings do not change.

import Foundation
import SwiftParser
import Testing

@testable import DollyCore

@Suite struct InternerAdoptionTests {
  private static func tokens(_ source: String, _ path: String) -> FileTokens {
    TokenSequenceExtractor().extract(from: Parser.parse(source: source), file: path, source: source)
  }

  @Test func `local ids are the interner's symbols, in first-occurrence order`() {
    let file = Self.tokens("let a = b\nlet c = a\n", "/x/A.swift")
    #expect(file.table.count == file.table.strings.count)
    #expect(file.table.strings.prefix(2) == ["let", "a"])
    for record in file.records {
      #expect(Int(record.rawID) < file.table.count && Int(record.normID) < file.table.count)
    }
  }

  /// The merged corpus gives every token the text it had in its file, and ids in the order of first occurrence
  /// across the files in order, as the dictionary-based assembler gave them.
  @Test func `the corpus is the ordered merge of the files' interners`() {
    let first = Self.tokens("struct A { let value = 1 }\n", "/x/A.swift")
    let second = Self.tokens("struct B { let other = value }\n", "/x/B.swift")
    let corpus = CorpusAssembler.assemble(files: [first, second])

    var expected: [String] = []
    for text in first.table.strings + second.table.strings where !expected.contains(text) {
      expected.append(text)
    }
    #expect(corpus.internCount == expected.count)
    #expect((0..<corpus.internCount).map { corpus.text(of: UInt32($0)) } == expected)

    for (file, sequence) in zip([first, second], corpus.sequences) {
      for (local, merged) in zip(file.records, sequence.records) {
        #expect(corpus.text(of: merged.rawID) == file.table.strings[Int(local.rawID)])
        #expect(corpus.text(of: merged.normID) == file.table.strings[Int(local.normID)])
      }
    }
  }

  @Test func `the cache keeps the interner, and a damaged one is a miss`() throws {
    let source = "func f(x: Int) -> Int { x + 1 }\n"
    let file = Self.tokens(source, "/x/F.swift")
    let cached = CachedFileFacts(tokens: file, directives: [], contentRegion: [], previewSpans: [])
    let restored = try #require(cached.fileTokens(path: "/x/F.swift", source: source))
    #expect(restored.table.strings == file.table.strings)
    #expect(restored.records == file.records)

    let damaged = CachedFileFacts(
      recordData: cached.recordData, internerBytes: Data(cached.internerBytes.prefix(3)),
      kindData: cached.kindData,
      boundaries: cached.boundaries, hasSourceLocationDirective: false, directives: [],
      contentRegion: 0,
      previewSpans: [])
    #expect(damaged.fileTokens(path: "/x/F.swift", source: source) == nil)
  }
}
