# SPEC-020 IMPL r3 → r4 absorption prompt

You are absorbing IMPL round-3 audit findings in worktree
`/Users/augstar/macprovider-spec-020-impl` on `impl/spec-020-provider-autoupdate`.

**Bar:** IMPL r4 must return 0/0/0. Read `specs/SPEC-020-IMPL-r3-audit.md`
for full per-finding text. r3 totals: 0C + 3H + 2M (down from r2's 4H/4M).

## Convergent fix (A+C, both HIGH) — sentinel/recovery integrity

In `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` startup
recovery (~lines 1409-1419):

Replace the current sentinel-scan logic with:

```
For each .macprovider-cli.success-<uuid> sentinel in <binary-dir>:
  1. Load sentinel payload (atomic O_NOFOLLOW read + JSON decode + validate UUIDv4).
  2. Validate sentinel.binary_version == CoordinatorClient.binaryVersion.
     - Mismatch: emit failure_class:"orphaned_success_sentinel"
       with reason "binary_version_mismatch", delete just the sentinel,
       do NOT touch pending/backup, continue.
  3. Look up matching pending.json:
     - If pending absent: emit failure_class:"orphaned_success_sentinel"
       with reason "no_matching_pending", delete just the sentinel,
       do NOT touch backup (the backup, if present, is stale and will
       be cleaned by the stale-backup-without-pending scan).
     - If pending present BUT pending.update_id != sentinel.update_id:
       this is the pre-staged-sentinel attack path or a leftover from
       a prior failed update. Emit failure_class:"orphaned_success_sentinel"
       with reason "update_id_mismatch", delete just the sentinel,
       do NOT touch pending/backup. The orphan-pending-recovery routine
       will handle the legitimate pending marker on its own.
     - If pending present AND update_id matches: continue to step 4.
  4. Send the coord-visible success event FIRST via sendStateUpdate
     (outcome:"success", phase:"post_start", target_version, binary_version).
     AWAIT delivery to coordinator.
  5. Call completeSuccessfulUpdate(pending) — unlinks pending,
     deletes backup, releases lock.
  6. Call finalizeSuccessfulUpdate(updateID:) — deletes the sentinel.
```

Sentinel remains durable across crash between any pair of steps. Crash between (4) and (5) → next startup re-runs the recovery and the send is idempotent at the coord side; pending+backup still present. Crash between (5) and (6) → next startup finds sentinel without matching pending → goes to step 3's "no_matching_pending" path which is safe.

Add tests for AC-22 covering pre-staged sentinel attack (sentinel exists with `update_id` not matching pending) → assert no swap-cleanup occurs + correct event emitted.

## Standalone HIGH — C-r3-H-2 marker_deadline tolerance

In `phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift` `validateMarker` (~line 401):

Replace `now + 24h` upper bound with `now + post_start_window + 30 min`.

```swift
let postStartWindowSeconds: TimeInterval = 60   // current default
let futureToleranceSeconds: TimeInterval = postStartWindowSeconds + 30 * 60  // 1860 s
let upperBound = Date().addingTimeInterval(futureToleranceSeconds)
guard marker.markerDeadline <= upperBound else {
    throw MarkerValidationError.markerDeadlineFutureBeyondTolerance
}
```

Lower bound stays at `now - 300s` (5 min tolerance for slight clock drift on otherwise valid markers).

In `ops/macprovider-watchdog/watchdog.sh` (~line 249):

```sh
post_start_window=60
future_tolerance=$(( post_start_window + 30 * 60 ))
upper_bound=$(( now + future_tolerance ))
if [ "$deadline_epoch" -gt "$upper_bound" ]; then
    emit_failure "orphaned_pending_marker" "marker_deadline_future_beyond_tolerance"
    quarantine_marker
    exit 0
fi
```

Both Swift and shell sides must use the same tolerance.

## Standalone MEDIUMs

### C-r3-M-1: Replace `try?` on signed-policy persist

In `phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift` `updateSignedPolicy` (~line 364):

```swift
do {
    let data = try encoder.encode(combinedPolicy)
    try data.write(to: signedPolicyPath, options: [.atomic, .completeFileProtection])
} catch {
    // Persist failed. Best-effort rollback:
    //   - If backup is still present, restore it (we just swapped successfully,
    //     so backup exists until finalizeSuccessfulUpdate).
    //   - Emit failure_class:"signed_policy_persist_failed".
    //   - Disable autoupdate for the session.
    if FileManager.default.fileExists(atPath: backupPath.path) {
        try? AutoUpdateMarkerStore.restoreBackup(updateID: updateID)
    }
    AutoUpdateEventStore.shared.record(.failure(
        failureClass: "signed_policy_persist_failed",
        reason: String(describing: error).redacted()
    ))
    SessionAutoupdateGate.shared.disable(reason: "signed_policy_persist_failed")
    throw error
}
```

Add `signed_policy_persist_failed` to R-6.5 enum in `AutoUpdateEvent.swift`.

### B-r3-M-1: Test assertions for AC-10 + AC-22 + AC-23

**AC-10 watchdog tests**: Extend `ops/macprovider-watchdog/Scripts/test-ac-19-20-watchdog-recovery.sh` (or new `test-ac-10-post-start-classifications.sh`) to cover:

1. `post_start_crash`: fake `launchctl print` showing last_exit_status != 0 → assert rollback emitted with this failure_class.
2. `post_start_health_failed`: fake /healthz returning 5xx → assert this class.
3. `post_start_rejoin_timeout`: fake healthz 200 + version probe returning != target → assert this class.

Each fake can be a small shell function or test fixture file the watchdog reads from when `TEST_MODE=1` env var is set.

**AC-22 Swift test**: Add `testTrustLossBetweenAuthAndSwapAbortsAutoupdate` in `AutoUpdateTests.swift`. Setup:
- Mock AutoUpdateTrustState.evaluate to return eligible at first call, then notify-only at subsequent calls.
- Drive AutoUpdater.run() to completion.
- Assert: no swap occurred (binary unchanged), `trust_state_lost` event emitted, partial state cleaned.

**AC-23 Swift test**: Add `testSuccessFinalizeOnlyAfterCoordSendReturns` in `AutoUpdateTests.swift`. Setup:
- Mock CoordinatorFrameRecorder to delay/track sendStateUpdate calls.
- Drive completeSuccessfulUpdate + sendStateUpdate + finalizeSuccessfulUpdate.
- Assert: finalize is called AFTER send returns. Sentinel still on disk between send-initiate and send-return.

## Process

1. Read `specs/SPEC-020-IMPL-r3-audit.md` for context.
2. Apply each fix above.
3. Run `swift test` from `phase3-binary/` AND `go test ./internal/ws/... ./internal/pool/...` from `phase4-coordinator/`. Both must be green.
4. Run `bash -n ops/macprovider-watchdog/watchdog.sh` AND `bash ops/macprovider-watchdog/Scripts/test-ac-19-20-watchdog-recovery.sh` (and the new AC-10 test if you split it).
5. Confirm `signed_policy_persist_failed` value is added to the R-6.5 enum in `AutoUpdateEvent.swift` and the watchdog enum.
6. Output: commits on `impl/spec-020-provider-autoupdate`. Tests green.

You are absorbing — not re-auditing. Goal: r4 = 0/0/0.
