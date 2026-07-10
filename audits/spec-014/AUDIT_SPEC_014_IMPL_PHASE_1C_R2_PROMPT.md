# Implementation audit prompt — SPEC-014 Phase 1C, round 2 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify the round-1 MEDIUM
finding is CLOSED and to re-sweep for any new findings the closure
edits may have introduced.

Round 1 (`specs/SPEC-014-impl-audit.md` Phase 1C section) returned:
- 0 CRITICAL
- 0 HIGH
- 1 MEDIUM:
  - **E.5** `check-bundle.sh` source contained literal
    `operator-key` / `operator_key` strings in comments and echo
    messages, which would match the same external grep patterns
    the script enforces against the bundle. Required idiom is
    string concatenation for ALL prohibited literals, not just
    the route literals.
- 0 MINOR / 0 QUESTION.

The fix has been applied: every prohibited literal in
`check-bundle.sh` (in comments, variable assignments, and emitted
echo messages) is now split via Bash string concatenation. This
audit verifies closure and re-sweeps Category E.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Read-only.

---

```
=== BEGIN PROMPT ===

You are performing round 2 of the SPEC-014 Phase 1C implementation
audit. Round 1 returned 1 MEDIUM finding; the operator edited the
working tree to close it. Your job is to verify CLOSURE and check
for any NEW finding the edit may have introduced.

This is a **read-only review**. No file edits, no commits, no
branches.

## Required reading

1. The round 1 audit report:
   `/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`
   (Phase 1C section).

2. The current working tree on branch
   `feat/spec-014-provider-portal` (uncommitted):
   - `frontdoor/provider-portal/check-bundle.sh`
   - `frontdoor/provider-portal/index.html` (unchanged in this
     round; verify no regression).
   - `frontdoor/provider-portal/README.md` (unchanged).

3. The Phase 1C BUILD prompt:
   `specs/BUILD_SPEC_014_IMPL_PHASE_1C_PROMPT.md`, constraint 6
   (check-bundle.sh requirements).

## Verification — round 1 finding closure

### E.5 closure
The fix must:
1. The script's own source MUST NOT contain a literal that matches
   the same external grep patterns the script enforces against
   the bundle. Specifically, the script source MUST NOT contain
   a literal `operator-key`, `operator_key`, `/poolz`,
   `/admin/blacklist`, `/admin/provisional`, `/admin/promote`,
   `/admin/reject`, `/admin/ledger`, `your fleet`, `your machines`,
   `across machines`, `all machines`, `N machines`, `N/M`, `x3`,
   or `machine grid` — all such occurrences must be split via
   Bash string concatenation or equivalent.

2. The script's bundle-grep behavior MUST remain unchanged:
   - Exit 0 on the current clean bundle, prints `check-bundle: OK`.
   - Exit 1 on a synthetic bundle containing `/poolz`, prints
     `FAIL [8(b)]: ...`.
   - Exit 2 when `index.html` is missing.
   - Patterns still cover EVERY string in BUILD prompt
     constraint 6 (op_routes + op_key + multi_machine).

Verify each. File as CLOSED or NOT_CLOSED.

Suggested external check:
```bash
grep -nEi 'operator[_-]?key|/poolz|/admin/blacklist|/admin/provisional|/admin/promote|/admin/reject|/admin/ledger|your fleet|your machines|across machines|all machines|N machines|N/M|x3|machine grid' frontdoor/provider-portal/check-bundle.sh
```
A non-zero exit (no matches) confirms self-protection.

## Re-sweep — Category E only

In addition to closure verification, re-sweep Category E (the
check-bundle.sh contract) for any NEW finding the closure edits may
have introduced (e.g. a label rename that breaks the emitted
`FAIL [8(b)]: ...` format expected by CI scrapers). Other categories
were already (no findings) and need not be re-walked.

## Severity definitions

Same five-tier scale as round 1.

## Output structure

Append to `/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`
a new section:

```
---

# Phase 1C audit — round 2 closure verification

**Audited:** working tree on branch feat/spec-014-provider-portal (uncommitted)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1C, round 2 of N
**Date:** 2026-06-21
**Round 1 findings status:** [E.5 CLOSED | NOT_CLOSED]
**New findings:** [N CRITICAL / N HIGH / N MEDIUM / N MINOR / N QUESTION]
**Phase 1C readiness:** [READY TO COMMIT | FIX REQUIRED]
**check-bundle.sh status:** [PASSES | FAILS]
**Single-PR readiness:** [READY TO OPEN PR | BLOCKED]
```

Then a section per closed finding (1-3 sentences) and one for new
findings (or `(no findings)`).

## Out of scope

- Re-walking Categories A-D, F-I, O.
- Phase 1A / 1B work (LOCKED).
- v0.2 work.
- Spec edits.

=== END PROMPT ===
```
