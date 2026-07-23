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
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DollyCore", targets: ["DollyCore"]),
        .executable(name: "dolly", targets: ["dolly"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "DollyCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "dolly",
            dependencies: [
                "DollyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "DollyCoreTests",
            dependencies: ["DollyCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
