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
        // Tag 3.33.0-macprovider.94 on 3.33.0-macprovider.92:
        // 3.33.0-macprovider.92 with only the mlx-swift pin moved to be16992
        // (0.33.0-macprovider.28 on MLX core 4ff2db419, the fork stack merged
        // with upstream mlx v0.32.5 with small-M routes 1 and 2 unchanged,
        // mlx-c 715780d); no model source changes.
        // Tag 3.33.0-macprovider.92 (#2505) on 3.33.0-macprovider.91: Inkling
        // 2 continuous batching: each batched row attends through the model's
        // own one-row attention over its paged cache, and batched one-token
        // rows route experts, take the one-row projection spans and the
        // close-gap verify head as they do alone, so CB rows match serial
        // greedy tokens; no other model's code changes.
        // Tag 3.33.0-macprovider.91 (#2474) on 3.33.0-macprovider.90: a
        // GLM-5.3-Flash sliced (wide) prefill projects only the last 64 rows of
        // its last slice to logits instead of every row (the batching route
        // samples the last row); the rows kept stay on MLX qmm and match the
        // full-width projection bit for bit. TTFT -1.3% at 3,673 tokens, noise
        // at 14,126, identical tokens (A/B/A on the M3 Ultra).
        // Tag 3.33.0-macprovider.90 (#2487) on 3.33.0-macprovider.89:
        // 3.33.0-macprovider.89 plus the Inkling 2 DSpark draft
        // (Inkling2DSparkDraftModel, loaded from mtp.safetensors and bound to
        // the loaded target), staged and rewound rounds over the target's
        // attention rings and convolution tails (ConvolutionTailCache,
        // CacheListRoundStrategy), target hidden-state taps and exact
        // one-dispatch verify rows; the shared MLXLMCommon changes are opt-in
        // (MTPExactVerifyLimitModel and MTPChunkedPromptHiddenModel target
        // protocols, and round staging of an attention plus convolution-tail
        // CacheList, which it refused before), so no other model's decode
        // path changes; the tag is cut from this revision at merge.
        // Tag 3.33.0-macprovider.89 (#2467) on 3.33.0-macprovider.88:
        // 3.33.0-macprovider.88 plus the Inkling 2 Mini text model
        // (inkling2_loop: model file, registry entry, tests and a tiny test
        // fixture) and its Ollama-ported decode kernels (fused attention
        // inputs, residual mix, message controllers, short convolutions,
        // router top-k, ring attention; new MLXLMCommon kernel files and a
        // read-only RotatingKVCache.ringRotation), rebased unchanged from
        // macprovider/2467-ollama-kernels (ea6f545c); no other model's code
        // changes. Measured on this revision (Studio run 20261124T073707Z):
        // 64/64 greedy parity against mlx-vlm on both layouts at 1K and 8K; on
        // the oQ4e weights 45.3/43.9/40.2 decode tok/s at 1K/8K/32K, 156-163%
        // of mlx-vlm, prefill 99-107%.
        // Tag 3.33.0-macprovider.88 (engine-333) on 3.32.3-macprovider.87: The
        // fork patch stack rebased onto upstream mlx-swift-lm 3.33.0, with the
        // mlx-swift pin at 0.33.0-macprovider.28 (upstream 0.33.0 plus the
        // small-M route and dense qmm tile), MLX core v0.32.4-macprovider.18
        // (.17 plus upstream mlx 4883, 4881, 4930) and mlx-c v0.8.0-macprovider.5.
        // Upstream 633 changes gated-delta Qwen text on purpose (q/k eps).
        // Tag 3.32.3-macprovider.87 (#2451) on 3.32.3-macprovider.86: Dense
        // qmm_t in the MLX core takes a 64-row tile from 1024 rows for affine
        // bfloat16 group-64 weights. No model source changes.
        // Tag 3.32.3-macprovider.86 (#2462) on 3.32.3-macprovider.85: The
        // small-M route is set per request (SPEC-038 FR-CB9 `mixed`): native
        // MTP graphs build under a row_invariant scope while ordinary requests
        // keep stock order; the MLX core captures the route per quantized
        // matmul at graph build. Other paths are unchanged.
        // Tag 3.32.3-macprovider.85 (#2451, #2448) on 3.32.3-macprovider.84:
        // GLM5Next prefill slices (`glm5NextPrefillSlicesKey`): the routed and
        // shared experts and dense MLPs run once over consecutive balanced
        // chunks while router, hyper-connections and attention stay per chunk,
        // bit-identical to separate forwards; on NAX GPUs slices join only when
        // the wide gather_qmm call keeps their row tile. Plus a Qwen4Exp
        // join/leave test and a GLM5NextTests type-check split. Other model
        // families and decode are unchanged.
        // Tag 3.32.3-macprovider.84 (#2409) on 3.32.3-macprovider.83: Six
        // commits on 3.32.3-macprovider.83 add the native qwen4_exp /
        // qwen4_exp_text text model (Qwen3.8-Flash-Next: QSA indexer,
        // hyper-connections, PLE n-gram) and its batched decode, each row bit for bit
        // its serial forward, with the rows' q/k norms, RoPE (one offset per
        // row) and output gate run once across the rows. New model files, the
        // two registry entries and their tests only; other model families are
        // unchanged.
        // Tag 3.32.3-macprovider.83 (#2373) on 3.32.3-macprovider.81: Three
        // commits on 3.32.3-macprovider.81 (tag .82 is the first two and was
        // never pinned): TokenIterator evaluates only the token for the K/V
        // buffers of KVCacheSimple and RotatingKVCache layers, as mlx-lm's
        // generate_step does, instead of naming them in every token's
        // evaluation; a zero-width buffer of such a layer (the DeepSeek V4
        // window values) and the state of every other cache stay in the
        // evaluation. It touches Evaluate.swift and its test only; the serial
        // route is the only serving path that uses TokenIterator.
        // Tag 3.32.3-macprovider.81 (#2328) on 3.32.3-macprovider.80: The
        // three Gemma 4 commits of the campaign (packed assistant drafter,
        // embedded assistant loader and target state emission; cache-owned
        // attention for row-safe batching; the two K/V-read layers attend
        // through the cache too), first carried by 3.32.3-macprovider.65 on
        // .63, cherry-picked onto 3.32.3-macprovider.80 without conflicts;
        // other model families, the native-MTP read-column pruning and the
        // Swift, core and C rows are as in .80.
        // Tag 3.32.3-macprovider.80 (#2393) on 3.32.3-macprovider.79: On
        // 3.32.3-macprovider.79, the last native-MTP layer (GLM-5-Next nextn
        // head, Qwen 3.5/3.6 MTP predictor) runs its post-attention norm and
        // MoE/MLP, and Qwen's final norm, on each row's read column only,
        // while attention and the drafter cache write still run on every
        // column (MLX_LM_MTP_LAST_COLUMN=0 runs every column again); carries
        // the #2373 candidate: TokenIterator settles simple and rotating
        // caches by their stored buffers, and Llama and Qwen3 run SwiGLU as
        // one compiled kernel.
        // Tag 3.32.3-macprovider.79 (#2338) on 3.32.3-macprovider.78: It is
        // 3.32.3-macprovider.78 plus one commit that only moves its mlx-swift
        // pin to 0.32.3-macprovider.25
        // (12d26ef6c6d65ba3a265a2b65c3c9380d9c22bd7), 0.32.3-macprovider.24
        // plus two Swift-layer commits: a synchronous eval schedules the
        // graph and copies its completion events under the process-wide
        // evalLock, waits for the device without the lock, then retakes the
        // lock to finish; recursive entry, a CPU stream and a failed
        // asynchronous schedule keep the stock locked path. The core and C
        // rows are unchanged and no Metal kernel changed.
        // Tag 3.32.3-macprovider.78 (#2389) is 3.32.3-macprovider.76
        // plus three commits that only move its
        // mlx-swift pin to 0.32.3-macprovider.24
        // (7fbcada97b58ddafab567121da63b959b8d092e3), whose MLX core
        // v0.32.4-macprovider.15 (4e9a71dc9e765f739003868f38d3aca05871e70d)
        // adds the SPEC-038 FR-CB9 stock-order small-row route
        // (MLX_METAL_SMALL_M_ROW_INVARIANT=2); the row-invariant route that
        // native MTP serves on is unchanged.
        // Tag 3.32.3-macprovider.76 (#2381) on 3.32.3-macprovider.71: Two
        // upstream fixes as picks: the serial prefill chunk loop clears the
        // MLX buffer cache after each chunk (ml-explore/mlx-swift-lm #710),
        // behind PrefillParameters.clearsBufferCache (default true) for hosts
        // without a Metal library, and an MLX error raised on the loader's
        // worker threads is thrown instead of ending the process (port of
        // ml-explore/mlx-swift-lm #698). No model source, decode step or
        // kernel route changes; continuous-batch prefill does not use the
        // chunk loop.
        // Tag 3.32.3-macprovider.71 (#2376) on 3.32.3-macprovider.63:
        // MiniMax M3 projects a refusal direction out of the attention and
        // MLP/MoE outputs of the configured decoder layers when the
        // refusal_ablation config key is present (the abliterated M3.1-Flash
        // variant), refusing an alpha outside 0 < alpha <= 4 or a direction
        // that is not a finite unit vector; an indexed checkpoint may store it
        // as language_model.refusal_direction. The text sanitize drops stored
        // model.layers.N.refusal_direction keys, so only the validated
        // direction sets them. 29b5778 (04a1d29 plus the audit fixes) touches
        // MiniMaxM3.swift and its tests only; a model without the key runs the
        // unchanged fused path.
        // Tag 3.32.3-macprovider.63 (#2352) on 3.32.3-macprovider.61:
        // DeepSeek V4 prefill can yield between evaluated tiles so other
        // continuous-batch rows decode while a reference prefill is in
        // flight. 8f88216 cherry-picks the .62 pause hook (505f368,
        // DeepseekV4.swift only) onto ef656c59.
        // Tag 3.32.3-macprovider.61 (#2327) on 3.32.3-macprovider.59:
        // Qwen2-VL and Qwen2.5-VL M-RoPE cos/sin take the hidden-state dtype,
        // so an image prefill no longer leaves the language model and its KV
        // cache in float32 (upstream ml-explore/mlx-swift-lm #766); FastVLM
        // image pixels take the patch-embed weight dtype and Mistral3 drops
        // its bfloat16 image-feature cast.
        // Tag 3.32.3-macprovider.59 (#2327) on 3.32.3-macprovider.58:
        // Qwen2-VL post-vision decode uses fused non-traditional RoPE when
        // the three M-RoPE axes share one rope delta; per-row deltas and
        // traditional RoPE stay on the position-id path.
        // Tag 3.32.3-macprovider.58 (#2335) on 3.32.3-macprovider.56: MLX core
        // v0.32.4-macprovider.14 (via mlx-swift 0.32.3-macprovider.22): one row
        // of a qualifying affine weight takes affine_qmv_mma1, a single-row
        // kernel with qmv_mma's exact reduction order, and rows 2-16 take
        // qmv_mma; a row is bit-identical alone and in a batch because the two
        // kernels are bit-identical (checked on M5 and M3 Ultra GPUs; not on
        // M1, M2 or M4). The switch point is a speed choice (M3 Ultra, Llama
        // 3.1 8B 4-bit, aggregate tok/s: 1 row 93 on qmv_mma1 against 75 on
        // qmv_mma, 2 rows 120 against 146). MLX_METAL_SMALL_M_ROW_INVARIANT,
        // read once per process with atoi, keeps that window by default; a
        // value that parses to 0 skips it for the fork's pre-window small-row
        // routing (per-row qmv below the qmm limit), which the provider sets
        // only for a serial-only serve process (SPEC-038 FR-CB9). Measured on
        // the M3 Ultra, Llama 3.1 8B 4-bit, one row over HTTP against stock
        // mlx-lm in the same window: serial-only route 0.93 to 0.97x,
        // row-invariant route 0.81 to 0.84x, main 0.65 to 0.71x. Core
        // `pytest python/tests/test_quantized.py -k small_m`: 5 passed at
        // 0f26baba on the M3 Ultra. Not measured on M1.
        // Tag 3.32.3-macprovider.56 (#2305) is .49 plus four DeepSeek V4-only
        // prefill commits (tile pipelining, grouped MoE expert launches, grouped gather_qmm, expert-batch memory bound): attention and indexer prefill tiles are evaluated one
        // ahead (asyncEval, at most two in flight) and on the M3 Ultra the MoE prefill groups wide-route experts into one launch per row-count group and serves gathered plain and split-K runs with sorted gather_qmm (single-row experts and declined gathers stay per expert), in ascending-id expert batches of at most 49,152 routed rows, with the per-token sum over the selected experts in ascending expert order in float32. Outputs are bit-identical to the per-expert loop.
        // Tag 3.32.3-macprovider.49 (#2307) is .48 plus one tests-only commit:
        // the GLM-5-Next row-invariance test checks row counts up to the
        // provider's per-forward decode bound (core qmv limit minus 1, see
        // ContinuousBatchDecodeRouteBound), and two GLM-5-Next tests use a
        // tolerance derived from TF32 error on GPUs that run float32 matmuls
        // in TF32. No library code changes.
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
        // resolves the Augustas11/mlx-swift fork (tag 0.32.3-macprovider.25, MLX
        // core v0.32.4-macprovider.15 (4e9a71dc9) and mlx-c v0.6.0-macprovider.2). Core keeps
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
        // #2462: branch macprovider/2462-route-on-main (bcffd492) is
        // 3.32.3-macprovider.85 (8aa564db) with only the mlx-swift pin moved to
        // aaa8265, .25 plus a per-op small-M route (core dd68f1d2d on .15, mlx-c
        // 70f188c on v0.6.0-macprovider.2): QuantizedMatmul captures the route at
        // graph build from a thread scope (withSmallMRoute).
        // #2451: branch macprovider/2451-dense-tile (0efe0402) is
        // 3.32.3-macprovider.86 (bcffd492) with only the mlx-swift pin moved to
        // e7243b3, .26 plus the core dense qmm_t 64-row tile (core 6c2ac790c on
        // dd68f1d2d; mlx-c unchanged).
        .package(
            url: "https://github.com/Augustas11/mlx-swift-lm.git",
            revision: "0d9aaeeba002d8e814cdf0661d74dfbf3ef5294d"
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
