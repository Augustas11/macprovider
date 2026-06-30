# SPEC-020 v0.1.4 IMPL — Round 3 audit prompt (per-lane)

You are auditing the **IMPL** of SPEC-020 v0.1.4 LOCKED at HEAD of
`impl/spec-020-provider-autoupdate` in worktree
`/Users/augstar/macprovider-spec-020-impl`.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Return `VERDICT: READY TO MERGE`
if zero blocking findings.**

## Trend

- IMPL r1: 0C + 12H + 6M
- IMPL r2: 0C +  4H + 4M
- IMPL r3 target: 0/0/0

## What changed since r2

Commit `8161aab` — "Restore before autoupdate recovery cleanup"
(+520 / -67 across 8 files). Read `specs/SPEC-020-IMPL-r2-audit.md`
for r2 narrative and `specs/AUDIT_SPEC_020_v0_1_IMPL_r2_ABSORPTION_PROMPT.md`
for the absorption fixes.

The absorption targeted:
- **Convergent (B+C, both HIGH)**: orphan-marker recovery restores backup BEFORE cleanup (active-flock test, validate marker, validate backup hash, restore-if-valid OR quarantine-if-corrupt, THEN delete marker + record cooldown).
- **B-r2-H-1**: watchdog respects 60s post-start window via `marker_deadline` parse; classifies into `post_start_crash` / `post_start_health_failed` / `post_start_rejoin_timeout` based on launchctl print + healthz probe.
- **B-r2-H-3**: success sentinel preserved across the coord-visible event send. New order: write sentinel → unlink pending → delete backup → release lock → sendStateUpdate (sentinel still alive) → AWAIT send completion → delete sentinel.
- **A-r2-M-1**: notify-only pre-gate short-circuits ALL notify-only verdicts regardless of recommendation parse/compare.
- **C-r2-M-1**: watchdog binary-dir containment — derive binary_dir from launchd plist ProgramArguments[0]; reject if target/backup not in real binary dir.
- **C-r2-M-2**: signed-policy persistence deferred to AFTER `applyValidatedUpdate` completes.
- **B-r2-M-1**: AC coverage — added tests for AC-10 (3 classifications), AC-17 (event_payload_too_large fallback), AC-19 (orphan restore), AC-20 (corrupt quarantine), AC-22 (trust-loss after auth), AC-23 (crash-between-cleanup-step). Also new shell-level watchdog integration test `phase3-binary/Scripts/test-ac-19-20-watchdog-recovery.sh`.

Counts: 659 swift tests pass (was 655; +4 ACs), Go tests pass, watchdog syntax pass.

## Authoritative inputs

- IMPL at HEAD of `impl/spec-020-provider-autoupdate`
- SPEC at `specs/SPEC-020-provider-autoupdate.md` (LOCKED, do not audit)
- r1 narrative at `specs/SPEC-020-IMPL-r1-audit.md`
- r2 narrative at `specs/SPEC-020-IMPL-r2-audit.md`

## Lane-specific focus

Re-verify each r2 finding was actually absorbed.

### Lane A — Codex architect

- **Convergent restore-before-cleanup**: trace `recoverOrphanedMarker` (or renamed equivalent) end-to-end. Active-flock test correctness? Hash-mismatch quarantine path?
- **B-r2-H-1 absorption**: marker_deadline-respecting watchdog timing. Is there still a window where watchdog can roll back a normal still-starting binary?
- **B-r2-H-3 absorption**: success sentinel lifecycle. Trace AutoUpdater + CoordinatorClient. Confirm sentinel survives across `sendStateUpdate`.
- **A-r2-M-1 absorption**: pre-gate completeness for all notify-only paths (invalid / equal / older / malformed).
- New architectural issues: any cycle, contradiction, or invariant broken by the absorption?

### Lane B — Codex code

- Same restore-before-cleanup trace, with file:line citations.
- `marker_deadline` parsing correctness in both Swift and shell (cross-platform date handling).
- Sentinel finalize ordering — is `finalizeSuccessfulUpdate(updateID:)` invoked exactly once per success, AFTER `sendStateUpdate` returns?
- Watchdog binary-dir detection: PlistBuddy invocation correct? Handles missing plist gracefully?
- Signed-policy deferral: now after `applyValidatedUpdate` — confirm call site moved.
- AC tests landed: AC-10, AC-17, AC-19, AC-20, AC-22, AC-23. Confirm each has a real assertion (not just a stub).
- Compiler warnings? Anything in the absorbed code raises Swift 6 strict concurrency warnings?

### Lane C — Codex security

- Restore-before-cleanup adversarial trace: can a stale lockfile + malformed marker cause incorrect restore?
- `marker_deadline` clock manipulation: if attacker sets future deadline via marker tampering, does it get caught by validation?
- Sentinel persistence: if attacker pre-stages sentinel with valid update_id + binary_version match, can they bypass the success path? (Should require: trusted-state-root invariants on sentinel write).
- Watchdog binary-dir containment: PlistBuddy reads attacker-writable plist? Or only the trusted plist path?
- Signed-policy post-apply: now persisted AFTER swap. If swap succeeds + persist fails, what happens? Rollback?

---

## Output format

`VERDICT: READY TO MERGE` if 0/0/0. Else `VERDICT: NEEDS REVISION`
with counts + ID-prefixed findings (`A-r3-H-1` etc.) with file:line.

Convergent cross-lane findings = strongest signal.
