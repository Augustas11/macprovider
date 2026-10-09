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
        // Fork tag 3.32.3-macprovider.2: upstream mlx-swift-lm 3.32.3 plus the
        // packed MTP verification, fused A3B MoE and GDN checkpoint commits
        // upstream does not carry. It resolves the Augustas11/mlx-swift fork
        // (tag 0.32.3-macprovider.1), whose MLX core keeps small-M quantized
        // matmuls on one kernel route so a row decodes the same tokens alone
        // and inside a continuous batch (the startup batched-isolation gate).
        .package(
            url: "https://github.com/Augustas11/mlx-swift-lm.git",
            revision: "37f0d7ceacf6f5eca3ec2ceddc96d0f6e91ed2f1"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.4"
        ),
        // swift-transformers 1.3.4 resolves swift-jinja 2.4.2 transitively; pin
        // it directly so `import Jinja` (native null tool-schema rendering,
        // issue #718) binds to the same reviewed version.
        .package(
            url: "https://github.com/huggingface/swift-jinja.git",
            exact: "2.5.1"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.103.0"
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
                .enableExperimentalFeature("StrictConcurrency"),
                // SPEC-049 privacy fixture seams compile only into debug/test builds.
                .define("MACPROVIDER_TEST_FIXTURES", .when(configuration: .debug))
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
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
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
