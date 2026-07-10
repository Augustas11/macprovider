# SPEC-017 IMPL Step 2 - SECURITY audit r6

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `f2e2415` (`impl(017): Step 2 - round-5 audit fixes (visibility seam, drift union, late-event GREATEST, Shape C content-equality)`)
Prior security lock point: r5 `a3844aa`
Round-6 delta audited: `a3844aa..f2e2415`; full Step 2 diff spot-checked against `origin/main...HEAD`.
Lens: role isolation, provider identity, secret handling, defense-in-depth, and Step 3/4 attack surfaces.

Required reading completed: `CLAUDE.md`; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` section 1 prereqs, section 5 critical constraints, and section 2 Step 2; `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 1.5, 6.1, 6.2, 6.4, 6.6.2, 6.6.3, 7.2, 7.3, 9.3, and 9.4; `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`; prior round `specs/SPEC-017-IMPL-STEP_2-security-r5-audit.md`; memory notes `provider-auth-unauthenticated-end-to-end`, `audit-loop-catches-billing-ledger-drift`, and `c2-gate-gateway-credential-validation-asymmetry`; PR #173 body via `gh pr view 173`.

## Validation Run

- `git show --name-only --oneline HEAD` - round-6 fix scope identified as rollup code, rollup integration tests, and r5 audit artifacts.
- `git diff a3844aa..HEAD -- phase4-coordinator/internal/stats/rollup/... phase4-coordinator/internal/stats/rollup_integration_test.go` - round-6 delta inspected.
- `gh pr view 173 --json number,title,headRefName,baseRefName,body,url` - PR body still records the provider-token trust-source decision and links the Step 1 decision record.
- `rg` sweeps found no production Step 2 rollup references to `provider_session`, `provider_handshake`, raw hello-frame identity sources, runtime `Origin` branching, runtime `Authorization` handling, production `token_hash` logging, rollup mutation of `partner_keys`, rollup mutation of `provider_visibility_audit`, or production Shape A/B SQL (`TRUNCATE`, `ALTER TABLE RENAME`, `DROP TABLE`).
- `go test ./internal/stats/rollup/... -count=1` from `phase4-coordinator/` - PASS.
- `go test ./internal/stats/rollup -run 'TestEmitDriftPayloadRedaction|TestClassifyPanic|TestConfigValidate|TestConfigDefaultsApplied' -count=1` - PASS.
- `go test ./internal/stats -run 'TestOpenMissingDSNFailClosed|TestPoolsCloseNilSafe' -count=1` - PASS.
- `go test -tags=integration -c ./internal/stats/` - PASS compile.
- `go test -tags=integration ./internal/stats -run 'TestRollupVisibilityDefaultTuple|TestRollupDriftFiresOnProviderDeletedByRebuild|TestRollupLateEventUpdatedAtCorrection|TestRollupIgnoresUnauthenticatedProviders|TestStatsRollupDeniedPartnerKeysAndVisibilityAudit' -count=1` - BLOCKED by local environment: testcontainers panicked with `rootless Docker not found`.
- `gofmt -l internal/stats/rollup/*.go` - clean.
- `git diff --check origin/main...HEAD` - FAIL only on pre-existing trailing whitespace in older Step 2 audit markdown files; no inspected implementation file or this r6 audit file is implicated.

## Category Verdicts

A. Role + pool isolation: PASS. Production still constructs the runner with `statsrollup.New(statsPools.Rollup, ...)` only (`phase4-coordinator/cmd/coordinator/main.go:185-256`), `stats.Open` keeps `stats_rollup` on write-pool sizing (`phase4-coordinator/internal/stats/stats.go:193-204`, `stats.go:264-270`), and grants still deny `stats_rollup` access to `partner_keys` and `provider_visibility_audit` (`phase4-coordinator/internal/stats/migrations/004_grants.up.sql:52-75`). The r6 delta uses only injected `db` handles already owned by the rollup runner.

B. Identity trust: PASS. Full recompute still joins `provider_tokens` for work, rewards, and visibility defaulting before materializing leaderboard provider IDs (`phase4-coordinator/internal/stats/rollup/leaderboard.go:261-400`). Incremental active-provider discovery and provider-scoped recompute still key through `provider_tokens` for both work and rewards (`phase4-coordinator/internal/stats/rollup/incremental.go:222-352`). The r6 late-event GREATEST fix preserves the `JOIN provider_tokens` gate before inserting `stats_late_events` (`phase4-coordinator/internal/stats/rollup/late_events.go:66-84`). PR #173 still documents the trust-source decision.

C. Bucket / projection invariant: PASS. Storage continues to write exact `earnings_usd`, `earnings_work_usd`, and `earnings_rewards_usd` plus storage-time `earnings_bucket`; it does not add a public-projection exact column or any Origin/key-conditional value (`phase4-coordinator/internal/stats/migrations/001_stats_tables.up.sql:39-133`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:492-523`, `phase4-coordinator/internal/stats/rollup/incremental.go:417-456`). The r6 visibility change left-joins `provider_visibility` through `provider_tokens` with COALESCE defaults and carries the tuple in-memory/test-facing only; it does not branch on `blocked_from_partner_projection` and does not widen public storage (`leaderboard.go:151-245`, `leaderboard.go:363-400`, `incremental.go:143-170`).

D. Drift + late events + AC-20: PASS. The r6 drift fix expands drift comparison to `pre union rebuilt` and still logs only bounded event/window/axis/provider sample/numeric fields (`phase4-coordinator/internal/stats/rollup/rebuild.go:138-231`); redaction tests passed. The late-event fix changes the arrival watermark to `GREATEST(created_at_utc, updated_at_utc)` while preserving authenticated identity and `stats_late_events`-only writes (`phase4-coordinator/internal/stats/rollup/late_events.go:58-97`). No rollup code path inserts `provider_visibility_audit`, and Step 1 AC-20 fixtures remain outside the rollup path.

E. Configuration safety: PASS. `usd_per_million_credits` remains non-negative (`phase4-coordinator/internal/config/config.go:1053-1055`, `phase4-coordinator/internal/stats/rollup/config.go:125-127`). `late_events_retention_days` defaults to 90, clamps `(0,30)` to 30 with a warning, and rejects negative values before runner construction (`phase4-coordinator/internal/config/config.go:1044-1051`, `phase4-coordinator/internal/stats/rollup/runner.go:50-63`). `backfill_mode` remains limited to `partial` or `full`, and drift threshold remains bounded (`phase4-coordinator/internal/config/config.go:1039-1058`, `phase4-coordinator/internal/stats/rollup/config.go:119-140`).

F. Provider-rewards-ledger handling: PASS. `provider_rewards_ledger` remains limited to the `rewards_populated` EXISTS probe and leaderboard rewards aggregation/active-provider discovery (`phase4-coordinator/internal/stats/rollup/rewards.go:43-55`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:312-354`, `phase4-coordinator/internal/stats/rollup/incremental.go:222-352`). No production rollup UPDATE or INSERT to `provider_rewards_ledger` appears.

G. Process isolation: PASS. Per-tick panic recovery still logs classified panic context only, updates only the affected component health row, and returns to that job's ticker loop (`phase4-coordinator/internal/stats/rollup/runner.go:136-211`). The goroutine-level backstop and nightly rebuild recovery also classify panic values without raw message payloads (`runner.go:150-160`, `runner.go:230-269`).

## Findings

None.

## Positive Security Observations

- The r6 visibility LEFT JOIN fix improves Step 2's proof of the `provider_visibility` default tuple while preserving the v0.1 rule that `blocked_from_partner_projection` is not consumed.
- The r6 drift union fix closes a defense-in-depth alerting blind spot for stale rows dropped by full recompute without adding any credential, Origin, DSN, or raw-token log fields.
- The r6 late-event GREATEST fix catches corrected old billing rows without weakening provider-token identity gating or changing the Step 3/4 public projection boundary.
- The new test seam is read-only and exposes deterministic rollup output to integration tests; it does not create a runtime HTTP, DB-role, or secret-handling surface.

## Final Verdict

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
INFO: 0

READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 6 meets the lock target.
