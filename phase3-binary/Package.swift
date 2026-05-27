// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "phase3-binary",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "macprovider-cli",
            targets: ["macprovider-cli"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-examples.git",
            exact: "2.29.1"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.65.0"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            exact: "1.6.0"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.5.0"
        ),
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "5.1.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "macprovider-cli",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/macprovider-cli",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "macprovider-cliTests",
            dependencies: ["macprovider-cli"],
            path: "Tests/macprovider-cliTests"
        )
    ]
)
