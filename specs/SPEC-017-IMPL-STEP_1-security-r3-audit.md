# SPEC-017 IMPL Step 1 Security Audit r3

Audit target: branch `impl/spec-017-step-1`, diff `HEAD` (`21d3c2a215309439e71cada94c76921a59805304`) against `origin/main` (`e816dffb82cb08a9c8010a467498f9e6a1ac09f9`).

Required reading completed: `CLAUDE.md`; `BUILD_SPEC_017_IMPL_PROMPT.md` prereqs / critical constraints / Step 1; locked `SPEC-017-network-stats-api.md` v0.1.8 sections 1.5, 5.4.1, 6.1, 6.6.2, 7.2, 7.3; `SPEC-002-coordinator.md` line 3 + section 7 provider-token contract; `SPEC-005-billing.md` line 3 + sections 4.3-4.8; memory notes `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, and `deploy-gate-example-file-guard-invariant`; r1/r2 security audits; Step 1 diff.

## Per-Category Verdicts

- A. Role-grant scope: PASS. The runtime-role grants remain inside the locked Step 1 inventory; no request-path OLTP grant, partner-key writer role, or rollup partner-key/audit privilege was found.
- B. Operator CLI DSN handling: PASS. `partner_keys_admin_dsn` is env-resolved and optional, but coordinator startup does not open it.
- C. DSN + secret handling: PASS. No production DSN literal or committed runtime-role password was found in the Step 1 code path; config and smoke errors name roles/checks without printing DSNs.
- D. Defense-in-depth for Steps 2/3/4: PASS. No raw token fixture was found, and AC-20 is wired into the unconditional stats integration CI job.
- E. Provider-identity trust source: FAIL. The decision artifact now exists and matches SPEC-002, but the required PR-description record is still not visible/verifiable from this checkout.
- F. Migration safety: PASS with INFO. Migrations are operator-side/admin-DSN only, and no destructive Step 1 migration was found. OPS backup posture for the new Postgres tables remains undocumented.
- G. testcontainers + CI hygiene: PASS. Integration tests are build-tagged, use mapped ports, and pin Postgres by digest.

## Findings

### CRITICAL

None.

### HIGH

1. `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md:7`
   Evidence: the decision file says "the Step 1 PR description links it", but `gh pr list --head impl/spec-017-step-1 --json number,title,url,body,headRefName,baseRefName,state --limit 10` returned `[]`, and `gh pr view impl/spec-017-step-1 --json number,title,url,body,headRefName,baseRefName,state` reported `no pull requests found for branch "impl/spec-017-step-1"`. `git ls-remote --heads origin impl/spec-017-step-1` also returned no remote branch in this checkout.
   Why: category E.2 requires the PR description to record the provider-identity trust-source decision explicitly, with absence rated HIGH. The code-side artifact now correctly states that `stats_rollup` may read SPEC-002 `provider_tokens` and must not fall back to hello-frame identity, but the requested review-boundary PR record is not actually verifiable.
   Fix: push/open the PR for `impl/spec-017-step-1` and add the trust-source text or a direct link to `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md` in the PR body. The body should state: Step 1 grants `stats_rollup` SELECT on `provider_tokens`; Step 2 must not join raw hello-frame provider identity; public cutover is blocked or filtered if production provider IDs are not authenticated.

### MEDIUM

None.

### LOW

None.

### INFO

1. `OPS.md:98`
   Evidence: OPS backup notes cover `gateway.db` and coordinator config backups, but this audit found no `Postgres`, `pg_dump`, `SPEC-017`, `stats`, or `partner_keys` backup/runbook note.
   Why: category F.3 says Step 1 introduces tables containing partner-key hashes and backup posture should be surfaced as INFO unless OPS notes are missing. This is not a Step 1 code blocker, but it should be captured before Step 4 partner-key issuance.
   Fix: add an OPS/runbook note that Postgres backups cover SPEC-017 tables, including `partner_keys`, with restore/retention expectations.

## Round-2 Closure Checks

- r2 HIGH partially fixed: `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md:11` through `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md:21` records `provider_tokens` as the authenticated source and forbids fallback to unauthenticated identity. The remaining gap is PR-body visibility, not code-side trust-source selection.
- r2 INFO retained: `OPS.md:98` still only documents `gateway.db` backup coverage; Step 4.C remains the natural scope for the partner-key-hash backup runbook.

## Positive Checks

- `stats_reader` grants in `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:27` through `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:39` are limited to the section 7.2.1 request-path set plus chosen `stats_rewards_populated` storage.
- `stats_reader` denies on `stats_late_events`, `provider_rewards_ledger`, and `provider_visibility_audit` are explicit at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:43` through `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:47`; OLTP deny coverage is exercised in `phase4-coordinator/internal/stats/integration_test.go:209` through `phase4-coordinator/internal/stats/integration_test.go:250`.
- `stats_rollup` receives DML on the rollup-owned stats tables, SELECT on `provider_visibility` and `provider_rewards_ledger`, and sequence access only for `stats_late_events_id_seq` at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:52` through `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:72`; no TRUNCATE / ALTER / DROP grant is present.
- `stats_rollup` is denied `partner_keys` and `provider_visibility_audit` at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:75`, with integration coverage at `phase4-coordinator/internal/stats/integration_test.go:755` through `phase4-coordinator/internal/stats/integration_test.go:781`.
- `provider_portal` receives only visibility/audit writes and the audit sequence grant at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:84` through `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:89`; it is denied stats and partner-key tables at `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:93` through `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:106`.
- `partner_keys_writer` is not created in `phase4-coordinator/internal/stats/migrations/003_roles.up.sql`; startup only opens the optional writer pool when `LastUsedAtUpdatesEnabled` is true (`phase4-coordinator/internal/stats/stats.go:198`), and config only requires `writer_dsn` under that flag (`phase4-coordinator/internal/config/config.go:1008`).
- `partner_keys_admin_dsn` is not opened by `stats.Open`; `phase4-coordinator/internal/stats/stats.go:178`, `phase4-coordinator/internal/stats/stats.go:184`, and `phase4-coordinator/internal/stats/stats.go:191` open only reader, rollup, and portal pools by default.
- Startup smoke asserts the current Postgres user, positive grants, and deny probes without including DSNs in errors at `phase4-coordinator/internal/stats/stats.go:296` through `phase4-coordinator/internal/stats/stats.go:374`.
- AC-20 runs in the unconditional `coordinator-stats-integration` GitHub Actions job at `.github/workflows/ci.yml:167` through `.github/workflows/ci.yml:187`; the SQL assertion is `phase4-coordinator/internal/stats/integration_test.go:448` through `phase4-coordinator/internal/stats/integration_test.go:475`.
- testcontainers uses a digest-pinned image at `phase4-coordinator/internal/stats/integration_test.go:62` and the ephemeral mapped port via `MappedPort` at `phase4-coordinator/internal/stats/integration_test.go:117`.

## Verification

- `cd phase4-coordinator && go test ./internal/stats/...` passed.
- `cd phase4-coordinator && go test ./internal/config -run 'TestLoadResolvesEnv|TestLoadFailsClosedOnEmptyEnv|TestProviderTokensRequiredByDefault|TestStats'` passed.
- `cd phase4-coordinator && go test -tags=integration -timeout 5m ./internal/stats/...` was attempted but could not run in this local environment: testcontainers panicked with `rootless Docker not found`. The tests are still build-tagged and wired to the Docker-backed CI job; this is a local validation gap, not a Step 1 code finding.

## Final Verdict

Not ready to lock.

Counts: 0 CRITICAL, 1 HIGH, 0 MEDIUM, 0 LOW, 1 INFO.

`READY TO LOCK`: no. Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
