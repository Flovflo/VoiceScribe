// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ASRBenchmark", platforms: [.macOS(.v14)],
    products: [.library(name: "BenchmarkMetrics", targets: ["BenchmarkMetrics"])],
    targets: [.target(name: "BenchmarkMetrics"), .testTarget(name: "BenchmarkMetricsTests", dependencies: ["BenchmarkMetrics"])]
)
