# MLX Decode-Engine Perf Upgrade — Roll-up Report

**Date:** 2026-06-30
**Branch:** `perf/mlx-compile-bf16`
**Spec:** `specs/perf-mlx-compile-bf16-upgrade.md`
**Reference design:** [Layr-Labs/d-inference#482](https://github.com/Layr-Labs/d-inference/pull/482)
**Companion docs:** `mlx-upgrade-report.md`, `perf-deferred.md`

## Summary table

| Phase | Item | Outcome | TPS delta | Default state | Notes |
|---|---|---|---|---|---|
| 1 | MLX upgrade | Path C (stay) | n/a (no bench) | n/a | pin: 2.29.1 → 2.29.1; mlx-swift override blocked by transitive `.upToNextMinor` constraint. See [mlx-upgrade-report.md](./mlx-upgrade-report.md). |
| 2 | Baseline + bench harness | Harness shipped; live baseline deferred to M-series operator | — | — | `macprovider-cli decode-bench` subcommand added; output schema versioned; `state/perf/*.json` location latched. |
| 3 | bf16 weight cast | Shipped behind env flag | not measured here | OFF | `MACPROVIDER_BF16_WEIGHTS=1` enables; wired into both `loader` (warm-swap) and bootstrap load. |
| 4 | `compile()` decode wrapper | Scaffolding shipped, runtime wire-in deferred to follow-up | not measured here | OFF | `MACPROVIDER_COMPILED_DECODE=1` (currently inert in runtime; bench reports flag state for reproducibility). |
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

## Live-execution checklist (M-series operator follow-up)

To turn this PR's scaffolding into shipped perf, a future session on
the production-class Mac should:

1. `swift build -c release` in `phase3-binary/`.
2. Run baseline:
   ```bash
   macprovider-cli decode-bench --model <target> --label baseline
   ```
   Confirm `state/perf/baseline-<model>-mlxsx-2.29.1-<ts>.json` exists.
3. Run bf16:
   ```bash
   MACPROVIDER_BF16_WEIGHTS=1 macprovider-cli decode-bench \
     --model <target> --label bf16-on
   ```
   Compare decode TPS p50 vs baseline. Sanity-check output quality
   on a held-out prompt.
4. Wire `CompiledDecodeStep` into `ModelRuntime`'s decode loop
   (currently the runtime ignores `MACPROVIDER_COMPILED_DECODE`).
   With the wire-in, run with the flag on; FIRST verify token-exact
   equivalence vs OFF on a deterministic prompt (greedy decode,
   temperature=0); THEN measure TPS.
5. Apply the spec's Phase 4 decision gate:
   - Lift ≥15% with matching outputs → leave flag, prep follow-up PR
     to flip default ON.
   - Lift 5–15% → leave flag OFF; needs cross-model evaluation.
   - Lift <5% or correctness break → document in a new audit note
     "compile() revisit when mlx-swift ships compile-friendly API"
     and leave the scaffolding inert.

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
