//  ProtobufPayloadTests.swift
//  dolly
//
//  The facts cache's payloads are protobuf (analyzerkit roadmap 0017): the
//  token stream as packed varint lanes instead of base64 blobs. Every payload
//  field round-trips, and a 3,000-file corpus stays within its size budget.

import AemiJSON
import AemiProtobuf
import Foundation
import Testing

@testable import DollyCore

@Suite struct ProtobufPayloadTests {
  /// A file with preview spans, suppression directives, generics, string
  /// literals and repeated shapes, so every token kind and lane is exercised.
  static func source(_ index: Int) -> String {
    """
    import SwiftUI

    // @dl:disable structural-clone -- generated-like \(index)
    struct Row\(index)<Value: Hashable>: View {
      let title: String = "row \(index)"
      let values: [Value]
      var body: some View {
        VStack {
          ForEach(values, id: \\.self) { value in Text("\\(value)") }
          if values.count > \(index % 7) { Text(title).padding(\(index % 11)) }
        }
      }
    }
    // @dl:enable structural-clone

    func compute\(index)(_ input: [Int]) -> Int {
      var total = 0
      for value in input where value % 2 == 0 { total += value * \(index) }
      return total &+ 0x\(String(index, radix: 16))
    }

    #Preview { Row\(index)(values: [1, 2, 3]) }
    """
  }

  static func extracted(_ index: Int) throws -> ExtractedFile {
    let path = "/corpus/Sources/Module\(index % 40)/File\(index).swift"
    return Analyzer.extract(bytes: Array(source(index).utf8), path: path)
  }

  @Test func `every payload field round-trips through protobuf`() throws {
    let original = try Self.extracted(5)
    let facts = try #require(original.facts)
    #expect(!facts.directives.isEmpty && !facts.previewSpans.isEmpty && !facts.boundaries.isEmpty)
    let bytes = try ProtobufEncoder().encodeToBytes(original)
    let decoded = try #require(
      try ProtobufDecoder().decode(ExtractedFile.self, fromBytes: bytes).facts)
    #expect(decoded.recordData == facts.recordData)
    #expect(decoded.strings == facts.strings)
    #expect(decoded.kindData == facts.kindData)
    #expect(decoded.boundaries == facts.boundaries)
    #expect(decoded.hasSourceLocationDirective == facts.hasSourceLocationDirective)
    #expect(decoded.directives == facts.directives)
    #expect(decoded.contentRegion == facts.contentRegion)
    #expect(decoded.previewSpans == facts.previewSpans)
    #expect(
      try ProtobufEncoder().encodeToBytes(ExtractedFile(facts: decoded, degraded: nil)) == bytes,
      "byte-stable")

    let degraded = try ProtobufDecoder().decode(
      ExtractedFile.self,
      fromBytes: ProtobufEncoder().encodeToBytes(
        ExtractedFile(facts: nil, degraded: "not valid UTF-8")))
    #expect(degraded.degraded == "not valid UTF-8" && degraded.facts == nil)
  }

  /// The budget is set from 0017's measurement (JSON 11.5 MB, protobuf 3.5 MB
  /// for these 3,000 files): protobuf's packed lanes must stay under 40% of
  /// what the JSON path wrote, base64 blobs included.
  @Test func `a 3,000-file corpus stays within its size budget`() throws {
    var json = 0
    var protobuf = 0
    for index in 0..<3_000 {
      let file = try Self.extracted(index)
      json += try AemiJSON.JSONEncoder().encodeToBytes(file).count
      protobuf += try ProtobufEncoder().encodeToBytes(file).count
    }
    print("ProtobufPayloadTests: 3,000 files, JSON \(json) bytes, protobuf \(protobuf) bytes")
    #expect(protobuf * 5 < json * 2, "JSON \(json) bytes, protobuf \(protobuf)")
  }
}
