# SPEC-017 IMPL Step 1 Security Audit r1

Audit target: branch `impl/spec-017-step-1`, diff `HEAD` against `origin/main`.

Required reading completed: `CLAUDE.md`; `BUILD_SPEC_017_IMPL_PROMPT.md` Step 1 / critical constraints / prereqs; locked `SPEC-017-network-stats-api.md` v0.1.8 §1.5, §5.4.1, §6.1, §6.6.2, §7.2, §7.3; `SPEC-002-coordinator.md` line 3 + §7 provider-token contract; `SPEC-005-billing.md` line 3 + §4.3-§4.8; memory notes `provider-auth-unauthenticated-end-to-end`, `c2-gate-gateway-credential-validation-asymmetry`, and `deploy-gate-example-file-guard-invariant`.

## Per-Category Verdicts

- A. Role-grant scope: FAIL. The role grant inventory is mostly aligned, but the role migration commits fixed runtime-role passwords.
- B. Operator CLI DSN handling: PASS. `partner_keys_admin_dsn` is declared but not opened at coordinator startup.
- C. DSN + secret handling: FAIL. Fixed Postgres passwords are committed, and new stats DSN fields are not reachable through the existing env indirection resolver.
- D. Defense-in-depth for Steps 2/3/4: PASS. Fixtures avoid raw tokens and AC-20 is wired into PR CI.
- E. Provider-identity trust source: FAIL. Code-side `provider_tokens` grant is present, but no PR metadata is visible to satisfy the required trust-source decision record.
- F. Migration safety: FAIL. Coordinator startup applies migrations through the `stats_rollup` runtime pool by default.
- G. testcontainers + CI hygiene: FAIL. Integration tests are tagged and use mapped ports, but the Postgres image is not digest-pinned.

## Findings

### CRITICAL

1. `phase4-coordinator/internal/stats/migrations/003_roles.up.sql:31`
   Evidence: lines 31-41 create `stats_reader`, `stats_rollup`, and `provider_portal` as `LOGIN PASSWORD '__set_at_deploy__'` roles.
   Why: the audit severity model treats a Postgres password committed to the repo as CRITICAL. Even if named as a placeholder, this is a valid fixed password in the migration. If an operator applies the migration before rotating the roles, the runtime roles are remotely guessable with repo-known credentials.
   Fix: do not commit usable password literals. Create roles without password login material, or require operator-provisioned roles/passwords outside the embedded migration. If the migration must create identities, use `NOLOGIN` or no password and have deploy automation perform `ALTER ROLE ... LOGIN PASSWORD ...` from the secret store before enabling `stats.enabled`.

2. `phase4-coordinator/cmd/coordinator/main.go:157`
   Evidence: when `stats.enabled=true`, startup calls `statsmigrations.Apply(context.Background(), statsPools.Rollup)` unless `STATS_SKIP_MIGRATIONS_AT_BOOT=1` is set.
   Why: the audit prompt marks using `stats_rollup_dsn` to apply DDL as CRITICAL. `stats_rollup` is one of the runtime roles with only the locked §7.2.2 grant set; it must not be the migration superuser. Making the safe path depend on an opt-out env var also creates a default-on production footgun.
   Fix: remove boot-time migration application from the coordinator runtime path, or require a separate migration/admin DSN that is never stored in the runtime pools. Production-safe behavior should be the default; local/dev migrations can use an explicit development command or explicit admin DSN.

### HIGH

1. GitHub PR metadata for branch `impl/spec-017-step-1`
   Evidence: `gh pr list --head impl/spec-017-step-1 --json number,title,url,body` returned `[]`, and `gh pr view` reported `no pull requests found for branch "impl/spec-017-step-1"`. Code-side comment in `phase4-coordinator/internal/stats/migrations/005_oltp_source_grants.up.sql:8` records `provider_tokens` as the authenticated source, but the required PR-description record is absent/not visible.
   Why: category E.2 requires the PR description to record the trust-source decision explicitly, with absence rated HIGH. The memory note `provider-auth-unauthenticated-end-to-end` warns that live beta provider identity has historically been attacker-controlled when `require_provider_tokens=false`; this decision must be visible at the review boundary, not only buried in SQL comments.
   Fix: create/update the PR description with the explicit trust-source decision: Step 1 grants `stats_rollup` SELECT on `provider_tokens` as the authenticated source, Step 2 must not join raw hello-frame provider identity, and public cutover remains blocked/gated if production provider IDs are unauthenticated.

### MEDIUM

1. `phase4-coordinator/internal/config/config.go:541`
   Evidence: `resolveEnv()` resolves only `auth.operator_key` and `auth.gateway_service_token` through `resolveEnvValue`; the new stats DSN fields declared at lines 60-72 are never passed through that resolver. Validation at lines 978-988 only checks non-empty strings, so `env:STATS_READER_DSN` is accepted as a literal non-empty DSN until connection smoke fails.
   Why: category C.2 requires DSN config fields to be reachable via the existing env override pattern. Operators should inject DSNs at deploy time, not put plaintext DSNs into `coordinator.yaml`.
   Fix: resolve `stats.reader_dsn`, `stats.rollup_dsn`, `stats.provider_portal_dsn`, `stats.partner_keys.writer_dsn`, and `stats.partner_keys_admin_dsn` with `resolveEnvValue`, and add config-loader tests proving `env:NAME` works and fails closed on unset/empty env vars.

2. `phase4-coordinator/internal/stats/integration_test.go:60`
   Evidence: the test image is `postgres:16.4-alpine3.20`, while the adjacent comment at lines 56-59 claims a digest-pinned image.
   Why: category G.1 requires a pinned Postgres image digest SHA, not a mutable tag. This is not `:latest`, so it is not the category's CRITICAL case, but it still fails the stated hygiene requirement.
   Fix: pin the image as `postgres:16.4-alpine3.20@sha256:<digest>` and keep the comment in sync.

### LOW

None.

### INFO

1. `OPS.md:98`
   Evidence: OPS backup references cover `gateway.db` and config backup paths, but this audit found no operator note for Postgres/`pg_dump` coverage of the new `partner_keys` table.
   Why: category F.3 says backup posture for tables containing partner-key hashes should be surfaced as INFO unless OPS notes are missing. This is not a Step 1 code blocker, but Step 4/ops convergence should document it before partner-key issuance.
   Fix: add an OPS/runbook note that Postgres backups cover SPEC-017 tables, including `partner_keys`, and document restore/retention expectations.

## Positive Checks

- `stats_reader` grant list in `004_grants.up.sql:19` matches the §7.2.1 request-path set plus `stats_rewards_populated`.
- `stats_reader` explicit denies on `stats_late_events`, `provider_rewards_ledger`, and `provider_visibility_audit` are present at `004_grants.up.sql:35`.
- `stats_rollup` has no `TRUNCATE`, `ALTER`, or `DROP` grant and explicitly revokes `partner_keys` plus `provider_visibility_audit` at `004_grants.up.sql:67`.
- `partner_keys_writer` is not created in the role migration; `003_roles.up.sql:8` documents the default-off v0.1 decision.
- `partner_keys_admin_dsn` is passed through config but not opened by `stats.Open`; `stats.go:178` opens only reader, rollup, portal, and optionally writer pools.
- AC-20 runs under the unconditional `coordinator-stats-integration` PR job at `.github/workflows/ci.yml:158`, and the SQL assertion is in `integration_test.go:443`.
- testcontainers uses an ephemeral mapped port via `MappedPort` at `integration_test.go:115`; no fixed host port binding was found.
- Integration tests are build-tagged with `//go:build integration` at `integration_test.go:1`.

## Final Verdict

Not ready to lock.

Counts: 2 CRITICAL, 1 HIGH, 2 MEDIUM, 0 LOW, 1 INFO.

`READY TO LOCK`: no. Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.
