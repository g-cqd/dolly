//  ExactCloneAttributionTests.swift
//  dolly
//
//  Regression guard for the suffix-array exact-clone attribution bug: SA-IS
//  skipped its second induction pass whenever every LMS substring received a
//  unique name, returning a MISORDERED suffix array. A misordered SA breaks
//  the min-LCP nesting property that `findRepeatGroups` relies on, so a long
//  genuine repeat (the epoll/kqueue parallel-backend clone in the HTTP
//  corpus) smeared its length onto lexicographically adjacent — but otherwise
//  unrelated — suffixes (crypto/HPACK/QPACK anchors), each falsely reported
//  as a "similarity 1.00" exact clone that shared only a 2-3 token prefix.
//
//  These tests assert the defining invariant of a Type-1 clone: the two
//  reported regions are genuinely identical raw-token runs.

import Foundation
import SwiftParser
import Testing

@testable import DollyCore

@Suite struct ExactCloneAttributionTests {
  /// Build a corpus large and lexically diverse enough to exercise the SA-IS
  /// recursion (n well past the 32-token direct-sort cutoff, with the
  /// per-declaration separators that make its alphabet sparse — the exact
  /// shape that tripped the skipped-second-induction bug).
  private static func fillerFunctions(_ salt: Int, _ count: Int) -> String {
    // Lexically diverse bodies: unique identifiers, literals, and shapes per
    // function push the interned alphabet toward the all-distinct-LMS regime
    // that exposed the skipped second induction pass.
    (0..<count)
      .map { index in
        let tag = salt &* 101 &+ index
        return """
          func transform\(tag)(input series\(tag): [Int], pivot p\(tag): Int) -> Int {
              var register\(tag) = \(tag &* 7 &+ 3)
              let threshold\(tag) = "boundary-\(tag)-marker"
              for sample\(tag) in series\(tag) where sample\(tag) > p\(tag) {
                  register\(tag) = register\(tag) &* \(tag % 29 &+ 7) &+ sample\(tag)
                  register\(tag) ^= (sample\(tag) &<< \(tag % 5 &+ 1)) &- \(tag &+ 11)
                  if threshold\(tag).count > register\(tag) { register\(tag) &-= \(tag % 13 &+ 2) }
              }
              return register\(tag) &+ \(tag &* 17 &- 5)
          }
          """
      }
      .joined(separator: "\n\n")
  }

  /// RFC 5869 HKDF-Expand — an HMAC accumulation `while` loop. Starts
  /// `{ guard length ...` like the socket `sendFile` below, then diverges
  /// completely: zero shared tokens past the third.
  private static let hkdfExpand = """
    enum KeyDerivation {
        static func expand(pseudoRandomKey key: [UInt8], info: [UInt8], length: Int) -> [UInt8]? {
            guard length >= 0, length <= 255 * 32 else {
                return nil
            }
            var output: [UInt8] = []
            var block: [UInt8] = []
            var counter: UInt8 = 1
            while output.count < length {
                block = authenticationCode(key: key, message: block + info + [counter])
                output += block
                counter &+= 1
            }
            return Array(output.prefix(length))
        }
    }
    """

  /// A POSIX socket `sendFile` — a `withUnsafeThrowingContinuation` block.
  /// Also opens `{ guard length ...`, then diverges completely.
  private static let socketSendFile = """
    struct SocketConnection {
        func sendFile(descriptor file: Int32, offset: Int, length: Int) async throws {
            guard length > 0 else {
                return
            }
            let socket = self.descriptor
            let eventLoop = self.eventLoop
            try await withUnsafeThrowingContinuation { continuation in
                writeResumer.reset(continuation)
                Self.sendFileRemaining(
                    file: file, offset: offset, remaining: length,
                    socket: socket, eventLoop: eventLoop, once: writeResumer)
            }
        }
    }
    """

  /// A genuine ~60-token copy pasted into two files — the positive control
  /// that must be reported as a Type-1 clone, proving the detector is live
  /// (so the "no false positive" checks are not vacuously green).
  private static let genuineClone = """
    enum RunLengthCodec {
        static func encode(_ bytes: [UInt8]) -> [(UInt8, Int)] {
            var runs: [(UInt8, Int)] = []
            var index = 0
            while index < bytes.count {
                let value = bytes[index]
                var length = 1
                while index + length < bytes.count, bytes[index + length] == value {
                    length += 1
                }
                runs.append((value, length))
                index += length
            }
            return runs
        }
    }
    """

  /// The interned records for `source`, corpus-assembled exactly as the
  /// analyzer does, so the raw-id lane matches the production stream.
  private func corpus(_ sources: [(name: String, text: String)]) -> TokenCorpus {
    let extractor = TokenSequenceExtractor()
    let files = sources.map { source -> FileTokens in
      let tree = Parser.parse(source: source.text)
      return extractor.extract(from: tree, file: source.name, source: source.text)
    }
    return CorpusAssembler.assemble(files: files)
  }

  /// Extract the raw-id run of `count` tokens beginning at 1-based
  /// `(line, column)` in the named sequence — the ground truth a Type-1
  /// finding claims is shared.
  private func rawRun(
    in corpus: TokenCorpus, file: String, line: Int, column: Int, count: Int
  ) -> [UInt32]? {
    guard let sequence = corpus.sequences.first(where: { $0.file == file }) else { return nil }
    guard
      let start = sequence.records.firstIndex(where: {
        Int($0.line) == line && Int($0.column) == column
      })
    else { return nil }
    let end = min(start + count, sequence.records.count)
    return sequence.records[start..<end].map(\.rawID)
  }

  /// The mixed corpus: the two divergent decoys (HKDF / socket), a genuine
  /// copy-paste pair, and lexically diverse filler.
  private static func mixedSources() -> [(name: String, text: String)] {
    [
      (name: "HKDF.swift", text: hkdfExpand),
      (name: "Socket.swift", text: socketSendFile),
      (name: "CodecA.swift", text: genuineClone),
      (name: "CodecB.swift", text: genuineClone),
    ] + (0..<6).map { (name: "Filler\($0).swift", text: fillerFunctions($0, 6)) }
  }

  @Test("Every exact-clone region is a genuinely identical raw-token run")
  func exactCloneRegionsAreRawIdentical() {
    let built = corpus(Self.mixedSources())
    let groups = SuffixArrayCloneDetector(minimumTokens: 20).detect(in: built)

    // Positive control: the copy-pasted codec must be found, so the checks
    // below are exercised rather than vacuously satisfied.
    #expect(
      groups.contains { group in
        Set(group.clones.map { ($0.file as NSString).lastPathComponent })
          .isSuperset(of: ["CodecA.swift", "CodecB.swift"])
      }, "the genuine copy-paste pair must be reported as an exact clone")

    for group in groups {
      #expect(group.similarity == 1.0)
      let runs = group.clones.map {
        rawRun(
          in: built, file: $0.file, line: $0.startLine, column: $0.startColumn,
          count: $0.tokenCount)
      }
      // Anchor run must resolve, and every region must be the SAME raw run.
      guard let reference = runs.first ?? nil else {
        Issue.record("could not resolve the anchor region back to tokens")
        continue
      }
      for run in runs {
        #expect(
          run == reference,
          "exact-clone group mixes non-identical raw runs — misattribution regression")
      }
    }
  }

  @Test("HKDF-Expand and socket sendFile are never an exact clone")
  func crossDomainPairIsNotAnExactClone() async {
    // The real HTTP false-positive shape, reduced: two functions that share
    // only a `{ guard length` prefix must not be reported identical, while a
    // genuine copy-paste in the same corpus still is.
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "dolly-attrib-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var paths: [String] = []
    for source in Self.mixedSources() {
      let url = dir.appending(path: source.name)
      try? source.text.write(to: url, atomically: true, encoding: .utf8)
      paths.append(url.path)
    }

    let report = await Analyzer().analyze(files: paths)
    let exact = report.findings.filter { $0.rule == .exactClone }

    // Positive control: the genuine copy-paste is surfaced.
    #expect(
      exact.contains { finding in
        let mentionsA =
          finding.path.hasSuffix("CodecA.swift") || finding.note?.contains("CodecA.swift") == true
        let mentionsB =
          finding.path.hasSuffix("CodecB.swift") || finding.note?.contains("CodecB.swift") == true
        return mentionsA && mentionsB
      }, "the copy-pasted codec must be reported")

    // No decoy pairing: the crypto loop and the socket sendFile never group.
    for finding in exact {
      let mentionsHKDF =
        finding.path.hasSuffix("HKDF.swift") || finding.note?.contains("HKDF.swift") == true
      let mentionsSocket =
        finding.path.hasSuffix("Socket.swift") || finding.note?.contains("Socket.swift") == true
      #expect(
        !(mentionsHKDF && mentionsSocket),
        "crypto expand loop and socket sendFile share no tokens: \(finding.message)")
    }
  }
}
