# SPEC-020 v0.1.4 IMPL — Round 4 audit prompt (per-lane)

You are auditing the **IMPL** of SPEC-020 v0.1.4 LOCKED at HEAD of
`impl/spec-020-provider-autoupdate` in worktree
`/Users/augstar/macprovider-spec-020-impl`.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Return `VERDICT: READY TO MERGE`
if zero blocking findings.**

## Trend

- r1: 0C + 12H + 6M
- r2: 0C +  4H + 4M
- r3: 0C +  3H + 2M
- r4 target: 0/0/0

## What changed since r3

Commit `6774559` — "Preserve autoupdate recovery evidence before
cleanup" (+501 / -118 across 9 files). Read
`specs/SPEC-020-IMPL-r3-audit.md` for r3 narrative and
`specs/AUDIT_SPEC_020_v0_1_IMPL_r3_ABSORPTION_PROMPT.md` for the
applied fixes.

The absorption targeted:
- **Convergent A+C HIGH (sentinel/recovery integrity)**: startup
  recovery now requires `pending.update_id == sentinel.update_id`
  match; pre-staged sentinel detection via `orphaned_success_sentinel`
  with structured reason (`binary_version_mismatch`,
  `no_matching_pending`, `update_id_mismatch`); send coord-visible
  success event BEFORE finalize for both happy-path AND startup-
  recovery paths.
- **C-r3-H-2 marker_deadline tolerance**: tightened to
  `now + post_start_window + 30 min` (~31 min) in both Swift validator
  and watchdog. Was `now + 24h`.
- **C-r3-M-1 signed-policy persist failure**: replaced `try?` with
  do/catch; on failure restores backup if present, emits
  `signed_policy_persist_failed` failure_class (new in R-6.5),
  disables autoupdate for session.
- **B-r3-M-1 AC test coverage**: added AC-10 (3 classifications),
  AC-22 (trust-loss after auth), AC-23 (send-before-finalize ordering).

Counts: 662 swift tests pass (was 659; +3 from new ACs), Go pass,
watchdog syntax pass.

## Authoritative inputs

- IMPL at HEAD of `impl/spec-020-provider-autoupdate`
- SPEC at `specs/SPEC-020-provider-autoupdate.md` (LOCKED, do not audit)
- r1 + r2 + r3 narratives in `specs/SPEC-020-IMPL-r{1,2,3}-audit.md`

## Lane-specific focus

This is the defensive round. Re-verify EVERY prior finding was
absorbed AND that absorption didn't introduce new issues.

### Lane A — Codex architect

Re-verify previously absorbed and confirm no regressions:
- Sentinel/recovery integrity (A-r3-H-1 + C-r3-H-1):
  - Sentinel scan validates `binary_version` AND `update_id` match
    pending marker.
  - All three mismatch paths emit `orphaned_success_sentinel` with
    correct structured reason.
  - Coord-visible event sent BEFORE finalize (both happy-path and
    startup-recovery).
- `marker_deadline` tolerance is `now + post_start_window + 30 min`
  in Swift AND shell. Consistent.
- Signed-policy persist failure rollback path: restore-on-failure
  doesn't create a worse state (e.g., partial restore that breaks
  rollback observer's expected state).
- New AC tests don't introduce architectural assumptions that
  contradict the SPEC.

### Lane B — Codex code

- File:line citations resolve to actual code.
- `update_id` validation against pending: case-insensitive UUID
  comparison? Or strict lowercase per UUID v4 canonical form?
- `marker_deadline` upper bound: 90 minutes in seconds = 5400. Both
  sides use the same constant?
- `signed_policy_persist_failed`: is it in the failure_class enum?
  Properly classified as terminal vs retryable?
- AC tests: are they actually exercising the production code path
  (not stubs)? Specifically check AC-10 watchdog tests use real
  shell + test fixtures; AC-22 + AC-23 Swift tests assert ordering.

### Lane C — Codex security

- Pre-staged sentinel attack: confirmed `update_id` mismatch path
  rejects.
- `marker_deadline` upper bound: 31 minutes is enough? Could an
  attacker pin a binary for 31 min via clock skew + valid signed
  release? Acceptable residual?
- Signed-policy persist failure: when rollback fails too, what's
  the worst-case state? Operator must manually recover — is this
  surfaced loud enough?
- Any new attack surface from the test fixtures (e.g., TEST_MODE=1
  env var bypass)?
- Cross-process race: pending.json deleted between startup-recovery
  send and finalize — recovery runs again on next startup — is this
  idempotent / safe?

---

## Output format

`VERDICT: READY TO MERGE` if 0/0/0. Else `VERDICT: NEEDS REVISION`
with counts + ID-prefixed findings (`A-r4-H-1` etc.) with file:line.

Convergent cross-lane findings = strongest signal.
