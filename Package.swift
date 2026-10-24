// swift-tools-version: 6.4
import PackageDescription

// Strict-by-default: warnings are errors; upcoming features are on so the code
// is already valid under the next language mode's semantics, and strict memory
// safety keeps the unsafe surface at zero. Swift 6 language mode (below)
// already includes complete strict concurrency.
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
    // swift-system supplies the one thing FoundationEssentials lacks for a CLI:
    // a safe, Sendable stderr handle. Foundation's FileHandle would re-link
    // ~50 MiB of ICU on Linux; the C `fputs` route needs three separate unsafe
    // markers. One small, dependency-free Apple package is the better trade.
    .package(url: "https://github.com/apple/swift-system.git", from: "1.8.1"),
    // The project model the analyzers share: previews, test code, generated
    // files. Pinned by revision, as the other analyzers pin it.
    .package(
      url: "https://github.com/g-cqd/analyzerkit.git",
      revision: "a9c1e991dfa077077b41c7071e0051fba6431f92"
    ),
  ],
  targets: [
    .target(
      name: "DollyCore",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "ProjectModel", package: "analyzerkit"),
        .product(name: "SourceCorpus", package: "analyzerkit"),
        .product(name: "ReportSupport", package: "analyzerkit"),
        .product(name: "WordPiece", package: "analyzerkit"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "dolly",
      dependencies: [
        "DollyCore",
        .product(name: "SourceCorpus", package: "analyzerkit"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SystemPackage", package: "swift-system"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "DollyCoreTests",
      dependencies: [
        "DollyCore", .product(name: "SourceCorpus", package: "analyzerkit"),
        .product(name: "WordPiece", package: "analyzerkit"),
      ],
      resources: [.copy("Fixtures")],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
