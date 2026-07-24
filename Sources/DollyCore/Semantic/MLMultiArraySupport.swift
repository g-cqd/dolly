//  MLMultiArraySupport.swift
//  dolly
//
//  Shared Core ML input construction used by both the HF and raw Core ML
//  embedding providers, factored out so the two providers do not carry
//  near-identical MLMultiArray-building blocks.

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
#endif
