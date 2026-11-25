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
      revision: "429602d69219a9063c443b9dd6bfcc9b75ae3d33"),
    .package(
      url: "https://github.com/g-cqd/analyzerkit.git",
      revision: "cb3bce90930110980509460a59b902362caceacf"
    ),
    .package(
      url: "https://github.com/g-cqd/AemiProtobuf.git",
      revision: "13ed22e06bc9febdf2a8135a3145ae7305bc07e2"
    ),
    .package(
      url: "https://github.com/g-cqd/AemiJSON.git",
      revision: "33ee6739c071fb1e647fa2fd8c2587534cb0f00c"
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
