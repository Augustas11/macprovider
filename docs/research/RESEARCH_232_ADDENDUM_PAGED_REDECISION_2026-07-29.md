# RESEARCH_232 Addendum — Dense-vs-Paged, re-decided against the competitive picture

| Field | Value |
|---|---|
| Date | 2026-07-29 |
| Amends | `docs/research/RESEARCH_232_MULTISTREAM_BATCHING_MEMO.md` (2026-07-22) |
| Status | Decision addendum. Supersedes the original memo's Approach-A-primary recommendation AND rejects the 2026-07-29 codex re-run's "measure current occupancy / deprioritize" conclusion as a melting-ice-cream category error. Corrected framing: paged/servability is strategic **infrastructure for the network being built**; next step is the kernel-vs-fork spike, not a fleet measurement. |
| Evidence boundary | **Public repo metadata only** — GitHub language stats, `.gitmodules`, `Package.swift`/`Package.resolved` manifests, PR titles/states. **No `layr-labs/d-inference` or `Layr-Labs/*` fork SOURCE was inspected.** Clean-room intact. |

## Why this addendum exists

The original memo recommended **Approach A** (contribute/pin an upstream `mlx-swift-lm` batch API) as *primary*, **Approach B** (a narrow native Swift **dense** scheduler) as *fallback*, and **deliberately deferred PagedAttention** — see its "Paged KV" section (memo lines 758–778), the custom-paged-attention-kernel non-goal (line 1795), and "pivot to a paged layout only if contiguous KV fails a measured gate" (line 2367). Its rationale was defensible on its inputs: dense batching yields a real 1.2–2.1× (line 1493) without paged cost, and even Python's own paged-KV proposal (`mlx-lm` PR #610) *closed without merge* (line 776).

But the memo explicitly did **not** examine the competitive landscape — line 72: *"No d-inference source was inspected."* Correct on clean-room, but it conflated "don't read their source" with "don't look at their public activity at all," and so it missed the one signal that reframes the whole decision. This addendum supplies that signal (from metadata only) and re-decides.

## New facts (metadata-verified 2026-07-29)

**1. Upstream continuous batching is structurally dead, not merely stalled.**
- The only upstream continuous-batching PR — `ml-explore/mlx-swift-lm` **#263** (author `Gajesh2007`, `authorAssociation = NONE`, head repo = **`Layr-Labs/mlx-swift-lm`** fork) — is OPEN but **stale since 2026-05-03**, zero maintainer review, no CI. It is the memo's exact dense/contiguous design.
- Its author (Layr-Labs) then moved development to their **private fork**: `Layr-Labs/mlx-swift-lm` shows active **"cbv2"** work through 2026-07-27 — a *v0.8.0 PagedAttention migration*, paged storage core, MTP-on-paged banks, DFlash speculative. They **abandoned the upstreamable dense v1 (#263) for a paged v2 they keep private.**
- The other capable contributor, `ronaldmannak`, merged batching **prep** upstream (RoPE #178, cache round-trip #155, Gemma4 RoPE #212 — all already in the pinned `3.31.4`), but his recent work is unrelated; he is **not** driving the engine.
- **Conclusion: no one is landing continuous batching into ml-explore. Approach A (the memo's primary) is a dead bet.**

**2. The leading competitor forked the entire MLX stack.**
- `layr-labs/d-inference` (product **Darkbloom**, darkbloom.dev; "Private Inference Network on Idle Macs") vendors **three forks as git submodules**: `libs/mlx → Layr-Labs/mlx` (the **C++/Metal core**), `libs/mlx-swift → Layr-Labs/mlx-swift`, `libs/mlx-swift-lm → Layr-Labs/mlx-swift-lm`. `provider-swift/Package.swift` consumes them via **local paths**, not upstream SPM pins.
- Language mix: **Go 6.95 MB** (coordinator) + **Swift 6.52 MB** (provider engine) dominate; **Python 254 KB (~2%)**. Architecture mirrors macprovider (Go coordinator + Swift provider). Their engine is **Swift/Metal, not Python.**
- Implication: **real Apple-Silicon continuous batching = forking the stack down to Metal kernels for PagedAttention.** That is the true cost of top-tier batching, and it is a moat *because* it is expensive.

**3. Integration reality — how a paged engine attaches to the pinned Apple tag (`3.31.4`).**
Three layers, only the deepest is the real question:
- **Scheduler + batched decode loop** — pure Swift, above the tag (this is the landed SPEC-038 scaffold). Zero coupling.
- **Paged KV cache manager** — Swift, can conform to `mlx-swift-lm`'s `KVCache` protocol. Pluggable *only if* attention can read a non-contiguous (paged) layout — which stock attention cannot.
- **Paged-attention kernel — the blocker.** Stock `scaledDotProductAttention` assumes contiguous KV. Two attach options: **(3a)** a **custom Metal kernel beside the pinned tag** via MLX's user-kernel path (keeps `3.31.4`, additive) — *if it reaches deep enough*; **(3b)** **fork `mlx-swift`** (Darkbloom's route) and rebase on Apple tags forever. Extra friction: the model's forward must route through your paged op + cache, which stock models don't — so per-architecture attention injection (or forking the LM library) is required. **Which of 3a/3b applies is an empirical spike, not knowable from outside.**

## What this changes vs the original memo

- **Approach A (upstream-primary) is void** — the upstream path will not deliver.
- **Approach B was scoped to DENSE (1.2–2.1×).** The competitive bar the market and Darkbloom set is **PAGED**, which the memo deliberately excluded. So the memo's "continuous batching" and *competitive* continuous batching are different things; the gap is exactly the paged engine the memo deferred.
- The memo's "defer paged, pivot on a measured gate" was reasonable on 2026-07-22 inputs. **The new input — the leading builder committed to paged and abandoned upstream — is precisely the signal that should re-open that gate.**

## Re-framed option set (honest costs)

| # | Option | Effort | Throughput | Stays on Apple tag? | Notes |
|---|---|---|---|---|---|
| 1 | **Dense batching now** (memo's Approach B, un-gated by upstream) | ~6–10 wk | **1.2–2.1×** on multi-slot tiers | Yes (additive) | Real but modest; **below the paged bar**; built from public `mlx-lm` `BatchGenerator` (MIT) + #263 (Apache/MIT) as reference |
| 2 | **Paged batching** (heavy path; Darkbloom's answer) | Large + ongoing | Top-tier + memory efficiency (helps context / bigger models) | 3a: yes / 3b: no (fork) | Custom paged-attention Metal kernel + PagedKVCache + per-model attention injection. Built from **public** sources (`mlx-lm` MIT, vLLM Apache-2.0, PagedAttention paper) — **never** their fork |
| 3 | **Engine swap** (llama.cpp/Metal) | Full provider-path rewrite | Batching "for free" | N/A (leaves MLX) | Memo's Approach D was a no-go; re-open only as a serious tradeoff. Note: Darkbloom **stayed on MLX (forked it)** — the strongest signal MLX is the right substrate *if you can fund building on it* |
| 4 | **Don't build** | 0 | none | Yes | Accept lower per-Mac throughput vs paged competitors; compete on P2P supply / cost / privacy / model breadth. A real, **permanent, stated gap** — not "parked" |

## Decision (corrected — future-network framing)

**A first independent re-run (2026-07-29, codex-backed) concluded "deprioritize / measure current fleet occupancy first." That conclusion is REJECTED as a category error and is recorded here only to be corrected.** It measured *today's* fleet (mostly 1-slot residential Macs, low concurrency) to decide about infrastructure macprovider is building *to change that fleet*. That is the melting-ice-cream error: gauging today's melt to decide whether to build the factory. For a network being built, **topology is an output of your capabilities, not a fixed input** — and gating demand-enabling infrastructure on current demand is circular (no batching → no efficient Ultra serving → no reason for Ultra owners to join → low concurrency → "batching isn't worth it").

The correct framing splits the two axes and **re-prioritizes them for the network being built:**

- **Paged / memory-servability is the PRIMARY strategic bet — not "over-engineering."** It lets a Mac serve **bigger models and longer contexts** than it otherwise could — the differentiated capability that attracts serious (Ultra/high-memory) providers and big-model/long-context buyers, i.e. the flywheel that *creates* the target network. It is **concurrency-independent** (helps a 1-slot Ultra as much as a busy one), so "low concurrency today" is **not** an argument against it. The competitor confirms it: **Darkbloom forked the entire MLX stack to build exactly this** because it is load-bearing infrastructure for a serious Mac-inference network. If macprovider does not build it, the Ultra tier goes to them.
- **Dense / throughput is the secondary axis, built *ahead of* recruited demand.** Its payoff scales with multi-stream concurrency, which a deliberate Ultra-provider strategy *manufactures* — you build ahead of it, as datacenter batching was built before 50-stream demand existed, not behind it.
- **Engine-swap (Option 3) stays a no-go**; **don't-build (Option 4) = ceding the Ultra tier to the competitor**, not a neutral park.

**What survives from the rejected re-run (kept because it is timeline-independent):** the two-axis decomposition itself; the finding that PR #804's FR-CB10 activation theory is dead (below); and the engine-swap no-go.

**Immediate next action is the spike, NOT a fleet measurement.** The real unknown and cost driver is whether paged attention attaches additively to the pinned tag (custom Metal kernel, 3a) or forces an `mlx` fork (3b) — see "The spike" below. The only *forward* demand signal worth watching in parallel is **unmet model/context requests** (buyers asking for models/contexts a Mac can't serve — the servability signal), which is a future signal, not a current-occupancy one.

## PR #804 — reframe to locally-owned activation

The scaffold's **seam is sound and worth keeping**: default-OFF knob, serial-identical inert `off` path (no usage/receipt/billing/slot change), fail-closed strict mode with a named reason, canary observable-serial-route (never a silent downgrade), MSB aggregate-throughput helper; the three-lane BUILD audit converged 0 C/H/M.

Its **activation theory is dead-on-arrival, however**, and must be reframed. The code hard-codes `reviewedUpstreamBatchRevision = nil` and `on` fails closed with `continuous_batching_unavailable` whose *entire* satisfaction path (FR-CB10) is *"pin a reviewed upstream `mlx-swift-lm` batch API."* Per new fact #1 that pin will **never exist** — upstream #263 is abandoned and its author moved to a private paged fork. So the gate is **permanently unsatisfiable via the path the code names.**

**Reframe:** the activation authority must flip from *"a reviewed upstream revision exists"* to *"a locally-owned batching engine capability exists"* — i.e. the dense scheduler, or the paged engine (PagedKVCache + custom Metal kernel + per-model attention injection), built in-repo from public sources. Until that capability exists, #804 is a **dormant safety/telemetry surface**, and its presence on a branch must not be read as momentum toward shipping. Concrete follow-up when batching is picked up: amend `ContinuousBatchingPolicy` so the gate references a locally-owned capability flag, not an upstream revision. #804 stays unmerged until that reframe (or a decision to land it purely as the dormant seam with the corrected gate).

## The spike (how to run it)

**Where: this M5 (32 GB) dev Mac — no lab Mac needed.** Kernel feasibility uses trivial memory. Metal + Swift + `mlx-swift` are present and building here. **Caveat:** this M5 also runs the live production provider daemon, so the spike is a **standalone SwiftPM package** with light load and **no process-killing** (a broad `pkill` once downed the live provider — see `incident-2026-07-27`).

- **Phase 0 — the 3a/3b decider:** in a throwaway package pinning `mlx-swift 0.31.6`, confirm MLX's **user-defined Metal-kernel path** exists and dispatches on the pinned version (core exposes `mx.fast.metal_kernel`; confirming the *mlx-swift* surface is the test). Registers → **3a** (additive on the tag). Can't express it → **3b** (fork `mlx`).
- **Phase 1 — correctness:** implement a minimal paged-attention gather (KV read from non-contiguous blocks via a block table) in that kernel; run one attention step on synthetic Q/K/V; bit-compare vs contiguous `scaledDotProductAttention`.
- **Phase 2 (later spike, not this one):** route a real Llama forward through the paged op — the per-model attention-injection question.

Timebox to days. The Phase-0 result sizes the entire paged build and is the gate before any production commitment.

## Boundary note (repeat, load-bearing)

Every competitive fact above is from **public metadata** (language stats, submodule/manifest declarations, PR titles/states). **No `Layr-Labs/*` fork or `d-inference` source was read.** Any future batching build uses only **ml-explore upstream (MIT/Apache) + public `mlx-lm` + vLLM + the PagedAttention paper** — never the Layr forks' diverged commits.
