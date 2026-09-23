import Testing

@testable import DollyCore

/// The analyzer reads the corpus through `ParallelProcessor.map` and keeps its
/// results in file order, so the corpus, and every report built from it, is
/// the same from run to run.
@Suite struct ParallelProcessorTests {
  @Test("Results come back in input order under any cap", arguments: [0, 1, 3, 64])
  func preservesInputOrder(maxConcurrency: Int) async {
    let items = Array(0..<500)
    let results = await ParallelProcessor.map(items, maxConcurrency: maxConcurrency) { $0 * 2 }
    #expect(results == items.map { $0 * 2 })
  }

  @Test("No items means no work and no results")
  func emptyInput() async {
    let results = await ParallelProcessor.map([Int](), maxConcurrency: 4) { $0 }
    #expect(results.isEmpty)
  }
}
