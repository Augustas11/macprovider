# Audit prompt — SPEC-011 v0.5 (normative, round 4 — LOCK confirmation)

Operator-paste prompt to audit SPEC-011 v0.5
(`specs/SPEC-011-operator-pushed-warm-swap.md`).

**Round 4 — LOCK confirmation.** Round 3 (Codex on v0.4)
delivered LOCK-READY pending narrow polish: 0 CRITICAL / 0
MAJOR / 2 MINOR. v0.5 is a 4-edit polish pass closing those
MINORs (B3.1 AC-26 wording, F3.1(a) stale §6.1 citation,
F3.1(b) R-3.7.3 untyped shorthand, plus one bonus §3.9
inline-comment cleanup).

Round 4 has ONE job: confirm 0 CRITICAL / 0 MAJOR / 0 MINOR
across the v0.5 surface, and emit a **LOCK CONFIRMATION**
verdict — mirroring SPEC-010 v1.5 round 6 (which delivered
LOCK CONFIRMED on the sibling spec).

Trajectory:
- v0.2 round 1: 2 CRITICAL / 5 MAJOR / 3 MINOR
- v0.3 round 2: 0 / 2 / 4
- v0.4 round 3: 0 / 0 / 2 — LOCK-READY pending polish
- v0.5 round 4 target: **0 / 0 / 0 → LOCK CONFIRMED**

Append round-4 findings to existing
`specs/SPEC-011-audit.md` as a new top-level section after
round 3.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted
at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-011 v0.5 at /Users/augstar/macprovider-poc/
specs/SPEC-011-operator-pushed-warm-swap.md. This is round 4
and the LOCK confirmation pass.

Round 3 (Codex GPT-5 on v0.4) delivered LOCK-READY pending
narrow polish with 0 CRITICAL / 0 MAJOR / 2 MINOR. v0.5 is a
4-edit polish pass closing both round-3 MINORs (B3.1, F3.1)
plus one minor §3.9 inline-comment cleanup.

Your job:
1. **R3V — Round-3 MINOR fix verification.** For each of
   B3.1, F3.1, cite v0.5 location and mark
   PASS / PARTIAL / FAIL.
2. **LOCK confirmation.** If round 4 finds 0 CRITICAL / 0
   MAJOR / 0 MINOR, state explicitly "LOCK CONFIRMED" in
   the executive summary. If round 4 finds new MINORs but
   no MAJOR/CRITICAL, state "LOCK CONFIRMED WITH MINOR
   DEFERRED FIXES." If round 4 finds any new MAJOR or
   CRITICAL, state "LOCK NOT CONFIRMED — UNEXPECTED
   REGRESSION."

This is a small surface to audit (4 narrow edits). Expected
duration ~10-15 min.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-011-audit.md

APPEND a new top-level section:
  `## Round 4 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION`
followed by R3V table + category findings (likely "(no
findings)" across most categories).

## Severity definitions

Unchanged from rounds 1-3.

## Critical constraints

**1. Locked decisions (§2 L-1..L-7) READ-ONLY.**

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-010 v1.5
LOCKED.** v0.5 candidate annotations in §6.x are unchanged
from v0.4 except for F3.1(a) citation fix
(`SPEC-011 v0.3 §3.1` → `SPEC-011 v0.x locked §3.1`).

**3. v0.5's scope is unchanged from v0.4.** Polish pass
only — no new R-rules, no new ACs, no new sections.

**4. AC-26 verification is the new spot-check.** v0.5
rewrote AC-26 as 3 structural assertions instead of a
literal-substring grep. Spot-check:
- Run `grep -n '\$XDG_RUNTIME_DIR'
  specs/SPEC-011-operator-pushed-warm-swap.md` and verify
  EVERY match falls in one of the 4 allowed locations
  AC-26 enumerates (change-log entries, R-3.1.5 "Why not"
  rationale, R-3.9.2 prohibition rule, AC-26 self-
  reference).
- Verify §3.9 config block has NO `$XDG_RUNTIME_DIR` as
  any flag's default value.
- Verify no wire example in §3.1, §3.4, §3.6, §3.8
  contains `$XDG_RUNTIME_DIR` as a value.

**5. Round 4 is a sanity check, not a deep audit.** If
nothing new surfaces, the verdict is LOCK CONFIRMED.

**6. Clean-room.** No d-inference inspection.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 — focus on:
   - v0.5 change log
   - AC-26 (rewritten with 3 structural assertions +
     4-location allowlist + verification procedure)
   - §6.1 line ~1539 (cite `SPEC-011 v0.x locked §3.1`)
   - R-3.7.3 line ~968 (typed `switch_ack` frame
     reference)
   - §3.9 config block (no inline `$XDG_RUNTIME_DIR`
     parenthetical; references R-3.9.2 instead)

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-audit.md`
   rounds 1-3 — find `### B3.1` and `### F3.1` in round-3
   section to verify v0.5 fixes address Codex's actual
   concerns.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` — conventions.

4. Code spot-check (light): no new code-grounded surface
   in v0.5; the polish pass is contained to spec text.

## Audit categories

### Category R3V: Round-3 fix verification

Table format: round-3 finding, PASS/PARTIAL/FAIL, v0.5
location, 1-sentence evidence.

- **R3V-B3.1** AC-26 grep contract impossible → v0.5
  AC-26 rewritten as 3 structural assertions
- **R3V-F3.1** Residual editorial drift (§6.1 stale
  citation + R-3.7.3 untyped shorthand) → v0.5
  `SPEC-011 v0.x locked` + typed `switch_ack` reference

### Category A4: Locked-decision preservation (sanity check)

A4.1  L-1..L-7 sanity check after v0.5 polish. Nothing
      v0.5 touched should affect any lock.

A4.2  R-3.1.0 opt-in gate still enforces L-1 (no changes
      in v0.5).

### Category B4: AC-26 structural assertion correctness

B4.1  Run `grep -n '\$XDG_RUNTIME_DIR'
      specs/SPEC-011-operator-pushed-warm-swap.md`.
      Verify EVERY match falls in one of AC-26's 4
      allowed locations (change-log, R-3.1.5 rationale,
      R-3.9.2 body, AC-26 self-reference). If any match
      is in a forbidden location = MAJOR (the v0.5 fix
      didn't fully clean the spec).

B4.2  Verify the 3 structural assertions in AC-26 are
      operationally testable. Specifically: assertion 1
      ("§3.9 config block code block — no `default`
      line contains the substring") — parse the code
      block, check each `default <whatever>` line.
      Assertion 2 (no JSON field value in wire examples)
      — parse §3.1/§3.4/§3.6/§3.8 code blocks. Assertion
      3 (no R-rule outside R-3.9.2 advertises as default)
      — parse R-rule bodies, allow forbidden-rationale
      uses. If any assertion is too vague to implement =
      MINOR.

### Category C4: §6.1 citation correctness

C4.1  §6.1 cites `SPEC-011 v0.x locked §3.1`. Is this
      version-agnostic form correctly aligned with the
      SPEC-010 v1.5 G5.1 precedent? Cross-check: SPEC-010
      v1.5 §6.1 used `SPEC-010 v1.x locked §3.1 and §3.6`.
      Same idiom in SPEC-011 v0.5.

### Category D4: R-3.7.3 typed frame consistency

D4.1  R-3.7.3 now uses "typed `switch_ack` frame per
      R-3.1.5 with `accepted: false`, `reason: "cooldown"`,
      `seconds_remaining: N`". Is this consistent with
      R-3.1.5's `switch_ack` field reference? Specifically:
      `type` is REQUIRED on every frame per R-3.1.5; does
      R-3.7.3 imply `type` even if not literally written?
      If ambiguous = MINOR.

D4.2  Walk the rest of §3.7 for any other untyped
      shorthand v0.5 might have missed. (v0.4 had 2; v0.5
      fixed both. Are there any 3rd ones?)

### Category E4: Anything else

E4.1  Has the v0.5 polish pass introduced any new surface
      that should be audited?

E4.2  Documentation drift.

E4.3  Decision-log entry: NOT a finding, but reminder
      that one should be added after lock (alongside
      SPEC-010 v1.5 Entry 54).

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-011-audit.md`.
Start with:

```
---

## Round 4 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-011 v0.5 (specs/SPEC-011-operator-pushed-warm-swap.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 4 of N (normative, LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-4 executive summary — LOCK VERDICT

[1-2 sentences. State explicitly one of:
- "LOCK CONFIRMED" (0/0/0)
- "LOCK CONFIRMED WITH MINOR DEFERRED FIXES" (0/0/N
  with N ≤ 2, MINORs are non-blockers)
- "LOCK NOT CONFIRMED — UNEXPECTED REGRESSION" (any new
  MAJOR or CRITICAL)]

### Round-3 fix verification (R3V)

[Table format.]
```

Then for each category R3V, A4-E4, write a section. For
each finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- d-inference inspection
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008
- Auditing SPEC-010 v1.5 (LOCKED)
- Re-litigating rounds 1-3 findings marked PASS

## Done criteria

You are done when:

- Round-4 section APPENDED to SPEC-011-audit.md (rounds
  1-3 intact)
- Every round-3 MINOR has PASS/PARTIAL/FAIL in R3V
- Every category R3V, A4-E4 has a section
- Executive summary states the explicit LOCK verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 10-15 min (4 micro-edits to verify).
- If verdict is LOCK CONFIRMED: lock SPEC-011 v0.5,
  append Entry 55 to `beta/DECISION_CRITERIA.md`
  (alongside SPEC-010 v1.5 Entry 54), proceed to
  SPEC-001 v1.3 / SPEC-002 v1.3.5 BUILD prompts that
  cite both locked specs.
- If unexpected regression: narrow v0.6 fix + round 5.
