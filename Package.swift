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
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
    .package(
      url: "https://github.com/Aemi-Studio/aemi.git",
      revision: "32f1d61e0ee2fe19af99c1c1a040f1fbdae91d4a"),
    .package(
      url: "https://github.com/g-cqd/analyzerkit.git",
      revision: "682eadd1e42d1c0dda956a3325d691030c59b084"
    ),
    .package(
      url: "https://github.com/g-cqd/AemiProtobuf.git",
      revision: "dc010bdba44b44de354805ca5ba24d07dca3047d"
    ),
    .package(
      url: "https://github.com/g-cqd/AemiJSON.git",
      revision: "fdcf306b1ffbbd29161df787ae2ea97e56718d2c"
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
