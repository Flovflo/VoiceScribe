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
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4")
    ],
    targets: [
        .target(
            name: "VoiceScribeCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/VoiceScribeCore"
        ),
        .executableTarget(
            name: "VoiceScribe",
            dependencies: ["VoiceScribeCore"],
            path: "Sources/VoiceScribe",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "VoiceScribeTests",
            dependencies: ["VoiceScribeCore"]
        )
    ]
)
