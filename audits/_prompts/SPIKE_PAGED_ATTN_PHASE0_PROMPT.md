# SPIKE (Phase 0) — PagedAttention Metal-kernel feasibility on mlx-swift: 3a-vs-3b

## The one question this answers
Can a **PagedAttention Metal kernel be registered + dispatched BESIDE the pinned `mlx-swift`** (custom-kernel API → **3a**, stay on the Apple tag additively), or does it require **forking `mlx`** (→ **3b**)? Plus: does a paged KV gather produce **correct** attention output? This single result **sizes the entire paged continuous-batching build.** It is a **days-scale de-risking probe, NOT the build.**

## Why (self-contained)
- Per `docs/research/RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md`: continuous batching — especially the **paged / memory-servability** axis (bigger models, longer contexts, attracting Ultra providers) — is **strategic infrastructure for the network being built, not a demand-gated optimization.** The one real unknown / cost-driver is **3a-vs-3b**; this spike answers it before any production commitment.
- Upstream will not deliver batching (PR #263 abandoned; the competitor forked the whole MLX stack privately). macprovider builds it in-house; this is the first, cheapest step.

## CLEAN-ROOM boundary (hard)
Build ONLY from public, licensed sources: `mlx-swift`/`mlx` (MIT), `mlx-lm` `BatchGenerator` (MIT), vLLM PagedAttention (Apache-2.0), the PagedAttention paper (Kwon et al.). **NEVER read `Layr-Labs/*` forks or `layr-labs/d-inference` source** (public metadata only, if anything).

## Machine + MANDATORY resource isolation
- **Run on this Mac: Apple M5 / 32 GB / macOS 26.5 / Swift 6.3.3 / Metal toolchain present** (all verified). `mlx-swift` builds here. No lab Mac needed — kernel feasibility uses trivial memory.
- **⚠ This M5 also runs the LIVE PRODUCTION provider.** Building `mlx-swift` from source compiles the whole MLX C++/Metal stack (heavy CPU+RAM), and the spike exercises the GPU. **Do NOT run the spike alongside a live model-loaded provider on the same 32 GB machine** — a loaded 30B-4bit model alone holds ~17 GB. **Stop/pause the provider first so the spike has clean RAM / CPU / GPU. Never run two resource-heavy instances together.**

### STOP the production provider SAFELY (before the spike)
The provider is launchd-managed and has a **watchdog that will respawn it** if you just kill the process. Discovered labels (verify current state first):
| Label | Role | Action order |
|---|---|---|
| `live.malibu.provider-watchdog` | **watchdog — respawns the provider** | **STOP FIRST** |
| `live.malibu.provider` | the provider (was PID 25228) | stop second |
| `com.malibu.coldwarm-postreboot-watch`, `com.malibu.coldwarm-warm` | cold/warm watchers (may load a model / contend) | stop |
| `live.malibu.provider-catalog-canary-tunnel` | canary tunnel | stop |

Procedure:
1. **Confirm buyer impact.** This M5 is (likely) the sole/primary prod provider — pausing it takes the pool down → buyer 503s. Treat the spike as a **bounded, off-peak maintenance window.** Check the `coordinator.malibu.tech` pool for redundancy first; if it's the only provider, get the operator's go-ahead and pick a low-traffic window.
2. **Record state for exact restore:** `launchctl list | grep streamvc` (labels + PIDs) and the plist paths in `~/Library/LaunchAgents/`. Save it.
3. **Stop gracefully, WATCHDOG FIRST, then provider, then watchers/tunnel** — `launchctl bootout gui/$(id -u)/<label>` (graceful). **NEVER `pkill -9 -f "macprovider-cli serve"` broadly** — a broad pkill downed the live provider before (`incident-2026-07-27`). If you must signal a PID, match it exactly and narrowly.
4. Verify the provider process is gone and RAM is freed (`ps`, memory pressure) before building.

### RESTORE the provider AFTER the spike (non-negotiable)
1. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/live.malibu.provider.plist` (+ the watchdog + watchers + tunnel), or `launchctl kickstart -k gui/$(id -u)/live.malibu.provider`.
2. Verify it **reconnects to the coordinator** (pool shows it / `/healthz` version) and **serves a test inference**.
3. Confirm the **watchdog** is back. Leave the machine exactly as found. Keep the outage window bounded.

## The spike

### Phase 0 — the 3a/3b decider (the point)
1. Create a **throwaway standalone SwiftPM package** (e.g. `~/spikes/paged-attn-spike`) — **NOT** inside `phase3-binary`, NOT in the macprovider serve path.
2. Pin **`mlx-swift 0.31.6`** (matches macprovider's `mlx-swift-lm 3.31.4`).
3. Confirm MLX's **user-defined Metal-kernel path exists and dispatches from Swift** on the pinned version. MLX core exposes `mx.fast.metal_kernel`; find and exercise the **mlx-swift** surface (e.g. `MLXFast` / a custom-kernel API). Write a minimal custom Metal kernel (even elementwise), register + dispatch it from Swift, `eval`, verify output.
   - **Registers + runs → 3a candidate** (paged attention can attach beside the pinned tag; you stay on Apple releases, additive).
   - **No usable custom-kernel surface on 0.31.6 → 3b** (fork `mlx`); document exactly what's missing.

### Phase 1 — paged-gather correctness
1. Implement a minimal **paged-attention gather** in the custom kernel: KV stored in **non-contiguous blocks** addressed by a **block table**; compute attention for a small synthetic case (a few heads, short sequence, 2–3 blocks).
2. Compare against contiguous `scaledDotProductAttention` on the same logical KV reassembled contiguously. **Assert numerical match within tolerance.**

### Phase 1b (optional) — perf sanity
Rough timing: paged-gather vs contiguous SDPA (clean, since the provider is paused). Order-of-magnitude sanity read, not a benchmark.

### Phase 2 (NOT this spike — note only)
Routing a real model's forward (Llama) through the paged op — the per-model attention-injection question. Record concerns for the follow-up spike.

## Deliverables
Write findings to a committed doc `docs/research/SPIKE_PAGED_ATTN_PHASE0_RESULT_<date>.md`:
- **3a or 3b verdict** with evidence (compiles + dispatches, or the specific API gap).
- **Correctness result** (paged gather == contiguous SDPA within tol).
- **Rough effort estimate** for the full paged build implied by the verdict.
- **Blockers / Phase-2 concerns** (per-model attention injection, quantized KV, etc.).
- **Confirmation the production provider was restored + verified serving.**
Commit + push (docs → direct-push OK per repo ruleset; pushes route to `Augustas11` automatically). The throwaway package stays under `~/spikes`, out of the repo.

## Boundaries / do-nots
- Public sources only; no Layr/d-inference source.
- Standalone throwaway package; do NOT modify `phase3-binary`, the macprovider engine, or PR #804.
- Graceful provider stop/restore, watchdog first; NO broad pkill.
- Keep the outage window bounded; **restore + verify the provider before ending the session.**
