// swift-tools-version: 6.1
import PackageDescription

// Isolated, local-only benchmark package — never wired into CI, so a
// beta-toolchain incompatibility here can never block the main build.
// Baselines are committed (.benchmarkBaselines) so every later engine stage
// compares against the recorded stage-0 numbers.
let package = Package(
  name: "benchmarks",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(path: ".."),
    .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.27.0"),
  ],
  targets: [
    .executableTarget(
      name: "DollyBenchmarks",
      dependencies: [
        .product(name: "Benchmark", package: "package-benchmark"),
        .product(name: "DollyCore", package: "dolly"),
      ],
      path: "Benchmarks/DollyBenchmarks",
      plugins: [
        .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
      ]
    ),
    .testTarget(
      name: "BenchmarksSmokeTests",
      dependencies: [.product(name: "DollyCore", package: "dolly")]
    ),
  ]
)
