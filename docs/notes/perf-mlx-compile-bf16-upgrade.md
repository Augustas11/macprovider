# MLX Decode-Engine Perf Upgrade — Implementation Spec

> Paste this prompt into a fresh Claude Code session rooted in
> `/Users/augstar/macprovider-poc`. Self-contained; no prior context needed.

---

# Mission

Adopt the upstream-portable subset of the Darkbloom (Layr-Labs/d-inference)
mlx-swift-lm decode-perf work into `macprovider-poc`. Source PR for the work
pattern: [Layr-Labs/d-inference#482](https://github.com/Layr-Labs/d-inference/pull/482).
We are NOT depending on Darkbloom's fork — we adopt only the underlying upstream
MLX features they leverage, on our `mlx-swift-examples` pin (bumping it first
if a newer upstream version exists).

Target lift, on dense Qwen2.5 / Llama-3.2 at B=1: **+15–25% TPS**. Bandwidth
utilization target: ~50%+ of theoretical (we're currently in the ~25% land
that #482 measured before compile).

# Background — must read before starting

- Current pin: `phase3-binary/Package.swift` has
  `mlx-swift-examples` **exact `2.29.1`** (released 2025-10-16). Through that
  pin we transitively get `mlx-swift 0.29.x`.
- Engine files: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
  (1,684 lines, uses `MLXLLM`), `InferenceRelay.swift` (865 lines, streams
  chunks back over WS).
- Autotune candidates today: Qwen2.5-32B-Instruct-4bit, Qwen2.5-14B,
  Qwen2.5-Coder-7B, Llama-3.2-3B, Llama-3.2-1B — **all dense, full-attention**.
- Of #482's four optimizations, only #1 (compiled decode) and #4 (bf16
  conversion) apply to our model set. #2 (CompilableRotatingKVCache) needs
  sliding-window models; #3 (fused gate+up) needs MoE. Both are deferred
  unless the model set expands.
- Out of scope, permanently: MLX 0.32.0 / M5 NAX (Darkbloom-fork only,
  not in upstream `mlx-swift` releases as of last check), switching to
  `Layr-Labs/mlx-swift-lm`, vendoring MLX, patching upstream.

# Execution order

User-requested ordering: **MLX upgrade research FIRST.** We want to lock in
the freshest reachable upstream pin before benchmarking anything, so all
subsequent perf numbers attribute correctly to the optimization under test
(not to "we happened to also be on a stale MLX"). After the pin is locked,
benchmark once; then layer bf16, then compile().

All work on a single branch: `perf/mlx-compile-bf16`.

---

## Phase 1 — MLX upgrade feasibility research (START HERE)

**Goal:** answer "are we on the latest available upstream MLX, and if not,
get there." Decision-and-bump phase. No benchmarking yet.

1. **Survey current state of upstream releases:**
   - `gh release list -R ml-explore/mlx-swift-examples --limit 10` — find the
     latest tag. Compare to our pin (`exact: "2.29.1"`).
   - `gh release list -R ml-explore/mlx-swift --limit 10` — find the latest
     tag. Read its `Package.swift` / release notes if needed.
   - Open `mlx-swift-examples`'s latest tag and check which `mlx-swift`
     version it pins. Compute the gap between (a) what *our* current pin
     transitively gives us and (b) what the latest reachable `mlx-swift` is.

2. **Branch out the answer:**

   - **Already on latest of both** (`mlx-swift-examples` at HEAD release AND
     that release pins the latest `mlx-swift`): no upgrade work. Skip to
     Phase 2. Document the version numbers and dates in
     `audits/<date>/mlx-upgrade-report.md` as "no upgrade required."

   - **`mlx-swift-examples` has a newer release than 2.29.1** (Path A —
     clean): bump our `exact:` pin in `phase3-binary/Package.swift`,
     `swift build`, run existing test suite (`swift test`). If green, keep
     the bump and proceed to Phase 2. If any test breaks, read the
     CHANGELOG between 2.29.1 and the target for breaking API changes in
     `MLXLLM` / `MLXLMCommon`; apply minimal adapter shims if the breakage
     is mechanical (renames, signature changes). Don't fight large
     refactors — if breakage is non-trivial, fall back to Path B or Path C.

   - **`mlx-swift-examples` still on 2.29.1 but `mlx-swift` itself has
     moved** (Path B — override): the transitive `mlx-swift` pin is
     limiting us. Add an explicit `mlx-swift` package dependency to our
     `Package.swift` to override the transitive version, e.g.
     `.package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.0")`.
     Run `swift build` + `swift test`. If green, keep. If MLXLLM API drift
     breaks the build (likely since MLXLLM is sourced from
     `mlx-swift-examples` which was tested against the older mlx-swift),
     revert the override and fall back to Path C.

   - **Both upstreams stuck OR upgrade breaks the build past trivial
     fixes** (Path C — stay): document in
     `audits/<date>/mlx-upgrade-report.md` exactly what's blocked (which
     symbols/APIs broke, which release the gap appears at). Leave the pin
     at 2.29.1. Proceed to Phase 2 on the existing version.

3. **Output of Phase 1:** `audits/<date>/mlx-upgrade-report.md` with:
   - Latest `mlx-swift-examples` release (tag, date, mlx-swift pin)
   - Latest `mlx-swift` release (tag, date)
   - Our pin before/after this phase
   - Path chosen (A/B/C) with one-paragraph evidence
   - Any breaking changes encountered

4. **What is explicitly OUT OF SCOPE in this phase:**
   - Pulling MLX 0.32.0 / M5 NAX — not in upstream releases.
   - Switching dependency to `Layr-Labs/mlx-swift-lm`.
   - Vendoring or patching MLX.
   - Performance benchmarks (those come in Phase 2).

---

## Phase 2 — Establish baseline (on the pin locked by Phase 1)

1. **Detect the target model.** The model to benchmark against = the one
   currently running on this Mac, biased upward per "targeting higher
   models now." Check in order:
   - Active provider process / state files under `state/`, `.omc/`,
     `state/sessions/`, recent log dirs.
   - Most recent autotune output (see `AutotuneCommand.swift`).
   - The largest autotune candidate that fits this Mac's RAM
     (`MacProviderCore/ModelFit.swift` logic + `sysctl hw.memsize`).
   - **If undetermined, ASK the user before benchmarking.** Wrong model =
     worthless numbers.

2. **Bench harness.** If none exists, create
   `phase3-binary/Tools/DecodeBench/main.swift`:
   - Loads the target model via the same `MLXLLM` / `MLXLMCommon` path
     `ModelRuntime.swift` uses (do not bypass — measure the real forward).
   - Fixed prompt (~512 tokens prefill), generates exactly 256 tokens at
     B=1, three runs after one warmup run.
   - Reports: prefill TPS, decode TPS (p50 across 3 runs), peak RAM,
     decode wall time. JSON to stdout + human summary.
   - No coordinator, no WS — pure decode loop.

3. **Run baseline** on the target model. Record numbers as
   `state/perf/baseline-<model>-<pin>-<date>.json` (including the MLX pin
   in the filename so we never confuse versions). **Do not proceed until
   this file exists.**

---

## Phase 3 — bf16 weight conversion at load

User's original "start here" before re-ordering. Lowest-risk, additive.

1. **Decide if it applies.** Inspect the loaded model's weight dtypes.
   `mlx-community/*-4bit` variants are usually pre-quantized; embedding
   / lm_head / norm layers may still be fp16. Print weight-dtype histogram
   before and after.

2. **Implement** in `ModelRuntime.swift` (or a sibling `WeightCast.swift`):
   - After model load, walk parameters; for any tensor with
     `dtype == .float16`, cast to `.bfloat16` in-place. Skip quantized
     blocks. Skip if already bf16.
   - Chunked: convert in batches to bound peak memory.
   - Gate behind env flag `MACPROVIDER_BF16_WEIGHTS=1` (default OFF in
     this branch; flip default in a follow-up after live evidence).

3. **Bench:** baseline vs. bf16-on. Quality check first (run a sanity
   prompt and eyeball the output for regressions). If lift ≥3% with
   matching outputs, record and proceed. If quality regression, document
   and disable.

---

## Phase 4 — MLX `compile()` wrapper for B=1 decode

The headline gain. Most of #482's 21% lift comes from this. Our Qwen/Llama
KV caches are `KVCacheSimple`-equivalent, already graph-traceable — we do
NOT need Darkbloom's `CompilableRotatingKVCache` machinery.

1. **Find the forward.** In `ModelRuntime.swift`, locate the per-token
   forward call inside the decode loop (the call that runs
   `model(inputs, cache: ...)` or equivalent). This is the call to wrap.

2. **Implement:**
   - New file `phase3-binary/Sources/macprovider-cli/CompiledDecode.swift`.
   - Wrapper using MLX's `compile()` (check the exact Swift API in our
     locked mlx-swift version — function name may be `compile`, `compiled`,
     or via a property wrapper depending on version).
   - Inputs that vary per step: token ids `[1, 1]`, cache state tensors.
     Stable across the request: model weights.
   - Handle cache state correctly: the compiled function must take cache
     tensors as inputs and return updated cache tensors as outputs (no
     mutation captured into the graph). For `KVCacheSimple`, this means
     extracting `keys` / `values` / `offset` as MLX arrays, threading
     through, writing back.
   - **B=1 only** in this phase. Skip compile for prefill (variable input
     length defeats the graph) — only compile the per-token decode step.
   - Gate behind env flag `MACPROVIDER_COMPILED_DECODE=1` (default OFF).

3. **Correctness gate FIRST:** generate the same prompt with compile OFF
   and ON; token sequence MUST match exactly. If outputs diverge, cache
   threading is wrong — fix before benchmarking.

4. **Bench:** target model (and one tier up if it fits). Record p50 decode
   TPS, and **also measure time-to-first-token** (compile has a warmup
   cost on the first request — make sure to measure steady-state across
   at least 3 runs after warmup, not the first call).

5. **Decision gate:**
   - Lift ≥15% with matching outputs: leave env flag, document, prep to
     flip default ON in a follow-up.
   - Lift 5–15%: ship behind the flag, don't flip default; needs more
     evaluation across model sizes.
   - Lift <5% or correctness break: document why (likely API limitation
     in this mlx-swift version) and file a "revisit when mlx-swift ships
     compile-friendly API" note in `audits/`.

---

## Phase 5 — Deferred items (do NOT implement in this branch)

Gated on model-family expansion. Document only.

- **#482-item-2 (CompilableRotatingKVCache):** worthwhile only if we serve
  **sliding-window attention** models (Gemma-2/3/4, some Mistral variants).
  Probe current and planned autotune candidates. If none use
  sliding-window, document as "deferred — N/A on current/planned model
  set" in `audits/<date>/perf-deferred.md`.

- **#482-item-3 (Fused gate+up gatherQuantizedMM):** worthwhile only if we
  serve **MoE** models (Qwen MoE, Mixtral, Gemma4-MoE, DeepSeek-V3). If
  dense-only, document and skip.

For each deferred item, the note should include: (a) why it's N/A today,
(b) the exact upstream MLX feature gap (if any) that would gate
implementation when the model set expands, (c) link back to #482 for the
reference design.

---

## Final deliverable

A summary report at `audits/<date>/perf-mlx-engine.md`:

| Phase | Item | Outcome | TPS delta | Default state | Notes |
|---|---|---|---|---|---|
| 1 | MLX upgrade | Path A/B/C | n/a (no bench) | n/a | pin: X → Y |
| 2 | Baseline | — | — TPS | — | model + pin recorded |
| 3 | bf16 conversion | shipped/deferred | +X% | ON/OFF | — |
| 4 | compile() decode | shipped/deferred | +X% | ON/OFF | — |
| 5 | rotating-cache | deferred | n/a | n/a | model-family gate |
| 5 | fused gate+up | deferred | n/a | n/a | model-family gate |

Plus:
- The `mlx-upgrade-report.md` from Phase 1.
- Bench JSON files in `state/perf/`.
- One-sentence answer to: **"if compile() lands us at ~50% bandwidth
  utilization, what's the next 20%?"** (Likely candidates: B>1 batched
  decode, kernel-level quant kernels, or further mlx-swift bumps as they
  ship.)

## Constraints

- Single branch: `perf/mlx-compile-bf16`.
- All new behavior behind env flags, defaults OFF in this branch — flip
  defaults in a follow-up PR after live evidence.
- Do NOT modify the WS / `CoordinatorClient.swift` send path (separate
  hypothesis test, already settled — see
  `specs/hypothesis-ws-send-latency.md` and audit
  `audits/ws-send-latency-2026-06-30.md`).
- Do NOT switch dependency to `Layr-Labs/mlx-swift-lm`. Stay on
  `mlx-swift-examples`.
- Do NOT vendor MLX or patch upstream.
- Correctness before perf: if compile() changes outputs, the
  implementation is wrong — fix correctness before measuring.
- If a phase's lift is negligible or negative, **don't ship it just
  because the spec lists it** — document and skip. Honest negative
  results are the point.
