# SPEC-017 IMPL Step 1 Security Audit r2

Audit target: branch `impl/spec-017-step-1`, diff `HEAD` (`0b3e87b6db509d3e927e1471f8ef5e0c9fb25bc2`) against `origin/main` (`e816dffb82cb08a9c8010a467498f9e6a1ac09f9`).

Required reading completed: `CLAUDE.md`; `BUILD_SPEC_017_IMPL_PROMPT.md` prereqs / critical constraints / Step 1; locked `SPEC-017-network-stats-api.md` v0.1.8 sections 1.5, 5.4.1, 6.1, 6.6.2, 7.2, 7.3; `SPEC-002-coordinator.md` line 3 + section 7 provider-token contract; `SPEC-005-billing.md` line 3 + sections 4.3-4.8; memory notes `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, and `deploy-gate-example-file-guard-invariant`; r1 security audit; Step 1 diff.

## Per-Category Verdicts

- A. Role-grant scope: PASS. The runtime-role grant set matches the Step 1 security boundary; no request-path OLTP exposure or partner-key writer default-on path was found.
- B. Operator CLI DSN handling: PASS. `partner_keys_admin_dsn` is declared and env-resolved, but coordinator startup does not open it.
- C. DSN + secret handling: PASS. Stats DSNs are env-resolved, not logged by config/startup paths, and smoke errors identify role/check without printing DSNs.
- D. Defense-in-depth for Steps 2/3/4: PASS. No raw token fixture was found; AC-20 is in the unconditional stats integration CI job.
- E. Provider-identity trust source: FAIL. The code-side `provider_tokens` grant is present, but the promised trust-source decision artifact / PR record is absent in this checkout.
- F. Migration safety: PASS with INFO. Boot-time runtime-role migrations are removed; no destructive Step 1 migration was found. OPS backup posture for the new Postgres tables remains undocumented.
- G. testcontainers + CI hygiene: PASS. Integration tests are build-tagged, use mapped ports, and pin the Postgres image by digest.

## Findings

### CRITICAL

None.

### HIGH

1. `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md:1`
   Evidence: the user named this as the trust-source decision record, but the file is absent from the worktree and `git ls-files`; `find /Users/augstar/macprovider-spec017-step1 -name '*trust*source*' -o -name '*SPEC-017*decision*' -o -name '*STEP_1*trust*'` returned no matches. `gh pr list --head impl/spec-017-step-1 --json number,title,url,body,headRefName,baseRefName,state` returned `[]`, so no PR description record is visible either. The only in-diff record is the SQL comment at `phase4-coordinator/internal/stats/migrations/005_oltp_source_grants.up.sql:8` naming `provider_tokens` as the authenticated identity source.
   Why: category E.2 requires the PR description to record the trust-source decision explicitly. The r1 HIGH finding asked for that record because `provider-auth-unauthenticated-end-to-end` warns that hello-frame provider identity was historically attacker-controlled when provider tokens were not enforced. A SQL comment documents the grant intent, but it is not the required review-boundary decision artifact and does not state the Step 2/production cutover gate.
   Fix: add the missing decision record at `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md` or update the PR description, then include the explicit decision: Step 1 grants `stats_rollup` SELECT on `provider_tokens` as the authenticated source; Step 2 must not join raw hello-frame provider identity; public cutover is blocked or filtered if production provider IDs are not authenticated.

### MEDIUM

None.

### LOW

None.

### INFO

1. `OPS.md:98`
   Evidence: OPS backup notes cover `gateway.db` and coordinator config backup paths, but no `Postgres`, `pg_dump`, `SPEC-017`, `stats`, or `partner_keys` backup/runbook entry was found.
   Why: category F.3 says Step 1 introduces tables containing partner-key hashes and backup posture should be surfaced as INFO unless OPS notes are missing. This is not a Step 1 code blocker, but it should be captured before Step 4 partner-key issuance.
   Fix: add an OPS/runbook note that Postgres backups cover SPEC-017 tables, including `partner_keys`, with restore/retention expectations.

## Round-1 Closure Checks

- r1 CRITICAL fixed: `003_roles.up.sql:43` creates `stats_reader`, `stats_rollup`, and `provider_portal` as `NOLOGIN`; no `CREATE ROLE ... PASSWORD` literal remains in the migration. `integration_test.go:682` verifies the default `rolcanlogin=false` state before test-only rotation.
- r1 CRITICAL fixed: `cmd/coordinator/main.go:143` opens/smokes runtime pools only; `main.go:148` documents that migrations are no longer run at coordinator boot. `migrations.go:127` requires an admin/migration-capable caller and states runtime roles are not migration-capable.
- r1 HIGH still open: no PR metadata or promised trust-source decision file is visible. See HIGH finding above.
- r1 MEDIUM fixed in code: `config.go:560` through `config.go:564` resolve `stats.reader_dsn`, `stats.rollup_dsn`, `stats.provider_portal_dsn`, `stats.partner_keys.writer_dsn`, and `stats.partner_keys_admin_dsn` through the existing `env:` resolver.
- r1 MEDIUM fixed: `integration_test.go:62` pins Postgres as `postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c`.

## Positive Checks

- `stats_reader` grants in `004_grants.up.sql:27` through `004_grants.up.sql:39` are limited to the section 7.2.1 request-path set plus chosen `stats_rewards_populated` storage.
- `stats_reader` explicit denies on `stats_late_events`, `provider_rewards_ledger`, and `provider_visibility_audit` are present at `004_grants.up.sql:43` through `004_grants.up.sql:47`; OLTP deny coverage is exercised in `integration_test.go:209` through `integration_test.go:250`.
- `stats_rollup` receives DML on the rollup-owned stats tables, SELECT on `provider_visibility` and `provider_rewards_ledger`, and sequence access only for `stats_late_events_id_seq` at `004_grants.up.sql:52` through `004_grants.up.sql:72`; no TRUNCATE / ALTER / DROP grant is present.
- `stats_rollup` is explicitly denied `partner_keys` and `provider_visibility_audit` at `004_grants.up.sql:75`, with integration coverage at `integration_test.go:755` through `integration_test.go:781`.
- `provider_portal` receives only visibility/audit writes and the audit sequence grant at `004_grants.up.sql:84` through `004_grants.up.sql:89`; it is denied stats and partner-key tables at `004_grants.up.sql:93` through `004_grants.up.sql:106`, with integration coverage at `integration_test.go:720` through `integration_test.go:749`.
- `partner_keys_writer` is not created in `003_roles.up.sql`; startup only opens the optional writer pool when `LastUsedAtUpdatesEnabled` is true (`stats.go:198`), and config only requires `writer_dsn` under that flag (`config.go:1008`).
- `partner_keys_admin_dsn` is not opened by `stats.Open`; `stats.go:178`, `stats.go:184`, and `stats.go:191` open only reader, rollup, and portal pools by default.
- AC-20 runs in the unconditional `coordinator-stats-integration` GitHub Actions job at `.github/workflows/ci.yml:167` through `.github/workflows/ci.yml:187`; the SQL assertion is `integration_test.go:448` through `integration_test.go:475`.
- testcontainers uses the ephemeral mapped port via `MappedPort` at `integration_test.go:117`; no fixed host port binding was found.

## Verification

- `cd phase4-coordinator && go test ./internal/stats/...` passed.
- `cd phase4-coordinator && go test ./internal/config -run 'TestLoadResolvesEnv|TestLoadFailsClosedOnEmptyEnv|TestProviderTokensRequiredByDefault'` passed.
- Docker-backed `go test -tags=integration ./internal/stats/...` was not run in this audit round; the integration tests and CI wiring were inspected statically.

## Final Verdict

Not ready to lock.

Counts: 0 CRITICAL, 1 HIGH, 0 MEDIUM, 0 LOW, 1 INFO.

`READY TO LOCK`: no. Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
