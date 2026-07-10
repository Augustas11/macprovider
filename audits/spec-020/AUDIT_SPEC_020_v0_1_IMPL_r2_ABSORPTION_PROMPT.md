# SPEC-020 IMPL r2 → r3 absorption prompt

You are absorbing IMPL round-2 audit findings in worktree
`/Users/augstar/macprovider-spec-020-impl` on `impl/spec-020-provider-autoupdate`.

**Bar:** IMPL r3 must return 0/0/0. Read `specs/SPEC-020-IMPL-r2-audit.md`
for full per-finding text. r2 totals: 0C + 4H + 4M (down from r1's 12H/6M).

## Convergent fix (B+C, both HIGH)

**Restore-before-cleanup in orphan recovery (B-r2-H-2 + C-r2-H-1).**

In `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` (~line 1442):

Replace the `fileExists(updateLockPath)` check with an active-flock test:
```swift
private func updateLockIsLive(at path: URL) -> Bool {
    let fd = open(path.path, O_RDWR | O_NOFOLLOW)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var fl = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
    // F_GETLK probes without acquiring; on macOS prefer flock(LOCK_EX|LOCK_NB).
    let rc = Darwin.flock(fd, LOCK_EX | LOCK_NB)
    if rc == 0 {
        // Acquired: lock is stale. Release.
        _ = Darwin.flock(fd, LOCK_UN)
        return false
    }
    return errno == EWOULDBLOCK  // live lock held by another process
}
```

(Implementation detail — pick whichever works on macOS. The semantics: return `true` only when another live process holds the lock.)

In `AutoUpdateMarker.swift` `orphanPendingMarker` (~line 261), rewrite
to `recoverOrphanedMarker(marker:)`:

```
1. Validate marker shape via existing shared `validateMarker(_:)`.
   If invalid → quarantine (rename pending.json → pending-quarantined-<timestamp>.json),
   delete backup if present, emit failure_class:"orphaned_pending_marker" with reason "marker_invalid", record cooldown, release lock, return.
2. Compute backup hash. If backup missing OR hash mismatch:
   - Emit failure_class:"rollback_backup_corrupt".
   - Quarantine marker, leave live binary alone (do NOT restore, do NOT delete).
   - Disable autoupdate for this session.
   - Release lock. Return.
3. Backup valid → call AutoUpdateMarkerStore.restoreBackup(updateID:),
   which atomically renames backup → target_path (the live binary).
4. Delete marker + backup.
5. Record cooldown keyed by (NORMALIZED_TARGET, "orphaned_pending_marker").
6. Emit failure_class:"orphaned_pending_marker" with outcome:"failure", phase:"rollback".
7. Release lock.
```

Watchdog: `ops/macprovider-watchdog/watchdog.sh` `restore` function (~line 389+) should mirror the same restore-then-delete pattern. Currently `restore` does call the backup-validate path; verify it's invoked from BOTH the stale-pending-marker path AND the post-start-failure path. If a code path goes "no sentinel → restore" without verifying backup hash first, fix it.

## Lane B HIGHs

### B-r2-H-1: Watchdog must respect 60s post-start window

In `ops/macprovider-watchdog/watchdog.sh`:

- Around line 471 (`restore(marker)` call when no sentinel): add a deadline check first.
- Around line 448 (classifies running provider as `post_start_rejoin_timeout`): same.

Logic:
1. Parse `marker_deadline` from `pending.json` (RFC 3339).
2. Compute `now = date -u +%s` and `deadline = date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$deadline_str" +%s`.
3. If `now < deadline`: still inside post-start window. Do NOT roll back. Exit cleanly.
4. If `now >= deadline`: classify the rollback reason:
   - Check `launchctl print gui/<uid>/live.streamvc.macprovider`:
     - If last exit status non-zero / process not running → `post_start_crash`.
     - If running but `/healthz` probe fails → `post_start_health_failed`.
     - If running + healthy but `binary_version` (from `--version` or healthz response) != NORMALIZED_TARGET → `post_start_rejoin_timeout`.
5. Call `restore(marker)` with classified reason.

(Swift side: equivalent check in `AutoUpdateMarker.swift` startup recovery — verify marker_deadline expired before triggering rollback.)

### B-r2-H-3: Success sentinel durable until coord-visible event

Reorder `AutoUpdater.swift` post-start success sequence:

Current order (broken):
1. Sentinel write.
2. Pending unlink.
3. Backup delete.
4. Sentinel delete (during finalize).
5. sendStateUpdate with success.

New order:
1. Sentinel write (durable anchor).
2. Pending unlink.
3. Backup delete.
4. Lock release.
5. **sendStateUpdate** with `outcome:"success", phase:"post_start", target_version, binary_version` (sentinel still present).
6. AWAIT send completion (synchronously, via `try await send(...)`).
7. **THEN** delete sentinel.

Crash between (6) and (7) → next startup sees sentinel + current binary_version matches target → delayed cleanup path (idempotent: just delete the sentinel).

Crash between (4) and (5) → sentinel still present → same delayed cleanup.

Crash between (1)–(3) → existing recovery handles via orphan marker.

In `CoordinatorClient.swift` (around lines 1309, 1355):

- Move sentinel deletion from `completeSuccessfulUpdate()` to a separate
  `finalizeSuccessfulUpdate(updateID:)` call.
- `completeSuccessfulUpdate()` returns AFTER (4). Caller invokes `sendStateUpdate(...)` to emit success. Then caller invokes `finalizeSuccessfulUpdate(updateID:)` to delete sentinel.

Update AC-V0.1-23 tests to cover the new sequence: crash between each of (1)→(7) must be recoverable.

## Lane MEDIUMs

### A-r2-M-1: Notify-only pre-gate complete short-circuit

In `CoordinatorClient.swift` ~line 1311:

Current logic: only short-circuits notify-only when recommendation parses AND is newer.

Replace with: if trust verdict is notify-only, emit notify event and return — regardless of recommendation parse/compare. The version check matters only for the eligible path:

```swift
let trust = await AutoUpdateTrustState.evaluate(...)
if !trust.isEligible {
    emitNotifyOnlyEvent(trust)
    return
}
// only past this point do we parse + compare version, take lock, etc.
```

### C-r2-M-1: Watchdog binary-dir containment

In `ops/macprovider-watchdog/watchdog.sh`:

- Read `MACPROVIDER_BINARY_DIR` from env OR detect from launchd plist `ProgramArguments[0]`:
  ```sh
  plist_path="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
  binary_dir=$(/usr/libexec/PlistBuddy -c 'Print ProgramArguments:0' "$plist_path" 2>/dev/null | xargs dirname)
  ```
- In `restore`: require `realpath(dirname(target_path)) == realpath(binary_dir)`. Reject otherwise with `failure_class:"unsupported_install_topology"`.
- Same check for `backup_path`.

### C-r2-M-2: Signed-policy persistence deferred to post-apply

In `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`:

- Remove `updateSignedPolicy` call at ~line 100 (currently fires after checksum signature verification, BEFORE tarball validation).
- Move the `updateSignedPolicy` call to AFTER `applyValidatedUpdate` completes successfully. The new binary is now live; the signed policy is real.
- For coordinator-triggered updates that pass through `runByTag`: same deferral.

(Alternative — bind `signed_policy.json` into the signed `checksums.txt` — defer to v0.2.)

### B-r2-M-1: AC coverage tests

Add focused unit tests in `AutoUpdateTests.swift`:

- **AC-10**: 3 cases (`post_start_crash`, `post_start_health_failed`, `post_start_rejoin_timeout`) — each triggers rollback with correct failure_class. Mock `launchctl print` / healthz probe outputs.
- **AC-17**: `event_payload_too_large` fallback — synthesize an event whose JSON-minified size exceeds 4096; assert all optional fields dropped in priority order; final fallback is minimal stable payload.
- **AC-19**: orphan-pending-marker with valid backup → restore + delete marker.
- **AC-20**: orphan-pending-marker with missing/corrupt backup → quarantine + no restore + autoupdate disabled for session.
- **AC-22**: trust-loss-between-auth-and-swap (build on existing notify-only test).
- **AC-23**: crash-between-each-step in the success cleanup sequence — simulate by partially completing the sequence then re-running startup recovery; assert idempotent + safe outcome.

Watchdog: add shell-level integration test under `phase3-binary/Scripts/` or `ops/macprovider-watchdog/Scripts/` named `test-ac-19-20-watchdog-recovery.sh`. Create fake marker + backup; invoke watchdog tick; assert correct behavior.

## Process

1. Read `specs/SPEC-020-IMPL-r2-audit.md` for context.
2. Apply each fix above.
3. Run `swift test` from `phase3-binary/` AND `go test ./internal/ws/... ./internal/pool/...` from `phase4-coordinator/`. Both must be green.
4. Run `bash -n ops/macprovider-watchdog/watchdog.sh`.
5. Confirm no new `failure_class` values added that are absent from R-6.5 enum.
6. Output: commits on `impl/spec-020-provider-autoupdate`. Tests green.

You are absorbing — not re-auditing. Goal: r3 = 0/0/0.
