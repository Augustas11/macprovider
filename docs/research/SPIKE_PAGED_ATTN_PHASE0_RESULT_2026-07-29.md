# SPIKE (Phase 0) RESULT — PagedAttention Metal-kernel feasibility on mlx-swift: **3a**

- **Date:** 2026-07-29
- **Machine:** Apple M5 / 32 GB / macOS 26.5 (25F71) / Swift 6.3.3 / Xcode Metal toolchain present
- **Pin:** `mlx-swift` **0.31.6** (matches macprovider's `mlx-swift-lm 3.31.4` transitive pin), resolved commit `0bb916c`
- **Package:** throwaway standalone SwiftPM package at `~/spikes/paged-attn-spike` (NOT in the repo, NOT in `phase3-binary`, NOT in the serve path)
- **Prompt:** `audits/_prompts/SPIKE_PAGED_ATTN_PHASE0_PROMPT.md`
- **Clean-room:** built only from public `mlx-swift` (MIT) API + the PagedAttention paper's block-table idea. No `Layr-Labs/*` / `layr-labs/d-inference` source consulted.

---

## Verdict: **3a** — custom PagedAttention kernel attaches BESIDE the pinned mlx-swift; **no fork of `mlx` required**

`mlx-swift 0.31.6` ships a first-class, public, JIT-compiled **user-defined Metal-kernel API**. A custom kernel written as a Metal source string can be registered from Swift, dispatched on the GPU, and its output `eval`'d — additively, on the Apple release tag, with zero changes to `mlx`/`mlx-swift` sources. This is the decisive result: **the entire paged continuous-batching build can be sized as a 3a effort.**

### The API surface (evidence)

Public function (both spellings resolve to the same implementation):

```swift
// Source/MLX/MLXFastKernel.swift  (also re-exported as MLXFast.metalKernel)
public static func MLXFast.metalKernel(
    name: String,
    inputNames: [String],          // -> const device T* <name> in the generated signature
    outputNames: [String],         // -> device T* <name>
    source: String,                // Metal function BODY; signature is auto-generated
    header: String = "",
    ensureRowContiguous: Bool = true,   // inputs forced row-contiguous before dispatch
    atomicOutputs: Bool = false
) -> MLXFast.MLXFastKernel

// call:
kernel(
    _ inputs: [any ScalarOrArray],
    template: [(String, any KernelTemplateArg)]? = nil,  // Int/Bool/DType compile-time args
    grid: (Int, Int, Int),
    threadGroup: (Int, Int, Int),
    outputShapes: [[Int]],
    outputDTypes: [DType],
    initValue: Float? = nil,
    stream: StreamOrDevice = .default
) -> [MLXArray]
```

Backed by the C `mlx_fast_metal_kernel_*` symbols in the vendored `Cmlx`; on macOS the real Metal implementation is compiled (the non-Metal branch is a `fatalError` stub only for platforms without Metal). `thread_position_in_grid` and friends are available in the kernel body; inputs arrive as `const device <dtype>*` buffers in `inputNames` order.

### Phase 0 empirical proof (not just the API existing)

A minimal elementwise kernel (`out[i] = a[i]*a[i] + 1`) was registered + dispatched + `eval`'d:

```
custom kernel compiled + dispatched: YES
maxAbsDiff(custom, cpu-ref) = 0.0
PHASE 0 RESULT: PASS -> 3a candidate
```

Exact match. The custom-kernel path compiles and runs beside the pinned tag.

---

## Correctness: paged KV gather == contiguous attention (Phase 1)

A **paged-attention gather** kernel was implemented: KV stored in **non-contiguous physical blocks** addressed by a **block table**, with extra garbage physical blocks interleaved to force real indirection (logical→physical permutation `[4,1,3]` across 5 physical blocks; physical blocks `{0,2}` are never read). One thread per head, two-pass numerically-stable softmax, gathering K/V through the block table.

Synthetic case: `H=4` heads, `D=8` head-dim, `blockSize=2`, `3` logical blocks → `S=6` KV positions, decode-style single query per head.

Compared against two references on the same logical KV reassembled contiguously:

```
paged-gather vs manual-MLX contiguous attention: maxAbsDiff = 1.19e-07
MLXFast.scaledDotProductAttention reference:     ran OK; sdpa-vs-manual = 5.96e-08, paged-vs-sdpa = 1.19e-07
PHASE 1 RESULT: PASS (within tol 1e-4)
```

Agreement is at float32 epsilon. The paged gather produces **numerically correct attention**, and MLX's own fused `scaledDotProductAttention` agrees with both (small head dims did not trip a fast-path constraint here).

### Phase 1b — rough timing (order-of-magnitude sanity only, NOT a benchmark)

```
paged-gather kernel:       276.9 us/dispatch (incl. eval)
manual-MLX matmul+softmax: 202.3 us/dispatch (incl. eval)
```

On a trivially small case, per-dispatch/eval overhead dominates and swamps kernel work, so this says nothing about real throughput — it only confirms the paged path runs in the same ballpark. Meaningful perf requires a realistically-sized kernel (proper grid/threadgroup parallelism over heads×positions, flash-style online softmax) and is out of scope for Phase 0.

---

## Operational gotcha found while building (matters for the real build)

The raw `swift build` CLI path does **not** regenerate mlx-swift's `default.metallib` resource bundle (the `PrepareMetalShaders` step / resource bundle is produced under Xcode/plugin builds, not the plain SwiftPM CLI). A freshly-built spike binary aborts at first GPU op with:

```
MLX error: Failed to load the default metallib. library not found ...
```

Fix used for the spike: copy the **version-matched** `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` that macprovider already ships (mlx-swift 0.31.6) next to the built binary. For a production paged build this means the metallib packaging path must be wired deliberately (Xcode resource bundling, or an explicit `PrepareMetalShaders`-equivalent build step), not assumed from `swift build`. **This is a packaging concern, not a feasibility blocker** — mlx-swift 0.31.6 already builds and runs on this machine (it is the live provider's engine).

---

## Rough effort estimate for the full paged build (implied by 3a)

Feasibility is settled favorably; remaining cost is real engineering, not a fork. Rough, judgment-based sizing:

| Piece | Size | Notes |
|---|---|---|
| Production paged-attention Metal kernel | **M–L** | flash-style online softmax, GQA/MQA head grouping, proper grid/threadgroup tiling over heads×blocks, real head dims (128), fp16/bf16, quantized-KV path. The Phase-1 gather is the toy version of this. |
| Block/KV-cache manager (allocator, block table, free list, eviction) | **M** | vLLM-shaped paged allocator; the memory-servability engine. Pure Swift, no kernel risk. |
| Continuous-batching scheduler (admission, preemption, per-request block tables) | **M–L** | the batching brain; independent of the kernel-feasibility question this spike closed. |
| Per-model attention injection into the Llama/Qwen forward pass | **L + risk** | **the real open unknown** — see Phase-2 concerns. Routing a live model's attention through the paged op per architecture. |
| Metallib/resource packaging into the provider build + release | **S–M** | the gotcha above; deliberate, not automatic. |

Order-of-magnitude: a **multi-week** build, dominated by per-model attention injection and the scheduler, **not** by kernel registration (which this spike proved is cheap).

---

## Blockers / Phase-2 concerns (recorded for the follow-up spike)

1. **Per-model attention injection (the next real unknown).** This spike drove a synthetic query through a standalone kernel. It did **not** route a real model's (Llama/Qwen) forward pass through the paged op. mlx-swift models call `MLXFast.scaledDotProductAttention` internally; swapping that for a paged kernel per architecture (and keeping RoPE, GQA/MQA, masking, and dtype exactly consistent) is the next spike (Phase 2 in the prompt).
2. **Quantized KV.** The live model is 4-bit (`Qwen3-Coder-30B-A3B-Instruct-4bit`). The paged kernel here used fp32 KV. Real paged KV must handle quantized/`fp16`/`bf16` blocks and match mlx's KV dtype exactly — a correctness surface not exercised here.
3. **Realistic kernel perf.** Phase 1b is overhead-bound noise. A real perf verdict needs proper parallelism and head_dim=128; only then is paged-vs-contiguous throughput meaningful.
4. **Metallib packaging** (see gotcha) must be solved in the provider release path, not left to `swift build`.
5. **`ensureRowContiguous` cost.** The default forces row-contiguous inputs before dispatch; for large paged caches this copy could matter and may need `ensureRowContiguous: false` with hand-managed strides.

---

## Production provider — stopped, restored, verified serving (non-negotiable)

The spike ran inside a **bounded off-peak maintenance window** on the live-provider M5. Full stop/restore executed safely (watchdog first; **no broad pkill**; graceful `launchctl bootout`/`bootstrap`). Restore state snapshot saved to `scratchpad/spike-paged-attn-restore-state-20260729T105503.txt`.

- **Redundancy check before stop:** coordinator pool healthy at `pool_size:3, pool_ready:3`; `requests_total:0` (≈zero live traffic). Window opened ~10:55 EEST, just past the 04:00–10:00 peak.
- **Stopped (WATCHDOG FIRST):** `live.malibu.provider-watchdog` → `live.malibu.provider` → `coldwarm-warm` → `coldwarm-postreboot-watch` → `catalog-canary-tunnel`. Verified provider process gone, RAM freed (76 MB → ~16.5 GB), coordinator pool cleanly `3 → 2` (survivors served buyers throughout).
- **Restored:** all 5 agents `bootstrap`'d back (provider first). Cold model reload took ~5 min; then port `61920` listening, coordinator pool recovered **2 → 3 (3/3 ready)**, watchdog rescheduled.
- **Verified serving:** real buyer inference through `api.malibu.tech` returned exactly `spike-restore-ok` (`model_hash_observed` present, `total_tokens:21`). Machine left exactly as found.

**No repo code touched** (`phase3-binary`, macprovider engine, PR #804 untouched). The throwaway package stays under `~/spikes`.
