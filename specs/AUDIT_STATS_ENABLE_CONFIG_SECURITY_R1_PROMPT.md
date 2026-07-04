# SPEC-017 stats.enabled=true — SECURITY-lane audit (R1)

You are the **security** lane. This PR activates a public HTTP
surface (`stats.streamvc.live/v1/stats/{overview,leaderboard,health}`)
that until now returned 404. Once merged + deployed, the surface
goes live to the internet.

## Branch / commit
- Branch: `feat/stats-enable-config`
- Worktree root: `/Users/augstar/macprovider-stats-enable`
- Base: `origin/main` @ `c8a644f`
- File: `phase4-coordinator/dist/coordinator.yaml` — adds `stats:`
  section with 3 env-indirected DSNs.

## What this activates (transparency)

Live surface after deploy:
- `/v1/stats/overview` — unauthenticated, 60 rpm/IP, 30s public cache,
  CORS on. Returns network aggregate + 30-min timeseries.
- `/v1/stats/leaderboard` — optional Bearer partner key (partner keys
  not issued in this PR); public tier: 60 rpm/IP.
- `/v1/stats/health` — unauthenticated, 60 rpm/IP.

The SnapshotProvider for `/overview` was audited on PR #353 and
returns 5 wired fields (nodes_online, nodes_hardware_attested,
unified_ram_gb_total, models_serving, network_utilization_pct)
plus 4 zeroed fields (bandwidth/power/cores).

Postgres roles all bind to 127.0.0.1 only; scram-sha-256 password
auth; no external port exposed.

## Security-lane scope

### SEC-1. New public surface disclosure

Re-verify against SPEC-017 §5.1: every field the endpoint will now
return is spec-authorized public. This is the same posture PR #353's
security lane approved; confirm the same argument holds now that
the endpoint actually serves.

### SEC-2. Env-indirection secret handling

- All 3 DSNs use `env:NAME` — no inline secret in yaml.
- Verify the env resolver in `phase4-coordinator/internal/config/`
  fails-closed on empty/missing (not silently continuing with an
  empty DSN which would produce a cryptic Postgres error, or worse,
  fall through to a default that connects to a wrong DB).
- Verify no log line prints resolved DSN values on the coordinator
  boot path (grep for `.Str("dsn"`, `.Str("reader_dsn"`, etc.).

### SEC-3. Postgres role posture

- Roles are LOGIN + password-auth. Passwords set on Pearl, never
  transited in the PR.
- Per migration 003: `provider_portal` and `stats_reader` are
  SELECT-only against non-secret tables; `stats_rollup` writes only
  to `stats_*` tables. Grep migration 004 (`004_grants.up.sql`) and
  005 (`005_oltp_source_grants.up.sql`) to confirm the runtime
  roles CANNOT read `partner_keys` (the SPEC-017 §7.2 partner-key
  secret material), CANNOT read `ledger_request_credits` beyond
  aggregate SUM, and CANNOT read any onboarding secret material
  in `provider_identities`.
- Any role holding a broader grant than the SPEC §7.2 spec?

### SEC-4. pg_hba + listen posture

- Verified live: PG binds default (127.0.0.1 only). No external port.
- Verified: pg_hba.conf `host all all 127.0.0.1/32 scram-sha-256`
  (no `md5`, no `trust`).
- Confirm no attack path where a compromised coordinator process
  (running as `macprovider` user) could escalate to postgres
  superuser. `pg_hba` `local all postgres peer` means only the
  `postgres` unix user can reach the superuser role — good.

### SEC-5. CORS default

Public overview endpoint will emit CORS headers. Verify:
- Default `Access-Control-Allow-Origin` is `*` OR a specific
  allowlist. If `*`, confirm the endpoint has no
  Authorization-bearing surface — otherwise Bearer credentials
  could leak cross-origin.
- Cross-check: leaderboard endpoint accepts Bearer, so its CORS
  must NOT be wildcard. Grep the CORS handler.

### SEC-6. Rate limit posture

- 60 rpm/(IP, endpoint) at the edge (nginx `limit_req` — already
  deployed).
- In-process 300 rpm/IP/endpoint on auth-failure tier (SPEC §5.4.7).
- Partner-tier 600 rpm/key/endpoint — no partner keys issued yet,
  so this branch is dormant.

### SEC-7. First-time-enable attack window

Between PR merge and deploy completing:
- Nginx routes stats.streamvc.live → coordinator's provider port.
- Old binary (running now) does NOT register /v1/stats/* mux, returns 404.
- After restart, new config enables the mux.

Is there a window where a partially-loaded coordinator serves the
mux without rate-limit / auth wiring? Trace boot ordering in
main.go Step 3 (stats registration).

### SEC-8. Postgres backup (deferred)

Backup discipline is same-box pg_dump — not part of THIS PR
(planned as a follow-up). Confirm this doesn't create a CRITICAL
window (data loss = replayable from ledger; not
irreversible-secret material).

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Attack:  <one-sentence adversary scenario>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/STATS_ENABLE_CONFIG_R1_SECURITY_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE`
