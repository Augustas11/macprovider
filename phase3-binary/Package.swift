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
        // Tag 3.32.3-macprovider.48 (#2111) is .47 plus the DeepSeek V4
        // campaign commits: DeepSeek's reference norm, rotary, hyper-connection,
        // router and indexer arithmetic, the DSpark drafter, shared MXFP8
        // multi-row projection tiles, last-position-only serving prefill logits
        // and row-invariant decode selection and attention kernels that serial
        // and batched rows share. Other families keep .47 arithmetic; the
        // DeepSeek-only hyper-connection options default off.
        // Tag 3.32.3-macprovider.47 (#2256) is .44 (MiniMax) plus one commit: the
        // mlx-swift 0.32.3-macprovider.18 pin. mlx-swift .18 is .13 with the
        // MLX core gitlink on v0.32.4-macprovider.10 (26ac61533), which sends
        // every small-M affine product whose K is not a multiple of 128
        // (gpt-oss, K = 2880) to qmv_wide for every row count on gen 15 and 16
        // GPUs, one row included; other shapes and gen 17 keep their routes.
        // qmv_wide reduces each vector in an order the vector tile does not
        // change, so a row keeps its serial result while up to 5 rows share one
        // read of the weights.
        // Tag 3.32.3-macprovider.44 (#2189, #2284) is .43 (#2230) plus five MiniMax M3
        // commits in MiniMaxM3.swift and its tests: the float32 router reads
        // the one-launch norm's float32 copy, a one-launch clamped SwiGLU on
        // the fused gate/up gather, the shared expert's and dense MLPs'
        // gate/up fused at load, and a one-launch expert combine, each
        // bitwise the path it replaces, per row; plus the seeded fused-norm
        // test. No other model's code and no shared code.
        // Tag 3.32.3-macprovider.43 (#2230) is .42 plus seven commits: the
        // Mamba2 segsum batch-mask fix and its test, upstream #728 (cache-list
        // attention masks sized from the live rows), #703 (quantized-KV prefill
        // blocks of 64+ query tokens through the fused SDPA kernel), #712/#754
        // (Nemotron 3.5 text models, Mamba activations in the input dtype) and
        // #747 (rotating-cache keep mask for multi-token blocks). Upstream #740
        // (MLXFast gated delta) is left out: its chunked prefill breaks the
        // serial-versus-batched parity paged KV needs on Qwen3.6.
        // Tag 3.32.3-macprovider.42 (#2254, #2255) is .40 plus two GPT-OSS
        // commits: `3490b04` clips the GPT-OSS SwiGLU with plain Float bounds,
        // so bf16 activations stay bf16 instead of promoting to f32, and
        // `e0cac07` adds a lab-only gpt-oss per-layer dump, off unless
        // MLX_LM_GPTOSS_LAYER_DUMP is set. GPTOSS.swift and its tests only.
        // Tag 3.32.3-macprovider.40 (#2231) is .38 plus three commits: the
        // LiquidAI LFM3 text model (`lfm3`, upstream ml-explore/mlx-swift-lm
        // #750) and its registry entry, the #756 hardening (config and
        // tokenizer validation, padded conv rows masked) and the integration
        // project's swift-transformers 1.4.0 requirement. New model files, a
        // registry line and a default no-op `validate(tokenizer:)`; no other
        // model's code and no shared cache, attention or generation code.
        // Tag 3.32.3-macprovider.38 (#2265) is .35 plus two commits: the
        // mlx-swift 0.32.3-macprovider.13 pin (#2234) and GLM-5-Next projecting
        // 1...8 decode tokens with one kernel, so its rows stay bitwise when
        // MLX itself takes qmv_mma (GPUs without NAX). mlx-swift .13 pins core
        // 565070fe4, which sends every eligible affine small-M product to
        // qmv_mma from 1 to 16 rows, so the kernel never depends on the row
        // count, and its metallib ships the gather_mm_offsets and SDPA VJP
        // kernels that core calls. .35 (#2270) on .32 adds the `ricursive`
        // text model (Ripple-65B Preview) and its 2048-token prefill chunk.
        // Tag 3.32.3-macprovider.32 (#2244, #2189) on 3.32.3-macprovider.25:
        // `6c27b74` (from `73df016af`) maps a Hugging Face per-layer
        // quantization map to module paths at load, so the Solstice-AI
        // uncensored GLM-5.3-Flash checkpoint loads. Decode is unchanged.
        // Tag 3.32.3-macprovider.25 (#2198, #2189) on 3.32.3-macprovider.24:
        // .23's GLM-5.3 MTP head prefill over the last 4096 prompt columns
        // (`da8f193`, from `93234b6`) on top of .24's MiniMax M3 work.
        // Tag 3.32.3-macprovider.23 (#2198) on 3.32.3-macprovider.21: GLM-5.3
        // MTP head prefills the last 4096 prompt columns (NoPE); prompts
        // within 4096 unchanged.
        // Tag 3.32.3-macprovider.24 (#2189) on 3.32.3-macprovider.22: The
        // MiniMax M3.1-Flash checkpoint loads within 256 GB: the gate/up
        // tensors that load-time fusion replaces are freed as each layer
        // fuses instead of staying resident beside the fused weights.
        // Tag 3.32.3-macprovider.22 (#2189) on 3.32.3-macprovider.21: MiniMax
        // M3 text model (`4f96c37`, `3c0a551`, `d755f93`), with each sparse
        // row keeping its own cache (`7feb4c3`) so a continuous batch matches
        // a serial forward of that row.
        // Tag 3.32.3-macprovider.21 (#2198) on 3.32.3-macprovider.19 changes
        // GLM-5.3 prefill only: DSA radix-select per prefill chunk, a fused
        // mHC Sinkhorn and heads-as-queries sparse attention. Decode is .19's.
        // Tag 3.32.3-macprovider.19 (#2200) is one commit on .18 that routes GPT-OSS
        // attention with its sinks through a conforming batched cache
        // (KVCacheSinkAttentionProtocol). Tag 3.32.3-macprovider.18 (#2201) adds the Qwen2-VL token-only text
        // forward and keeps Nemotron-H Mamba activations in the model dtype, on
        // 3.32.3-macprovider.12. Tag 3.32.3-macprovider.12 adds LFM-only reference-prefill arithmetic
        // on 3.32.3-macprovider.10.15.1 (reference expert order). Other models
        // retain the default route; single-token decode is unchanged. The core
        // Python binding preserves its existing arity and passes the option false.
        // Fork tag 3.32.3-macprovider.10.15 combines GLM MTP (10.13) and
        // Prism schema-2 loading, lazy vision and row-safe masks (10.14), on tag
        // 3.32.3-macprovider.10.5 (c8be0f61, campaign/2111-dsv4-cb), on tag
        // 3.32.3-macprovider.10.4 (676a62a4), on tag 3.32.3-macprovider.10.3, then
        // 3.32.3-macprovider.10.1 (branch glm53/tuple-0324, on 3.32.3-macprovider.10):
        // upstream mlx-swift-lm 3.32.3 plus the 3.32.3-macprovider.9 stack (the
        // packed MTP verification, fused A3B MoE, GDN checkpoint and compiled
        // MTP verification step commits upstream does not carry, and upstream
        // #631 with every Qwen3.5 trace declaring the arrays it reads as
        // compile state) and the GLM-5-Next text model with batched rows. It
        // resolves the Augustas11/mlx-swift fork (tag 0.32.3-macprovider.18, MLX
        // core v0.32.4-macprovider.10 (26ac61533) and mlx-c v0.6.0-macprovider.2). Core keeps
        // small-M quantized matmuls on one kernel route so a row decodes the same tokens alone
        // and inside a continuous batch (the startup batched-isolation gate),
        // erases a freed compiled function from every thread's compile cache
        // so a model reload cannot replay a dead trace, and keeps internal
        // casts and broadcasts on the caller's stream so one decode step runs
        // on one Metal queue. 10.3 adds campaign #2111's deepseek_v4 text model
        // and its reference prefill plan, two commits on 10.1's revision 87dc5159.
        // 10.4 adds row-owned batched pool/window decode and corrects incomplete
        // multi-token pooling continuation. 10.5 shares attention, compressor/indexer
        // projections and rotary offsets across rows, with keys-only windows and
        // geometric pool storage. 10.10 batches GLM MTP indexer projections and
        // compatible per-column attention while retaining row-owned caches.
        .package(
            url: "https://github.com/Augustas11/mlx-swift-lm.git",
            revision: "e246b8fd6ed35c6b1ab969c927222c06f759ec82"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.4.0"
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
            exact: "2.104.0"
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
