# SPEC-004 Pillars D + A — combined three-lane codex audit results

D and A were audited together because both Phase D step 2 (server.go
log delegation + class.go BalancedScores extraction) and Phase A
(routing/sticky/ package extraction) landed in adjacent commits.
Prompts live in `specs/AUDIT_SPEC_004_PILLAR_DA_R*_*.md`; raw codex
responses under `.omc/artifacts/ask/` (gitignored).

## R1

Source commit: `59f4184` (Phase A IMPL — sticky package extraction)
following `05cdd9a` (Phase D step 1: routing/log.go SPEC-004 §7
surface) and `c2d7e73` (Phase D step 2: server.go log delegation +
BalancedScores).

| Lane | Tally | Notes |
|------|-------|-------|
| CODE | 0/1/0/0 | HIGH: log refactor renamed/dropped legacy fields (`slots_free`/`throughput_tps`/`seed`/`draw`/`reason`) — would break pre-Phase-D consumers |
| SECURITY | 0/0/1/1 | MEDIUM: `seedForRequest` missing daily-key derivation (would leak cross-day patterns); LOW: `slots_total` dropped from candidate entries |
| ARCHITECT | 0/0/1/1 | MEDIUM: sticky.Map.Update refresh-at-cap could evict unrelated entries; LOW: BalancedScores doc referenced a non-existent helper |

**Fix commit:** `922e454` absorbed all five findings — added Legacy*
aliases to Decision + CandidateLogEntry; introduced
`seedForRequestWithKey(requestID, dailyKey)` + UTC daily-key bucket;
split sticky.Map.Update into refresh-FIRST then insert-with-eviction
path; reworded BalancedScores doc.

## R2

Source commit: `922e454` (R1 fix-pass).

| Lane | Tally | Notes |
|------|-------|-------|
| CODE | **0/0/0/0 ACCEPT** ✅ | — |
| SECURITY | **0/0/0/0 ACCEPT** ✅ | — |
| ARCHITECT | **0/0/0/0 ACCEPT** ✅ | — |

Pillars D + A converged at R2 across all three lanes.

## Post-R2 CI integration regression

Source commit (R2 fixed): `34f459b`. After R2 ACCEPT a CI integration
test (`TestStickyHeaderForwardedToCoordinator` in `test/integration`)
caught a regression that all three R1 audit lanes missed: the
log-refactor delegation lost the `reason` field for sticky-miss
variants (`sticky_miss_not_found`, `sticky_miss_expired`,
`sticky_miss_provider_not_candidate`) because server.go's reverse-
map only translated `deterministic`/`randomized` to `tiebreak_mode`,
leaving LegacyReason empty for sticky cases. Fix: always populate
`Decision.LegacyReason` with the caller-supplied reason string
regardless of TiebreakMode mapping.

**Lesson logged** in [[feedback-audit-prompts-log-shape-backcompat]]
(memory rule TBD): audit prompts for log-shape refactors MUST include
explicit "enumerate every pre-refactor field/value and prove it still
emits" coverage — three-lane audits missing a back-compat regression
that integration tests caught is signal for the discipline, not noise.
