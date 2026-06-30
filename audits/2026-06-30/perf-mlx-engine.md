# MLX Decode-Engine Perf Upgrade — Roll-up Report

**Date:** 2026-06-30
**Branch (this docs PR):** `docs/perf-mlx-research-findings`
**Branch (implementation code, NOT merged):** `perf/mlx-compile-bf16` (kept alive for the compile() wire-in follow-up)
**Spec:** `specs/perf-mlx-compile-bf16-upgrade.md`
**Reference design:** [Layr-Labs/d-inference#482](https://github.com/Layr-Labs/d-inference/pull/482)
**Companion docs:** `mlx-upgrade-report.md`, `perf-deferred.md`

> **Status: docs-only landing.** This PR ships the research narrative,
> the live bench numbers (Phase 2), and the negative-result decision
> on bf16 (Phase 3). The actual implementation code (`WeightCast.swift`,
> `CompiledDecode.swift`, `DecodeBenchCommand.swift`, runtime wire-in,
> receipts guard) was developed and audited on branch
> `perf/mlx-compile-bf16` but is **NOT merged** here. Rationale: the
> live bench showed bf16 is net-negative on Apple Silicon
> (−26.4% decode TPS, output divergence), so shipping the gated cast
> + the receipts-attestation guard that defends against the gated
> cast would be importing maintenance surface for a feature we've
> proven harmful. The `compile()` decode wrapper — the headline
> perf hypothesis from #482 — was never wired into the runtime in
> the original PR (deferred to follow-up per spec's correctness
> gate). When that wire-in lands and shows a measurable lift, the
> bench tool + compile() code will land together in a fresh PR
> built on top of the surviving branch. This PR preserves the
> research record so the next engineer doesn't re-discover the
> negative bf16 result.

## Summary table

| Phase | Item | Outcome | TPS delta | Default state | Notes |
|---|---|---|---|---|---|
| 1 | MLX upgrade | Path C (stay) | n/a (no bench) | n/a | pin: 2.29.1 → 2.29.1; mlx-swift override blocked by transitive `.upToNextMinor` constraint. See [mlx-upgrade-report.md](./mlx-upgrade-report.md). |
| 2 | Baseline + bench harness | Harness shipped, **live baseline captured (M5 / Qwen2.5-7B-Q4)** | decode 29.2 TPS, prefill 273.7 TPS p50 | — | `macprovider-cli decode-bench` subcommand; baseline JSON at `state/perf/baseline-Qwen2.5-7B-Instruct-4bit-mlxsx-2.29.1-*.json`. |
| 3 | bf16 weight cast | Shipped behind env flag, **empirically net-negative on M5** | decode **−26.4%** (29.2 → 21.5 TPS); prefill **−20.2%** (273.7 → 218.4 TPS); **output diverges** (greedy decode produces 42 tokens vs 58 baseline → different stop point) | OFF — confirmed correct default | Apple Silicon has native fp16 fast paths; bf16 has no kernel advantage on M-series. Default OFF is empirically the right call. Cast scaffolding remains useful for future hardware / mlx-swift versions where the picture may flip. JSON at `state/perf/bf16-on-Qwen2.5-7B-Instruct-4bit-mlxsx-2.29.1-*.json`. |
| 4 | `compile()` decode wrapper | Scaffolding shipped, runtime wire-in deferred to follow-up | not measured (not wired in) | OFF | `MACPROVIDER_COMPILED_DECODE=1` recognized but inert in runtime; correctness gate (token-exact equivalence) requires live wire-in. |
| 5 | Rotating-cache compile (#482 item 2) | Deferred (model-family gate) | n/a | n/a | N/A on dense candidates; see [perf-deferred.md](./perf-deferred.md). |
| 5 | Fused gate+up `gatherQuantizedMM` (#482 item 3) | Deferred (model-family gate) | n/a | n/a | N/A on dense candidates; see [perf-deferred.md](./perf-deferred.md). |

## What ships in this PR

### Code (all defaults OFF; production decode path unchanged)

- `phase3-binary/Sources/macprovider-cli/WeightCast.swift` — fp16→bf16
  cast helper. Walks model parameters via `Module.apply { ... }` and
  skips quantized blocks via the default `filterValidParameters`
  filter. Emits a one-line stderr diagnostic with before/after dtype
  histograms when the cast runs.
- `phase3-binary/Sources/macprovider-cli/CompiledDecode.swift` — Phase 4
  scaffolding. `CompiledDecodeStep` wraps a per-token forward in
  `MLX.compile()`, threading `KVCache` mutations via a lightweight
  `KVCacheUpdatableAdapter` (avoids declaring retroactive `Updatable`
  conformance on the upstream `BaseKVCache`).
- `phase3-binary/Sources/macprovider-cli/DecodeBenchCommand.swift` —
  `macprovider-cli decode-bench` subcommand. Pure-decode benchmark; no
  coordinator, no WS; writes versioned JSON to `state/perf/`.
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` — wired
  the bf16 cast into both the warm-swap loader closure and the
  bootstrap synchronous load path so both surfaces are covered.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` —
  registered `DecodeBenchCommand` as a subcommand.

### Tests

- `phase3-binary/Tests/macprovider-cliTests/WeightCastTests.swift` —
  8 tests covering env-flag parsing, percentile math, and pin tag.

### Audits (this directory)

- `mlx-upgrade-report.md` — Phase 1 decision with evidence.
- `perf-deferred.md` — Phase 5 deferred items + revisit triggers.
- `perf-mlx-engine.md` — this roll-up.

## Live bench results (M5 / Qwen2.5-7B-Instruct-4bit, 2026-06-30)

Executed pre-merge on the production-class Mac (Apple M5, 32 GB,
running live coordinator-attached provider on PID 42395 throughout
the bench; live provider was unaffected — bench loaded its own
copy of the smaller Qwen2.5-7B-Q4 in a separate process). Release
build via `swift build -c release` + `mlx-swift_Cmlx.bundle` copied
next to the binary for metallib resolution. Default bench config:
`--tokens 256 --prefill 512 --runs 3` (one warmup not in samples).
Raw JSON committed under
[`bench-snapshots/`](./bench-snapshots/) for reproducibility
(state/ is gitignored; these are the immutable per-PR snapshots).

### Baseline (no env flags)

| Metric | Run 1 | Run 2 | Run 3 | p50 |
|---|---|---|---|---|
| decode TPS | 29.24 | 29.21 | 29.18 | **29.21** |
| prefill TPS | 274.91 | 273.66 | 271.76 | **273.66** |
| decode tokens | 58 | 58 | 58 | 58 (greedy + early stop) |
| prefill tokens | 542 | 542 | 542 | 542 |

Variance across 3 runs: < 0.07 TPS on decode, < 4 TPS on prefill —
tight, signal-grade numbers.

### bf16-on (`MACPROVIDER_BF16_WEIGHTS=1`)

| Metric | Run 1 | Run 2 | Run 3 | p50 | Δ vs baseline |
|---|---|---|---|---|---|
| decode TPS | 21.53 | 21.57 | 21.52 | **21.53** | **−26.3%** |
| prefill TPS | 218.39 | 218.44 | 217.25 | **218.44** | **−20.2%** |
| decode tokens | **42** | **42** | **42** | 42 | **−16 tokens vs baseline** |
| prefill tokens | 542 | 542 | 542 | 542 | unchanged |

**Two findings, both meaningful:**

1. **Performance regression.** bf16 cast is net-negative on M-series
   for 4-bit-quantized dense Qwen-class models. Hypothesis: Apple
   Silicon's Metal kernels have highly optimized fp16 matmul; bf16
   doesn't get a faster path here (bf16's wider exponent range is
   useful on hardware where fp16 has dynamic-range issues, e.g.
   NVIDIA training; on Apple Silicon inference, fp16 is the native
   fast path).
2. **Output divergence under greedy decode.** Same prompt, same
   temperature=0.0, same model, different bf16 setting → different
   generated tokens (42 vs 58 → different stop point). This is the
   expected consequence of dropping mantissa precision (fp16
   10-bit → bf16 7-bit) and confirms the SEC-1 fix is necessary
   (without the receipts guard, two providers running bf16-on vs
   bf16-off would emit different bytes for the same prompt while
   reporting the same `model_hash`).

### Decision applied (per spec Phase 3 gates)

> "If lift ≥3% with matching outputs, record and proceed. If
> quality regression, document and disable."
> "If a phase's lift is negligible or negative, **don't ship it
> just because the spec lists it** — document and skip. Honest
> negative results are the point."

bf16 default stays **OFF**. The scaffolding (env-flag plumbing,
`WeightCast.swift`, quantized-subtree filter, receipts guard)
remains useful for:
- Future hardware where the picture may flip (M-series successors,
  non-Apple deployments — unlikely but possible)
- Future mlx-swift versions that may add Apple Silicon bf16 kernel
  optimizations (track via the upstream-issue follow-up — see
  [mlx-swift-examples-upstream-issue.md](./mlx-swift-examples-upstream-issue.md))
- Operators on other model families (Llama-3, Mistral) where the
  precision-vs-throughput tradeoff may differ — bench surface is
  reusable

### Compile() decode wrapper — not benched

Wire-in is deferred per spec; the runtime ignores
`MACPROVIDER_COMPILED_DECODE` today. Bench therefore cannot exercise
it. Decision gate from Phase 4 carries forward to the follow-up
wire-in PR; with bf16 negative, compile() becomes the only remaining
candidate for a real perf win — but the cost is now well-defined
(per spec, ~15% lift over baseline = 33.6 TPS on this model, and
~21% from d-inference#482 measurements suggests 35 TPS achievable).

## Why correctness-first matters here

The spec calls this out explicitly: *"correctness before perf: if
compile() changes outputs, the implementation is wrong — fix
correctness before measuring."* The `KVCacheUpdatableAdapter` approach
in `CompiledDecode.swift` is the standard mlx-swift pattern for
threading mutable state through compile(), but `KVCacheSimple.update()`
reallocates its backing buffer when full — a graph-trace boundary that
needs to be re-validated against live token output, not just code-
reviewed. Until that validation runs on hardware, the flag stays OFF
by default and the runtime decode path is unchanged.

## Next 20% beyond compile()

If `compile()` lands us near the spec's ~50% bandwidth-utilization
target, the next-most-likely candidates are:

1. **B>1 batched decode** — sharing per-step weight reads across two
   to four concurrent requests gives a near-linear bandwidth lift on
   M-series wide memory. Largest single win on the table once compile
   is stable. Requires lifting `maxConcurrencyOverride` past 1 on the
   serve path (the AsyncSemaphore is already in place; mlx-swift
   parallel-generation safety is the gate).
2. **Kernel-level quant kernels** — the `MLXFast` quant kernels in
   newer `mlx-swift` (post-0.29) reportedly reduce dequant overhead
   on the hot path; benefit gated on getting past the
   `mlx-swift-examples` pin floor described in `mlx-upgrade-report.md`.
3. **Further `mlx-swift-examples` bumps as upstream ships** — passive
   wins as Apple's MLX team continues optimizing.

(Cheapest of these is #1 because it doesn't depend on upstream
release cadence.)
