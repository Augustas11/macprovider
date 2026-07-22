# macprovider research roadmap

**Living doc — state drifts; verify against `origin/main` before acting.**
Last synthesized: 2026-07-22 (post-236; + Cluster-F oversized-model-sharding
consolidation). Ranks research/e2e threads by expected impact on buyer UX
(time-to-first-token, tokens/sec, reliability) and provider UX (model selection,
earnings). Source: session synthesis of `docs/research/RESEARCH_2*`,
`audits/_prompts/RESEARCH_2*`, `beta/DECISION_CRITERIA.md`.

## Delivered (research complete; at decision/impl/campaign gates)

| Thread | State | Recommendation / verdict | Next gate |
|---|---|---|---|
| **236** P4 cache-reuse regression gate | **MERGED** (PR **#696**, 2026-07-22; 0 C/H/M, governance green) | B8 armed PASS≥0.60 / WARN[0.50,0.60) / FAIL<0.50 from measured **0.725** baseline; B9 record-only | wire the continuous/CI phase-C consumer (must treat WARN+SKIP non-green; run-salt the sticky tag) |
| **235** P3 thermal-soak INSTRUMENT | **MERGED** (PR **#698**, 2026-07-22; B10 sustained-TPS retention) | instrument only; soak **campaign parked** for lab Mac | run campaign on lab Mac → safe-sustained-load envelope for #584 (Tier C) |
| **234** cold/warm TTFT | harness merged (#668); campaign armed + accumulating | — | calibration PR / prewarm rec / cold-start SLO pend passive data; cold idle-evict cell = post-reboot-only (no lab Mac) |
| **233** KV survival on restart | memo landed (`d6881b14`) | **Approach A** (encrypted disk tier behind `ConversationCache`), fallback C; provider-local, no receipt field | SPEC draft (awaiting go) |
| **232** continuous batching | memo landed (`8d80f6c4`) | **Approach A** (upstream mlx-swift-lm batch API), fallback B; **pivot-gate = INDEPENDENT → parallel with 233** | SPEC draft (awaiting go) |
| **231** oMLX calibration | synthesized + refreshed | advisory-only, ~zero shipped impact, blocked on >32GB Mac; Entry 179 + `UPSTREAM_WATCH` refreshed (oMLX v0.5.3, board ~340k rows) | FB-02/03/04 benches (lab-Mac cluster); oMLX-seeded gates = issue #687 |

## Forward ranking (what to do next)

### Tier A — unblocked, do now
1. **RESEARCH_233 + RESEARCH_232 SPEC drafts — THE next work.** With 235's
   instrument merged (#698), the entire e2e suite is delivered and Tier A's old
   quick-win is gone; these two are now the only substantive levers that need
   **no hardware and no external gate**. Both memos are landed with a chosen
   approach, and they are confirmed **parallel-independent**, so they run as two
   separate SPEC-draft sessions (same handoff pattern as the in-flight SPEC-036):
   - **233 — KV survival on restart** (buyer TTFT): memo `d6881b14`, **Approach A**
     = encrypted disk tier behind `ConversationCache`, fallback C; provider-local,
     no receipt field. Handoff prompt:
     `audits/_prompts/BUILD_SPEC_233_KV_SURVIVAL_DRIVE_TO_FULL_PROMPT.md`.
   - **232 — continuous batching** (provider earnings): memo `8d80f6c4`,
     **Approach A** = upstream mlx-swift-lm batch API, fallback B. Handoff prompt:
     `audits/_prompts/BUILD_SPEC_232_CONTINUOUS_BATCHING_DRIVE_TO_FULL_PROMPT.md`.
   - Number reservation to avoid collision with in-flight SPEC-036:
     **233 → SPEC-037**, **232 → SPEC-038** (verify-and-bump at runtime).

### In flight (parallel sessions)
- **SPEC-036 — compute-integrity receipt companion** (settlement drift gate, from
  stale PR #390): executing in another session off
  `feat/compute-integrity-receipt-companion` — renumber 030→036 + dep rewire +
  open-questions done; SPEC-audit → IMPL → money-path three-lane audit next.
  Handoff: `audits/_prompts/BUILD_SPEC_036_COMPUTE_INTEGRITY_DRIVE_TO_FULL_PROMPT.md`.

### Tier B — smaller unblocked / decision-gated (no hardware)
2. **oMLX provisional-gates Stage 1** (issue #687) — cheap, unblocked; gated on the
   value call (how many rows blocked *only* on throughput self-verification).
3. **RESEARCH_227 rate-card close-out** — Nemotron license + live OpenRouter
   re-pull; unblocks catalog pricing.

### Tier C — the lab-Mac cluster (one M4 Max 64GB unblocks three)
4. Acquire one controllable lab Mac → unblocks simultaneously:
   - **RESEARCH_235 P3 thermal-soak CAMPAIGN** — run the (now-merged #698) instrument
     to produce the "safe sustained-load envelope" #584's canary redesign consumes.
   - **RESEARCH_234 cold idle-evict cell** — the cold-TTFT measurement
     post-reboot-only can't cover.
   - **RESEARCH_231 FB-02/03/04** — catalog gate-loosening → provider availability.

### Tier D — second wave / gated
5. Stochastic spec-decode enablement (SPEC-030 losslessness-probe open items) → fleet-wide buyer TPS.
6. Workload-class runtime classifier (SPEC-029 deferred).
7. CPU-time instrumentation — cheap diagnostic; run before the 232 batching build.
8. **RESEARCH_237 — Cluster F (oversized-model sharding across shared Macs)** —
   consolidated below. Runtime feasibility **de-risked**; **demand-gated, don't
   build**. Next action is a one-line upstream watch, not a campaign.
9. Goodhart v0.2 demand-signal — traffic-gated, don't start.
10. Standing hygiene — monthly oMLX snapshot (partly done 2026-07-22), Darkbloom re-pull.

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
- Shape after 235/236 merged: **the e2e suite is fully delivered** (P1–P4 all
  landed; 235 instrument #698, 236 gate #696). The next work is **232/233 SPEC
  drafts** — now Tier A, the only substantive levers needing neither hardware nor
  an external gate — running as two parallel SPEC-draft sessions alongside the
  in-flight SPEC-036.
- **Three SPEC tracks can run in parallel right now:** SPEC-036 (compute-integrity,
  in flight), SPEC-037/233 (KV survival, buyer TTFT), SPEC-038/232 (batching,
  provider earnings). All three are memo/handoff-ready; none blocks another.
- The remaining backlog splits cleanly: **SPEC-draft work (232/233, unblocked
  now)**, **one hardware bottleneck gating a cluster of three (235 campaign / 234
  cold cell / 231 FB → one lab Mac)**, and **demand-gated second-wave (237
  Cluster-F, Goodhart)**.
- The lab-Mac gap is a standalone procurement decision, not three separate stalls.
- **Cluster-F sharding is now one thread, not two loose docs.** The shard track
  answered "can the engine work on MLX?" (yes, Spike 01) and the Mesh-LLM track
  answered "what really blocks it?" (billing/anonymity/availability/demand, not
  the engine). Consolidated verdict: runtime de-risked, **demand-gated** — the
  only pending action is a one-line upstream watch on mlx-swift PR #371.
