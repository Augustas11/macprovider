# Implementation audit prompt — SPEC-014 Phase 1B, round 2 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify round-1 MEDIUM
findings are CLOSED and re-sweep for any new findings the closure
edits may have introduced.

Round 1 (`specs/SPEC-014-impl-audit.md` Phase 1B section) returned:
- 0 CRITICAL
- 0 HIGH
- 2 MEDIUM:
  - **C.4** Step 3 autotune cite included `SPEC-003 §6.2`, which
    SPEC-003 §6.2's CLI subcommand table does not list `autotune`.
  - **H.1** New CSS in Phase 1B used raw `#0a0b0e` instead of
    `var(--bg)` for `.snippet code` and `.release-card pre.rel-body`.
- 0 MINOR / 0 QUESTION.

Both MEDIUM have been edited. This audit verifies closure and
re-sweeps Categories C and H.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Read-only.

---

```
=== BEGIN PROMPT ===

You are performing round 2 of the SPEC-014 Phase 1B implementation
audit. Round 1 returned 2 MEDIUM findings; the operator edited the
working tree to close them. Your job is to verify CLOSURE and check
for any NEW finding the edits may have introduced.

This is a **read-only review**. No file edits, no commits, no
branches.

## Required reading

1. The round 1 audit report:
   `/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`
   (Phase 1B section).

2. The current working tree on branch
   `feat/spec-014-provider-portal` (uncommitted):
   - `frontdoor/provider-portal/index.html`
   - `frontdoor/provider-portal/README.md`

3. The Phase 1B BUILD prompt:
   `specs/BUILD_SPEC_014_IMPL_PHASE_1B_PROMPT.md`.

4. SPEC-003 §6.2 (CLI subcommand table) — verify `autotune` is
   not present.

5. The locked sections: SPEC-014 §4.2 + §6 + §8(a) Surface B.

## Verification — round 1 finding closure

### C.4 closure
The fix must:
1. Remove the `SPEC-003 §6.2` suffix from the Step 3 autotune
   citation. The only binding source for the autotune CTA is
   SPEC-013 §6 / NFR-4.
2. Step 1 + Step 2 citations must remain unchanged (Step 1 still
   cites SPEC-003 §4 / FR-C2; Step 2 still cites SPEC-003 §4 /
   FR-C4 / §6.2).

Verify each. File as CLOSED or NOT_CLOSED.

### H.1 closure
The fix must:
1. Replace `#0a0b0e` with `var(--bg)` in `.snippet code`.
2. Replace `#0a0b0e` with `var(--bg)` in `.release-card pre.rel-body`.
3. NOT introduce any new hex literal in Phase 1B's CSS additions.

Verify each. File as CLOSED or NOT_CLOSED.

## Re-sweep — Categories C and H only

In addition to closure verification, re-sweep Categories C (B.2
setup steps) and H (visual tokens + accessibility) for any NEW
findings the round-1 edits may have introduced. Other categories
were already (no findings) or out-of-scope and need not be re-walked.

## Severity definitions

Same five-tier scale as round 1.

## Output structure

Append to `/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`
a new section:

```
---

# Phase 1B audit — round 2 closure verification

**Audited:** working tree on branch feat/spec-014-provider-portal (uncommitted)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1B, round 2 of N
**Date:** 2026-06-21
**Round 1 findings status:** [C.4 CLOSED | NOT_CLOSED, H.1 CLOSED | NOT_CLOSED]
**New findings:** [N CRITICAL / N HIGH / N MEDIUM / N MINOR / N QUESTION]
**Phase 1B readiness:** [READY TO COMMIT | FIX REQUIRED]
```

Then a section per closed finding (1-3 sentences), and one for
new findings (or `(no findings)`).

## Out of scope

- Re-walking Categories A, B, D-G, I, O.
- Phase 1C work.
- Spec edits.

=== END PROMPT ===
```
