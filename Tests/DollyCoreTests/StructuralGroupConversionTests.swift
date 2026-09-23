import Foundation
import Testing

@testable import DollyCore

@Suite("Structural group conversion") struct StructuralGroupConversionTests {
  private static func reference(
    _ groups: [[Int]], info: [Int: DocumentLocationInfo], pairs: [ClonePairInfo],
    minimumSimilarity: Double
  ) -> [CloneGroup] {
    groups.compactMap { component in
      let clones = component.compactMap { id -> Clone? in
        guard let document = info[id] else { return nil }
        return Clone(
          file: document.file, startLine: document.startLine,
          startColumn: document.startColumn, endLine: document.endLine,
          tokenCount: document.tokenCount, codeSnippet: "")
      }
      guard clones.count >= 2 else { return nil }
      let members = pairs.filter {
        component.contains($0.doc1.id) && component.contains($0.doc2.id)
      }
      let similarity =
        members.isEmpty
        ? minimumSimilarity
        : members.reduce(0.0) { $0 + $1.similarity } / Double(members.count)
      return CloneGroup(
        type: .structural, clones: clones, similarity: similarity,
        fingerprint: component.sorted().map(String.init).joined(separator: "-"))
    }
  }

  @Test("Random component groups preserve every clone and similarity", arguments: 0..<200)
  func randomGroupsMatchPairwiseReference(seed: Int) throws {
    var rng = SAISDifferentialTests.LCG(state: UInt64(seed) &+ 1)
    var groups: [[Int]] = []
    var info: [Int: DocumentLocationInfo] = [:]
    var documents: [Int: ShingledDocument] = [:]
    for _ in 0..<(1 + rng.next(12)) {
      let ids = (documents.count..<(documents.count + 2 + rng.next(7))).map(\.self)
      groups.append(ids)
      for id in ids {
        let document = ShingledDocument(
          file: "file-\(id % 5).swift", startLine: id + 1, endLine: id + 4,
          tokenCount: 50 + id, shingleHashes: [], shingles: [], id: id)
        documents[id] = document
        if rng.next(5) != 0 { info[id] = DocumentLocationInfo(document: document) }
      }
    }
    var pairs: [ClonePairInfo] = []
    for _ in 0..<(1 + rng.next(200)) {
      let group = groups[rng.next(groups.count)]
      let first = rng.next(group.count)
      let second = (first + 1 + rng.next(group.count - 1)) % group.count
      let doc1 = try #require(documents[group[first]])
      let otherGroup = groups[rng.next(groups.count)]
      let otherID = otherGroup[rng.next(otherGroup.count)]
      let secondID = rng.next(5) == 0 ? otherID : group[second]
      let doc2 = try #require(documents[secondID])
      pairs.append(
        ClonePairInfo(
          doc1: doc1, doc2: doc2, similarity: Double(rng.next(100)) / 100))
    }

    let detector = StructuralCloneDetector(minimumSimilarity: 0.5)
    let expected = Self.reference(groups, info: info, pairs: pairs, minimumSimilarity: 0.5)
    let actual = detector.convertToCloneGroups(groups, documentInfo: info, pairs: pairs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(actual) == encoder.encode(expected))
  }
}
