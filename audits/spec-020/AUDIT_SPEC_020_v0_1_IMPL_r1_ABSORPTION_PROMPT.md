# SPEC-020 IMPL r1 → r2 absorption prompt

You are absorbing IMPL round-1 audit findings on commit `37514b9` of
`impl/spec-020-provider-autoupdate` in worktree
`/Users/augstar/macprovider-spec-020-impl`.

**Bar:** IMPL r2 must return 0 CRITICAL + 0 HIGH + 0 MEDIUM across the
three lanes (architect / code / security).

Read `specs/SPEC-020-IMPL-r1-audit.md` for the full per-finding narrative
with file:line citations. r1 totals were 0C + 12H + 6M across 3 lanes.

## Absorption plan — themes first, fixes in priority order

### T-1: Trust-state lifecycle (3 lanes, ALL HIGH — load-bearing)

This is the single most important fix. Three coordinated changes:

**1. Pre-gate notify-only BEFORE calling `runAutoupdateIfEligible`** (A-r1-H-1).

In `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` at
the `acceptCoordinatorSession` call site (~line 1287), evaluate
`AutoUpdateTrustState.evaluate(...)` FIRST. If verdict is notify-only,
emit a notify-status event ONLY — do NOT call
`runAutoupdateIfEligible`. Specifically: do NOT insert into
`autoupdateAttemptedTargets`, do NOT take the update lock, do NOT
record cooldown, do NOT do any state mutation.

In `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift`, the
first action in `run()` MUST be a trust-state check; on notify-only
verdict at entry, return immediately without ANY state mutation.

**2. Restore on late trust-loss (after committed swap/marker/backup)**
(A-r1-H-2 + C-r1-H-1).

In `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift`:

- Track `committedMarker: Bool`, `committedBackup: Bool`, `committedSwap: Bool` flags in the run pipeline.
- The catch block that handles `trustStateLost` (around line 150) MUST:
  - If `committedSwap == true`: invoke `AutoUpdateMarkerStore.restoreBackup(...)` to restore the prior binary.
  - If `committedMarker == true || committedBackup == true`: delete committed marker + backup.
  - Release `update.lock`.
  - Suppress `launchctl bootstrap` of the new binary.
  - Emit `failure_class:"trust_state_lost"` with stable trigger reason (`encrypted_leg_invalidated`, `tier_demoted`, `token_revoked`, `coordinator_disconnected`, `attestation_state_degraded`).
  - Mark session-disabled for autoupdate (no retry until next coord session).

Add AC-V0.1-22 test: trust loss between auth_response and swap → no swap occurs; if swap committed, prior binary is restored.

**3. Live predicate, not handshake snapshot** (A-r1-H-3).

In `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`:

- `currentAutoupdateTrustState()` MUST re-evaluate from current
  session facts (tier, encrypted-leg session live, token validity,
  attestation state) each time it's called, NOT return a cached
  value.
- On AEAD decrypt failure in
  `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` (around
  line 57), DEMOTE the trust state with reason
  `encrypted_leg_invalidated`. Same for tier demotion, token
  revocation, attestation degradation events — emit a stable demotion
  reason and update the live predicate.
- The 5 re-eval points in `AutoUpdater.swift` (before download, drain,
  marker, swap, bootstrap) MUST call `currentAutoupdateTrustState()`
  AT THE CALL SITE, not read a cached value.

### T-2: Rollback backup crash-safety (B-r1-H-2 + C-r1-M-1)

In `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift`:

Route backup preservation through the hardened marker-store primitive,
NOT the local `copyNoFollow`. Either:
- (a) Delete `copyNoFollow` and have `preserveMarkerAndSwap` call
  `AutoUpdateMarkerStore.atomicCopyNoFollow(from: liveBinary, to: backupPath)`, which already includes parent-dir fsync.
- (b) Keep `copyNoFollow` but add `fsync(parent_dir_fd)` immediately
  after the atomic rename, AND lstat-validate the binary-dir ancestry
  (mode 0700, provider-UID-owned, no symlinks) before placing the
  backup.

(a) is the safer route; consolidates the trust invariant on a single
hardened path.

### T-3: Recovery state machine (B-r1-H-3..H-6 + C-r1-M-2)

**B-r1-H-3 — shared marker validator**:

Add a `validateMarker(_ pending: PendingMarker) throws` function in
`phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift` that:
- Validates `update_id` is canonical UUIDv4 (RFC 4122 §3, 36-char with dashes, version nibble = 4).
- Validates `target_version` matches the version regex AND is the normalized form (no leading `v`).
- Validates `target_path` and `backup_path` are absolute, no trailing slash.
- Validates `size` >= 0 and within a sane bound (e.g., ≤ 1 GiB).
- Validates `mode` is a decimal int in [0, 0o7777].
- Validates `sha256` matches `^[0-9a-f]{64}$` (lowercase only, not `.lowercased()`-coerced).
- Validates `marker_deadline` parses as RFC 3339 UTC; passes the tolerance check (R-4.10 future-beyond / expired / malformed).

Call `validateMarker` from `readPending()` and `validateBackup()`.
Malformed → R-4.10 orphan-recovery path (delete + cooldown +
`failure_class:"orphaned_pending_marker"`).

Update `watchdog.sh` `read_marker()` to perform the same validations
(reject any deviation). Add a helper `validate_marker_strict()` that
exits 1 on any deviation.

Also remove `.lowercased()` from `validateBackup()` SHA comparison —
require the marker's `sha256` to already be lowercase.

**B-r1-H-4 — startup recovery scan BEFORE handshake**:

In `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`,
introduce a startup recovery routine that runs in `main` / startup
sequence BEFORE the first coordinator connection attempt. The routine:

1. Scan `$BINARY_DIR` for any `.macprovider-cli.success-*` sentinel.
   - If sentinel's `binary_version` matches current `binaryVersion`:
     this is a delayed success cleanup. Unlink matching `pending.json`
     (no orphan recovery), delete matching rollback backup, release
     any held `update.lock`, delete the sentinel. Treat as
     `outcome:"success"`.
   - If sentinel exists but `binary_version` does NOT match current:
     emit `failure_class:"orphaned_success_sentinel"`, delete the
     sentinel, continue.
2. Scan `$TRUSTED_ROOT/pending.json`:
   - If present AND `update.lock` not held AND no observer process
     running: orphan-recovery (R-4.10).
3. Scan `$BINARY_DIR` for stale `.macprovider-cli.rollback-*` backups
   with no matching pending marker: delete without restoring.

Watchdog `watchdog.sh` MUST also run these scans on its tick — not
just exit when `pending.json` is absent. Update the tick handler.

**B-r1-H-5 — sentinel as durable recovery anchor**:

In `AutoUpdateMarker.swift` `completeSuccessfulUpdate()`:

Reorder the cleanup to leave the sentinel as the durable recovery
anchor UNTIL after the success event is emitted by the caller. New
sequence:

1. Write success sentinel atomically (this is the durable marker).
2. Return from `completeSuccessfulUpdate(...)` — caller now emits the success event.
3. After the caller has confirmed the event reached the coordinator
   (or after a soft timeout for offline mode), the caller calls a new
   `finalizeSuccessfulUpdate(updateId:)` which:
   - Unlinks `pending.json`.
   - Deletes the rollback backup.
   - Releases `update.lock`.
   - Deletes the sentinel LAST.

On next provider startup, if the sentinel is still present and
`binary_version` matches current, run the same finalize sequence (the
startup recovery routine).

**B-r1-H-6 — post-start classification**:

In `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift` and
`ops/macprovider-watchdog/watchdog.sh`, add post-start observation
state tracking:

- After `launchctl bootstrap`, the observer (watchdog OR in-process)
  watches for:
  - **`post_start_crash`**: new binary exits with non-zero status
    within 60s (`launchctl print` shows last_exit_status != 0 OR
    process not in process table).
  - **`post_start_health_failed`**: new binary is running but
    `/healthz` probe (or equivalent local readiness check) fails
    within 60s.
  - **`post_start_rejoin_timeout`**: new binary is running AND
    healthy locally but did NOT rejoin coordinator with
    `binary_version == NORMALIZED_TARGET` within 60s.
- Each rollback event MUST emit one of the three classes (NOT
  `orphaned_pending_marker` — that's reserved for marker recovery
  with no observer).

**C-r1-M-2 — watchdog restore path containment**:

In `ops/macprovider-watchdog/watchdog.sh`, the `restore` function MUST:

- Read `update_id` and `target_path` from validated marker.
- Compute expected backup path as `<dir(target_path)>/.macprovider-cli.rollback-<update_id>`.
- Read marker's `backup_path` field; reject restore if it does NOT
  match the expected derivation.
- Canonicalize parents of `target_path` and `backup_path`; reject if
  either is outside the trusted binary directory.
- Reject if either path crosses a symlink, has non-provider-owner, or
  has group/world/non-owner-ACL write.

### T-4: Convergence boundary enforcement (A-r1-H-4)

In `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift`:

- Replace `fileExists(watchdogPlist)` check with active enablement
  detection: run `launchctl print gui/<uid>/live.malibu.provider-watchdog`
  and verify the service is loaded AND not disabled. If unavailable,
  fail closed with `failure_class:"rollback_observer_unavailable"`.
- For the main LaunchAgent: `restartLaunchdIfInstalled` MUST NOT
  silently return if plist is absent AFTER swap. Refactor:
  pre-validate the LaunchAgent plist is present AND loaded BEFORE
  any state mutation. If not, fail closed with
  `failure_class:"unsupported_install_topology"`.

Add `unsupported_install_topology` to the failure_class enum in
`AutoUpdateEvent.swift` if not present.

### T-5: ACL checks on trusted root (C-r1-H-2)

In `phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift`
`validateTrustedRoot()` (~line 273):

For each ancestor of `$HOME/.local/share/macprovider/autoupdate/`:
- Call `acl_get_link_np(path, ACL_TYPE_EXTENDED)`.
- Iterate entries with `acl_get_entry(...)`.
- For each entry, get tag (`acl_get_tag_type`) and permset (`acl_get_permset`).
- Reject if the entry grants `ACL_WRITE_DATA` / `ACL_APPEND_DATA` /
  `ACL_ADD_FILE` to any tag OTHER than `ACL_USER` matching provider's
  effective UID, or to `ACL_GROUP` / `ACL_OTHER`.

In `ops/macprovider-watchdog/watchdog.sh` `validate_trusted_root()`
(~line 167):

Use `ls -le <path>` (macOS) to display ACL entries; parse each `0:`,
`1:`, etc. line; reject if any line shows write/append for non-owner.

Helper invocation example:
```sh
ls -le "$path" | awk '/^[ 0-9]+:/ {if ($0 ~ /write|append/ && $0 !~ /^ *[0-9]+: user:'"$PROVIDER_USER"'/) exit 1}'
```

### Cooldown double-count (B-r1-H-1)

In `phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift`
`recordCooldown(target:failureClass:)` (~line 225):

This is the ONE site that owns cooldown persistence. It increments
attempt AND applies the formula. Other paths (`fail()` and friends
in `AutoUpdater.swift` lines 120, 129, 137, 153, 246) MUST NOT also
call `recordCooldown` for the same logical failure.

Refactor: `AutoUpdater.fail(reason: FailureClass)` calls
`recordCooldown` exactly once per outer attempt; callers that already
called `fail()` MUST NOT also call `recordCooldown` directly.

Add a unit test that asserts: 1 failure → attempt 1, cooldown 300s.
3 consecutive failures → attempt 3, cooldown 1200s. 4+ → 3600s cap.

## Non-convergent MEDIUMs

**C-r1-M-3 — wire signed-policy persistence**:

In `SelfUpdate.swift`:
- Extend `GitHubRelease` to decode signed-policy metadata if present
  (probably embedded in the release body or via a separate signed
  artifact like `signed_policy.json` adjacent to `checksums.txt`).
- After signature/checksum validation passes, before applying the
  update, call `AutoUpdateMarkerStore.updateSignedPolicy(...)` to
  fold the observed `signed_policy_minimum` / `signed_policy_revoked`
  into the persisted monotonic state.
- Add unit tests for: attempting to lower the floor (rejected),
  attempting to remove from revoked set (rejected), legitimate
  raise/add (accepted + persisted).

**C-r1-M-4 — event reason redaction**:

In `AutoUpdater.swift` (lines 130, 154 and similar):

Replace `String(describing: error)` with a mapping function that
returns a stable `failure_class` enum value + a redacted reason
string. The reason MUST NOT include:
- Full URLs (strip query string + fragment; keep only host).
- Absolute paths (replace with `<binary-dir>` / `<state-root>` placeholders).
- Raw checksum / signature material.
- Free-text error strings (truncate to enum-tagged structured reason).

Add a test that takes every `UpdateError` case, runs it through the
redaction pipeline, and asserts the output contains no raw URLs /
paths / hex over 16 chars.

**C-r1-M-5 — O_NOFOLLOW on reads**:

In `AutoUpdateMarker.swift` `readPending()`, `validateBackup()`, and
the SHA helper (~lines 157, 178, 409):

Replace `Data(contentsOf: url)` with:
```swift
let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
defer { close(fd) }
var st = stat()
fstat(fd, &st)
// verify inode/mode/links/owner against expected
// read data via Data(fileDescriptor:)
```

Pattern: lstat-then-open is TOCTOU; use O_NOFOLLOW + fstat instead.

**B-r1-M-1 — AC coverage**:

Add focused unit tests in
`phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift`:
- AC-V0.1-10: each of `post_start_crash`, `post_start_health_failed`, `post_start_rejoin_timeout` triggers rollback with the correct failure_class.
- AC-V0.1-17: `event_payload_too_large` fallback emits a minimal stable payload.
- AC-V0.1-19: orphaned pending marker recovery path.
- AC-V0.1-20: corrupt rollback backup recovery path.
- AC-V0.1-22: trust-state-lost between auth_response and swap → no swap occurs.
- AC-V0.1-23: success cleanup happy path + crash-between-each-step recovery.

Add a watchdog integration test (shell-level) for AC-V0.1-19/20.

## Process

1. Read `specs/SPEC-020-IMPL-r1-audit.md` for context.
2. Apply each fix above (be liberal about adding small refactor commits
   if it improves clarity; squash later or keep as commit history).
3. Update tests for each absorbed finding.
4. Run `swift test` from `phase3-binary/` and `go test ./internal/ws/... ./internal/pool/...` from `phase4-coordinator/`. Both green.
5. Run `bash -n ops/macprovider-watchdog/watchdog.sh`.
6. Update `failure_class` enum if new values were added
   (`unsupported_install_topology`).
7. Output: commits on `impl/spec-020-provider-autoupdate`. Tests green.

You are absorbing — not re-auditing. Goal: r2 = 0/0/0.
