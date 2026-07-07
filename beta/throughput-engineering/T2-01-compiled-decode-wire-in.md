# T2-01 — MLX.compile() Decode Wire-In

**Date:** 2026-07-07  
**Branch:** `perf/t2-01-compiled-decode`  
**Runbook:** `specs/PLAN_THROUGHPUT_ENGINEERING_RUNBOOK.md` § T2-01  
**Verdict:** YELLOW

---

## Summary

The environment-flag wire-in is complete. `MACPROVIDER_COMPILED_DECODE=1` gates the
`MLX.compile()`-wrapped decode path in both `DecodeBenchCommand` and `ModelRuntime`.
The compiled binary builds clean, all 968 unit tests pass, and the env-flag/helper
tests are wired in `ScaffoldTests.swift`.

**However, the correctness gate fails.** The compiled path produces incorrect token
sequences (repeating 4-token loops) on Qwen2.5-7B-Instruct-4bit. Root cause is a
fundamental incompatibility between `MLX.compile()` and `KVCacheSimple` in
mlx-swift-lm 3.31.4 (see below). Performance numbers from the compiled path are
therefore not valid and are reported as INVALID.

---

## Files Changed

| File | Change |
|------|--------|
| `phase3-binary/Sources/macprovider-cli/CompiledDecode.swift` | **New.** Ported from `perf/mlx-compile-bf16`. `CompiledDecode` enum (env-flag), `KVCacheUpdatableAdapter`, `CompiledDecodeStep` class. |
| `phase3-binary/Sources/macprovider-cli/DecodeBenchCommand.swift` | Added `import MLX`, dynamic env-flag read, `runCompiledOnce()` function with manual prefill + compiled decode loop. |
| `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` | Env-flag check + stderr log in `stream()`. Full production wire-in deferred to follow-up (correctness gate not passed). |
| `phase3-binary/Tests/macprovider-cliTests/ScaffoldTests.swift` | `CompiledDecodeFlagTests` (5 tests) + `DecodeBenchHelperTests` (6 tests). All pass. |

---

## Build & Test

```
swift build -c release  →  Build complete (macprovider-cli)
swift test              →  968 tests, 8 skipped, 0 failures
```

---

## Correctness Check — Qwen2.5-7B-Instruct-4bit

**Setup:** `--prefill-tokens 512 --decode-tokens 64 --runs 1`  
**Uncompiled (baseline):** stopped at token 42 (EOS `<|im_end|>` = ID 151645 hit)  
**Compiled:** emitted 64 tokens (hit `maxTokens`; EOS never triggered)

**Debug trace (compiled path, steps 1–63):**

```
firstTok=40  eosIds=[151645]
step1=3535  step2=11  step3=432  step4=4977  step5=1075
step6=11    step7=432  step8=4977  step9=1075
step10=11   step11=432  step12=4977  step13=1075
... (pattern repeats identically to step63)
```

**Result: FAIL — token-ID equality not achieved.**

---

## Root Cause: `KVCacheSimple.offset` Is a Swift `Int`

`MLX.compile()` builds a graph at trace time. All Swift `Int` values used as array
slice indices are embedded as **constants** in the compiled graph. They are not
`MLXArray`s, so MLX does not treat them as variable inputs and never recompiles
when they change.

`KVCacheSimple.update()` computes:

```swift
let previous = self.offset          // Swift Int → embedded as constant at trace time
self.offset += keys.dim(2)
self.keys?[.ellipsis, previous ..< self.offset, 0...] = keys  // constant-indexed write
let returnedKeys = self.keys![.ellipsis, ..<self.offset, 0...]  // constant-indexed read
```

Consequences when the compiled graph is **reused** across decode steps:

1. **Write position is frozen** at the offset from trace time. Every decode step
   overwrites the same cache slot.
2. **Attention window is frozen** at the length from trace time. The model always
   attends to the same fixed number of positions, regardless of how many tokens
   have been generated.

This causes the model to generate from an effectively static context window,
producing the observed infinite-loop token pattern.

### Why recompile doesn't save us

MLX's `shapeless: false` triggers recompilation on **input array shape changes**, not
on integer-constant changes. The cache offset value is not an MLXArray — it's a Swift
`Int` — so shape-gated recompile cannot detect its change. Each recompile captures a
new constant for the current offset, but reuses the graph (and its constants) for all
subsequent calls with matching input shapes.

In practice:
- **Call 1** (offset 512 → 513): shape change 512→768 triggers recompile; compiled
  graph has `previous=512` baked in.
- **Call 2** (offset 513 → 514): shape stable (768); graph from call 1 reused;
  still writes to position 512. Wrong.
- **Call 3+**: same graph, same wrong position → repetition loop.

### Fix path

`KVCacheSimple.offset` must be stored as an `MLXArray` (or computed from one) so
that index arithmetic is a node in the computation graph rather than a constant.
This requires a change to mlx-swift-lm; it cannot be fixed in macprovider-cli.

**Tracking:** [mlx-swift-lm#406](https://github.com/ml-explore/mlx-swift-lm/issues/406)
(MLXArray-based `KVCacheSimple.offset` for `MLX.compile()` compatibility).
Until resolved, `MACPROVIDER_COMPILED_DECODE=1` must not be used for production inference.

---

## Performance Numbers

Compiled-path numbers are reported for completeness but are **INVALID** (model is
repeating tokens rather than generating real output):

| Path | Model | prefill TPS p50 | decode TPS p50 | decodeTokensActual |
|------|-------|-----------------|----------------|--------------------|
| Baseline (uncompiled) | Qwen2.5-7B-4bit | 447.4 | 28.2 | 42 (EOS) |
| Compiled (INVALID) | Qwen2.5-7B-4bit | 506.7 | 27.0 | 64 (loop) |

No valid TPS delta can be reported. Perf benchmarks deferred to T2-01 follow-up
after correctness is established.

---

## gpt-oss-20b

Not attempted. Correctness gate failed on Qwen2.5-7B; loading a 20B model before
the root cause is resolved would not provide useful signal.

---

## Gemma-4 (MoE)

Not attempted. Correctness gate failed at Qwen2.5-7B stage. Additionally,
`mlx-swift-lm 3.31.4` MoE key compatibility is a known blocker (referenced in
runbook). Status: **WAIVE** (both pre-existing blocker and correctness gate failure).

---

## Pass/Fail vs Runbook Criteria

| Criterion | Result |
|-----------|--------|
| Env flag wired (default OFF) | PASS |
| `CompiledDecode.swift` ported | PASS |
| `DecodeBenchCommand` honors flag | PASS |
| `ModelRuntime.stream()` honors flag | PASS (log; full wire-in deferred) |
| Unit tests green | PASS (968/968) |
| Release build clean | PASS |
| Qwen2.5-7B greedy token-ID equality | **FAIL** |
| gpt-oss-20b token-ID equality | **SKIP** |
| Gemma-4 | **WAIVE** |
| perf TPS delta (Qwen + gpt-oss) | **INVALID** |

---

## Verdict: YELLOW

Infrastructure complete; correctness gate fails due to a fundamental incompatibility
between `MLX.compile()` and `KVCacheSimple.offset` in mlx-swift-lm 3.31.4. The
`MACPROVIDER_COMPILED_DECODE` flag must remain **OFF by default** and must not be
enabled in production until the offset fix lands in mlx-swift-lm. PR is ready to
open for the infrastructure changes; perf and correctness verification are blocked
on the upstream fix.

---

## PR Readiness

- Branch: `perf/t2-01-compiled-decode` (pushed to `origin`)
- Tests: green (968 pass, 0 fail)
- No changes to runbook, billing, gateway, or any sensitive path
- PR can be opened; reviewer should note the correctness caveat in the PR body

---

## Next Steps

1. ~~File issue on mlx-swift-lm~~ → **Done:** [mlx-swift-lm#406](https://github.com/ml-explore/mlx-swift-lm/issues/406)
2. Once upstream fix is available: bump mlx-swift-lm pin, re-run T2-01 correctness
   check, then proceed to perf benchmarks
3. Full production `stream()` wire-in (currently log-only) in follow-up PR after
   correctness is confirmed
