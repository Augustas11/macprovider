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
| **236** P4 cache-reuse regression gate | PR **#696** open (audited 0 C/H/M, governance green), awaiting user merge | B8 armed PASS≥0.60 / WARN[0.50,0.60) / FAIL<0.50 from measured **0.725** baseline; B9 record-only | merge #696; then wire the continuous/CI phase-C consumer (must treat WARN+SKIP non-green; run-salt the sticky tag) |
| **234** cold/warm TTFT | harness merged (#668); campaign armed + accumulating | — | calibration PR / prewarm rec / cold-start SLO pend passive data; cold idle-evict cell = post-reboot-only (no lab Mac) |
| **233** KV survival on restart | memo landed (`d6881b14`) | **Approach A** (encrypted disk tier behind `ConversationCache`), fallback C; provider-local, no receipt field | SPEC draft (awaiting go) |
| **232** continuous batching | memo landed (`8d80f6c4`) | **Approach A** (upstream mlx-swift-lm batch API), fallback B; **pivot-gate = INDEPENDENT → parallel with 233** | SPEC draft (awaiting go) |
| **231** oMLX calibration | synthesized + refreshed | advisory-only, ~zero shipped impact, blocked on >32GB Mac; Entry 179 + `UPSTREAM_WATCH` refreshed (oMLX v0.5.3, board ~340k rows) | FB-02/03/04 benches (lab-Mac cluster); oMLX-seeded gates = issue #687 |

## Forward ranking (what to do next)

### Tier A — unblocked, do now
1. **RESEARCH_235 (P3 thermal-soak) INSTRUMENT** — build the soak scenario
   (`15_thermal_soak.yaml`), the sustained-TPS-retention invariant, and the
   provider-side thermal capture collector NOW; **park the soak campaign** for the
   lab Mac (same split we used for 234's cold cell and 236). Completes the 4-part
   e2e suite (P1 shipped, P2/234 + P4/236 done, P3 is the last) and directly serves
   OPEN **P0 #584** (canary collapses healthy providers → buyer 503s) — the biggest
   unaddressed reliability gap. **ID collision:** 236 took `B8`/`B9`; 235's prompt
   says `B8` for retention — use the next free ID (**B10**) instead.

### Tier B — research done, decision-gated (no hardware)
2. **233 + 232 SPEC drafts** — the two biggest levers (232 = provider earnings via
   batching; 233 = buyer TTFT via KV survival), confirmed parallel-independent.
   SPEC-draft stage needs only a go-ahead → codex SPEC-audit loop → BUILD_SPEC.
3. **oMLX provisional-gates Stage 1** (issue #687) — cheap, unblocked; gated on the
   value call (how many rows blocked *only* on throughput self-verification).
4. **RESEARCH_227 rate-card close-out** — Nemotron license + live OpenRouter
   re-pull; unblocks catalog pricing.

### Tier C — the lab-Mac cluster (one M4 Max 64GB unblocks three)
5. Acquire one controllable lab Mac → unblocks simultaneously:
   - **RESEARCH_235 P3 thermal-soak CAMPAIGN** — run the (Tier-A-built) instrument
     to produce the "safe sustained-load envelope" #584's canary redesign consumes.
   - **RESEARCH_234 cold idle-evict cell** — the cold-TTFT measurement
     post-reboot-only can't cover.
   - **RESEARCH_231 FB-02/03/04** — catalog gate-loosening → provider availability.

### Tier D — second wave / gated
6. Stochastic spec-decode enablement (SPEC-030 open items) → fleet-wide buyer TPS.
7. Workload-class runtime classifier (SPEC-029 deferred).
8. CPU-time instrumentation — cheap diagnostic; run before the 232 batching build.
9. **RESEARCH_237 — Cluster F (oversized-model sharding across shared Macs)** —
   consolidated below. Runtime feasibility **de-risked**; **demand-gated, don't
   build**. Next action is a one-line upstream watch, not a campaign.
10. Goodhart v0.2 demand-signal — traffic-gated, don't start.
11. Standing hygiene — monthly oMLX snapshot (partly done 2026-07-22), Darkbloom re-pull.

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
- Shape after 236: **one unblocked quick win left (235 instrument)**, **two
  decision-gated big levers (232/233 SPEC drafts)**, **one hardware bottleneck
  gating a cluster of three (235 campaign / 234 cold cell / 231 FB → one lab Mac)**.
- The e2e-test suite is nearly complete: 235's instrument is the last piece
  buildable without hardware. After it, the unblocked research backlog is
  exhausted — remaining progress is either a SPEC-draft go-ahead (232/233) or the
  lab-Mac procurement.
- The lab-Mac gap is a standalone procurement decision, not three separate stalls.
- **Cluster-F sharding is now one thread, not two loose docs.** The shard track
  answered "can the engine work on MLX?" (yes, Spike 01) and the Mesh-LLM track
  answered "what really blocks it?" (billing/anonymity/availability/demand, not
  the engine). Consolidated verdict: runtime de-risked, **demand-gated** — the
  only pending action is a one-line upstream watch on mlx-swift PR #371.
