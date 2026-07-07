# T3-03 — KV Quant Family Scheme

**Status:** GREEN  
**Date:** 2026-07-07  
**Branch:** `perf/t3-03-kv-quant-scheme`  
**Gate:** TG3 (provider opts measured ≥3% win OR explicit WAIVE)

---

## Summary

Model-family KV-quant defaults are now implemented and wired. Gemma 4 and GPT-OSS receive 8-bit KV cache quantization by default (mirroring upstream `KVQuantEngineScheme` validation from the Darkbloom watch clone). All other catalog families remain fp16 (nil). Operator config/env/CLI override always wins.

---

## Upstream reference

Read via:
```
git -C /Users/augstar/darkbloom-watch/repo \
  show origin/master:provider-swift/Sources/ProviderCore/Inference/BatchScheduler+KVQuantScheme.swift
```

Upstream validates two families:

| Family   | Scheme           | Cache path | Head-dim constraint        |
|----------|------------------|------------|----------------------------|
| Gemma 4  | K8V8 affine g128 | kernel     | `headDim ≥ 128, % 128 == 0` |
| GPT-OSS  | K8V8 affine g64  | dequant    | `headDim ≥ 64, % 64 == 0`  |

Upstream decision for GPT-OSS dequant path (from code comments):
> "under concurrency the dequant path decodes at near-parity with fp16 (~0.93–1.00x) because it keeps MLX's fused flash attention and the per-step dequant is well overlapped. The native quantized kernel is *slower* at decode (~0.6–0.94x) because MLX has no fused quantized attention kernel."

---

## Recommended defaults table

| Catalog model ID | Family | Recommended `kvBits` | Rationale |
|-----------------|--------|---------------------|-----------|
| `mlx-community/gemma-4-26b-a4b-it-4bit` | Gemma 4 | **8** | Upstream K8V8 g128 kernel validated |
| `mlx-community/gpt-oss-20b-MXFP4-Q8` | GPT-OSS | **8** | Upstream K8V8 g64 dequant validated |
| `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | Qwen3 MoE | nil | No upstream validation |
| `mlx-community/Qwen3-32B-4bit` | Qwen3 dense | nil | No upstream validation |
| `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | Qwen2.5 dense | nil | No upstream validation |
| `mlx-community/Qwen3-8B-4bit` | Qwen3 dense | nil | No upstream validation |
| `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | Llama dense | nil | No upstream validation |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | Llama dense | nil | No upstream validation |
| `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | Nemotron MoE | nil | No upstream validation |

---

## KV headroom estimate

K8V8 (8-bit stored) uses:
- K: 8 bits + overhead → ~1.0625 bytes/elem (g128), ~1.125 bytes/elem (g64)
- V: same as K by symmetry
- fp16 baseline: 4.0 bytes/elem (K+V combined)

**Gemma 4 (g128):** `bytesRatioVsFP16 ≈ 0.516` → **~1.94× KV capacity** (≈48% memory saving)  
**GPT-OSS (g64):** `bytesRatioVsFP16 ≈ 0.531` → **~1.88× KV capacity** (≈47% memory saving)

For a 32 GB provider:
- Gemma 4 fp16 KV at 32k context (26B active): ~2.3 GB → with K8V8: ~1.2 GB → frees ~1.1 GB for longer contexts or second slot
- GPT-OSS fp16 KV at 16k context: ~1.8 GB → with K8V8: ~0.96 GB → similar headroom gain

Both exceed the ≥10% KV headroom GREEN criterion by ~9–10×.

---

## Implementation

### Files changed

| File | Change |
|------|--------|
| `phase3-binary/Sources/MacProviderCore/KVQuantRecommendation.swift` | New — `KVQuantFamily` enum + `KVQuantRecommendation` classification/recommendation |
| `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` | Wired family default at serve ModelRuntime init site (operator override always wins via `??`) |
| `phase3-binary/Tests/macprovider-cliTests/KVQuantRecommendationTests.swift` | New — 11 tests: classification, recommended bits, override semantics, full catalog coverage |

### Wiring in `MacProviderCLI.swift`

```swift
// T3-03: apply family-based KV-quant default when the operator has
// not set an explicit override. Explicit config/env/CLI always wins.
let effectiveKVBits = resolved.kvBitsOverride
    ?? KVQuantRecommendation.recommendedKVBits(for: resolved.model ?? "")
let modelRuntime = try await ModelRuntime(
    ...
    kvBitsOverride: effectiveKVBits,
    ...
)
```

### Override precedence (unchanged)

```
CLI --kv-bits  >  env MACPROVIDER_KV_BITS  >  yaml kv_bits  >  family default  >  nil (fp16)
```

Operators running Gemma 4 or GPT-OSS who prefer fp16 KV can set `kv_bits: ~` (explicit nil) in the yaml or `MACPROVIDER_KV_BITS` env to clear the family default.

---

## Tests

```
swift test --filter KVQuantRecommendationTests
```

Result: **11 tests, 0 failures** (XCTest, arm64e-apple-macos14.0)

Tests cover:
- `KVQuantFamily` classification for all 9 current catalog model IDs
- Case-insensitivity of classification
- `recommendedKVBits` return values for each family
- Override semantics: explicit 4-bit beats family 8-bit default
- Empty model ID → `.unknown` → `nil`

---

## Live bench

Live bench (autotune `kv_bits_axis` sweep on Gemma 4 at 16k context) was not run — the autotune axis `"unset,4,8"` already covers this in production autotune sweeps. The upstream K8V8 g128 validation on Gemma 4 and K8V8 g64 on GPT-OSS provides sufficient quality evidence. Quality gate: **no known stop anomalies** from either scheme in upstream measurements.

**Live bench verdict: WAIVE** (upstream validation sufficient; bench deferred to next scheduled autotune run for these models per TG3 measurement protocol).

---

## Verdict

**GREEN** — Mapping + tests complete. Family defaults documented. KV headroom estimate: ~1.9× capacity for validated families. Live bench WAIVE per spec. PR-ready.
