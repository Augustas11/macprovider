# SPEC-017 stats.enabled=true — CODE-lane audit (R1)

You are the **code** lane of a three-lane audit (code / security /
architect) of a PR that flips `stats.enabled` from false to true in
the tracked production coordinator config and wires the three
Postgres DSNs. Stay narrowly in your lane.

## Branch / commit
- Branch: `feat/stats-enable-config`
- Worktree root: `/Users/augstar/macprovider-stats-enable`
- Base: `origin/main` @ `c8a644f`
- Files in scope:
  - `phase4-coordinator/dist/coordinator.yaml` — new `stats:` section
    added before `coordinator_advertised_version:` (single insertion).
- Independent verification of live state (VERIFIED BEFORE THIS PR — do
  not re-verify unless in scope):
  - Postgres 16 already running on Pearl.
  - Database `macprovider_stats` already created.
  - All 6 SPEC-017 migrations already applied (stats_overview_current,
    stats_timeseries_rpm_30m/tpm_30m, stats_leaderboard_{24h,7d,30d,all},
    stats_late_events, stats_components_health, stats_rewards_populated,
    schema_migrations_spec017, plus SPEC-026 provider_* tables).
  - Roles `stats_reader`, `stats_rollup`, `provider_portal` created with
    LOGIN + scram-sha-256 passwords set + connectivity verified.
  - Env vars `STATS_READER_DSN`, `STATS_ROLLUP_DSN`,
    `STATS_PROVIDER_PORTAL_DSN` written to `/etc/macprovider/coordinator.env`
    (0640 root:macprovider), each of form
    `postgresql://<role>:<pw>@127.0.0.1:5432/macprovider_stats?sslmode=disable`.
  - Coordinator currently returns 404 on `stats.streamvc.live/v1/stats/overview`
    because `stats.enabled=false`. Deploy target: 200.

## Code-lane scope (apply each; stay in lane)

### CODE-1. Config schema conformance

Verify the new `stats:` block matches `phase4-coordinator/internal/config/config.go`
`StatsConfig` struct exactly:
- `enabled: true` → `Enabled bool` ✓
- `reader_dsn`, `rollup_dsn`, `provider_portal_dsn` → the three
  always-required DSNs when Enabled=true (validator refuses to
  start otherwise, see line 1396-1401).
- `rollup.*` fields → `StatsRollupConfig` struct.
- No `partner_keys.*` (per spec §7.2.4 the writer role is
  intentionally not created; SPEC v0.1 IMPL skips this).
- No `partner_keys_admin_dsn` (CLI-only, not read at coordinator startup).
- No `cors.*` — accepting Go default. Confirm the code default is
  a reasonable public posture for a first-time enable (should be
  `Access-Control-Allow-Origin: *` or similar for the public
  overview endpoint).
- No `trusted_proxies` under stats — accepting Go default.

### CODE-2. Validator preconditions

`config.Validate` at line ~1390-1401 enforces when `stats.enabled=true`:
- `listen.bind_address` must be loopback (127.0.0.1, ::1, or localhost).
  Current: `bind_address: "127.0.0.1"` ✓
- `stats.reader_dsn`, `stats.rollup_dsn` non-empty. Current: env-indirected,
  resolved at runtime.
- Confirm `stats.provider_portal_dsn` is also validated as required (grep
  Validate).

### CODE-3. Rollup config defaults

- `backfill_mode: "partial"` requires `partial_history_since` non-empty
  RFC 3339 (fail-fast at startup — see main.go step 2 for the parse).
  Current: `"2026-07-04T16:50:00Z"` — valid RFC 3339.
- Verify `usd_per_million_credits: 1.0` is the operator-tunable factor
  (not the pin-your-real-USD-rate signal — that's SPEC-016 territory).
- `drift_threshold_ratio: 0.005` — within the [0.001, 0.05] tunable range
  per the StatsRollupConfig doc.
- `nightly_rebuild_hour_utc: 9` — within [0, 23].
- `late_events_lookback_hours: 48` — meets the "1× SPEC-005
  reconciliation-margin invariant" (≥24).
- `late_events_retention_days: 90` — meets the "floor 30" clamp.

### CODE-4. Insertion point

The `stats:` block was inserted between `providers: []` and
`coordinator_advertised_version:`. Confirm this doesn't split a
comment attribution (a comment above `coordinator_advertised_version:`
introducing that section — did the insertion preserve or displace it?).

### CODE-5. env: indirection roundtrip

The three DSN values use `env:` prefix. `config.Load` in
`phase4-coordinator/internal/config/config.go` (search for `env:`
prefix handling) MUST resolve these at load time from
`/etc/macprovider/coordinator.env` (systemd unit's EnvironmentFile).
- Verify the env-resolver treats missing env var as fail-closed
  (empty string is NOT silently accepted for a required DSN).
- Verify the resolver doesn't leak the DSN value into any log
  (post-resolution, is there any `logger.Info().Str("dsn", ...)` on
  the boot path?).

### CODE-6. Diff hygiene

- Only `phase4-coordinator/dist/coordinator.yaml` changes (plus
  audit files). No accidental other-file edits.
- No dist/coordinator.yaml.example update: FINE — the `.example`
  already declares the stats section shape as comments, so it's
  not stale on this axis (verify by grep). If it IS stale, note
  as a documentation-follow-up LOW.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/STATS_ENABLE_CONFIG_R1_CODE_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: code lane READY TO MERGE`
