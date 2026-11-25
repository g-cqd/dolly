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
      revision: "9e38d1bee60d5d65acffef4538c671b49860c6af"),
    .package(
      url: "https://github.com/g-cqd/analyzerkit.git",
      revision: "2e54cc659fab831ff3294c00b6e013fca15d45d8"
    ),
    .package(
      url: "https://github.com/g-cqd/AemiProtobuf.git",
      revision: "a472d8c967c0fb6b5cab2e12b011c7a0ca3d9248"
    ),
    .package(
      url: "https://github.com/g-cqd/AemiJSON.git",
      revision: "9144b71be7714e15db293197b47edcc55ffde71b"
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
