# SPEC-020 v0.1.4 IMPL — Round 2 audit prompt (per-lane)

You are auditing the **IMPL** of SPEC-020 v0.1.4 LOCKED at HEAD of
`impl/spec-020-provider-autoupdate` in worktree
`/Users/augstar/macprovider-spec-020-impl`.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Return `VERDICT: READY TO MERGE`
if zero blocking findings.**

## Trend

- r1: 0C + 12H + 6M (3 lanes; trust-state lifecycle dominant convergence)
- r2 target: 0/0/0

## What changed since r1

Three commits on top of the merged SPEC:

1. **`37514b9`** — initial IMPL (the r1 audit target).
2. **`d276886` — Absorb SPEC-020 autoupdate trust and recovery audit**
   (+918 / -87 across 9 files). Read
   `specs/SPEC-020-IMPL-r1-audit.md` for the r1 narrative the absorption
   targeted, and `specs/AUDIT_SPEC_020_v0_1_IMPL_r1_ABSORPTION_PROMPT.md`
   for the specific fixes applied.
3. **`7941a49` — test: clear AutoUpdateEventStore in disabled-mode
   heartbeat test** (5 lines) — minor: pre-existing
   `testHeartbeatDisabledModeOmitsBothFields` was written before
   `last_autoupdate_event` existed; absorption added a clear at test
   setup to preserve the original test contract.

The absorption targeted:
- **T-1 Trust-state lifecycle** (A-r1-H-1 + A-r1-H-2 + A-r1-H-3 + C-r1-H-1): pre-gate notify-only BEFORE state mutation; track committed marker/backup/swap and rollback on late trust-loss; live predicate that re-evaluates from current session facts; demote on AEAD/tier/token/attestation events.
- **T-2 Backup crash-safety** (B-r1-H-2 + C-r1-M-1): parent-dir fsync + ancestor validation.
- **T-3 Recovery state machine** (B-r1-H-3..H-6 + C-r1-M-2): shared marker validator; startup recovery BEFORE handshake; sentinel as durable anchor; post-start classification; watchdog containment.
- **T-4 Convergence boundary** (A-r1-H-4): fail-closed if rollback observer absent / launchd topology unsupported.
- **T-5 ACL checks** (C-r1-H-2): non-owner-write ACL detection in Swift + watchdog.
- **Cooldown double-count** (B-r1-H-1): exactly one path owns persistence.
- **MEDIUMs**: signed-policy wired; event reason redaction; O_NOFOLLOW reads; AC coverage tests.

## Smoke status

- `swift test` from `phase3-binary/`: 655 tests pass / 0 fail / 7 skipped
- `go test ./internal/ws/... ./internal/pool/...` from `phase4-coordinator/`: PASS
- `bash -n ops/macprovider-watchdog/watchdog.sh`: PASS
- `binaryVersion` constant: 1.7.0 ✓
- SPEC file unmodified ✓

## Lane-specific focus

Lanes A + B + C: same lens as r1 IMPL audit. Re-verify each r1 finding
was actually absorbed (not just superficially addressed). New findings
welcome.

### Lane A — Codex architect

Specifically re-verify trust-state lifecycle fixes:
- **A-r1-H-1 absorption**: pre-gate path. Notify-only verdict at
  `acceptCoordinatorSession` MUST emit notify event only AND NOT call
  any state-mutation code (`runAutoupdateIfEligible`, cooldown record,
  attempt tracking, lock acquisition). Confirm.
- **A-r1-H-2 + C-r1-H-1 absorption**: trust-loss-rollback. Trace the
  catch path for `trustStateLost` in `AutoUpdater.swift`. After a
  committed swap, does it call `AutoUpdateMarkerStore.restoreBackup`?
  Does it clear pending + backup? Does it suppress launchctl
  bootstrap?
- **A-r1-H-3 absorption**: live predicate. `currentAutoupdateTrustState()`
  must re-evaluate, not return cached. AEAD failure in
  `InferenceRelay.swift` must demote with `encrypted_leg_invalidated`.
- **A-r1-H-4 absorption**: convergence boundary. Watchdog availability
  active-enablement detection (launchctl print, not just fileExists).
  Pre-validate LaunchAgent loaded BEFORE swap.
- Anything new architecturally that the absorption introduced?

### Lane B — Codex code

Re-verify each B-r1-H-N:
- **B-r1-H-1 cooldown**: single owner. Trace every `recordCooldown` call
  site. First-failure-attempt-1, 3-failures-attempt-3, 4+-capped-3600s.
  Test exists.
- **B-r1-H-2 backup crash-safety**: route through
  `atomicCopyNoFollow` OR parent-dir fsync after rename. Inspect
  `AutoUpdater.swift` rollback backup path.
- **B-r1-H-3 marker validator**: shared `validateMarker` with all the
  field checks (UUIDv4, normalized target, paths, mode bounds,
  lowercase SHA, RFC3339 deadline). Used from `readPending` AND
  `validateBackup` AND watchdog `read_marker`. Confirm.
- **B-r1-H-4 startup recovery**: routine runs BEFORE handshake. Scans
  pending markers, success sentinels, stale rollback backups. All 3
  cases handled.
- **B-r1-H-5 sentinel anchor**: sentinel preserved UNTIL after event
  emission. Caller has access to `finalizeSuccessfulUpdate` (or
  equivalent). Startup recovery handles sentinel-only states.
- **B-r1-H-6 post-start classification**: `post_start_crash` vs
  `post_start_health_failed` vs `post_start_rejoin_timeout` — observer
  emits the correct one.
- **B-r1-M-1 AC coverage**: ACs 10, 17, 19, 20, 22, 23 all have tests.
- Anything new? `failure_class` enum exhaustive? `NORMALIZED_TARGET`
  propagation still consistent? Compiler warnings introduced?

### Lane C — Codex security

Re-verify each C-r1-H/M:
- **C-r1-H-1 trust-loss rollback** (= A-r1-H-2): confirm absorption.
- **C-r1-H-2 ACL checks**: Swift inspects ACLs via `acl_get_link_np` /
  `acl_get_entry` on every trusted-root ancestor; rejects non-owner
  write ACLs. Watchdog uses `ls -le` equivalent. Trace.
- **C-r1-M-1 backup fsync**: parent dir fsync added.
- **C-r1-M-2 watchdog containment**: restore path derives expected
  backup path from `target_path` + `update_id`, rejects mismatch,
  canonicalizes parents, rejects out-of-trust-boundary.
- **C-r1-M-3 signed-policy wired**: `updateSignedPolicy` called from
  validated-release path. Tests for monotonic invariant.
- **C-r1-M-4 redaction**: error reasons mapped to stable codes, no
  raw URLs / paths / hex over N chars.
- **C-r1-M-5 O_NOFOLLOW reads**: `Data(contentsOf:)` replaced with
  `open(O_RDONLY|O_NOFOLLOW)` + `fstat`.
- Anything new? Persistent monotonic state vulnerable to local
  tampering?

---

## Output format

`VERDICT: READY TO MERGE` if 0/0/0. Else `VERDICT: NEEDS REVISION`
with counts + ID-prefixed findings (`A-r2-H-1` etc.) + file:line.
Convergent cross-lane findings = strongest signal.
