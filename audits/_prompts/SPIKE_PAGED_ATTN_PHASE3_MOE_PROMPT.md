# SPIKE (Phase 3) — MoE validation: paged injection on the LIVE production model

## The one question this answers
Does the `PagedKVCache` injection that passed on dense Llama/Qwen (Phase 2) **also give exact parity on the live production model `Qwen3-Coder-30B-A3B` (MoE)** — the actual model macprovider serves? This closes the **last production-reality gap** before writing the SPEC-038 v0.2 / paged-engine spec and committing the build.

## Why this should carry — and what would be a surprise (state the hypothesis)
- **MoE changes the FEED-FORWARD (routed experts), NOT attention.** In `Qwen3-Coder-30B-A3B` (30B total, ~3B active/token) the MLP is replaced by expert routing; **attention is standard GQA with a `KVCache`, unchanged.** The `PagedKVCache` only reshuffles attention KV — it is **orthogonal to MoE routing**. So injection *should* carry unchanged.
- **What would be a genuine surprise worth catching:** the MoE model instantiating a **different cache path** than dense models — a different `KVCache` subclass, **sliding-window / hybrid attention**, per-layer cache heterogeneity, or a quantized cache by default. If the model's attention doesn't funnel through the same `attentionWithCacheUpdate` / `KVCache` seam Phase 2 used, that's the finding. **Inspect the cache types the model actually instantiates** (`newCache` / the model's cache array) and report them.

## Where this follows from (self-contained)
- Phase 0 (`SPIKE_PAGED_ATTN_PHASE0_RESULT_2026-07-29.md`, `e5ded571`) → 3a: custom Metal kernel attaches beside the pinned tag, no `mlx` fork.
- Phase 2 (`SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md`, `acc30b1e`) → injection feasible via the public `KVCache` seam, **architecture-general**, exact parity on dense Llama-3.2-3B + Qwen2.5-7B, production fp16 KV, no fork. **Reuse that spike's `PagedKVCache` unchanged** — the point is to prove it carries to MoE with no per-model work.
- Strategic framing: `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md`.

## CLEAN-ROOM boundary
Read `ml-explore/mlx-swift` + `mlx-swift-lm` source (MIT — your own deps) freely, incl. the Qwen3-MoE model + cache code to check the seam. **FORBIDDEN:** `Layr-Labs/*` forks and `layr-labs/d-inference` source.

## Machine + MANDATORY resource isolation (memory is the real constraint here)
- **This M5 / 32 GB.** The target is the **30B MoE (~17 GB in 4-bit weights)** — so pausing the live provider (which holds ~17 GB for the *same* model) is **not optional, it's a memory requirement**: you cannot load a second copy of the 30B alongside the running provider on 32 GB. **Stop the provider first; the freed ~17.5 GB is exactly what the spike needs.**
- **⚠ This M5 runs the LIVE PRODUCTION provider.** Full stop/restore procedure in `audits/_prompts/SPIKE_PAGED_ATTN_PHASE0_PROMPT.md`; critical bits (same as Phase 2, which executed it cleanly):
  - **Watchdog FIRST** (`live.streamvc.macprovider-watchdog`), then `live.streamvc.macprovider`, then cold/warm watchers + canary tunnel — graceful `launchctl bootout gui/$(id -u)/<label>`. **NEVER broad `pkill`** (`incident-2026-07-27`).
  - Record restore state; **bounded off-peak window** (past 04:00–10:00 EEST peak; check `coordinator.streamvc.live` traffic is ~idle first). The provider-stop `launchctl` calls are auto-mode-classifier-blocked → proceed only after the operator authorizes (as in Phase 2).
  - **After: `launchctl bootstrap`/`kickstart` provider + watchdog + watchers, verify it reconnects to the coordinator (pool 3/3 ready, port 61920 listening) and serves a real buyer inference via `api.streamvc.live`. Confirm watchdog rescheduled. Leave the machine exactly as found.**
- **Metallib gotcha:** copy the version-matched `default.metallib` (`mlx-swift 0.31.4`) next to the built binary; plain `swift build` doesn't regenerate it.

## The spike
1. **Reuse the Phase-2 throwaway package** (`~/spikes/paged-attn-phase2`), **prod-accurate pins `mlx-swift-lm 3.31.4` → `mlx-swift 0.31.4`** (NOT 0.31.6 — production runs 0.31.4; 0.31.6 has nothing macprovider-relevant).
2. **Load `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`** (cached; it loads in 3.31.4 — the live provider serves it). If it OOMs even with the provider stopped, note it and fall back to any small MoE you can pull (e.g. a Qwen3-MoE / OLMoE small variant) — but the 30B is the real target.
3. **Inspect the cache path first:** confirm the model's attention uses the same `KVCache` seam (report the concrete cache types from `newCache` / the model's cache array; flag any sliding-window/hybrid/quantized-by-default cache).
4. **Parity gate:** drop the **unchanged** `PagedKVCache` into the MoE forward; manual greedy decode **≥32 new tokens**, KV exercised every layer every step; compare vs stock `KVCacheSimple`. **Assert exact token-for-token greedy match.** Report the kernel-call count (should be `layers × 2 × steps`) to prove the paged kernel actually ran on every MoE layer.

## Deliverables
Commit `docs/research/SPIKE_PAGED_ATTN_PHASE3_MOE_RESULT_<date>.md`:
- **MoE parity verdict** (PASS/FAIL, model, token count, kernel-call count).
- **Cache-path report** — the actual cache types the MoE model instantiates; any deviation from the dense seam.
- **Whether the Phase-2 `PagedKVCache` carried unchanged** (the key result — per-model work needed or not).
- Any MoE-specific concern for the build (expert-routing interaction with batching later, memory).
- **Confirmation the production provider was restored + verified serving.**
Push (docs → direct-push OK; routes to `Augustas11`). Throwaway package stays under `~/spikes`.

## Boundaries / do-nots
- ml-explore MIT source OK; **NO `Layr-Labs/*` / `d-inference` source.**
- Standalone package; do NOT touch `phase3-binary`, the macprovider engine, or PR #804.
- Graceful provider stop/restore, watchdog first, no broad pkill; **restore + verify serving before ending.**
- Exact greedy parity is the gate. If it FAILS, the finding (which cache path MoE uses) is the deliverable — don't force a pass.
