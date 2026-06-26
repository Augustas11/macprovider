# SPEC-017 IMPL Step 2 - SECURITY audit r5

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `a3844aa` (`impl(017): Step 2 - round-4 audit fixes (rewards last_seen + late-event watermark)`)
Prior security lock points: r3 `745128e`, r4 `a70d75a`
Round-5 delta audited: `a70d75a..a3844aa`; full Step 2 diff spot-checked against `origin/main...HEAD`.
Lens: role isolation, provider identity, secret handling, defense-in-depth, and Step 3/4 attack surfaces.

Required reading completed: `CLAUDE.md`; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` section 1 prereqs, section 5 critical constraints, and section 2 Step 2; `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 1.5, 6.1, 6.2, 6.4, 6.6.2, 6.6.3, 7.2, 7.3, 9.3, and 9.4; `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`; prior rounds `specs/SPEC-017-IMPL-STEP_2-security-r1-audit.md` through `specs/SPEC-017-IMPL-STEP_2-security-r4-audit.md`; memory notes `provider-auth-unauthenticated-end-to-end`, `audit-loop-catches-billing-ledger-drift`, and `c2-gate-gateway-credential-validation-asymmetry`; PR #173 body via `gh pr view`.

Validation run:

- `git show --name-only --format=fuller a3844aa` - round-5 fix scope identified.
- `git diff --name-only a70d75a..HEAD` - current delta is limited to rollup code, rollup integration fixtures, and r4 audit artifacts.
- `rg` sweeps found no Step 2 rollup references to `provider_session`, `provider_handshake`, raw hello-frame identity sources, runtime `Origin` branching, runtime `Authorization` handling, production `token_hash` logging, rollup mutation of `partner_keys`, rollup mutation of `provider_visibility_audit`, or production Shape A/B SQL (`TRUNCATE`, `ALTER TABLE RENAME`, `DROP TABLE`).
- `go test ./internal/stats/rollup/... -count=1` from `phase4-coordinator/` - PASS.
- `go test ./internal/stats/rollup -run 'TestEmitDriftPayloadRedaction|TestClassifyPanic|TestConfigValidate|TestConfigDefaultsApplied' -count=1` - PASS.
- `go test ./internal/stats -run 'TestOpenMissingDSNFailClosed|TestPoolsCloseNilSafe' -count=1` - PASS.
- `go test -tags=integration -c ./internal/stats/` - PASS compile.
- Targeted integration execution could not run locally because testcontainers panicked with `rootless Docker not found`; this is an environment gap, not an implementation failure.
- `gofmt -l internal/stats/rollup/*.go` - clean.
- `git diff --check origin/main...HEAD` - FAIL only on pre-existing trailing whitespace in older Step 2 audit markdown files; no inspected implementation file or this r5 audit file is implicated.

## Category Verdicts

A. Role + pool isolation: PASS. Production wiring still constructs the runner with `statsrollup.New(statsPools.Rollup, ...)` only (`phase4-coordinator/cmd/coordinator/main.go:185-256`), `stats.Open` still uses write-pool sizing for `stats_rollup` (`phase4-coordinator/internal/stats/stats.go:193-204`, `stats.go:264-270`), and grants still deny `stats_rollup` access to `partner_keys` and `provider_visibility_audit` (`phase4-coordinator/internal/stats/migrations/004_grants.up.sql:52-75`). The r5 delta uses the injected rollup `db` only.

B. Identity trust: PASS. Full recompute still joins `provider_tokens` for work and rewards aggregation before materializing leaderboard provider IDs (`phase4-coordinator/internal/stats/rollup/leaderboard.go:254-327`). Incremental active-provider discovery and provider-scoped recompute also remain keyed through `provider_tokens` for both work and rewards (`phase4-coordinator/internal/stats/rollup/incremental.go:218-300`). The r5 late-event watermark query joins `provider_tokens` before inserting any work-side late-event row (`phase4-coordinator/internal/stats/rollup/late_events.go:59-82`). PR #173 still records the trust-source decision and links `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.

C. Bucket / projection invariant: PASS. Storage continues to write exact `earnings_usd`, `earnings_work_usd`, and `earnings_rewards_usd`, while computing the storage-time `earnings_bucket` from the total value (`phase4-coordinator/internal/stats/rollup/leaderboard.go:191-233`, `leaderboard.go:467-498`; `phase4-coordinator/internal/stats/rollup/incremental.go:331-348`, `incremental.go:413-452`). The r5 rewards `first_seen_at` / `last_seen_at` fix changes timestamp survival for rewards-only rows, not the public redaction contract. The rollup still reads but does not branch on `blocked_from_partner_projection` (`leaderboard.go:132-180`, `incremental.go:155-158`).

D. Drift + late events + AC-20: PASS. Drift logs remain bounded to event/window/axis/provider sample/numeric ratios and are covered by redaction tests (`phase4-coordinator/internal/stats/rollup/rebuild.go:186-195`, `phase4-coordinator/internal/stats/rollup/rebuild_test.go:62-87`). The r5 late-event path now filters work-side rows by `created_at_utc > lastOK`, joins `provider_tokens`, and writes only `stats_late_events`; rewards-side late-event recording is intentionally absent in v0.1 because the pinned `provider_rewards_ledger` schema has no arrival watermark (`phase4-coordinator/internal/stats/rollup/late_events.go:43-93`). The rollup still has no code path inserting `provider_visibility_audit`, and AC-20 fixtures seed only allowed provider-exact or operator-bucketed rows (`phase4-coordinator/internal/stats/integration_test.go:289-305`, `integration_test.go:440-475`).

E. Configuration safety: PASS. `usd_per_million_credits` remains non-negative with an explicit tested default (`phase4-coordinator/internal/config/config.go:502-510`, `config.go:1053-1055`, `phase4-coordinator/internal/stats/rollup/config.go:70-75`, `config.go:125-130`). `late_events_retention_days` defaults to 90, clamps `(0,30)` to 30 with a warning, and rejects negative values (`phase4-coordinator/internal/stats/rollup/runner.go:50-63`, `phase4-coordinator/internal/config/config.go:1044-1051`). Backfill mode remains limited to `partial` or `full`, with `partial` failing closed if `partial_history_since` is missing or unparsable in coordinator startup translation (`phase4-coordinator/cmd/coordinator/main.go:200-238`).

F. Provider-rewards-ledger handling: PASS. `provider_rewards_ledger` remains limited to the `rewards_populated` EXISTS probe and leaderboard rewards computation/maintenance (`phase4-coordinator/internal/stats/rollup/rewards.go:43-55`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:305-327`, `phase4-coordinator/internal/stats/rollup/incremental.go:218-300`). No UPDATE or INSERT to `provider_rewards_ledger` appears. The r5 removal of rewards-side late-event recording narrows ledger usage relative to r4 and avoids inventing an arrival watermark absent from SPEC §9.1a.

G. Process isolation: PASS. Per-tick panic recovery still logs only a type classification, updates the affected component health row, and returns to that job's ticker loop (`phase4-coordinator/internal/stats/rollup/runner.go:136-211`). Panic classification remains type-only and is covered by DSN/token-shaped regression cases (`runner.go:213-228`, `phase4-coordinator/internal/stats/rollup/rebuild_test.go:89-121`). Goroutine-level recovery remains a defense-in-depth backstop and does not crash the coordinator (`runner.go:150-160`).

## Findings

None.

## Positive Security Observations

- The r4 SECURITY LOW comment drift is fixed: `late_events.go` now describes the live incremental path rather than the earlier full-recompute simplification.
- The r5 rewards timestamp fix preserves the r1 trust-source closure: rewards-only providers still must exist in `provider_tokens` before any leaderboard row can be materialized.
- The r5 late-event watermark fix reduces forensic noise without creating a new raw-token, DSN, partner-key, Origin, or unauthenticated-identity log/storage path.
- Same-origin uniformity is preserved: Step 2 rollup code still does not inspect Origin, Authorization, partner-key rows, or per-key input when computing storage values.
- Shape C remains the only rebuild shape in production code and stays within the locked `stats_rollup` grant set.

## Final Verdict

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
INFO: 0

READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 5 meets the lock target.
