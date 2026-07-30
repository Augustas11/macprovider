# SPIKE (Phase 2) RESULT — Per-model paged-attention injection + real/quantized KV

- **Date:** 2026-07-29
- **Machine:** Apple M5 / 32 GB / macOS 26.5 (25F71) / Swift 6.3.3 / Metal toolchain present
- **Stack (matches macprovider exactly):** `mlx-swift-lm 3.31.4` → `mlx-swift 0.31.4`, `swift-transformers 1.0.0`, `swift-jinja 2.3.6`
- **Package:** throwaway standalone SwiftPM package at `~/spikes/paged-attn-phase2` (NOT in the repo / `phase3-binary` / serve path)
- **Prompt:** `audits/_prompts/SPIKE_PAGED_ATTN_PHASE2_PROMPT.md`
- **Follows:** Phase 0 (`SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md`, commit `e5ded571`) → 3a confirmed. This spike closes Phase 0's open risks: **per-model injection** and **real/quantized KV dtype**.
- **Clean-room:** built only from `ml-explore/mlx-swift` + `mlx-swift-lm` (MIT, macprovider's own deps) and the PagedAttention block-table idea. **No `Layr-Labs/*` / `d-inference` source consulted.**

---

## Injection verdict: feasible **without forking mlx-swift-lm** — via the `KVCache` seam, and it is **architecture-general**

### The mechanism (evidence from source)

- `mlx-swift-lm`'s attention modules (e.g. `LlamaAttention`) call one shared helper, `MLXLMCommon.attentionWithCacheUpdate(queries:keys:values:cache:scale:mask:)`. For a non-quantized cache it does `cache.update(keys:values:) -> (K,V)` then `MLXFast.scaledDotProductAttention(...)`; for a `QuantizedKVCacheProtocol` cache it routes to `quantizedScaledDotProductAttention`.
- **`LlamaAttention` and the other attention modules are `internal`** — they cannot be subclassed or replaced from outside the library. So the **only public, non-forking injection seam is the `KVCache` protocol** (public; passed into `model(_:cache:)`).
- Because every dense architecture funnels through the *same* `KVCache` + `attentionWithCacheUpdate` seam, **injection is architecture-general, not per-model** — the same custom cache dropped into Llama and Qwen worked unchanged.

### What was injected

A `PagedKVCache` conforming directly to `KVCache`. On each `update()` it takes the logical K/V and routes them through a **custom JIT Metal kernel** (`MLXFast.metalKernel`) that gathers fixed-size KV **blocks placed in non-contiguous (reversed) physical order** back into logical order via a **block table**, on the model's **real fp16 KV** (GQA head layout, RoPE'd keys). The gathered K/V feed stock SDPA. RoPE, causal masking, and GQA grouping are handled by the unmodified model and validated implicitly by exact token parity.

### Honest scope of what this proves vs. doesn't

- **Proven:** (1) the `KVCache` injection seam works end-to-end in the real forward pass; (2) a custom Metal kernel reads the model's real in-model fp16 KV (with GQA + RoPE + masking) and reconstructs SDPA inputs with **exact** output; (3) it generalizes across two architectures.
- **Out of scope here (low-risk plumbing):** the paged **block allocator** — KV bytes were held in an inner contiguous buffer; a real allocator (free list, eviction) is separate Swift code, sized as M below.
- **Requires a fork (see below):** a *truly-fused* paged-attention op that **replaces** `scaledDotProductAttention` (rather than feeding it) cannot be installed through the public seam, because the attention modules are internal.

---

## Correctness (the gate): greedy argmax parity vs stock

Manual greedy decode, **40 new tokens** (≥32), KV exercised across every step, paged-injected cache vs stock `KVCacheSimple`:

```
[Llama-3.2-3B-Instruct-4bit]  PARITY PASS: 40/40 tokens match; paged gather kernel ran 2240 times
[Qwen2.5-7B-Instruct-4bit]    PARITY PASS: 40/40 tokens match; paged gather kernel ran 2240 times
GATE: PASS — real-model paged injection matches stock
```

- **Exact** token-for-token match (not just within tolerance) — the block gather is lossless, so correct injection ⇒ identical logits ⇒ identical greedy tokens.
- Kernel-call count `2240 = 28 layers × 2 (K+V) × 40 steps` confirms the custom paged kernel actually ran on every layer, every step — not bypassed.
- **GQA / RoPE / causal masking** (Step 4) are validated implicitly by the exact parity; none needed special handling in the injected path (the unmodified model applies them; the cache only reshuffles KV).

### Second-architecture note (Qwen3-8B)

The prompt's named secondary, `mlx-community/Qwen3-8B-4bit`, **fails to load** in this stack: `keyNotFound(["lm_head","weight"])` — a tied-embedding loader incompatibility in mlx-swift-lm 3.31.4, **unrelated to paged attention** (it errors before any generation). `Qwen2.5-7B-Instruct-4bit` (Qwen family, GQA, 28 layers) stood in and passed, proving cross-architecture generalization. (The live production model, `Qwen3-Coder-30B-A3B`, is MoE and loads via a different path — see blockers.)

---

## Real / quantized KV (Step 3)

- **Real/default KV dtype = fp16.** The provider runs with `kv_bits: <unset, mlx default>` → **fp16 KV is the production path**, and that is exactly what the parity test above exercised (the custom kernel reads/writes fp16 blocks losslessly). **Production-relevant KV dtype: covered, exact.**
- **Quantized (`kvBits`) path characterization.** Running generation with the library's `QuantizedKVCache(bits=8, group=64)` vs fp16:
  ```
  quantized-KV(bits=8,group=64) vs fp16: 0/40 tokens agree before divergence (drifts at token 0)
  ```
  8-bit KV quantization changes the greedy output **immediately** — quantized KV is a **distinct numerical surface**, not output-equivalent to fp16. Implication for a future paged-quantized cache: its parity target must be the **quantized** SDPA path (`QuantizedKVCacheProtocol` → `quantizedScaledDotProductAttention`), *not* fp16, and the paged gather must operate on `(wq, scales, biases)` block tuples rather than a plain tensor. A paged-quantized gather was **not implemented** in this spike (sized as M below). This is the one Step-3 item left as characterization rather than execution.

---

## Bonus — fused paged-attention op at real dims (de-risks the fork path)

Since a truly-fused paged op (replacing SDPA) would require a fork, its numerical correctness was checked standalone at **production dims** (hq=32, hkv=8, head_dim=128, fp16 KV, block table, GQA mapping) vs `MLXFast.scaledDotProductAttention`:

```
fused paged-attn vs SDPA: maxAbsDiff = 9.3e-4   (fp16-level)
FUSED-OP CHECK: PASS
```

So the fused kernel a fork would install is already numerically sound at real dims — the fork is low-risk engineering, not a research unknown.

---

## Refined effort estimate for the full paged build

Both Phase-0 (kernel feasibility) and Phase-2 (injection + real KV) unknowns are now closed favorably. Remaining cost is engineering, sized:

| Piece | Size | Notes |
|---|---|---|
| Paged block allocator / KV-cache manager (free list, eviction, per-seq block tables) | **M** | pure Swift; not exercised here but no kernel/injection risk. |
| `PagedKVCache` for the fp16 path (production default) | **S–M** | proven feasible here; productionize storage + block reuse. |
| Continuous-batching scheduler (admission, preemption, batched block tables) | **M–L** | the batching brain; independent of the injection question this spike closed. |
| Paged **quantized**-KV cache (`kvBits` path) | **M** | only if prod enables kvBits; must gather `(wq,scales,biases)` blocks and match the quantized SDPA path (which itself diverges from fp16). |
| Truly-fused paged-attention op (replace SDPA) | **M + fork** | requires a **light fork of `mlx-swift-lm`** (replace internal attention modules or `attentionWithCacheUpdate`), NOT a fork of `mlx` core. Numerically de-risked above. Only needed for max memory-servability/perf; the gather-feeds-SDPA path needs no fork. |
| MoE support for the live 30B (`Qwen3-Coder-30B-A3B`) | **L + risk** | see blockers — the real production target is MoE, not exercised here. |

Net: a **multi-week** build. The **injection risk is retired**; remaining risk concentrates in the batching scheduler and MoE.

---

## Remaining blockers / concerns

1. **MoE (the live production model).** Parity was proven on dense Llama/Qwen. The production model `Qwen3-Coder-30B-A3B` is MoE (expert routing + size); its attention still uses the same `KVCache` seam, so injection *should* carry over, but MoE routing/scale is unvalidated and is the next real target.
2. **Fused op needs a light `mlx-swift-lm` fork** (internal attention modules). The non-forking `KVCache` seam gives paged storage + gather feeding SDPA — sufficient for memory-servability; a fully-fused op for max perf needs the fork (numerically de-risked here).
3. **Batching-scheduler interactions** (per-request block tables, preemption, prefix sharing) are unbuilt and are now the dominant remaining unknown.
4. **Quantized-KV paged gather** not implemented; quantized KV is a separate numerical surface (drifts from fp16 immediately).
5. **Perf** unmeasured at batch/scale here (correctness was the gate); the fused-op real-dims check is a numeric check, not a throughput benchmark.
6. **Qwen3-8B-4bit load incompatibility** in this stack (`lm_head.weight`) — incidental, but note it if that specific model is ever a target.

---

## Production provider — stopped, restored, verified serving (non-negotiable)

Ran inside a **bounded off-peak maintenance window** on the live-provider M5.

- **Before stop:** coordinator `pool_size:3, pool_ready:3`, `requests_total:0` (≈zero live traffic), 11:33 EEST (past the 04:00–10:00 peak). Restore-state snapshot: `scratchpad/spike-paged-attn-restore-state-20260729T105503.txt` (plists unchanged since Phase 0).
- **Stopped (WATCHDOG FIRST, graceful `launchctl bootout`, NO broad pkill):** watchdog → provider → coldwarm-warm → coldwarm-postreboot-watch → canary tunnel. RAM freed 76 MB → ~17.5 GB; pool cleanly `3 → 2` (survivors served buyers throughout). *(Note: the provider-stop `launchctl` calls were initially blocked by the auto-mode classifier; proceeded only after explicit operator authorization.)*
- **Restored:** all 5 agents `bootstrap`'d back (provider first). Model reload + coordinator reconnect ~2 min; pool recovered **2 → 3 (3/3 ready)**, port 61920 listening, watchdog rescheduled.
- **Verified serving:** real buyer inference via `api.streamvc.live` returned exactly `phase2-restore-ok` (`model_hash_observed` present, `total_tokens:22`). Machine left exactly as found.

**No repo code touched** (`phase3-binary`, macprovider engine, PR #804 untouched). Throwaway package stays under `~/spikes`.
