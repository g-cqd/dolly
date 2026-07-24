//  CoreMLSemanticEmbeddingProvider.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  `SemanticEmbeddingProvider` backed by a user-supplied Core ML model with a
//  caller-supplied tokenizer closure: tokenize, pack IDs into an
//  `MLMultiArray`, run inference, extract the pooled-output vector. A
//  lower-level provider than `HFSemanticEmbeddingProvider` (which pairs a HF
//  tokenizer with the model); exposed for programmatic bring-your-own-model
//  use. Not wired to a CLI flag.
//
//  Expected model shape — input `MLMultiArray<Int32>` of `[1, contextWindow]`
//  (token IDs, zero-padded); output `MLMultiArray<Float32>` of
//  `[1, embeddingDimension]` (the `[CLS]` or mean-pooled representation).

#if canImport(CoreML)
  import CoreML
  import Foundation

  // `@unchecked Sendable`: the only stored reference type is `MLModel`, held
  // immutably; `MLModel.prediction` is documented thread-safe. Same rationale
  // as `HFSemanticEmbeddingProvider`.
  final class CoreMLSemanticEmbeddingProvider: SemanticEmbeddingProvider, @unchecked Sendable {
    /// Converts a `String` into model-vocabulary token IDs. The caller owns
    /// special-token handling (`[CLS]`, `[SEP]`, …) and context-window
    /// truncation.
    typealias Tokenizer = @Sendable (String) throws -> [Int32]

    let embeddingDimension: Int

    /// - Parameters:
    ///   - modelURL: an `.mlmodel` bundle (compiled during init) or a
    ///     precompiled `.mlmodelc` directory.
    ///   - tokenizer: `String` → `[Int32]` token IDs.
    ///   - embeddingDimension: length of the model's embedding vector.
    ///   - contextWindow: maximum token-sequence length; inputs are
    ///     zero-padded to it and refused past it.
    ///   - inputName / outputName: model port names (CodeBERT/RoBERTa
    ///     defaults).
    init(
      modelURL: URL,
      tokenizer: @escaping Tokenizer,
      embeddingDimension: Int,
      contextWindow: Int,
      inputName: String = "input_ids",
      outputName: String = "pooler_output"
    ) async throws {
      let compiledURL: URL
      if modelURL.pathExtension == "mlmodelc" {
        compiledURL = modelURL
      } else {
        do {
          compiledURL = try await MLModel.compileModel(at: modelURL)
        } catch {
          throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
        }
      }
      do {
        self.model = try MLModel(contentsOf: compiledURL)
      } catch {
        throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
      }
      self.tokenize = tokenizer
      self.embeddingDimension = embeddingDimension
      self.contextWindow = contextWindow
      self.inputName = inputName
      self.outputName = outputName
    }

    func embed(snippet: String) async throws -> [Float] {
      let tokens = try tokenize(snippet)
      guard tokens.count <= contextWindow else {
        throw SemanticEmbeddingError.snippetTooLong(actual: tokens.count, limit: contextWindow)
      }
      // Zero-padded token IDs, length = the model's context window.
      let input = try MLInt32Input.make(length: contextWindow) { index in
        index < tokens.count ? tokens[index] : 0
      }
      let prediction: any MLFeatureProvider
      do {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
          inputName: MLFeatureValue(multiArray: input)
        ])
        prediction = try await model.prediction(from: provider)
      } catch {
        throw SemanticEmbeddingError.inferenceFailed(reason: "\(error)")
      }
      guard let outputValue = prediction.featureValue(for: outputName),
        let outputArray = outputValue.multiArrayValue
      else {
        throw SemanticEmbeddingError.inferenceFailed(
          reason: "Model output '\(outputName)' is missing or not an MLMultiArray")
      }
      return try makeEmbeddingVector(from: outputArray)
    }

    // MARK: - Private

    private let model: MLModel
    private let tokenize: Tokenizer
    private let contextWindow: Int
    private let inputName: String
    private let outputName: String

    private func makeEmbeddingVector(from output: MLMultiArray) throws -> [Float] {
      let count = output.count
      guard count == embeddingDimension else {
        throw SemanticEmbeddingError.inferenceFailed(
          reason: "Model produced \(count) values; expected \(embeddingDimension)")
      }
      var vector = [Float](repeating: 0, count: count)
      for index in 0..<count {
        vector[index] = output[index].floatValue
      }
      return vector
    }
  }
#endif  // canImport(CoreML)
