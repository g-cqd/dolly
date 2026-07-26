//  MLMultiArraySupport.swift
//  dolly
//
//  Shared Core ML plumbing used by both the HF and raw Core ML embedding
//  providers — input construction and model loading — factored out so the two
//  providers do not carry near-identical blocks. (dolly's own `near-clone` rule
//  is what caught the duplication when the loading path grew a compute-unit
//  ladder; the fix is this file rather than a suppression.)

#if canImport(CoreML)
  import CoreML
  import Foundation

  enum MLInt32Input {
    /// A `[1, length]` Int32 `MLMultiArray`, each element supplied by `value`.
    static func make(length: Int, _ value: (Int) -> Int32) throws -> MLMultiArray {
      let array: MLMultiArray
      do {
        array = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
      } catch {
        throw SemanticEmbeddingError.inferenceFailed(reason: "\(error)")
      }
      for i in 0..<length {
        array[[0, NSNumber(value: i)]] = NSNumber(value: value(i))
      }
      return array
    }
  }

  enum CoreMLModelLoader {
    /// Compiles `modelURL` unless it is already a `.mlmodelc`.
    static func compile(_ modelURL: URL) async throws -> URL {
      if modelURL.pathExtension == "mlmodelc" { return modelURL }
      do {
        return try await MLModel.compileModel(at: modelURL)
      } catch {
        throw SemanticEmbeddingError.modelLoadFailed(underlying: error)
      }
    }

    /// Loads `compiledURL` on the first compute-unit configuration that can
    /// actually run `probe`.
    ///
    /// Deliberately NOT `.all`. A model whose output shape depends on sequence
    /// length is refused by the Neural Engine — at *prediction* time, by writing
    /// an opaque Espresso "Invalid blob shape" diagnostic straight to **stdout**,
    /// which corrupts `--format json` for the caller and cannot be undone from
    /// Swift (measured on a RoBERTa export: 19 KB of garbage ahead of the
    /// report). Even probing `.all` first is unsafe, because the probe's own
    /// failure is what prints it. Nothing is lost by skipping it: over 230
    /// snippets `.cpuAndGPU` measured 5.29 s against 5.49 s for `.all`.
    static func loadRunnable(
      compiledURL: URL,
      probe: (MLModel) -> Bool
    ) throws -> MLModel {
      for units in [MLComputeUnits.cpuAndGPU, .cpuOnly] {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        guard let candidate = try? MLModel(contentsOf: compiledURL, configuration: configuration)
        else { continue }
        if probe(candidate) { return candidate }
      }
      throw SemanticEmbeddingError.modelLoadFailed(
        underlying: LoaderError.noWorkingComputeUnit(compiledURL.lastPathComponent))
    }

    enum LoaderError: Error, CustomStringConvertible {
      case noWorkingComputeUnit(String)

      var description: String {
        switch self {
        case .noWorkingComputeUnit(let name):
          """
          \(name) failed a trial prediction on every compute unit (GPU, CPU) — \
          the export is likely incompatible with this Core ML runtime
          """
        }
      }
    }
  }
#endif
