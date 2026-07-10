# AUDIT_SPEC_018_v0_2_SECURITY_r3

## Task

Round 3 security lane audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.2 after r2 absorption.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.2 SPEC body.
2. `specs/SPEC-018-v0_2-security-r2-audit.md` — your r2 findings: **READY TO LOCK** with 0C / 0H / 0M / 2m / 0Q.
3. `specs/SPEC-018-v0_2-r2-audit.md` — r2 narrative.
4. `specs/SPEC-018-v0_2-r2-absorption-prompt.md` — r2 absorption instructions (your r2 minors absorbed into v0.2.2).
5. `specs/SPEC-018-v0_2_2-DRAFT-NOTES.md` — codex absorption notes.

## Your tasks

1. **Confirm r2 security minors closed:**
   - m-1: `invalid_tools` table inheritance note added
   - m-2: AC-46 vs §10d.0.1 unknown-hash inconsistency fixed (Option A `null` sentinel)

2. **Defensive r3 security-lens sweep** — v0.2.1 was READY TO LOCK; v0.2.2 added new ACs (AC-50 through AC-55 aggregate caps) and changed AC-46 semantics. Verify no money-path or trust-boundary regression:
   - AC-50/51/52/53/54 (aggregate caps): money-path posture (these are request-validation errors, NOT fault-breaker-qualifying provider faults — confirm correctly classified)
   - AC-55 (linear validation): no new DoS surface introduced by validation runtime guarantee phrasing
   - AC-46 unknown-hash `null` value: information disclosure analysis (does `null` leak attacker-useful state vs. absent field?)
   - `prompt_echo_blocked` moved from public code table to internal-only: confirm no information about why parser failed leaks via the buyer-visible response (security-positive change)

3. **Final lock-readiness reconfirmation:** Security lane was READY TO LOCK in r2; verify v0.2.2 didn't regress that posture.

## Scope

Only v0.2.2 additions. Locked v0.1.5 still LOCKED.

## Output

Write `specs/SPEC-018-v0_2-security-r3-audit.md` with standard structure.

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO LOCK reconfirmation.
