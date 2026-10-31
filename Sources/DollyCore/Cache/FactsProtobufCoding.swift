// swift-format-ignore-file: AlwaysUseLowerCamelCase, NoLeadingUnderscores
// `__aepbEncode`/`__aepbDecode` are AemiProtobuf's protocol requirements, named by it.
//  FactsProtobufCoding.swift
//  dolly — the facts cache's payload on AemiProtobuf's wire (analyzerkit roadmap 0017)
//
//  Written by hand with analyzerkit's field helpers. The token stream, kept in
//  memory as 16-byte little-endian records, goes on the wire as packed varint
//  lanes: lines as zigzag deltas (they rarely go back), columns and the two
//  intern ids as plain varints, kinds as raw bytes. Field numbers are the
//  format: never renumber one.

public import AemiProtobuf
public import AemiProtobufCore
import CorpusScan

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension ExtractedFile: AemiProtoFastEncodable, AemiProtoFastDecodable {
  func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
    try writer.field(1, facts)
    writer.field(2, degraded)
  }

  static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
    var facts: CachedFileFacts?
    var degraded: String?
    try reader.forEachField { tag, reader throws(WireError) in
      switch tag.fieldNumber {
      case 1: facts = try reader.readMessage(CachedFileFacts.self)
      case 2: degraded = try reader.readString()
      default: try reader.skipField(tag)
      }
    }
    return Self(facts: facts, degraded: degraded)
  }
}

extension CachedFileFacts: AemiProtoFastEncodable, AemiProtoFastDecodable {
  func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
    let records = [UInt8](recordData)
    let count = records.count / 16
    var lines: [Int64] = []
    var columns: [UInt32] = []
    var raws: [UInt32] = []
    var norms: [UInt32] = []
    lines.reserveCapacity(count)
    columns.reserveCapacity(count)
    raws.reserveCapacity(count)
    norms.reserveCapacity(count)
    var previous: Int64 = 0
    for token in 0..<count {
      let base = token * 16
      let line = Int64(Int32(bitPattern: Self.word(records, base)))
      lines.append(line - previous)
      previous = line
      columns.append(Self.word(records, base + 4))
      raws.append(Self.word(records, base + 8))
      norms.append(Self.word(records, base + 12))
    }
    writer.appendPackedVarints(field: 1, lines, .zigzag)
    writer.appendPackedVarints(field: 2, columns)
    writer.appendPackedVarints(field: 3, raws)
    writer.appendPackedVarints(field: 4, norms)
    writer.field(5, strings)
    if !kindData.isEmpty {
      writer.appendTag(6, .lengthDelimited)
      writer.appendBytes([UInt8](kindData))
    }
    var last = 0
    writer.appendPackedVarints(
      field: 7,
      boundaries.map { boundary in
        defer { last = boundary }
        return Int64(boundary - last)
      }, .zigzag)
    writer.field(8, hasSourceLocationDirective)
    try writer.field(9, directives)
    writer.field(10, Int(contentRegion))
    for span in previewSpans {
      try writer.appendMessage(field: 11) { writer throws(WireError) in
        writer.field(1, span.start)
        writer.field(2, span.end)
      }
    }
  }

  static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
    var lines: [Int64] = []
    var columns: [UInt32] = []
    var raws: [UInt32] = []
    var norms: [UInt32] = []
    var strings: [String] = []
    var kinds: [UInt8] = []
    var boundaries: [Int64] = []
    var hasDirective = false
    var directives: [SuppressionDirective] = []
    var contentRegion = 0
    var spans: [FileContext.LineSpan] = []
    try reader.forEachField { tag, reader throws(WireError) in
      switch tag.fieldNumber {
      case 1: lines += try reader.readPackedVarints(Int64.self, .zigzag)
      case 2: columns += try reader.readPackedVarints(UInt32.self)
      case 3: raws += try reader.readPackedVarints(UInt32.self)
      case 4: norms += try reader.readPackedVarints(UInt32.self)
      case 5: strings.append(try reader.readString())
      case 6: kinds += try reader.readBytes()
      case 7: boundaries += try reader.readPackedVarints(Int64.self, .zigzag)
      case 8: hasDirective = try reader.readBool()
      case 9: directives.append(try reader.readMessage(SuppressionDirective.self))
      case 10: contentRegion = try reader.readInt()
      case 11:
        spans.append(
          try reader.readMessage { reader throws(WireError) in
            var start = 0
            var end = 0
            try reader.forEachField { tag, reader throws(WireError) in
              switch tag.fieldNumber {
              case 1: start = try reader.readInt()
              case 2: end = try reader.readInt()
              default: try reader.skipField(tag)
              }
            }
            return FileContext.LineSpan(start: start, end: end)
          })
      default: try reader.skipField(tag)
      }
    }
    // Lanes of unequal length are a damaged payload; `fileTokens` checks the kinds against the records.
    guard columns.count == lines.count, raws.count == lines.count, norms.count == lines.count else {
      throw .missingRequired(path: "CachedFileFacts.lanes")
    }
    var records = [UInt8]()
    records.reserveCapacity(lines.count * 16)
    var line: Int64 = 0
    for token in 0..<lines.count {
      line += lines[token]
      append(UInt32(bitPattern: Int32(truncatingIfNeeded: line)), to: &records)
      append(columns[token], to: &records)
      append(raws[token], to: &records)
      append(norms[token], to: &records)
    }
    var boundary = 0
    return Self(
      recordData: Data(records), strings: strings, kindData: Data(kinds),
      boundaries: boundaries.map { delta in
        boundary += Int(delta)
        return boundary
      },
      hasSourceLocationDirective: hasDirective, directives: directives,
      contentRegion: UInt8(truncatingIfNeeded: contentRegion), previewSpans: spans)
  }

  private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }

  private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8(truncatingIfNeeded: value))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    bytes.append(UInt8(truncatingIfNeeded: value >> 24))
  }
}

extension SuppressionDirective: AemiProtoFastEncodable, AemiProtoFastDecodable {
  public func __aepbEncode(into writer: inout WireWriter) throws(WireError) {
    for rule in rules.sorted(by: { $0.rawValue < $1.rawValue }) { writer.field(1, rule) }
    writer.field(2, Self.wireName(kind))
    writer.field(3, line)
    writer.field(4, reason)
  }

  public static func __aepbDecode(from reader: inout WireReader) throws(WireError) -> Self {
    var rules: Set<RuleID> = []
    var kind = Kind.accept
    var line = 0
    var reason: String?
    try reader.forEachField { tag, reader throws(WireError) in
      switch tag.fieldNumber {
      case 1: rules.insert(try reader.readEnum(RuleID.self))
      case 2:
        let name = try reader.readString()
        guard let known = Self.kind(wireName: name) else {
          throw .missingRequired(path: "Kind.\(name)")
        }
        kind = known
      case 3: line = try reader.readInt()
      case 4: reason = try reader.readString()
      default: try reader.skipField(tag)
      }
    }
    return Self(rules: rules, kind: kind, line: line, reason: reason)
  }

  private static func wireName(_ kind: Kind) -> String {
    switch kind {
    case .accept: "accept"
    case .acceptThis: "acceptThis"
    case .acceptNext: "acceptNext"
    case .regionDisable: "regionDisable"
    case .regionEnable: "regionEnable"
    }
  }

  private static func kind(wireName: String) -> Kind? {
    switch wireName {
    case "accept": .accept
    case "acceptThis": .acceptThis
    case "acceptNext": .acceptNext
    case "regionDisable": .regionDisable
    case "regionEnable": .regionEnable
    default: nil
    }
  }
}
