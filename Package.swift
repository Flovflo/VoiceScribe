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
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.10.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-nn", from: "0.10.0")
    ],
    targets: [
        .target(
            name: "VoiceScribeCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift-nn")
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
