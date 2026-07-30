# AUDIT_SPEC_017_IMPL_STEP_1 — Security lane

Operator-paste prompt to audit the **Step 1 IMPL code** under PR
`impl/spec-017-step-1`, from the SECURITY lens.

Audit target is the Step 1 implementation diff. SPEC-017 v0.1.8 is
LOCKED. The Step 1 attack surface is narrow (schema + DB roles +
DSN wiring; no public HTTP endpoints yet), but it is the
FOUNDATION for the public partner-facing surface that Steps 2/3/4
build on. A grant set that leaks a row in Step 1 is leaking
forever.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_1-security-rM-audit.md` (fresh per round).

---

```
=== BEGIN PROMPT ===

You are auditing the Step 1 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` from the SECURITY lens — role isolation,
grant scope, secret handling, defense-in-depth, attack surfaces
that Step 1 makes available to Steps 2/3/4.

Output: specs/SPEC-017-IMPL-STEP_1-security-rM-audit.md (round
M; fresh file per round).

Severity model:
- CRITICAL — a grant that surfaces exact $ to the public-projection
  request-path role, a grant that surfaces raw token bytes to any
  role other than the CLI operator, a DSN logged in plaintext, a
  Postgres password committed to the repo, a default-on
  `partner_keys_writer` role that runs without operator opt-in, a
  config-default that turns off fail-closed startup smoke.
- HIGH — defense-in-depth gap that wouldn't immediately leak but
  would let a Step 2/3/4 bug escalate (e.g. `stats_reader` granted
  SELECT on a table it doesn't currently read but Step 2 will
  reach for; DSN exposed in process env that downstream code
  could log; a connection pool sharing TLS config with an
  attacker-reachable surface).
- MEDIUM — hardening that two conforming sessions would resolve
  the same way once flagged.
- LOW — polish.
- INFO — observations.

## Critical constraints

1. The locked §7.2 grant inventory is the load-bearing isolation
   boundary. Step 1 is the FIRST place this boundary is encoded
   in code; every later step relies on it. Drift is CRITICAL.
2. SPEC §1.5 C2 + §6.1 pin "bucketed by default" for public $
   exposure. `stats_reader` (request-path) MUST NOT have any path
   to exact $ for `mode != 'exact'` providers. The grant set is
   the only thing standing between `stats_reader` and OLTP
   billing tables — verify every grant by name.
3. Partner-key isolation: only the operator CLI DSN
   (Step 4.A scope) should ever INSERT into `partner_keys`. The
   four runtime roles MUST NOT have INSERT on `partner_keys`. If
   Step 1's main.go opens a pool that has INSERT on
   `partner_keys`, that is CRITICAL.
4. `last_used_at` writer (`partner_keys_writer` role) is
   default-OFF in v0.1 per BUILD §2 Step 1 resolution. Default-ON
   is CRITICAL (would amplify a missing-isolation bug).
5. Provider-identity trust source (BUILD §1 prereq 4 +
   [[provider-auth-unauthenticated-end-to-end]]): Step 1 itself
   doesn't query OLTP, but if the Step 1 grants give `stats_rollup`
   SELECT on a `provider_*` table sourced from unauthenticated
   hello-frame payloads, that is HIGH (Step 2 will then amplify
   spoofed identities into the public leaderboard).

## Required reading

1. `specs/BUILD_SPEC_017_IMPL_PROMPT.md` §1 prereqs, §5 critical
   constraints, §2 Step 1.
2. `specs/SPEC-017-network-stats-api.md` v0.1.8 §1.5
   (constraints), §6.1 (bucketed default), §6.6.2 (partner-key
   surface), §7.2 (roles), §7.3 (process isolation), §5.4.1
   (`partner_keys` table).
3. The Step 1 diff at branch `impl/spec-017-step-1`.
4. `specs/SPEC-002-coordinator.md` line 3 + §7 (provider_tokens
   table — confirm `stats_rollup` reads from the authenticated
   surface).
5. `specs/SPEC-005-billing.md` line 3 + §4.3-§4.8 (ledger tables
   `stats_rollup` is granted SELECT on).
6. Memory: `[[provider-auth-unauthenticated-end-to-end]]`,
   `[[c2-gate-gateway-credential-validation-asymmetry]]`,
   `[[deploy-gate-example-file-guard-invariant]]`.

## Security audit categories

### A. Role-grant scope (the load-bearing boundary)
A.1  `stats_reader` has SELECT on EXACTLY the §7.2.1 enumeration
     + the chosen `rewards_populated` storage. Any extra grant
     is CRITICAL.
A.2  `stats_reader` does NOT have SELECT on
     `stats_late_events` (rollup-internal),
     `provider_rewards_ledger` (rollup-internal),
     `provider_visibility_audit` (write-only at request time),
     or any OLTP table (billing/session/pool). Each absent
     grant is verified by a positive grant query OR an
     explicit `REVOKE` in the migration. CRITICAL if missing.
A.3  `stats_rollup` has SELECT/INSERT/UPDATE/DELETE on the 7
     `stats_*` writer tables + `stats_late_events`, plus SELECT
     on `provider_visibility` + `provider_rewards_ledger`, plus
     USAGE,SELECT on the named sequences. No TRUNCATE / ALTER
     / DROP. Surplus is CRITICAL.
A.4  `stats_rollup` does NOT have any privilege on
     `partner_keys` or `provider_visibility_audit`. CRITICAL
     if violated.
A.5  `provider_portal` has ONLY INSERT/UPDATE on
     `provider_visibility` + INSERT on `provider_visibility_audit`
     + sequence grant. No `stats_*`, no OLTP, no
     `partner_keys`. CRITICAL if violated.
A.6  `partner_keys_writer` is default-OFF. The migration MUST
     NOT create it unconditionally. CRITICAL if violated.

### B. Operator CLI DSN handling (Step 4.A scope but Step 1 is
     where the config field is declared)
B.1  `coordinator.partner_keys_admin_dsn` config field, if
     present in Step 1, MUST NOT be opened at coordinator
     startup. Step 1's main.go MUST NOT instantiate a *sql.DB
     for it. CRITICAL if it does (coordinator process should
     never hold an INSERT-on-`partner_keys` connection at
     runtime).
B.2  The config field, if present, MUST NOT be required.
     Production coordinators that don't issue partner keys
     should not need it set. HIGH if required.
B.3  Config-load MUST NOT log the DSN value (it contains the
     superuser password). Grep the config loader for any
     `log.* %v ... cfg.Stats.PartnerKeysAdminDSN` pattern.
     CRITICAL if logged.

### C. DSN + secret handling
C.1  DSNs MUST NOT appear in commit or repo (search the diff
     for `password=` / `:5432` / `host=`). CRITICAL if found.
C.2  DSN config struct fields MUST be reachable via env
     overrides per the existing config loader pattern
     (operators inject DSNs at deploy time, not in
     `coordinator.yaml`). MEDIUM if env override is missing.
C.3  Smoke-test error logging MUST NOT include the DSN. On
     smoke failure, the error log MUST contain enough to
     diagnose (role name + table name + driver error class) but
     NOT the DSN string. CRITICAL if the DSN appears in error
     logs.

### D. Defense-in-depth for Steps 2/3/4
D.1  No raw token, no `token_hash`, no partner-key prefix
     present in any Step 1 SQL fixture. The fixtures Step 1
     creates will be reused by Step 3's AC-15 redaction sweep;
     a fixture with raw token bytes contaminates the sweep.
     HIGH if present.
D.2  `provider_visibility_audit` rows seeded by Step 1
     fixtures MUST use `actor_kind = 'provider'` or
     `actor_kind = 'system'`, NEVER `actor_kind = 'operator'
     AND new_mode = 'exact'` (AC-20 invariant — operator MUST
     NOT exact-enable). CRITICAL if violated.
D.3  AC-20 SQL assertion runs on EVERY PR (per BUILD §2.4),
     not behind a build tag. HIGH if PR-gated.

### E. Provider-identity trust source (BUILD §1 prereq 4)
E.1  If Step 1 declares the SPEC-002 `provider_tokens` table as
     a SELECT grant for `stats_rollup`, verify that
     `provider_tokens` IS the authenticated source per SPEC-002
     v1.4 §7. If Step 2 will instead join on a raw hello-frame
     payload table (a `provider_session` table sourced from
     unauthenticated frames), HIGH.
E.2  PR description records the trust-source decision
     explicitly per BUILD §1 prereq 4. Absent is HIGH.

### F. Migration safety
F.1  No `DROP TABLE` / `DROP INDEX` / `TRUNCATE` in Step 1
     migrations (Step 1 is creation only). CRITICAL if
     present.
F.2  Migrations run as the migration superuser, NOT as any of
     the four runtime roles. If the migration runner code
     uses `stats_rollup_dsn` to apply DDL, that is CRITICAL
     (would either fail or widen the role's privileges).
F.3  Backups / pg_dump considerations — Step 1 introduces
     tables containing partner-key hashes; the operator's
     backup posture MUST cover them. Not a Step 1 code
     finding; surface as INFO unless OPS.md notes are
     missing.

### G. testcontainers + CI hygiene
G.1  testcontainers-go uses a pinned Postgres image (digest
     SHA, not `:latest`). CRITICAL if `:latest`.
G.2  testcontainers tests do NOT bind the container to a host
     port (use the ephemeral mapped port). HIGH if a fixed
     host port is bound (CI parallel-job collision).
G.3  testcontainers tests run under a build tag
     (`//go:build integration`) so `make test-coordinator` on
     a Docker-less host does not fail. HIGH if not tagged.

## Output format

Per-category one-line verdict + per-finding entries (severity,
file:line, evidence, why, fix). Final verdict block.

`READY TO LOCK` iff 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
