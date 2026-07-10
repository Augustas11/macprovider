# SPEC-017 IMPL Step 1 Security Audit r4

Audit target: branch `impl/spec-017-step-1`, diff `HEAD` (`00c5301`) against `origin/main` (`e816dff`), PR `Augustas11/macprovider#173`.

Required reading completed: `CLAUDE.md`; `BUILD_SPEC_017_IMPL_PROMPT.md` prereqs / critical constraints / Step 1; locked `SPEC-017-network-stats-api.md` v0.1.8 sections 1.5, 5.4.1, 6.1, 6.6.2, 7.2, 7.3; `SPEC-002-coordinator.md` line 3 + section 7 provider-token contract; `SPEC-005-billing.md` line 3 + sections 4.3-4.8; memory notes `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, and `deploy-gate-example-file-guard-invariant`; r1/r2/r3 security audits; Step 1 diff; PR body via `gh pr view 173 --repo Augustas11/macprovider --json body`.

## Per-Category Verdicts

- A. Role-grant scope: PASS. The runtime-role grant inventory remains inside the locked Step 1 boundary; no request-path OLTP grant, rollup partner-key/audit privilege, provider-portal stats/OLTP privilege, or default-on `partner_keys_writer` path was found.
- B. Operator CLI DSN handling: PASS. `partner_keys_admin_dsn` is optional and env-resolved, but coordinator startup does not instantiate a pool for it.
- C. DSN + secret handling: PASS. No production DSN literal or committed runtime-role password was found in the Step 1 implementation path; smoke/config errors name roles/checks without logging DSNs.
- D. Defense-in-depth for Steps 2/3/4: PASS. No raw token fixture was found; AC-20 is in the unconditional stats integration CI job.
- E. Provider-identity trust source: PASS. `stats_rollup` is granted SELECT on SPEC-002 `provider_tokens`, no unauthenticated provider-session/handshake grant exists, and the PR body now records the trust-source decision explicitly.
- F. Migration safety: PASS with INFO. Migrations are creation/grant-only and operator-side/admin-DSN only; OPS backup posture for the new Postgres tables remains a Step 4.C documentation gap.
- G. testcontainers + CI hygiene: PASS. Integration tests are build-tagged, use a digest-pinned Postgres image, and use the ephemeral mapped container port.

## Findings

### CRITICAL

None.

### HIGH

None.

### MEDIUM

None.

### LOW

None.

### INFO

1. `OPS.md:98`
   Evidence: OPS backup notes still cover `gateway.db`, but this audit found no `Postgres`, `pg_dump`, `SPEC-017`, `stats`, or `partner_keys` backup/runbook note in the visible OPS backup section.
   Why: category F.3 says Step 1 introduces tables containing partner-key hashes and backup posture should be surfaced as INFO unless OPS notes are missing. This is not a Step 1 code blocker, but Step 4.C should document that Postgres backups cover SPEC-017 tables, including `partner_keys`, before production partner-key issuance.
   Fix: add an OPS/runbook entry for SPEC-017 Postgres backup, restore, and retention expectations.

## Round-3 Closure Checks

- r3 HIGH fixed: `gh pr view 173 --repo Augustas11/macprovider --json body` now returns a PR body with an explicit "Provider-identity trust-source decision" section. It states that Step 1 grants `stats_rollup` SELECT on SPEC-002 v1.4 section 7 `provider_tokens`, forbids Step 2 joins on raw hello-frame payloads (`provider_session` / `provider_handshake`), and records the production cutover gate if authenticated rows are not available.
- r3 INFO retained: `OPS.md:98` still documents the gateway DB backup path only; partner-key-hash backup posture remains naturally scoped to Step 4.C.

## Positive Checks

- `stats_reader` grants are limited to the section 7.2.1 request-path set plus chosen `stats_rewards_populated` storage at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:27`; explicit denies on `stats_late_events`, `provider_rewards_ledger`, and `provider_visibility_audit` are at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:43`.
- `stats_reader` OLTP denial is defense-in-depth covered by `phase4-coordinator/internal/stats/migrations/005_oltp_source_grants.up.sql:50` and integration coverage at `phase4-coordinator/internal/stats/integration_test.go:209`.
- `stats_rollup` receives DML on the rollup-owned stats tables, SELECT on `provider_visibility` and `provider_rewards_ledger`, and only the `stats_late_events_id_seq` sequence grant at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:52`; no `TRUNCATE`, `ALTER`, or `DROP` grant is present.
- `stats_rollup` is explicitly denied `partner_keys` and `provider_visibility_audit` at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:75`, with integration coverage at `phase4-coordinator/internal/stats/integration_test.go:755`.
- `provider_portal` is limited to `provider_visibility` writes, `provider_visibility_audit` insert, and the audit sequence grant at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:86`; deny coverage for stats tables is tested at `phase4-coordinator/internal/stats/integration_test.go:720`.
- `partner_keys_writer` is not created by the role migration; `phase4-coordinator/internal/stats/migrations/003_roles.up.sql:8` documents the default-off v0.1 decision, and config defaults keep `Stats.Enabled=false` with no writer opt-in at `phase4-coordinator/internal/config/config.go:478`.
- Runtime role identities are created `NOLOGIN` with no password material at `phase4-coordinator/internal/stats/migrations/003_roles.up.sql:43`; `TestNoLoginRoleDefault` verifies that state at `phase4-coordinator/internal/stats/integration_test.go:682`.
- `partner_keys_admin_dsn` is declared at `phase4-coordinator/internal/config/config.go:69` and env-resolved at `phase4-coordinator/internal/config/config.go:564`, but startup opens only reader, rollup, portal, and optional writer pools at `phase4-coordinator/internal/stats/stats.go:178`.
- Coordinator boot no longer applies migrations through a runtime pool; `phase4-coordinator/cmd/coordinator/main.go:148` documents that migrations are operator-applied only, and `phase4-coordinator/internal/stats/migrations/migrations.go:127` requires a migration/admin-capable role.
- Startup smoke asserts expected `current_user`, positive probes, and deny probes while avoiding DSN text in errors at `phase4-coordinator/internal/stats/stats.go:296`.
- The Step 1 OLTP grant inventory names `provider_tokens` and the SPEC-005 ledger tables only at `phase4-coordinator/internal/stats/migrations/005_oltp_source_grants.up.sql:32`; no `provider_session` or `provider_handshake` grant was found.
- AC-20 runs in the unconditional `coordinator-stats-integration` job at `.github/workflows/ci.yml:167`; the SQL assertion for zero `actor_kind='operator' AND new_mode='exact'` rows is at `phase4-coordinator/internal/stats/integration_test.go:448`.
- testcontainers uses a digest-pinned Postgres image at `phase4-coordinator/internal/stats/integration_test.go:62` and obtains the ephemeral mapped port at `phase4-coordinator/internal/stats/integration_test.go:117`; the file is build-tagged with `//go:build integration` at `phase4-coordinator/internal/stats/integration_test.go:1`.

## Verification

- `cd phase4-coordinator && go test ./internal/stats/...` passed.
- `cd phase4-coordinator && go test ./internal/config -run 'TestLoadResolvesEnv|TestLoadFailsClosedOnEmptyEnv|TestProviderTokensRequiredByDefault|TestStats|Test.*Stats'` passed.
- `cd phase4-coordinator && go test -tags=integration -timeout 5m ./internal/stats/...` was attempted but could not run in this local environment: testcontainers panicked with `rootless Docker not found`. The Docker-backed suite remains build-tagged and wired to the unconditional CI job; this is a local validation gap, not a Step 1 code finding.

## Final Verdict

Ready to lock.

Counts: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW, 1 INFO.

`READY TO LOCK`: yes. Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
