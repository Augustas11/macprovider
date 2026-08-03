// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "phase3-binary",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MacProviderCore",
            targets: ["MacProviderCore"]
        ),
        .executable(
            name: "macprovider-cli",
            targets: ["macprovider-cli"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "3.31.4"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.0.0"
        ),
        // swift-transformers 1.0.0 resolves swift-jinja 2.3.6 transitively; pin
        // it directly so `import Jinja` (native null tool-schema rendering,
        // issue #718) binds to the same reviewed version.
        .package(
            url: "https://github.com/huggingface/swift-jinja.git",
            exact: "2.4.2"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.101.3"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
        )
    ],
    targets: [
        .target(
            name: "MacProviderCore",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/MacProviderCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "macprovider-cli",
            dependencies: [
                "MacProviderCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Jinja", package: "swift-jinja"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/macprovider-cli",
            resources: [
                .copy("Resources/spec028")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "macprovider-cliTests",
            dependencies: [
                "MacProviderCore",
                "macprovider-cli",
                // Real-model paged-KV parity fixtures (PagedKVParityTests) load MLX models
                // from the local HF cache and drive the paged gather. Test-target only —
                // the shipped product dependency set / pins are unchanged.
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Tests/macprovider-cliTests",
            resources: [
                .copy("Fixtures/SPEC015_v03_jcs/null_hash.json"),
                .copy("Fixtures/SPEC015_v03_jcs/non_null_hash.json"),
                .copy("Fixtures/SPEC015_v03_jcs/README.md"),
                .copy("Fixtures/SPEC019"),
            ]
        ),
        .testTarget(
            name: "MacProviderCoreTests",
            dependencies: [
                "MacProviderCore",
            ],
            path: "Tests/MacProviderCoreTests"
        ),
        .testTarget(
            name: "mlx-stage-spikeTests",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Tests/mlx-stage-spikeTests",
            exclude: ["README.md"]
        )
    ]
)
