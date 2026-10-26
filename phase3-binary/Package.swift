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
        // Fork tag 3.32.3-macprovider.10.5 (branch campaign/2111-dsv4-cb), on tag
        // 3.32.3-macprovider.10.4 (676a62a4), on tag 3.32.3-macprovider.10.3, then
        // 3.32.3-macprovider.10.1 (branch glm53/tuple-0324, on 3.32.3-macprovider.10):
        // upstream mlx-swift-lm 3.32.3 plus the 3.32.3-macprovider.9 stack (the
        // packed MTP verification, fused A3B MoE, GDN checkpoint and compiled
        // MTP verification step commits upstream does not carry, and upstream
        // #631 with every Qwen3.5 trace declaring the arrays it reads as
        // compile state) and the GLM-5-Next text model with batched rows. It
        // resolves the Augustas11/mlx-swift fork (tag 0.32.3-macprovider.9, MLX
        // core v0.32.4-macprovider.4), whose MLX core keeps small-M quantized
        // matmuls on one kernel route so a row decodes the same tokens alone
        // and inside a continuous batch (the startup batched-isolation gate),
        // erases a freed compiled function from every thread's compile cache
        // so a model reload cannot replay a dead trace, and keeps internal
        // casts and broadcasts on the caller's stream so one decode step runs
        // on one Metal queue. 10.3 adds campaign #2111's deepseek_v4 text model
        // and its reference prefill plan, two commits on 10.1's revision 87dc5159.
        // 10.4 adds row-owned batched pool/window decode and corrects incomplete
        // multi-token pooling continuation. 10.5 shares attention, compressor/indexer
        // projections and rotary offsets across rows, with keys-only windows and
        // geometric pool storage; other family decode paths are unchanged.
        .package(
            url: "https://github.com/Augustas11/mlx-swift-lm.git",
            revision: "c8be0f618df1e0df230137a3cbe932aa798d602b"
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
            name: "MacProviderImageGen",
            dependencies: [
                // Reuse the pinned fork's MLX/MLXNN dependency graph.
                .product(name: "MLXLMCommon", package: "mlx-swift-lm")
            ],
            path: "Sources/MacProviderImageGen",
            exclude: ["LICENSE", "README.md"]
        ),
        .testTarget(
            name: "MacProviderImageGenTests",
            dependencies: ["MacProviderImageGen"],
            path: "Tests/MacProviderImageGenTests"
        ),
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
                "MacProviderImageGen",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
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
