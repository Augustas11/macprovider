# macprovider research roadmap

**Living doc — state drifts; verify against `origin/main` before acting.**
Last synthesized: 2026-07-29 (SPEC-038 batching SPEC merged #799 — scaffolding IMPL in flight, land flag-off; throughput engine gated on upstream PR #263;
SPEC-037 KV-survival shipped dormant #771; SPEC-036 compute-integrity SPEC merged
#390, IMPL pending). Ranks research/e2e threads by expected impact on buyer UX
(time-to-first-token, tokens/sec, reliability) and provider UX (model selection,
earnings). Source: session synthesis of `docs/research/RESEARCH_2*`,
`audits/_prompts/RESEARCH_2*`, `beta/DECISION_CRITERIA.md`.

## Delivered (research complete; at decision/impl/campaign gates)

| Thread | State | Recommendation / verdict | Next gate |
|---|---|---|---|
| **236** P4 cache-reuse regression gate | **MERGED** (PR **#696**, 2026-07-22; 0 C/H/M, governance green) | B8 armed PASS≥0.60 / WARN[0.50,0.60) / FAIL<0.50 from measured **0.725** baseline; B9 record-only | wire the continuous/CI phase-C consumer (must treat WARN+SKIP non-green; run-salt the sticky tag) |
| **235** P3 thermal-soak INSTRUMENT | **MERGED** (PR **#698**, 2026-07-22; B10 sustained-TPS retention) | instrument only; soak **campaign parked** for lab Mac | run campaign on lab Mac → safe-sustained-load envelope for #584 (Tier C) |
| **234** cold/warm TTFT | harness merged (#668); campaign armed + accumulating | — | calibration PR / prewarm rec / cold-start SLO pend passive data; cold idle-evict cell = post-reboot-only (no lab Mac) |
| **233 / SPEC-037** KV survival on restart | **SHIPPED DORMANT** — SPEC merged (PR **#702** v0.1.0, 2026-07-23) + IMPL merged (PR **#771** v0.1.1, `d53e8650`, 2026-07-27). Encrypted provider-local KV disk tier behind `ConversationCache`; default-off, synthetic-key-only, residency-only — merge enables nothing, worst-case defect = fallback to normal prefill. | **Approach A** delivered; no receipt change | **blind + real-hardware verification is the runtime-feature enable gate** (Entry **199**): a 5-lane R5 PASS + green CI + unit tests all passed while the feature was inert, so audits are *not* the enable gate — a real-Mac restart-persistence run is. Feature stays off until that passes. |
| **232 / SPEC-038** continuous batching | **SPEC MERGED** (PR **#799**, `1d78778a`; 0 C/H/M). Scaffold PR **#804 HELD** (activation theory dead — see below). | **Build it in-house** — upstream will never deliver it (see addendum). SPEC-028 spec-decode mutually exclusive in v1. | **See `RESEARCH_232_ADDENDUM_PAGED_REDECISION_2026-07-29.md` (corrected).** Upstream #263 is structurally dead (Layr abandoned it for a private paged fork; competitor forked the whole MLX stack). **Batching — esp. PAGED / memory-servability — is strategic infrastructure for the network being built (attracts Ultra providers + big-model/long-context buyers; concurrency-independent), NOT gated on today's fleet occupancy.** Next action = the **kernel-vs-fork spike** on this M5 (does a paged-attn Metal kernel register beside the pinned tag → 3a, or must we fork `mlx` → 3b). #804's FR-CB10 upstream-pin gate must be reframed to locally-owned activation. |
| **231** oMLX calibration | synthesized + refreshed | advisory-only, ~zero shipped impact, blocked on >32GB Mac; Entry 179 + `UPSTREAM_WATCH` refreshed (oMLX v0.5.3, board ~340k rows) | FB-02/03/04 benches (lab-Mac cluster); oMLX-seeded gates = issue #687 |

## Forward ranking (what to do next)

### Tier A — SPEC-038 continuous batching: scaffolding IMPL in progress
1. **Scaffolding IMPL is in flight — land it flag-off; it is NOT wasted.** The SPEC
   is merged (#799). `mlx-swift-lm` 3.31.4 ships no released batch API (single-request
   iterators only; the shared-forward *engine* is unmerged upstream PR #263), so the
   throughput engine can't be wired yet — but the **scaffolding is the integration
   surface every path needs** and is worth landing now:
   - **Deliverable now (buildable, safe, mergeable):** the feature-gated scheduler
     surface, unsupported-mode guards, telemetry/backpressure, and benchmark harness
     — flag **OFF**, serial path **identical to today** (zero behavior change),
     compiled+tested+audited. Merge it flag-off. Handoff
     `audits/_prompts/BUILD_SPEC_232_CONTINUOUS_BATCHING_DRIVE_TO_FULL_PROMPT.md`
     (Phase C). This is Path-A groundwork, not throwaway.
   - **Only the engine flip is gated — a later, separate step,** not something the
     current build must solve. Register **PR #263** in
     `beta/throughput-engineering/UPSTREAM_WATCH.json` (same pattern as the
     Cluster-F PR #371 watch) so the flip is tracked.
   - **Turning batching ON = pick a path when the engine exists:** **(A)** upstream
     #263 lands (or macprovider drives it) → pin + flip; or **(B)** the memo's
     fallback — a native Swift batch scheduler (bigger, diverges from upstream) if
     the earnings win can't wait. #263's API is still incomplete (quantized KV /
     spec-decode / some cache subclasses), so the scaffolding stays engine-agnostic
     at its seam.
   - **When the engine lands (path A):** pin the reviewed tag/revision (FR-CB10
     version-pin) → wire behind the flag → **replicate MSB-01..05 on real catalog
     models** (prove the multiplier holds on macprovider hardware; every vendor
     number is unreplicated until measured) → run the Entry-199 real-hardware
     enable gate (throughput + per-request usage/receipt correctness under the
     shared forward) → flip the flag default-off → canary → fleet.
   - When real batching does land, apply the **Entry-199 lesson** (real-hardware
     throughput + per-request-usage-correctness run is the enable gate, not green
     audits/CI), rebase on merged 037 KV, and confirm 038's batch-aware KV layout
     doesn't break 037's opaque serialization.
2. **SPEC-037 real-hardware verification** (small, unblocks a shipped feature).
   037 is merged but dormant; the enable gate per Entry 199 is a blind +
   real-Mac restart-persistence run (deploy/crash/relaunch/reboot re-prefill hit
   vs the in-RAM warm baseline, plus the buyer-purge primitive exercised). Until it
   passes, the disk tier stays default-off. Blocked only on a controllable Mac to
   run it — pairs with the Tier-C lab-Mac need.

### Delivered SPECs (merged; IMPL/verification state noted)
- **SPEC-038 — continuous batching** — **SPEC merged** (PR #799, `1d78778a`,
  2026-07-29; 0 C/H/M). **Scaffolding IMPL in flight** (Tier A item 1); land it
  flag-off as Path-A groundwork. Only the throughput *engine* is upstream-gated (no
  released mlx-swift-lm batch API; PR #263).
- **SPEC-037 — KV survival** — SPEC #702 + IMPL #771 **merged, dormant**. Next:
  the Entry-199 real-hardware enable gate (item 2 above).
- **SPEC-036 — compute-integrity receipt companion** (settlement drift gate, from
  stale PR #390): **SPEC merged LOCK-ready** (PR **#390**, 2026-07-23,
  `specs/SPEC-036-compute-integrity-receipt.md`; 14-round audit converged). **IMPL
  not yet done** — the coordinator settlement-gate build + money-path three-lane
  audit is the remaining 036 work. Handoff:
  `audits/_prompts/BUILD_SPEC_036_COMPUTE_INTEGRITY_DRIVE_TO_FULL_PROMPT.md` (its
  Phase C onward).

### Tier B — smaller unblocked / decision-gated (no hardware)
3. **oMLX provisional-gates Stage 1** (issue #687) — cheap, unblocked; gated on the
   value call (how many rows blocked *only* on throughput self-verification).
4. **RESEARCH_227 rate-card close-out** — Nemotron license + live OpenRouter
   re-pull; unblocks catalog pricing.

### Tier C — the lab-Mac cluster (one M4 Max 64GB unblocks three + the 037 enable gate)
5. Acquire one controllable lab Mac → unblocks simultaneously:
   - **SPEC-037 KV-survival enable gate** — the Entry-199 blind + real-hardware
     restart-persistence run that flips the shipped-dormant disk tier on.
   - **RESEARCH_235 P3 thermal-soak CAMPAIGN** — run the (now-merged #698) instrument
     to produce the "safe sustained-load envelope" #584's canary redesign consumes.
   - **RESEARCH_234 cold idle-evict cell** — the cold-TTFT measurement
     post-reboot-only can't cover.
   - **RESEARCH_231 FB-02/03/04** — catalog gate-loosening → provider availability.

### Tier D — second wave / gated
6. **SPEC-036 compute-integrity IMPL** — SPEC merged LOCK-ready (#390); the
   coordinator settlement-gate build + money-path three-lane audit remains. Larger
   than 232 and money-path; sequence after 232 unless prioritized.
7. Stochastic spec-decode enablement (SPEC-030 losslessness-probe open items) → fleet-wide buyer TPS.
8. Workload-class runtime classifier (SPEC-029 deferred).
9. CPU-time instrumentation — cheap diagnostic; run before the 232 batching build.
10. **RESEARCH_237 — Cluster F (oversized-model sharding across shared Macs)** —
    consolidated below. Runtime feasibility **de-risked**; **demand-gated, don't
    build**. Next action is a one-line upstream watch, not a campaign.
11. Goodhart v0.2 demand-signal — traffic-gated, don't start.
12. Standing hygiene — monthly oMLX snapshot (partly done 2026-07-22), Darkbloom re-pull.

## RESEARCH_237 — Cluster F: run big models on shared different Macs (consolidated)

**One goal:** let macprovider serve a model too large for any single provider
Mac by splitting it across several independently-owned Macs. This unifies two
separate desk-research tracks that were circling the same question from opposite
ends. **Status: unstarted numbered thread (237); runtime de-risked; demand-gated
— do not build.**

**Two source tracks now folded into one:**

| Track | Doc | Angle | What it settled |
|---|---|---|---|
| Shard pipeline-over-WAN | [`docs/research/shard-pipeline-feasibility.md`](shard-pipeline-feasibility.md) (2026-07-07, commit `9e45773a`) | *Can we build the MLX stage runtime?* Read-only compare vs the `shard`/c0mpute reference (pipeline-parallel, per-stage receipts, cwnd keep-warm, RTT-ring placement). | **Runtime primitive proved for Llama.** Spike 01 (`phase3-binary/Tests/mlx-stage-spikeTests/StageForwardParityTests.swift`) loads `layers[lo:hi]` on hidden state with per-stage KV and matches full-model greedy argmax on `Llama-3.2-3B-4bit`. Verdict: go-with-caveats; transport/placement patterns transferable now; cross-Mac serving still needs a stage runtime + swarm coordinator + activation wire. |
| Cluster F / Mesh-LLM | [`docs/research/HANDOFF-CLUSTER-F-MESH-LLM-RESEARCH-2026-07-22.md`](HANDOFF-CLUSTER-F-MESH-LLM-RESEARCH-2026-07-22.md) | *Should we, and what actually blocks it?* Desk compare vs Mesh-LLM (Rust/GGUF) & Exo (MLX); MLX-swift distributed primitive audit; blocker ranking. | This **is** the repo's own deferred "Cluster F sharding" (SPEC-015 Q3, `docs/OPEN_QUESTIONS.md`). Don't port Mesh-LLM (wrong stack). MLX-swift distributed C primitives exist; the Swift wrapper is upstream **PR #371** (open, ~4-month-stale, CPU-only ops). Runtime is the *most tractable* blocker, not the pacing one. |

**Combined verdict (the consolidation):** the *runtime* half is largely
answered — Spike 01 proves the MLX stage-forward primitive works for Llama, and
mlx-swift PR #371 is the tracked upstream that would supply distributed
`send`/`recv` collectives. So the classic "is the engine even possible on our
stack?" question is **no longer the blocker**. The real gates are all
**non-runtime**, ranked:

1. **Billing/receipts** — SPEC-015 assumes one provider per response; N-provider
   settlement is a money-path redesign of `phase4-coordinator` billing (new
   `SPEC-0NN-cluster-f-sharding` + full three-lane audit). **This is the pacing
   work**, independent of the engine.
2. **Anonymity** — pipeline-splitting routes buyer activations through N Macs →
   new timing/volume side-channel surface vs SPEC-017's deliberately small
   anonymity set. Needs explicit analysis *before* any build.
3. **Availability** — a response needing N flaky, independently-owned Macs up at
   once is strictly more fragile (cf. `prod-503-noprovider-transient-degrade`).
4. **Demand unestablished** — nothing in the corpus targets models too big for a
   high-end single Mac (M3 Ultra/512GB). Possibly solving a problem with no buyers.

**Recommendation & next actions (do these, in order — none is "start building"):**
1. **Register the upstream watch** — add `mlx_swift_371_distributed_communication`
   under `blockers` in `beta/throughput-engineering/UPSTREAM_WATCH.json` (mirror the
   existing `mlx_swift_lm_364_*` entries) → PR #371 surfaces on each watch refresh.
2. **Keep 237 as a placeholder, not a campaign** — it has a spike but no
   measurement campaign and no demand signal, so it stays a named thread, not a
   `RESEARCH_237_*_MEMO.md`. Promote to a real memo only on a **demand signal**
   (evidence buyers want models bigger than one Mac can serve).
3. **If PR #371 merges** → benchmark spike: two provider-class Macs over a
   realistic WAN link, measure CPU-only `send`/`recv` overhead vs real generation
   throughput before trusting the collectives for anything latency-sensitive.
4. **If ever prioritized** → start at the **billing/receipts N-provider
   settlement SPEC**, not the inference engine.

## Organizing insights
- Shape as of 2026-07-27: e2e suite fully delivered (P1–P4). **SPEC-037/233 KV
  survival SHIPPED dormant** (SPEC #702 + IMPL #771); **SPEC-036 compute-integrity
  SPEC merged LOCK-ready** (#390) with IMPL still to build. The single top
  unblocked lever is now **232/SPEC-038 continuous batching**.
- **"Unblocked" ≠ "implementable in full."** 233/037 was fully buildable and
  shipped; **232/038 is not** — its throughput engine depends on an unreleased
  upstream `mlx-swift-lm` batch API (PR #263), so only serial scaffolding builds
  now and real batching waits on an upstream-pin-or-native-scheduler decision.
  Rank future threads by *what actually ships*, not by "no hardware / no gate."
- **The 037↔038 sequencing constraint is resolved** (for whenever 038's real IMPL
  proceeds). 037 shipped, so 038 rebases onto the merged 037 KV changes without the
  earlier "land 037 first" wait. They still share
  `phase3-binary/.../ModelRuntime.swift` + the KV-cache classes, so 038's
  batch-aware KV layout must not break 037's opaque serialization — a
  rebase-and-verify concern, not a scheduling blocker.
- **Entry-199 lesson (load-bearing for every runtime build from here):** SPEC-037
  passed a 5-lane R5 audit, green CI, and unit tests **while shipping completely
  inert**. Audits/CI are not the enable gate for a runtime feature — a real
  hardware exercise is. Apply to 038 (throughput + per-request usage correctness on
  a real Mac) and to the 036 IMPL (settlement gate exercised end-to-end), not just
  to 037's own pending enable gate.
- The remaining backlog splits cleanly: **232/SPEC-038 batching (unblocked now)**,
  **036 compute-integrity IMPL (money-path, larger)**, **one hardware bottleneck
  gating a cluster of four (037 enable gate / 235 campaign / 234 cold cell / 231 FB
  → one lab Mac)**, and **demand-gated second-wave (237 Cluster-F, Goodhart)**.
- The lab-Mac gap is a standalone procurement decision that now also unblocks the
  037 enable gate, not just the three benches.
- **Cluster-F sharding is now one thread, not two loose docs.** The shard track
  answered "can the engine work on MLX?" (yes, Spike 01) and the Mesh-LLM track
  answered "what really blocks it?" (billing/anonymity/availability/demand, not
  the engine). Consolidated verdict: runtime de-risked, **demand-gated** — the
  only pending action is a one-line upstream watch on mlx-swift PR #371.
