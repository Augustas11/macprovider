# SPEC-020 v0.1.4 — Round 5 audit prompt (per-lane)

You are auditing **SPEC-020 v0.1.4 (2026-06-29, DRAFT)** post-r4 absorption.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Return `VERDICT: READY TO LOCK`
if you find zero blocking findings.**

## Trend

- r1: 0C + 4H + 13M
- r2: 0C + 2H + 10M
- r3: 0C + 1H + 8M
- r4: 0C + 0H + 2M (A+C already at LOCK)
- r5 target: 0/0/0 across all three lanes

## What changed since r4 (v0.1.3 → v0.1.4)

Only Lane B had findings; absorbing addressed both:

- **B-r4-M-1 absorption**: new "Success-state cleanup sequence and
  crash recovery" subsection with explicit 5-step ordered sequence
  (success sentinel → unlink pending → delete backup → release lock
  → emit success event) + structured crash-recovery semantics on
  next startup + new `orphaned_success_sentinel` failure_class +
  AC-V0.1-23 covering success-state cleanup end-to-end.

- **B-r4-M-2 absorption**: corrected `marker_deadline` malformed /
  missing / expired citations from "(R-4.8)" to "(R-4.10)";
  "future beyond tolerance" now triggers orphan recovery + cooldown
  entry + autoupdate disabled for session + structured reason
  `marker_deadline_future_beyond_tolerance`.

Counts: 902 lines (was 853), AC count 23 (was 22).

## Authoritative inputs

(Same as r4. Re-read SPEC body, `SPEC-020-r4-audit.md`, and
`AUDIT_SPEC_020_v0_1_r4_ABSORPTION_PROMPT.md` for the absorption fix
text — verify the absorption matched.)

## Lane-specific focus

This is a defensive round. Lanes A and C have already returned READY
TO LOCK at r4 against v0.1.3. v0.1.4 only adds Lane B's two MEDIUM
absorptions on top. Re-verify your prior LOCK still holds + any new
absorption text in your lens.

### Lane A — Codex architect

- Did the success-cleanup ordered sequence (R-4.10 changes) introduce
  any architectural inconsistency with the live trust-state predicate
  (R-1.x)? E.g., between step 4 (release lock) and step 5 (emit
  success event) — does trust loss matter? Probably not (swap is
  done, binary is live), but verify.
- Did the marker_deadline "future beyond tolerance" gating + cooldown
  introduce any conflict with the existing cooldown formula or
  trust-state-lost cleanup invariants?
- Citation fixes (R-4.8 → R-4.10): grep for any other places the SPEC
  cites R-4.8 incorrectly.

### Lane B — Codex code

- **The absorption itself**: is the 5-step ordered sequence
  implementable end-to-end without race? Specifically: does step 1
  (success sentinel write) require an O_CREAT|O_EXCL that could fail
  if a prior crash left a stale sentinel — is recovery defined?
- **Crash-recovery semantics**: the "delete backup without restoring
  if pending.json absent but rollback backup stale" branch — is
  "stale update_id" defined? How does the recovery code identify
  staleness without a pending marker?
- **AC-V0.1-23 coverage**: does it test (a) the happy path, (b) each
  crash-between-step recovery scenario? If only happy path, propose
  splitting.
- **failure_class enum completeness final**: `orphaned_success_sentinel`
  is present. Final final check on enum exhaustiveness against body
  occurrences.
- **AC count**: confirm 23 ACs total; confirm AC numbering is
  contiguous 1..23 with no gaps.

### Lane C — Codex security

- **Success sentinel as new attack surface**: created with
  O_CREAT|O_EXCL|O_NOFOLLOW mode 0600. Does the SPEC require the
  sentinel be created in the same trusted-state-root scope as marker/
  backup, or only "adjacent to live binary"? Trust-state ancestor
  invariants from earlier rounds — do they cover this path?
- **`update_id` reuse**: if an attacker can predict or fix
  `update_id`, can they pre-stage a malicious success sentinel
  before legitimate autoupdate runs? The SPEC says UUIDv4 — is
  randomness source pinned (cryptographic vs predictable)?
- **`marker_deadline_future_beyond_tolerance` cooldown**: this
  disables autoupdate for the session. Could a malicious coord cause
  a benign provider to enter this state by causing clock skew? Is
  this DoS path acceptable / documented?

---

## Output format

`VERDICT: READY TO LOCK` if zero blocking findings. Otherwise
`VERDICT: NEEDS REVISION` with C/H/M counts and ID-prefixed findings.

Convergent cross-lane findings still the strongest signal. Notes
welcome but do not block.
