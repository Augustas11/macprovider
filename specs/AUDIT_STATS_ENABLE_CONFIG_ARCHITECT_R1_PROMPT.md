# SPEC-017 stats.enabled=true — ARCHITECT-lane audit (R1)

You are the **architect** lane. This PR turns on the SPEC-017 stats
subsystem in production for the first time.

## Branch / commit
- Branch: `feat/stats-enable-config`
- Worktree root: `/Users/augstar/macprovider-stats-enable`
- Base: `origin/main` @ `c8a644f`
- Files in scope: `phase4-coordinator/dist/coordinator.yaml` — new
  `stats:` section only.

## Runtime state verified before this PR

- Postgres 16 already running on Pearl (colocated with coordinator on
  same 4GB VPS).
- All SPEC-017 migrations applied.
- Runtime roles LOGIN + password + connectivity verified.
- SnapshotProvider wired (PR #353); returns 5 live fields, 4 zeros.
- Coordinator binary at v1.8.0-11-ga01b05a already carries the code.

## Architect scope

### ARCH-1. Postgres colocation on the 4GB coordinator box

- Pearl is 2 vcpu / 4 GB RAM / 120 GB disk.
- Current usage: coord ~25 MB, PG idle ~20 MB, SPEC-026 onboarding
  workload negligible. Adding SPEC-017 rollup: rollup writes every
  30s, timeseries every minute, leaderboard rebuilds hourly + nightly.
  Expected steady-state RAM: coord 100 MB + PG 200 MB peak = 300 MB.
- 3.5 GB headroom. Fine at current provider count (2-10). Argue
  whether this holds at 100 providers, 1000 providers. When does
  colocation break?

### ARCH-2. Backfill mode = "partial" with a hard boundary

- `partial_history_since: "2026-07-04T16:50:00Z"` means the rollup
  ignores all ledger data before this timestamp.
- Consequences:
  - `tokens_served_total`, `requests_total` = "since we turned this
    on", not "since coordinator startup ever." Public users may
    interpret it as lifetime. Documentation surface?
  - No burn-in period; stats endpoint starts empty and populates
    over the first minutes/hours. Malibu.tech should render
    "starting up" or accept low-values state for the first 30-60
    minutes.
- Alternative: `backfill_mode: "full"` (partial_history_since
  empty) — includes all historical ledger. Might blow up the first
  overview tick with a full-history SUM. Argue tradeoff.

### ARCH-3. First-time-enable ordering (nginx vs coordinator)

- Nginx already routes `stats.streamvc.live` → coord provider port
  (deployed weeks ago).
- Currently returns 404 because coord mux isn't mounted.
- After this PR + deploy: coord mux mounts, 404 → 200.
- Blast-radius question: are there OTHER surfaces on the provider
  port that need to keep working during the switch? The provider
  port hosts /ws/provider, /poolz, /admin/*, /healthz today. Verify
  the stats mux mount doesn't accidentally shadow any of those.

### ARCH-4. CORS + partner-key posture

- This PR enables the endpoint with default CORS (no explicit
  `stats.cors:` block). What IS the default for
  `access_control_max_age_seconds` and `partner_origin_allowlist`?
- Malibu.tech will fetch cross-origin from `stats.streamvc.live`.
  Public overview is designed to allow this. Confirm the default
  posture supports it without further config change.
- Partner-key issuance is NOT in this PR (deferred to when we
  actually want per-partner metrics like exact earnings). Argue
  whether deferring adds any lock-in cost.

### ARCH-5. Backup discipline deferral

- Backups are planned as a follow-up (same-box pg_dump on systemd
  timer). This PR ships without backup.
- Consequence of loss: all rollup data disappears. Reconstructible
  from ledger (SPEC-005 rollup source), but requires a manual
  re-migration cycle. Not silent-corruption territory.
- Argue whether backup should be in this PR or follow-up is fine.

### ARCH-6. Config precedent

- This is the FIRST landed change to the tracked coordinator.yaml
  since it was pulled into git in PR #357 (yesterday).
- Sets the pattern for how "enable a subsystem" reads as a PR.
- Is the `stats:` block placement, comment style, and PR shape
  the right precedent? Future subsystems will look like this.

### ARCH-7. Rollback story

- Rollback = revert PR + redeploy. Coord returns 404 on stats
  endpoints again. Postgres tables stay populated (harmless).
- Partial rollback = set `stats.enabled: false` in a new commit
  without deleting the DSNs — leaves the pathway warm. Argue
  whether this is a documented option.

### ARCH-8. Timeseries retention

- `stats_timeseries_rpm_30m` / `tpm_30m` are 30-minute rolling
  buckets by design. Growth is bounded.
- `stats_late_events` retention is 90 days per config.
- `stats_leaderboard_all` is unbounded until nightly rebuild.
- No PG disk-pressure risk at current scale. Note the growth curve
  we'd expect over a year at N providers.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence architectural change>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/STATS_ENABLE_CONFIG_R1_ARCHITECT_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: architect lane READY TO MERGE`
