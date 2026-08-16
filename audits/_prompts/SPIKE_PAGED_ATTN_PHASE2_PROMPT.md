# SPIKE (Phase 2) — Per-model attention injection + quantized KV: the last gate before the paged build

## The one question this answers
Can a **real mlx-swift-lm model's forward pass be routed through the paged-attention op** — producing output **identical to the stock model** — while keeping **RoPE, GQA/MQA, causal masking, dtype, and the model's real (4-bit-model / fp16 or quantized) KV** exactly consistent? This is the **last real unknown** between "proven feasible" and "commit the multi-week paged build." Per-model injection is where the effort and risk actually live now (Phase 0 already proved the kernel is cheap).

## Where this follows from (self-contained)
- **Phase 0 (`docs/research/SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md`, commit `e5ded571`) → 3a CONFIRMED:** `mlx-swift 0.31.6` exposes a public JIT custom-Metal-kernel API (`MLXFast.metalKernel`); a custom kernel compiled+dispatched+eval'd (exact match), and a **synthetic** paged KV gather matched contiguous `scaledDotProductAttention` at float32 epsilon. So a paged kernel attaches **additively on the pinned Apple tag — no `mlx` fork.**
- Phase 0's open risks, which THIS spike closes: **per-model attention injection**, **quantized/real KV dtype**, and (secondarily) realistic kernel perf.
- Strategic framing: `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md` — paged/servability is strategic infrastructure for the network being built; this is the final de-risking gate before the build.

## CLEAN-ROOM boundary (hard — but note what IS allowed)
- **ALLOWED and required:** read `ml-explore/mlx-swift-lm` and `ml-explore/mlx-swift` source (MIT — this is macprovider's own dependency) to find the attention/KVCache injection point. Also public `mlx-lm` (MIT), vLLM (Apache-2.0), the PagedAttention paper.
- **FORBIDDEN:** `Layr-Labs/*` forks and `layr-labs/d-inference` source (public metadata only, if anything). Do not consult their attention/paged implementation.

## Machine + MANDATORY resource isolation (same as Phase 0)
- **Run on this M5 / 32 GB / macOS 26.5 / Swift 6.3.3 / Metal present.** This spike loads a **real model** into memory (Llama-3.2-3B-4bit ≈ a few GB), so pausing the live provider (which holds ~17 GB for the 30B) is even more necessary than in Phase 0.
- **⚠ This M5 runs the LIVE PRODUCTION provider. Stop/pause it first — never run two model-loaded instances together.** Full procedure is in `audits/_prompts/SPIKE_PAGED_ATTN_PHASE0_PROMPT.md` ("STOP the production provider SAFELY"); the critical bits, repeated:
  - Stop the **watchdog first** (`live.malibu.provider-watchdog`) or it respawns the provider mid-spike, then `live.malibu.provider`, then the cold/warm watchers + canary tunnel — via graceful `launchctl bootout gui/$(id -u)/<label>`. **NEVER broad `pkill -9 -f serve`** (`incident-2026-07-27`).
  - Record state for exact restore; treat as a **bounded off-peak maintenance window** (this is the prod provider → buyer 503s while down).
  - **After:** `launchctl bootstrap`/`kickstart` the provider + watchdog + watchers, verify it reconnects to `coordinator.malibu.tech` and serves a test inference, confirm the watchdog is back. Restore before ending.
- **Metallib gotcha (from Phase 0):** plain `swift build` doesn't regenerate `default.metallib`; copy the version-matched `mlx-swift_Cmlx.bundle/.../default.metallib` next to the built binary (mlx-swift 0.31.6, as the provider already ships).

## The spike

### Setup
- **Throwaway standalone SwiftPM package** (e.g. `~/spikes/paged-attn-phase2`) — NOT in `phase3-binary`, NOT in the serve path. Reuse the Phase-0 package if convenient.
- Pin `mlx-swift 0.31.6` + `mlx-swift-lm 3.31.4` (match macprovider), plus `swift-transformers` as needed for loading.
- **Primary model: `mlx-community/Llama-3.2-3B-Instruct-4bit`** (cached). Standard GQA attention — the simplest real target. **Secondary: `mlx-community/Qwen3-8B-4bit`** (cached) to confirm injection generalizes to a second architecture. (The live `Qwen3-Coder-30B-A3B` is **MoE** — note it as the ultimate production target, but MoE routing + size make it a later validation, not this spike's core.)

### Step 1 — find the injection point (the real unknown)
Read mlx-swift-lm's Llama attention path. Its attention modules call `MLXFast.scaledDotProductAttention(...)` against a `KVCache`. Determine the **least-invasive** way to route that call through a paged op. Candidate mechanisms (find which the library actually permits):
- A custom `KVCache`-conforming **PagedKVCache** + wrapping/subclassing the `Attention` module to call the paged kernel instead of stock SDPA.
- A model-load hook / module replacement that swaps the attention compute per layer.
Document the mechanism, and **how per-architecture it is** (does the same hook work for Qwen, or does each family need its own injection?).

### Step 2 — correctness vs the stock model (the pass/fail)
Run the **same prompt** through:
- (a) the **stock** mlx-swift-lm model (`generate`, contiguous KV), greedy;
- (b) the model with **paged attention injected** (PagedKVCache + paged kernel), greedy.

**Assert greedy argmax token-for-token match over a multi-token generation** (≥32 tokens), with the KV cache actually exercised across steps — the same parity bar the SPEC-037 stage spike used. Do it for **Llama-3.2-3B first**, then **Qwen3-8B**.

### Step 3 — real / quantized KV dtype
The paged gather must handle the model's **actual KV dtype**, not fp32. Test the model's default KV path (fp16/bf16), and exercise the **quantized-KV (`kvBits`) path** if the model/runtime uses it. Confirm the paged kernel reads quantized/half-precision KV blocks and still matches stock output. This is a distinct correctness surface from Phase 0's fp32 gather.

### Step 4 — GQA/MQA + RoPE + masking consistency
Confirm the injected path groups query heads correctly (Llama-3.2 uses GQA), applies **RoPE** at the right point, and applies **causal masking** identically — verified implicitly by the Step-2 parity, but call out any place they had to be handled explicitly.

### (Optional) Step 5 — realistic perf read
Only if time permits and Steps 2–3 pass: a real-size timing (head_dim=128, several decode steps, a batch of 2–4 sequences) paged vs contiguous. Still not a benchmark — an order-of-magnitude read on whether the paged path is perf-viable. Deprioritize vs correctness.

## Deliverables
Write findings to a committed doc `docs/research/SPIKE_PAGED_ATTN_PHASE2_RESULT_<date>.md`:
- **Injection verdict:** the mechanism found, how invasive, and whether it's per-architecture or general. Is real-model attention injection feasible on mlx-swift-lm without forking the LM library? (If it needs forking mlx-swift-lm — a *lighter* fork than mlx-core — say so and size it.)
- **Correctness:** greedy-argmax parity result vs stock, Llama-3.2-3B and Qwen3-8B, ≥32 tokens, KV exercised.
- **Quantized/real-KV result:** does the paged gather match with the model's real KV dtype (+ kvBits path)?
- **Refined effort estimate** for the full paged build now that injection is known.
- **Remaining blockers** (MoE for the live 30B, batching-scheduler interactions, perf).
- **Confirmation the production provider was restored + verified serving.**
Commit + push (docs → direct-push OK; pushes route to `Augustas11`). Throwaway package stays under `~/spikes`, out of the repo.

## Boundaries / do-nots
- Read ml-explore MIT source freely (it's your dependency); **NO `Layr-Labs/*` or `d-inference` source.**
- Standalone throwaway package; do NOT modify `phase3-binary`, the macprovider engine, or PR #804.
- Graceful provider stop/restore, watchdog first; NO broad pkill. **Restore + verify the provider before ending.**
- Correctness is the gate; perf (Step 5) is optional. Don't skip Step 3 (quantized KV) — it's a real risk, not a formality.
