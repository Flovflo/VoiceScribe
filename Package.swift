// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceScribe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceScribe", targets: ["VoiceScribe"]),
        .library(name: "VoiceScribeCore", targets: ["VoiceScribeCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6")
    ],
    targets: [
        .target(
            name: "VoiceScribeCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/VoiceScribeCore"
        ),
        .executableTarget(
            name: "VoiceScribe",
            dependencies: ["VoiceScribeCore"],
            path: "Sources/VoiceScribe"
        ),
        .testTarget(
            name: "VoiceScribeTests",
            dependencies: ["VoiceScribeCore"]
        )
    ]
)
