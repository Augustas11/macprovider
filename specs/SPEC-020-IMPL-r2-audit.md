# SPEC-020 v0.1.4 IMPL — Round 2 audit narrative

**Audited:** commit `7941a49` (test-fix on top of absorbed `d276886`)
**Round:** r2
**Lanes:** 3 codex (architect, code, security)

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect | NEEDS REVISION | 0 | 0 | 1 |
| B code | NEEDS REVISION | 0 | 3 | 1 |
| C security | NEEDS REVISION | 0 | 1 | 2 |

**Totals: 0 CRITICAL, 4 HIGH, 4 MEDIUM.**

Trend r1→r2: HIGH 12→4 (-8), MEDIUM 6→4 (-2). Big drop on trust-state cluster; recovery state machine cluster remains the focus.

## Convergent theme — restore-before-cleanup (B+C, both HIGH)

**B-r2-H-2 + C-r2-H-1**: orphan-marker recovery still doesn't restore. Both lanes hit:

- `CoordinatorClient.swift:1442` checks `fileExists(update.lock)` (NOT whether advisory lock is LIVE) → if lockfile absent → calls `orphanPendingMarker`.
- `AutoUpdateMarker.swift:261` `orphanPendingMarker` only deletes `pending.json`, records cooldown, removes lock. Does NOT call `restoreBackup`.
- Missing: AC-19 (orphaned pending with valid backup MUST restore before marker deletion) + AC-20 (`rollback_backup_corrupt` quarantine path).
- Startup runs before handshake, so it can consume the marker before watchdog recovery has a chance.

**Combined absorption**:
- Replace `fileExists(update.lock)` check with active-flock test (open + try-flock; if acquire succeeds, lock is stale → safe to recover; if EWOULDBLOCK, another process holds it).
- `orphanPendingMarker` (or new `recoverOrphanedMarker`) MUST:
  1. Validate marker JSON shape using shared validator.
  2. Validate backup hash against marker's `sha256`.
  3. If backup is missing → emit `failure_class:"rollback_backup_corrupt"`, quarantine marker (rename to `pending-quarantined-<timestamp>.json`), disable autoupdate for session, do NOT delete live binary.
  4. If backup hash matches → call `restoreBackup` (atomic rename backup → target_path), THEN delete marker + backup, THEN record cooldown + emit `outcome:"failure", phase:"rollback", failure_class:"orphaned_pending_marker"`.
  5. Release lock.

## Standalone HIGHs

### B-r2-H-1: Watchdog rolls back before 60s post-start window expires

`watchdog.sh:471` calls `restore(marker)` immediately when no success sentinel exists; `:448` classifies a running provider as `post_start_rejoin_timeout` without checking elapsed time or `marker_deadline`. A watchdog tick that lands seconds after swap can roll back a normal still-starting binary.

**Fix**: read `marker_deadline` from pending.json; only roll back if `now > marker_deadline` (RFC 3339 parse + comparison). For pre-deadline ticks where the binary is still starting, no-op. Add a "still starting" classification that exits without action.

### B-r2-H-3: Success sentinel deleted before coordinator-visible event sent

Current sequence at `CoordinatorClient.swift:1309` + `:1355` + `AutoUpdateMarker.swift:252`:
1. Sentinel written.
2. Pending unlinked.
3. Backup deleted.
4. Sentinel deleted (during finalize).
5. (LATER) sendStateUpdate emits success event.

If crash between (4) and (5), both the durable anchor AND coord-visible event are lost. AC-23 says sentinel MUST be durable until event is on the wire.

**Fix**: reorder.
1. Sentinel written.
2. Pending unlinked.
3. Backup deleted.
4. Lock released.
5. **sendStateUpdate** with `outcome:"success", phase:"post_start", binary_version=<TARGET>` (sentinel STILL present).
6. AFTER state update confirmed delivered (await `send` to return), THEN delete sentinel.

Crash between (5) and (6) → next startup sees sentinel + current binary_version matches → delayed cleanup path (R-4.10a) runs, idempotent. Crash between (4) and (5) → sentinel still present → same delayed cleanup path on next startup, but coord may see a stale `last_autoupdate_event` from prior session. Acceptable trade.

Alternative: emit event BEFORE cleanup (step 0), then run cleanup. Sentinel + pending both alive across crash → recovery handles it. Either works.

## MEDIUMs

### A-r2-M-1: Notify-only pre-gate incomplete for invalid/older/equal versions

`CoordinatorClient.swift:1311` only short-circuits notify-only when recommendation parses AND is newer. If notify-only AND recommendation is malformed / equal / older → falls through to `runAutoupdateIfEligible`. Downstream guard at `:1751` prevents state mutation, so MEDIUM not HIGH.

**Fix**: short-circuit ALL notify-only verdicts before `runAutoupdateIfEligible` — regardless of recommendation parse / compare result. Logic: if trust == notify-only, emit notify event and RETURN. The recommendation version check matters only for the eligible path.

### C-r2-M-1: Watchdog restore containment not bounded to actual binary dir

`watchdog.sh:389` derives `expected_backup` from marker's `target_path`, then sets `trusted_dir = realpath(dirname(target))`. Proves backup + target share a parent, but doesn't compare that parent to a KNOWN binary directory. A malformed marker can define its own "trusted" dir.

**Fix**: maintain a config value or env var `MACPROVIDER_BINARY_DIR` (or detect from the launchd plist's `ProgramArguments[0]`); validate `realpath(dirname(target_path))` == realpath(known binary dir). Reject otherwise.

### C-r2-M-2: Signed-policy persisted before full validation

`SelfUpdate.swift:100` persists `release.signedPolicy` immediately after `checksums.txt.sig` verification — BEFORE tarball checksum validation, archive validation, self-test, or installation. The policy is decoded from GitHub API fields / release body (NOT content covered by checksum signature). Lets unauthenticated metadata permanently raise floor / add revocations for a release that may never install.

**Fix**: defer `updateSignedPolicy` to AFTER:
1. Tarball SHA-256 matches signed checksums.
2. Archive validation (no path traversal).
3. `self-test` on new binary passes.
4. Atomic swap succeeded.

Persist only when the signed release is actually applied (post-`applyValidatedUpdate`).

OR: bind the signed-policy content to the checksum signature (include `signed_policy.json` in `checksums.txt`). v0.1.0 may not require this — simplest: defer persistence to post-apply.

### B-r2-M-1: AC coverage gap persists

`AutoUpdateTests.swift` covers cooldown, sentinel happy path, notify-only, redaction, signed policy, tag fallback. Still missing: AC-10 rollback classifications (3 cases), AC-17 minimal `event_payload_too_large` fallback, AC-19 orphan restore, AC-20 corrupt backup quarantine, AC-22 trust-loss after auth, AC-23 crash-between-each-cleanup-step recovery. No watchdog integration tests for AC-19/20.

**Fix**: add focused unit tests for each. Watchdog tests can be shell-level under `phase3-binary/Scripts/test-*.sh` or similar — pick an existing test pattern in repo.

## Non-blocking confirmations from Lane A

- ✓ Late `trustStateLost` after committed swap calls `restoreBackup`, clears pending/backup, does not reach `restartLaunchd` (T-1 absorption from r1 confirmed).
- ✓ `currentAutoupdateTrustState()` recomputes from current payload/session/token facts; AEAD failure demotes via `encrypted_leg_invalidated`.
- ✓ Rollback observer + provider topology checks use `launchctl print` active-state checks before download/drain/swap.

## Next action

Absorb r2 → IMPL commit on top of `7941a49`. Then fire r3. Trend suggests r3 should land near 0/0/0.

## Raw artifacts

- Lane A architect: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-2-audit-prompt-per-lane-you-are-a-2026-06-29T16-53-49-222Z.md`
- Lane B code: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-2-audit-prompt-per-lane-you-are-a-2026-06-29T16-54-37-359Z.md`
- Lane C security: `.omc/artifacts/ask/codex-spec-020-v0-1-4-impl-round-2-audit-prompt-per-lane-you-are-a-2026-06-29T16-53-52-168Z.md`
