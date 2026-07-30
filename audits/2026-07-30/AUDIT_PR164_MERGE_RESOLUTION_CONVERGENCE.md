# PR #164 merge-resolution audit — convergence record (2026-07-30)

Scope and prompt: `AUDIT_PR164_MERGE_RESOLUTION_PROMPT.md` (same directory).
Subject: revival merge of `origin/main` into `impl/spec-016` (merge commit
`59e9fc4e`) plus the fix commits it triggered. All lanes are codex via
`omc ask codex`.

## Round-by-round

| Round | Commit audited | code | security | architect |
|---|---|---|---|---|
| r1 | `59e9fc4e` (merge) | 0/1/0/0 | 0/1/0/0 | 0/1/1/0 |
| r2 | `a0fdf7ac` | 0/1/0/0 | **PASS 0/0/0/0** | 0/1/0/0 |
| r3 | `0f8705e2` | 0/1/0/0 | retired | **PASS 0/0/0/0** |
| r4 | `f14fdd1d` | 0/1/0/0 | retired | retired |
| r5 | `9f7adf6c` | **PASS 0/0/0/0** | retired | retired |

Counts are CRITICAL/HIGH/MEDIUM/LOW. Lanes retire on a clean pass
(never re-fired per house rule).

## Finding lineage (each round's HIGH and its closure)

1. **r1 convergent code+security HIGH, architect MEDIUM** — payout SIGHUP
   listener read only the base config; overlay-sourced tuning (incl. SPKI
   pins) could be silently reverted/dropped on SIGHUP. Closed in
   `a0fdf7ac`: `LoadPayoutTuningOnly(basePath, overlayPath)` with
   LoadWithOverlay semantics; unreadable overlay is a hard error.
2. **r1 architect HIGH** — general `reloadCoordinatorConfig` ran full
   `config.Load`, env-resolving + validating `payout.security.*` on SIGHUP
   (SPEC-016 v0.1.23 §6.5 violation; cross-namespace reload-rejection
   coupling). Closed in `a0fdf7ac` via `config.LoadForSIGHUPReload`.
3. **r2 convergent code+architect HIGH** — the reset ran AFTER typed
   decode; type-malformed payout scalars still rejected the reload.
   Closed in `0f8705e2` (strip before typed decode).
4. **r3 code HIGH** — the r2 strip used a map round-trip that normalized
   date-like scalars, RELAXING non-payout validation vs startup. Closed in
   `f14fdd1d` (node-level strip; scalar fidelity preserved; Load/reload
   parity regression test).
5. **r4 code HIGH** — strip loop `break`ed after the first payout entry;
   duplicate top-level payout blocks reached typed decode. Closed in
   `9f7adf6c` (filter all entries; two-hostile-blocks regression test).

## Evidence

- Full coordinator suite `go test -count=1 ./...` PASS at merge commit and
  at each fix commit; `go test -race ./internal/payout/...` PASS.
- Regression tests live in
  `phase4-coordinator/internal/config/config_payout_reload_test.go`.
- Lane transcripts: `.omc/artifacts/ask/` in the audit worktree; summaries
  mirrored to `scratchpad/pr164-merge-audit-*.log` in the canonical repo.

## Loop-cap note

Five rounds exceeds the normal 3–4-round anchored-loop cap. Rounds were
strictly convergent (two lanes retired early; every later finding was
against the newest fix, in edge-case territory the fix prompts explicitly
requested probed). Given the money-path surface, an additional independent
review pass (e.g. `/code-review ultra` on PR #164, user-triggered) before
merge is recommended as the anchoring counterweight, alongside the
required antfleet-ops PR review.
