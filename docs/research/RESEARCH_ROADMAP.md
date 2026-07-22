# macprovider research roadmap

**Living doc — state drifts; verify against `origin/main` before acting.**
Last synthesized: 2026-07-22 (post-236). Ranks research/e2e threads by expected
impact on buyer UX (time-to-first-token, tokens/sec, reliability) and provider UX
(model selection, earnings). Source: session synthesis of `docs/research/RESEARCH_2*`,
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
9. Goodhart v0.2 demand-signal — traffic-gated, don't start.
10. Standing hygiene — monthly oMLX snapshot (partly done 2026-07-22), Darkbloom re-pull.

## Organizing insights
- Shape after 236: **one unblocked quick win left (235 instrument)**, **two
  decision-gated big levers (232/233 SPEC drafts)**, **one hardware bottleneck
  gating a cluster of three (235 campaign / 234 cold cell / 231 FB → one lab Mac)**.
- The e2e-test suite is nearly complete: 235's instrument is the last piece
  buildable without hardware. After it, the unblocked research backlog is
  exhausted — remaining progress is either a SPEC-draft go-ahead (232/233) or the
  lab-Mac procurement.
- The lab-Mac gap is a standalone procurement decision, not three separate stalls.
