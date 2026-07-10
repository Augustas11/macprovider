# SPEC-017 IMPL Step 2 — SECURITY audit r2

Branch: `impl/spec-017-step-1` / PR #173
Diff audited: `b4993274bea617bcee494e77baf705abafc01b82..134ddc448b2296f0b6370942a3649b55fb26669d`
Round-1 fix commit: `134ddc4`
Lens: role isolation, provider identity, secret handling, defense-in-depth, and Step 3/4 attack surfaces.

Required reading completed: `CLAUDE.md`; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` §1, §5, §2 Step 2; `specs/SPEC-017-network-stats-api.md` v0.1.8 §1.5, §6.1, §6.4, §6.6.2, §6.6.3, §7.2, §7.3, plus §9 rollup details where needed; `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`; `specs/SPEC-017-IMPL-STEP_2-security-r1-audit.md`; memory notes `provider-auth-unauthenticated-end-to-end`, `audit-loop-catches-billing-ledger-drift`, and `c2-gate-gateway-credential-validation-asymmetry`; Step 2 diff through HEAD; PR #173 body via `gh pr view`.

Validation run:

- `git diff --name-status 134ddc4^..HEAD` — round-1 fix scope identified.
- `rg` checks found no Step 2 rollup references to `provider_session`, `provider_handshake`, raw `provider_visibility_audit` mutation, raw `token_hash`, or Origin-dependent rollup logic.
- `go test ./internal/stats/rollup/...` from `phase4-coordinator/` — PASS.
- `go test -tags=integration -c ./internal/stats/` from `phase4-coordinator/` — PASS compile.
- `go test ./internal/stats -run 'TestOpenMissingDSNFailClosed|TestPoolsCloseNilSafe'` from `phase4-coordinator/` — PASS.
- `git diff --check origin/main...HEAD` — FAIL only on pre-existing trailing whitespace in the three round-1 Step 2 audit markdown files; no code whitespace issue was found in the inspected Step 2 implementation.

## Category Verdicts

A. Role + pool isolation: **PASS**. Production wiring still calls `statsrollup.New(statsPools.Rollup, ...)` only (`phase4-coordinator/cmd/coordinator/main.go:245`), `stats.Open` uses the write-pool tune for rollup (`phase4-coordinator/internal/stats/stats.go:199-204`, `264-270`), and smoke keeps `stats_rollup` denied on `partner_keys` (`phase4-coordinator/internal/stats/stats.go:330-335`). No Step 2 rollup code attempts to mutate `partner_keys` or `provider_visibility_audit`.

B. Identity trust: **PASS**. Work, rewards, overview, timeseries, and late-event provider identity all join `provider_tokens` before materializing provider IDs. The r1 CRITICAL rewards-only bypass is fixed by `aggregateRewardsPerProvider` (`phase4-coordinator/internal/stats/rollup/leaderboard.go:277-286`) and covered by `TestRollupRewardsOnlyUnauthenticatedRejected` (`phase4-coordinator/internal/stats/rollup_integration_test.go:642-675`). PR #173 still records the trust-source decision and links the Step 1 decision record.

C. Bucket / projection invariant: **FAIL — HIGH**. Exact storage columns remain correct and bucket computation remains storage-time, but Step 2 now consumes the v0.1 `blocked_from_partner_projection` stub and drops providers from leaderboard storage before SPEC v0.2 defines that semantic.

D. Drift + late events + AC-20: **PASS**. Drift logs carry window/axis/provider sample/ratios only (`phase4-coordinator/internal/stats/rollup/rebuild.go:174-183`), late-event detection writes only `stats_late_events` and joins `provider_tokens` (`phase4-coordinator/internal/stats/rollup/late_events.go:38-77`), and Step 2 still does not insert `provider_visibility_audit` rows.

E. Configuration safety: **FAIL — MEDIUM**. `stats.rollup.usd_per_million_credits` is non-negative, but the runtime defaults a missing value to `1.0` instead of failing closed as this audit prompt requires.

F. Provider-rewards-ledger handling: **PASS**. `provider_rewards_ledger` is used for `rewards_populated` EXISTS probes and rewards/late-event aggregation only (`phase4-coordinator/internal/stats/rollup/rewards.go:47-54`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:277-286`, `phase4-coordinator/internal/stats/rollup/late_events.go:60-77`). No UPDATE or INSERT to `provider_rewards_ledger` appears in Step 2.

G. Process isolation: **FAIL — MEDIUM**. Per-tick recovery now continues the job after a panic, closing r1 MEDIUM 1. Panic redaction is still incomplete because error-like panic values include a raw truncated error string in logs and health rows.

## Findings

### HIGH 1 — Rollup consumes the v0.1 `blocked_from_partner_projection` stub and creates an unspecified Step 3/4 suppression control

Evidence:

- SPEC-017 §6.1 says `blocked_from_partner_projection` is a v0.1 column stub, the v0.1 rollup does not consume it, and v0.1 implementations must not branch on it.
- SPEC-017 §6.6.2 says partner-key projection surfaces exact `$` for all providers, including bucketed providers, and repeats that providers have no v0.1 wire mechanism to suppress partner-key exposure.
- BUILD §6 explicitly defers Q11 and says: "The `provider_visibility.blocked_from_partner_projection BOOLEAN` column stub is created in Step 1, but the v0.1 rollup does NOT consume it... Do NOT branch on the column in v0.1."
- Step 2 now loads `blocked_from_partner_projection` from `provider_visibility` (`phase4-coordinator/internal/stats/rollup/leaderboard.go:314-333`) and skips any provider where `v.Blocked` is true (`phase4-coordinator/internal/stats/rollup/leaderboard.go:168-177`).
- The new regression test locks the contrary behavior: a blocked provider is excluded from `stats_leaderboard_24h` (`phase4-coordinator/internal/stats/rollup_integration_test.go:733-772`).

Why this is HIGH:

This is not an immediate exact-dollar leak, so I am not rating it CRITICAL. It is a defense-in-depth breach that Step 2 makes available to Step 3/4: an as-yet-unspecified v0.2 portal/write-path flag can now suppress a provider from both public and partner leaderboard storage. The current `provider_portal` grant is broad enough to UPDATE `provider_visibility` (`phase4-coordinator/internal/stats/migrations/004_grants.up.sql:118`), and Step 2 turns the deferred stub into live projection behavior before the SPEC defines who may set it and what the partner response should be.

Required fix:

Remove the `Blocked` branch from the v0.1 rollup. Keep the §6.1 default semantics for `mode`/absence if needed, but do not let `blocked_from_partner_projection` alter leaderboard storage until a SPEC v0.2 decision defines the partner-projection behavior. Replace `TestRollupBlockedProviderExcluded` with a test asserting that a row with `blocked_from_partner_projection = TRUE` is ignored by v0.1 rollup behavior and still appears in storage.

### MEDIUM 1 — `usd_per_million_credits` does not fail closed when omitted

Evidence:

- The audit prompt requires `stats.rollup.usd_per_million_credits` to be non-negative and fail-closed on missing.
- The config default seeds `UsdPerMillionCredits: 1.0` (`phase4-coordinator/internal/config/config.go:502-508`).
- The rollup defaults any zero value to `1.0` (`phase4-coordinator/internal/stats/rollup/config.go:70-72`) and only rejects negative values (`phase4-coordinator/internal/stats/rollup/config.go:125-127`).
- The unit test locks the default behavior (`phase4-coordinator/internal/stats/rollup/config_test.go:15-16`).

Risk:

If an operator enables stats without explicitly setting the conversion factor, Step 2 computes exact storage dollars and public buckets using a silent default. That can misbucket providers and feed wrong exact-dollar values to the Step 3 partner projection. This is a configuration safety gap, not a direct credential or role-isolation break.

Required fix:

Represent the YAML field as explicitly set vs omitted, or move defaulting outside the production `stats.enabled=true` path. Add a config/startup test where `stats.enabled=true` and `stats.rollup.usd_per_million_credits` is omitted; startup should fail with a field-specific error. Keep the non-negative validation for explicitly supplied values.

### MEDIUM 2 — Panic redaction still includes raw error-message content

Evidence:

- r1 MEDIUM 2 required replacing raw panic serialization with a bounded redacted classification.
- `classifyPanic` now includes the panic value's concrete type, but for `error` panic values it appends up to 64 bytes of `err.Error()` (`phase4-coordinator/internal/stats/rollup/runner.go:210-220`).
- `runOne` writes that classification to structured logs and to `stats_components_health.last_error_message` as `"panic: "+class` (`phase4-coordinator/internal/stats/rollup/runner.go:180-190`).

Risk:

The current rollup code should not handle raw partner tokens or DSNs directly, so I am not rating this as an immediate leak. It still fails the redacted-context standard: a future lower-layer panic containing a DSN, token, token hash, Origin, or partner-key prefix would persist the first 64 bytes into logs and the database health row.

Required fix:

Make panic classification type-only or use a fixed message such as `panic: recovered` plus a non-secret class code. Add a unit test that panics with an error containing a fake DSN and token-like string and asserts neither appears in logs nor `stats_components_health.last_error_message`.

## Positive Security Observations

- The r1 CRITICAL trust-source bypass is closed: rewards-only rows now join `provider_tokens`, and the regression fixture proves unauthenticated rewards cannot enter the leaderboard.
- Rollup pool isolation remains correct in live coordinator wiring and in startup smoke.
- No Step 2 code path attempts to insert into `provider_visibility_audit`, preserving AC-20 ownership.
- Drift detection logs pseudonymizable `provider_id_sample` and numeric drift values only; no DSN, token, token hash, partner-key prefix, or Origin appears in that path.
- Same-origin uniformity is preserved in Step 2: the rollup does not inspect `Origin` or partner-key inputs when computing storage values.

## Final Verdict

CRITICAL: 0
HIGH: 1
MEDIUM: 2
LOW: 0
INFO: 0

**NOT READY TO LOCK.**

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM. The `blocked_from_partner_projection` branch must be removed or SPEC-bumped before Step 2 can lock, and the two configuration/log-redaction hardening issues should be fixed in the same round.
