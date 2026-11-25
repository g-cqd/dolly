// swift-tools-version: 6.4
import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
  .treatAllWarnings(as: .error),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InferIsolatedConformances"),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .strictMemorySafety(),
]

let package = Package(
  name: "dolly",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DollyCore", targets: ["DollyCore"]),
    .executable(name: "dolly", targets: ["dolly"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
    .package(
      url: "https://github.com/Aemi-Studio/aemi.git",
      revision: "bd5e4cf4441ca3ed1b424935142586ccaac0f835"),
    .package(
      url: "https://github.com/g-cqd/analyzerkit.git",
      revision: "3b5d779d61e51a346fcb86c69ac3ab8ebcbdd6c0"
    ),
    .package(
      url: "https://github.com/g-cqd/AemiProtobuf.git",
      revision: "b31d62bbf28286aed1b394c0762257d745bbb530"
    ),
    .package(
      url: "https://github.com/g-cqd/AemiJSON.git",
      revision: "1c098f0456a2f86dee32dfd9b85455980216589f"
    ),
  ],
  targets: [
    .target(
      name: "DollyCore",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "AemiKernel", package: "aemi"),
        .product(name: "ProjectModel", package: "analyzerkit"),
        .product(name: "CorpusScan", package: "analyzerkit"),
        .product(name: "AnalyzerConfiguration", package: "analyzerkit"),
        .product(name: "SourceCorpus", package: "analyzerkit"),
        .product(name: "Suppression", package: "analyzerkit"),
        .product(name: "ReportSupport", package: "analyzerkit"),
        .product(name: "SemanticEmbedding", package: "analyzerkit"),
        .product(name: "AemiProtobuf", package: "AemiProtobuf"),
        .product(name: "AemiProtobufCore", package: "AemiProtobuf"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "dolly",
      dependencies: [
        "DollyCore",
        .product(name: "AnalyzerCLI", package: "analyzerkit"),
        .product(name: "AnalyzerConfiguration", package: "analyzerkit"),
        .product(name: "CorpusScan", package: "analyzerkit"),
        .product(name: "ProjectModel", package: "analyzerkit"),
        .product(name: "ReportSupport", package: "analyzerkit"),
        .product(name: "SourceCorpus", package: "analyzerkit"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SystemPackage", package: "swift-system"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "DollyCoreTests",
      dependencies: [
        "DollyCore", .product(name: "AemiKernel", package: "aemi"),
        .product(name: "SourceCorpus", package: "analyzerkit"),
        .product(name: "WordPiece", package: "analyzerkit"),
        .product(name: "SemanticEmbedding", package: "analyzerkit"),
        .product(name: "Suppression", package: "analyzerkit"),
        .product(name: "ReportSupport", package: "analyzerkit"),
        .product(name: "CorpusScan", package: "analyzerkit"),
        .product(name: "AemiProtobuf", package: "AemiProtobuf"),
        .product(name: "AemiJSON", package: "AemiJSON"),
      ],
      exclude: ["Goldens"],
      resources: [.copy("Fixtures")],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
