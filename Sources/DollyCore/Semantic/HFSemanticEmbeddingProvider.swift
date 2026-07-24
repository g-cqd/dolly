//  HFSemanticEmbeddingProvider.swift
//  dolly — lifted from SwiftStaticAnalysis (MIT)
//
//  `SemanticEmbeddingProvider` backed by a Core ML model + a HuggingFace
//  `AutoTokenizer` (swift-transformers). The opt-in `--embedding-bundle`
//  provider: pass a directory holding both the Core ML model
//  (`.mlpackage` / `.mlmodelc`, compiled on first use) and the HF tokenizer
//  folder (`tokenizer.json`, …). Covers the standard HF feature-extraction
//  shape used by CodeBERT, GraphCodeBERT, jina-embeddings-v2-base-code,
//  CodeT5+, and MiniLM — a code-trained bundle gives materially higher recall
//  than the default NLContextual provider.
//
//  Adapted for dolly: the four model inputs are built through one helper
//  (was four near-identical blocks); pooling reads via MLMultiArray's safe
//  element subscript (no unsafe pointer, so strictMemorySafety is satisfied);
//  the `embedTokens` per-token path is deferred with the MaxSim reranker.

#if canImport(CoreML)
  import CoreML
  import Foundation
  import Tokenizers

  final class HFSemanticEmbeddingProvider: SemanticEmbeddingProvider, @unchecked Sendable {
    let embeddingDimension: Int
    let providerName: String

    /// - Parameters:
    ///   - bundleDir: directory holding both the Core ML bundle and the HF
    ///     tokenizer folder.
    ///   - modelURL: explicit model-bundle override; when `nil` the provider
    ///     picks the first `.mlpackage` / `.mlmodelc` in `bundleDir`.
    ///   - maxLength: cap on post-tokenization sequence length.
    ///   - inputIDsName / attentionMaskName / tokenTypeIDsName /
    ///     positionIDsName: model input feature names (optional inputs are
    ///     fed only when the model declares them).
    ///   - lastHiddenStateName: per-token output (mean-pooled here).
    init(
      bundleDir: URL,
      modelURL: URL? = nil,
      maxLength: Int = 256,
      inputIDsName: String = "input_ids",
      attentionMaskName: String = "attention_mask",
      tokenTypeIDsName: String? = "token_type_ids",
      positionIDsName: String? = "position_ids",
      lastHiddenStateName: String = "last_hidden_state"
    ) async throws {
      self.providerName = "bundle:\(bundleDir.lastPathComponent)"
      let resolvedModelURL: URL
      if let modelURL {
        resolvedModelURL = modelURL
      } else if let found = HFSemanticEmbeddingProvider.findModel(in: bundleDir) {
        resolvedModelURL = found
      } else {
        throw SemanticEmbeddingError.modelLoadFailed(
          underlying: HFProviderError.noModel(bundleDir.path))
      }

      let compiledURL: URL
      if resolvedModelURL.pathExtension == "mlmodelc" {
        compiledURL = resolvedModelURL
      } else {
        do {
          compiledURL = try await MLModel.compileModel(at: resolvedModelURL)
        } catch {
          throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
        }
      }

      let config = MLModelConfiguration()
      config.computeUnits = .all
      do {
        self.model = try MLModel(contentsOf: compiledURL, configuration: config)
      } catch {
        throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
      }

      do {
        self.tokenizer = try await AutoTokenizer.from(modelFolder: bundleDir)
      } catch {
        throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
      }

      self.maxLength = maxLength
      self.inputIDsName = inputIDsName
      self.attentionMaskName = attentionMaskName
      self.tokenTypeIDsName = tokenTypeIDsName
      self.positionIDsName = positionIDsName

      // Resolve output name: requested, then common alternates, then the
      // first declared multi-array output.
      let declaredOutputs = model.modelDescription.outputDescriptionsByName
      if declaredOutputs[lastHiddenStateName] != nil {
        self.lastHiddenStateName = lastHiddenStateName
      } else if declaredOutputs["hidden_states"] != nil {
        self.lastHiddenStateName = "hidden_states"
      } else if declaredOutputs["output"] != nil {
        self.lastHiddenStateName = "output"
      } else if let first = declaredOutputs.first(where: { $0.value.type == .multiArray }) {
        self.lastHiddenStateName = first.key
      } else {
        self.lastHiddenStateName = lastHiddenStateName
      }

      // Which optional inputs does the model actually accept?
      let inputDescriptions = model.modelDescription.inputDescriptionsByName
      let declaredInputs = Set(inputDescriptions.keys)
      self.acceptsTokenTypeIDs = tokenTypeIDsName.map(declaredInputs.contains) ?? false
      self.acceptsPositionIDs = positionIDsName.map(declaredInputs.contains) ?? false

      // Fixed input shape? Fully-baked exports declare `input_ids` as e.g.
      // [1, 128]; dynamic exports use [1, 1] or unconstrained.
      if let inputDesc = inputDescriptions[inputIDsName],
        let shape = inputDesc.multiArrayConstraint?.shape,
        shape.count == 2, shape[1].intValue > 1
      {
        self.fixedSequenceLength = shape[1].intValue
      } else {
        self.fixedSequenceLength = nil
      }

      // Embedding dimension: HF config.json hidden_size, else output shape,
      // else BERT-base fallback.
      let configURL = bundleDir.appendingPathComponent("config.json")
      if let hiddenSize = HFSemanticEmbeddingProvider.readHiddenSize(from: configURL) {
        self.embeddingDimension = hiddenSize
      } else if let outputDesc = model.modelDescription.outputDescriptionsByName[
        lastHiddenStateName],
        let shape = outputDesc.multiArrayConstraint?.shape,
        shape.count == 3, shape[2].intValue > 0
      {
        self.embeddingDimension = shape[2].intValue
      } else {
        self.embeddingDimension = HFSemanticEmbeddingProvider.defaultDimensionGuess
      }
    }

    func embed(snippet: String) async throws -> [Float] {
      // Tokenize via HF AutoTokenizer (BPE/WordPiece/SentencePiece, plus the
      // model's special tokens). Cap to the model's fixed length or maxLength.
      var ids = tokenizer.encode(text: snippet)
      let effectiveMax = fixedSequenceLength ?? maxLength
      if ids.count > effectiveMax {
        ids = Array(ids.prefix(effectiveMax))
      }
      let realTokenCount = ids.count
      guard realTokenCount > 0 else {
        throw SemanticEmbeddingError.inferenceFailed(reason: "Tokenizer produced an empty sequence")
      }
      let sequenceLength = fixedSequenceLength ?? realTokenCount

      // Build every Int32 input through one helper: attention mask is 1 for
      // real tokens and 0 for padding; ids pad with 0.
      var features: [String: MLFeatureValue] = [
        inputIDsName: MLFeatureValue(
          multiArray: try MLInt32Input.make(length: sequenceLength) {
            $0 < realTokenCount ? Int32(ids[$0]) : 0
          }),
        attentionMaskName: MLFeatureValue(
          multiArray: try MLInt32Input.make(length: sequenceLength) { $0 < realTokenCount ? 1 : 0 }),
      ]
      if acceptsTokenTypeIDs, let name = tokenTypeIDsName {
        features[name] = MLFeatureValue(
          multiArray: try MLInt32Input.make(length: sequenceLength) { _ in 0 })
      }
      if acceptsPositionIDs, let name = positionIDsName {
        features[name] = MLFeatureValue(
          multiArray: try MLInt32Input.make(length: sequenceLength) { Int32($0) })
      }

      let output: any MLFeatureProvider
      do {
        let input = try MLDictionaryFeatureProvider(dictionary: features)
        output = try await model.prediction(from: input)
      } catch {
        throw SemanticEmbeddingError.inferenceFailed(reason: "\(error)")
      }

      guard let lastHidden = output.featureValue(for: lastHiddenStateName)?.multiArrayValue else {
        throw SemanticEmbeddingError.inferenceFailed(
          reason: "Model output missing '\(lastHiddenStateName)' multi-array")
      }
      return try pool(lastHidden, sequenceLength: sequenceLength, realTokenCount: realTokenCount)
    }

    // MARK: - Private

    private let model: MLModel
    private let tokenizer: any Tokenizer
    private let maxLength: Int
    private let inputIDsName: String
    private let attentionMaskName: String
    private let tokenTypeIDsName: String?
    private let positionIDsName: String?
    private let lastHiddenStateName: String
    private let acceptsTokenTypeIDs: Bool
    private let acceptsPositionIDs: Bool
    private let fixedSequenceLength: Int?
    private static let defaultDimensionGuess = 768

    /// Mean-pool the model output over real tokens. Accepts pre-pooled
    /// `(1, D)` (used directly) or per-token `(1, T, D)` (averaged over the
    /// real tokens, skipping padding). Reads via MLMultiArray's element
    /// subscript so no unsafe pointer is taken; `.floatValue` converts any
    /// numeric output dtype.
    private func pool(
      _ lastHidden: MLMultiArray, sequenceLength: Int, realTokenCount: Int
    ) throws -> [Float] {
      let shape = lastHidden.shape.map(\.intValue)
      if shape.count == 2, shape[0] == 1, shape[1] > 0 {
        let dimension = shape[1]
        var pooled = [Float](repeating: 0, count: dimension)
        for d in 0..<dimension { pooled[d] = lastHidden[d].floatValue }
        return pooled
      }
      guard shape.count == 3, shape[0] == 1, shape[1] == sequenceLength else {
        throw SemanticEmbeddingError.inferenceFailed(
          reason: "Unexpected \(lastHiddenStateName) shape: \(shape) for seqLen=\(sequenceLength)")
      }
      let dimension = shape[2]
      var pooled = [Float](repeating: 0, count: dimension)
      for t in 0..<realTokenCount {
        let base = t * dimension
        for d in 0..<dimension { pooled[d] += lastHidden[base + d].floatValue }
      }
      let scale = 1.0 / Float(realTokenCount)
      for d in 0..<dimension { pooled[d] *= scale }
      return pooled
    }

    // TODO(deferred): `embedTokens(snippet:)` (per-token, L2-normalized,
    // padding-stripped output) fed the MaxSim late-interaction reranker in
    // SwiftStaticAnalysis. Re-add it here when that reranker returns
    // (see SemanticThresholds' deferred-reranker note).

    /// `.mlpackage` first, then `.mlmodelc`, one level deep in `dir`.
    private static func findModel(in dir: URL) -> URL? {
      guard
        let contents = try? FileManager.default.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: nil)
      else { return nil }
      for url in contents where url.pathExtension == "mlpackage" { return url }
      for url in contents where url.pathExtension == "mlmodelc" { return url }
      return nil
    }

    /// Read `hidden_size` (or T5 `d_model`) from a HF `config.json`.
    private static func readHiddenSize(from configURL: URL) -> Int? {
      guard let data = try? Data(contentsOf: configURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      if let hidden = json["hidden_size"] as? Int { return hidden }
      if let hidden = json["d_model"] as? Int { return hidden }
      return nil
    }
  }

  // MARK: - HFProviderError

  private enum HFProviderError: Error, CustomStringConvertible {
    case noModel(String)

    var description: String {
      switch self {
      case .noModel(let path): "No .mlpackage or .mlmodelc found in \(path)"
      }
    }
  }
#endif
