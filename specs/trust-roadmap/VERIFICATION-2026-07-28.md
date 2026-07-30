# Re-verification against `origin/main` @ `51a60c23` (2026-07-28)

The pieces were written against `8a39c636`. **17 commits landed since** — the
seam-hardening P0/P1/P2 set (#760–#769), the SPEC-032 posture reconciliation
(#769), and several Pearl-deploy/pricing commits. This is the per-piece
re-check. Verdict key: **VALID** (problem still exists as written) ·
**REDUCED** (part done by a shipped PR) · **SHAPE** (still valid but the
mechanism/scope changed) · **DONE** (fully fixed).

## Headline

- **No piece is obsolete.** Every ship-now piece and every brief still describes
  a real gap.
- **A2 shrinks**: its SPEC-032 posture-inversion item is **done** — PR #769
  reconciled the spec (now marked "2026-07-11 baseline; superseded"). A2 survives
  as SPEC-033 (missing migration 019) + SPEC-013 NFR-4 (egress list).
- **A8 got worse**: SPEC-023 is now `v0.8.1` LOCKED and the spec-vs-signed-catalog
  disagreement widened to **3 rows** (gemma-4-26b, qwen3-32b, qwen2.5-coder-32b),
  not just gemma.
- **A4 and B4 changed shape** (details below); **B4 got harder** (must now
  integrate with #763's durable bill-once journal).
- **Two new mechanisms landed adjacent to the thesis** and both pieces must
  reference them: #764 `capacity_clamp` (clamps provider-claimed concurrency/slots
  at ingest) and #765 `BenchmarkQuarantined` (a provider with no verified autotune
  benchmark is now route-excluded — `RoutingEligible` returns false).
- **Line numbers drifted** across roughly half the pieces (server.go +318,
  provider.go +71). Each piece file below carries its corrected refs.

## Ship-now pieces

| Piece | Verdict | Notes (current file:line @ 51a60c23) |
|---|---|---|
| **A1** | VALID | `README.md:22` + `docs/using-macprovider-with-openai-sdk.md:202` overclaims intact verbatim; `SPEC-006:343` still forbids. |
| **A2** | **REDUCED** | SPEC-032 posture item **DONE** (#769 — spec now "superseded", `SPEC-032:557,568`). Still valid: SPEC-033 roster omits migration 019 (`SPEC-033:17` lists only 007–017); SPEC-013 NFR-4 egress list (`SPEC-013:1279`). **Drop the runbook item** — `spec-drift-remediation.md:132` is a frozen dated history row, and the spec-level contradiction it recorded is now reconciled. |
| **A3** | VALID | `benchmarkPassesGate` still checks only thermal (`gate.go:88`) and `return true` (`:107`); `swap_detected` decoded (`evidence.go:13`) but unchecked. (ref was `:104-106` → `:107`.) |
| **A4** | **SHAPE** | Still valid: no in-band provenance (all 9 live rows carry only tps/ttft); `require_provenance` only in `generate` (`catalog-release.py:1502`; others `:1324,1589,1649,1697,1721`). **Change**: the client backfill now *fails closed* unless the catalog matches the pinned recovery release+SHA (`AutotuneRecommend.swift:796-797`, table `:799`, applied `:757-765`) — the live feed still matches that pin, so it is still backfilled client-side. Reword A4 to note the fail-closed pin. |
| **A5** | VALID | `MaxAdmittedMinRAMGB` still absent (only `MaxAdmittedModelKey` `provider.go:214`); `applyHeartbeatLocked` `:1868`, `p.ModelID = hb.ModelID` `:1908` (was `:1851`). **New context**: #765 `BenchmarkQuarantined` (`provider.go:188-194,446-457`) already route-excludes *no-evidence* providers — so A5's no-verified-evidence branch should build on that flag, and #764 `capacity_clamp` handles concurrency, not the RAM ceiling A5 targets. |
| **A6** | VALID | "Benchmarked N" (eligible count) `AutotuneRecommend.swift:2068` (was `:2057`); `$0.0050/hr` donor string `AutotuneCommand.swift:958`; unlabeled chip constants `ProviderHardwareSummary.swift:56-108`, surfaced `stats/handlers.go:84-87`. |
| **A7** | VALID | `pillar_c.go` marshals SE `Claimed` (carries `model_hash`) `:433`, hashes to `ClaimedSHA256` `:437,449,460`, never compared to catalog. |
| **A8** | **SHAPE (worse)** | SPEC-023 now `v0.8.1` LOCKED. Disagreement widened to 3 rows vs the live signed catalog (all live rows `recommendable`): `gemma-4-26b` spec **blocked** (`SPEC-023:271`); `qwen3-32b` spec **listed** (`:268`); `qwen2.5-coder-32b` spec **listed** (`:270`). Two live rows (`llama-3.2-3b`, `qwen3-8b`) have no spec-table counterpart. |

## The gate

| **G0** | VALID / runnable | `request_log` still carries the columns G0 queries (`model`, `provider_assigned_id`, `prompt_tokens`, `ts_utc`); no schema change blocks it. |

## Deferred briefs

| Brief | Verdict | Notes |
|---|---|---|
| **B1** | VALID | `request_log` still lacks `ttft_ms`/`decode_ms` (`store.go:43-100,463-514,527-568`); 8 `markProviderFirstByte` sites (now `server.go:2515,2606,2956,3162,3445,3616,3722,3977`); `phase_timing.go +75` was the #766 terminal latch, not persistence; SPEC-002 `+77` was `attempt_n`, does not block the column addition. |
| **B2** | VALID (+precedent) | Ceiling enforcement still unbuilt. **New precedent**: `RoutingEligible` now excludes `BenchmarkQuarantined` (`provider.go:446-457`) — B2's over-ceiling exclusion can follow the same pattern. |
| **B3** | VALID | Both self-report paths intact: `EffectiveThroughput` (`candidate.go:86-91`, consumed `objective.go:59-140`) and `BalancedScores` reading `ThroughputTPSEstimate` at 0.4 weight (`class.go:46,54`). Quarantined providers now dropped pre-ranking, but survivors still rank on the self-reported number. |
| **B4** | **SHAPE (harder)** | No discount/unbilled path exists (grep clean). Payout still voids under `minPayoutCredits` (`payout.go:124,141-146`). **#763 added a durable bill-once settlement journal** (`store.go` UNIQUE `:100,144,233`) — any probation discount/unbilled path must now integrate with idempotent settlement, not a naive recording seam. Scope grew. |
| **B5** | VALID | `RequireAutotuneHelloGate` flag present (`config.go:100`), off in prod; no `admitted_but_unapproved` state. |
| **B6** | VALID | `require_for_registration: false` (`coordinator.yaml:116`); `provider_id` still bound to `identity_pubkey` (`apptrack.go:313`). |
| **B7** | VALID | Deferred by physics (#584 unchanged; still <3 verified providers, >32 GB rows unmeasurable). |
| **B8** | VALID | Drift still self-vs-self: `benchmark.SustainedTPS` vs `provider.ThroughputTPSSinceLast` (`drift.go:236,243`); Pillar D baseline still provider-supplied `ModelLoadTimeMs` (`pillar_d.go:168`). |
| **B9** | VALID | SPEC-036 still zero code; post-beta. |
| **B10** | VALID | `/v1/rate-card` still unsigned (`rate_card.go:39,45`); #937f4b94 restored pricing only, added no signing. |

## Cross-cutting roadmap-doc updates implied

- **§4.6 (F6)**: the concurrency/slots half is now **done** — `ClampCapacity`
  (`capacity_clamp.go:47-86`) wired at ingest (`server.go:4316,4573`). RAM,
  context window, TPS-estimate, and model-load-time are still trusted as-is.
- **§4.5 / §2**: #765 `BenchmarkQuarantined` is a genuinely new admission
  control — no-verified-benchmark → route-excluded — that partially couples
  serving to verification (the thing §2.3 said was fully decoupled). It does not
  close FR-HG7 (a *quarantined-clear* provider can still heartbeat-switch above
  its ceiling), but the map should note it.
