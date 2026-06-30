# Deferred MLX Decode Optimizations — Phase 5 of perf/mlx-compile-bf16

**Date:** 2026-06-30
**Spec:** `specs/perf-mlx-compile-bf16-upgrade.md`
**Companion:** `audits/2026-06-30/mlx-upgrade-report.md`, `audits/2026-06-30/perf-mlx-engine.md`
**Reference design:** [Layr-Labs/d-inference#482](https://github.com/Layr-Labs/d-inference/pull/482)

## Why these are deferred, not skipped

The two items below come from the same upstream perf work that motivated
this PR. They were excluded from the current branch because the autotune
candidate set is **dense, full-attention only** (Qwen2.5 family, Llama-3.2
family). The optimizations only pay off on model families we do not yet
serve. Each deferral is a model-family gate, not a difficulty gate: once
we add a model that triggers one, this work activates.

---

## D1 — `CompilableRotatingKVCache` (gates on sliding-window models)

`mlx-swift-examples`'s `RotatingKVCache` (used by sliding-window attention
families: Gemma-2/3/4, certain Mistral variants, Phi-3.5-mini) carries
internal state that the stock `MLX.compile()` pipeline cannot thread
through cleanly. Item #2 of #482 replaces it with a graph-traceable
variant whose state is fully expressible as `[any Updatable]` arrays
(keys, values, ring-buffer offset).

### Why N/A today

Current and planned autotune candidates per spec:

- Qwen2.5-32B-Instruct-4bit
- Qwen2.5-14B (variants)
- Qwen2.5-Coder-7B
- Llama-3.2-3B
- Llama-3.2-1B

All five use **full-attention** `KVCacheSimple` — no rotating window.
`MLXLLM`'s registry contains the relevant `Gemma*`/`Mistral` configs but
none of them are in our autotune set today.

### Upstream feature gap to monitor

A graph-traceable rotating cache is not in `mlx-swift-examples` 2.29.1.
Tracking signal: when `mlx-swift-examples` cuts a release that lands a
`CompilableRotatingKVCache` (or equivalent rename), re-evaluate whether
to ship it gated behind the same `MACPROVIDER_COMPILED_DECODE` flag —
the wiring would mirror what `CompiledDecode.swift` already does for
`KVCacheSimple`.

### Trigger to revisit

Any of:

1. A sliding-window model is added to the autotune candidate set
   (file: `phase3-binary/Tools/autotune-candidates.json` or equivalent).
2. Operator config sets a Gemma-2/3/4 or sliding-window Mistral model
   as the served model.
3. `mlx-swift-examples` ships a compile-friendly rotating cache and the
   release notes call it out.

---

## D2 — Fused gate+up `gatherQuantizedMM` (gates on MoE models)

#482 item #3 fuses the `gate × up` projection in MoE expert FFNs into a
single `gatherQuantizedMM` call. The fused kernel avoids reading
quantized expert weights twice per token. For Qwen-MoE / Mixtral /
DeepSeek-V3-style routing, this can be substantial because the gate +
up projections dominate decode-time arithmetic intensity.

### Why N/A today

Every autotune candidate is **dense** — single FFN block per layer, no
expert routing, no `gather*` op. There is no gate/up pair to fuse: the
op simply isn't called. Even the largest current candidate
(Qwen2.5-32B-Instruct-4bit) is dense.

### Upstream feature gap to monitor

`gatherQuantizedMM` exists in mlx-swift as a public op, but the
MoE-aware decode path that calls it lives in `mlx-swift-examples`
MoE model implementations. Until we add an MoE model to the registry
in production, there is no caller to optimize.

### Trigger to revisit

Any of:

1. A Qwen-MoE / Mixtral / Gemma4-MoE / DeepSeek-V3 / OLMoE variant is
   added to the autotune candidate set.
2. Operator demand for an MoE model is reflected in
   `state/perf/` request logs or operator feedback.
3. `mlx-swift-examples` ships a fused-gate-up MoE FFN by default and we
   benefit transparently via the pin bump — at which point this item
   converts from "deferred work" to "free".

---

## Companion: `compile()` decode wrapper status

Phase 4 (the headline `MLX.compile()` decode wrapper, item #1 of #482)
is NOT deferred — its scaffolding ships in this PR at
`phase3-binary/Sources/macprovider-cli/CompiledDecode.swift`, gated
behind `MACPROVIDER_COMPILED_DECODE=1`. The runtime wire-in to
`ModelRuntime`'s decode loop and the correctness gate are left to a
follow-up PR that can run a live correctness comparison on an
M-series Mac with a real model loaded — token-exact equivalence
needs to be verified BEFORE perf is measured (the spec is explicit:
"correctness before perf"). See `audits/2026-06-30/perf-mlx-engine.md`
for the live-execution checklist.
