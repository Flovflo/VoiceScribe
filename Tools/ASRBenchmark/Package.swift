// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ASRBenchmark", platforms: [.macOS(.v14)],
    products: [.executable(name: "asr-benchmark", targets: ["ASRBenchmark"])],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "8d86630ade569728aaea3dc1a29fc44e2efa719b"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.6")
    ],
    targets: [
        .target(name: "BenchmarkMetrics"),
        .executableTarget(name: "ASRBenchmark", dependencies: ["BenchmarkMetrics",
            .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXNN", package: "mlx-swift")]),
        .testTarget(name: "BenchmarkMetricsTests", dependencies: ["BenchmarkMetrics"])
    ]
)
