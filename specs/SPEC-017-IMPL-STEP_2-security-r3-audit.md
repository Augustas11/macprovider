# SPEC-017 IMPL Step 2 - SECURITY audit r3

Branch: `impl/spec-017-step-1` / PR #173
Diff audited: `b4993274bea617bcee494e77baf705abafc01b82..745128e210436ad73f3e846375a161dfb9e463b5`
Round-2 fix commit: `745128e`
Lens: role isolation, provider identity, secret handling, defense-in-depth, and Step 3/4 attack surfaces.

Required reading completed: `CLAUDE.md`; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` section 1 prereqs, section 5 critical constraints, section 2 Step 2; `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 1.5, 6.1, 6.4, 6.6.2, 6.6.3, 7.2, 7.3, plus section 9 rollup details where needed; `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`; `specs/SPEC-017-IMPL-STEP_2-security-r1-audit.md`; `specs/SPEC-017-IMPL-STEP_2-security-r2-audit.md`; memory notes `provider-auth-unauthenticated-end-to-end`, `audit-loop-catches-billing-ledger-drift`, and `c2-gate-gateway-credential-validation-asymmetry`; Step 2 diff through HEAD; PR #173 body via `gh pr view`.

Validation run:

- `git diff --name-status b4993274..HEAD` - Step 2 rollup package, coordinator/config wiring, and Step 2 audit artifacts identified.
- `git diff --name-status 134ddc4..HEAD` - round-2 fix scope identified.
- `rg` checks found no Step 2 rollup references to `provider_session`, `provider_handshake`, raw `provider_visibility_audit` mutation, raw `partner_keys` mutation, raw Origin-dependent rollup logic, or runtime token-hash logging.
- `go test ./internal/stats/rollup/...` from `phase4-coordinator/` - PASS.
- `go test -tags=integration -c ./internal/stats/` from `phase4-coordinator/` - PASS compile.
- `go test ./internal/stats -run 'TestOpenMissingDSNFailClosed|TestPoolsCloseNilSafe'` from `phase4-coordinator/` - PASS.
- `git diff --check origin/main...HEAD` - FAIL only on pre-existing trailing whitespace in Step 2 r1/r2 audit markdown files; no inspected code whitespace issue was found.

## Category Verdicts

A. Role + pool isolation: **PASS**. Production wiring still constructs the runner with `statsrollup.New(statsPools.Rollup, ...)` only (`phase4-coordinator/cmd/coordinator/main.go:250`), and `stats.Open` uses the write-pool tuning for `Rollup` (`phase4-coordinator/internal/stats/stats.go:199-204`). The grant inventory gives `stats_rollup` write grants only on rollup-owned tables plus SELECT on `provider_visibility` and `provider_rewards_ledger`, and explicitly revokes `partner_keys` and `provider_visibility_audit` (`phase4-coordinator/internal/stats/migrations/004_grants.up.sql:52-75`).

B. Identity trust: **PASS**. Overview, timeseries, work aggregation, rewards aggregation, and late-event scans all join `provider_tokens` before materializing provider IDs (`phase4-coordinator/internal/stats/rollup/overview.go:120-124`, `timeseries.go:32-36`, `timeseries.go:117-121`, `leaderboard.go:241-247`, `leaderboard.go:284-288`, `late_events.go:64-69`, `late_events.go:86-90`). The r1 rewards-only bypass remains covered by `TestRollupRewardsOnlyUnauthenticatedRejected` (`phase4-coordinator/internal/stats/rollup_integration_test.go:730-763`). PR #173 still records the trust-source decision and links `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.

C. Bucket / projection invariant: **PASS**. Rollup storage still writes exact values into `earnings_usd`, `earnings_work_usd`, and `earnings_rewards_usd`, with only `earnings_bucket` as the storage-time bucket (`phase4-coordinator/internal/stats/rollup/leaderboard.go:433-457`). Bucket thresholds match the locked section 6.2 values and half-open boundary semantics (`phase4-coordinator/internal/stats/rollup/bucket.go:17-42`, `bucket.go:53-77`). The r2 HIGH on `blocked_from_partner_projection` is fixed behaviorally: the rollup intentionally does not branch on `.Blocked` (`leaderboard.go:168-180`), and `TestRollupBlockedProviderStillAppearsInV01` pins that a blocked-stub row still appears in v0.1 storage (`phase4-coordinator/internal/stats/rollup_integration_test.go:829-863`).

D. Drift + late events + AC-20: **PASS**. Drift logs carry bounded numeric fields plus a `provider_id_sample`; no DSN, token, token hash, partner-key prefix, or Origin string is included by that path (`phase4-coordinator/internal/stats/rollup/rebuild.go:186-195`), with regression coverage in `TestEmitDriftPayloadRedaction` (`phase4-coordinator/internal/stats/rollup/rebuild_test.go:62-86`). Late-event detection writes only `stats_late_events`, joins `provider_tokens`, and serializes concurrent 30d/all scans with a Postgres advisory lock (`phase4-coordinator/internal/stats/rollup/late_events.go:10-22`, `late_events.go:42-99`). Step 2 still does not insert any `provider_visibility_audit` rows.

E. Configuration safety: **PASS**. Backfill mode is limited to `partial` / `full`, and `partial` now fails closed when `partial_history_since` is empty or unparsable (`phase4-coordinator/cmd/coordinator/main.go:206-236`). Retention values in `(0, 30)` clamp to 30 with a warning, default is 90, and validation rejects negative values (`phase4-coordinator/internal/stats/rollup/runner.go:50-63`, `phase4-coordinator/internal/config/config.go:1044-1055`). Drift threshold is bounded to `[0.001, 0.05]` (`phase4-coordinator/internal/config/config.go:1056-1058`, `phase4-coordinator/internal/stats/rollup/config.go:128-130`). The r2 MEDIUM on `usd_per_million_credits` is closed for the security lane: the author has intentionally kept `1.0` as an explicit, tested operator-tunable default (`phase4-coordinator/internal/config/config.go:502-510`, `phase4-coordinator/internal/stats/rollup/config_test.go:12-18`), and the code still rejects negative values (`phase4-coordinator/internal/stats/rollup/config.go:125-127`). That default can affect operator accounting correctness if misconfigured, but it does not weaken role isolation, identity trust, secret handling, same-origin uniformity, or bucket/default-public-redaction security.

F. Provider-rewards-ledger handling: **PASS**. `provider_rewards_ledger` is used only for the rewards-populated EXISTS probe, rewards aggregation, and late-event rewards scan (`phase4-coordinator/internal/stats/rollup/rewards.go:47-54`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:280-289`, `phase4-coordinator/internal/stats/rollup/late_events.go:80-97`). No Step 2 UPDATE or INSERT to `provider_rewards_ledger` appears.

G. Process isolation: **PASS**. Per-tick recovery catches panics, logs only a redacted type classification, updates the affected component health row, and returns control to that job's ticker (`phase4-coordinator/internal/stats/rollup/runner.go:173-203`). The r2 panic-payload gap is fixed by type-only `classifyPanic` (`runner.go:205-220`) and covered by `TestClassifyPanic` with DSN/token-like payloads (`phase4-coordinator/internal/stats/rollup/rebuild_test.go:89-113`). Goroutine-level recovery remains as a backstop and does not crash the coordinator (`runner.go:142-152`).

## Findings

### LOW 1 - Stale leaderboard comments still describe the removed blocked-provider exclusion behavior

Evidence:

- The file header still says the provider-visibility left join skips rows when `blocked_from_partner_projection = TRUE` (`phase4-coordinator/internal/stats/rollup/leaderboard.go:31-41`).
- The `computeLeaderboardRows` comment repeats that blocked providers are excluded and that the stub becomes load-bearing when SPEC-014 v0.9 starts writing it (`phase4-coordinator/internal/stats/rollup/leaderboard.go:132-140`).
- The executable code below those comments explicitly does not branch on `.Blocked` (`phase4-coordinator/internal/stats/rollup/leaderboard.go:168-180`), and the integration test asserts the v0.1 behavior (`phase4-coordinator/internal/stats/rollup_integration_test.go:829-863`).

Risk:

This is not a current storage or projection bug, so it is not HIGH. It is comment drift that could mislead a Step 3/4 or v0.2 modifier into reintroducing the r2 HIGH behavior.

Recommended fix:

Update the two comments to state the current v0.1 contract: rollup may load the stub column for left-join/default coverage, but must not branch on it until a SPEC v0.2 decision defines partner-projection suppression semantics.

## Positive Security Observations

- The r1 CRITICAL provider-identity bypass remains closed for both work and rewards paths.
- The r2 HIGH blocked-stub branch is fixed behaviorally and locked by a regression test.
- The r2 panic-redaction finding is closed with type-only panic classification and a secret-shaped payload regression test.
- Same-origin uniformity is preserved: Step 2 rollup code does not inspect Origin, partner key state, or per-key inputs when computing storage values.
- Shape C rebuild uses DELETE+INSERT under the locked `stats_rollup` grant set, avoiding TRUNCATE/ALTER/DROP privilege widening.

## Final Verdict

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 1
INFO: 0

**READY TO LOCK.**

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 3 meets the lock target. The one LOW finding is documentation drift only; it should be cleaned before or alongside Step 3/4 work but does not block the Step 2 security lock.
