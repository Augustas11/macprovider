# Implementation audit prompt — SPEC-014 Phase 1A, round 2 (closure verification)

Operator-paste prompt for Codex GPT-5 to verify that round-1 HIGH
findings are CLOSED and to re-sweep for any new findings the closure
edits may have introduced.

Round 1 (specs/SPEC-014-impl-audit.md) returned:
- 0 CRITICAL
- 2 HIGH:
  - **A.2** `require_provider_tokens` non-true unreachable
    flag-false page (generic `configError` rendering won).
  - **C.4** Stale-config notice never reachable because
    `submitSignIn()` reset `state.authFailBySurface = {}` on every
    retry.
- 0 MEDIUM
- 0 MINOR
- 1 QUESTION (B.5 autocomplete=off — accepted as the chosen default).

Both HIGH have been edited in the working tree. This audit verifies
the closure and re-sweeps Categories A and C.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Read-only.

---

```
=== BEGIN PROMPT ===

You are performing round 2 of the SPEC-014 Phase 1A implementation
audit. Round 1 returned 2 HIGH findings; the operator edited the
working tree to close them. Your job is to verify CLOSURE and check
for any NEW finding the edits may have introduced.

This is a **read-only review**. You MUST NOT edit any file, commit,
push, or modify the git state. Your only output is the structured
findings report.

## Required reading

1. The round 1 audit report:
   `/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`
   (note the two HIGH and one QUESTION).

2. The current working tree (on branch
   `feat/spec-014-portal-phase-1a`, uncommitted):
   - `frontdoor/provider-portal/index.html`
   - `frontdoor/provider-portal/portal-config.json.example`
   - `frontdoor/provider-portal/README.md`

3. The Phase 1A BUILD prompt:
   `specs/BUILD_SPEC_014_IMPL_PHASE_1A_PROMPT.md`.

4. The locked SPEC, focused sections:
   - `specs/SPEC-014-provider-portal.md` §2.3 (AUTH-3 fail-CLOSED
     loader + stale-config guard), §2.4 (deployment-mode gating
     restated), §8(b) (auth ACs).

## Verification — round 1 finding closure

### A.2 closure
The fix must:
1. Set `state.flagFalse = true` for ANY non-true
   `require_provider_tokens` value (false, "true", 1, null, etc.),
   not only literal `false`.
2. Render `renderUnavailable_FlagFalse()` reliably for those cases
   (not be shadowed by `state.configError`).
3. Make ZERO subsequent network calls in any of those branches
   (no `/v1/pool/check`, no `/providers/{id}/earnings`, no GitHub).
4. Cite SPEC-002 FR-P12 + SPEC-005 §11.5 in the explanation copy.

Verify each, file as CLOSED or NOT_CLOSED. If NOT_CLOSED, file a
new HIGH at the same code path.

### C.4 closure
The fix must:
1. Preserve `state.authFailBySurface[surface]` across auth-rejection
   retries within the same browser session.
2. Reset the counter ONLY on:
   (a) a successful authenticated provider-endpoint 2xx, or
   (b) explicit `signOut()` / new browser session.
3. After two consecutive authenticated 401/403/404 to the same
   surface, the second rejection MUST render the `signinMisconfigNotice`
   on the sign-in screen ALONGSIDE the 403/404-identical
   "sign-in rejected" copy. The first rejection MUST NOT render
   the misconfig notice.

Verify each, file as CLOSED or NOT_CLOSED.

## Re-sweep — Categories A and C only

In addition to closure verification, re-sweep Categories A
(AUTH-3 deployment-mode loader) and C (AUTH-2 status handling +
stale-config guard) for any NEW findings the round-1 edits may have
introduced. Other categories were already (no findings) and need not
be re-walked.

## Severity definitions

Use the same five-tier scale as round 1
(CRITICAL / HIGH / MEDIUM / MINOR / QUESTION).

## Output structure

Append to `/Users/augstar/macprovider-poc/specs/SPEC-014-impl-audit.md`
a new section titled:

```
---

# Round 2 — closure verification

**Audited:** working tree on branch feat/spec-014-portal-phase-1a (uncommitted)
**Auditor model:** Codex / GPT-5
**Audit round:** Phase 1A, round 2 of N
**Date:** 2026-06-21
**Round 1 findings status:** [A.2 CLOSED | NOT_CLOSED, C.4 CLOSED | NOT_CLOSED]
**New findings:** [N CRITICAL / N HIGH / N MEDIUM / N MINOR / N QUESTION]
**Phase 1A readiness:** [READY TO COMMIT / FIX REQUIRED]
```

For each round-1 finding:

```
## A.2 closure
Status: CLOSED | NOT_CLOSED

[1-3 sentences: what the fix did; why it (does | does not) satisfy the
required behavior.]
```

For each NEW finding:

```
### A.x  [TITLE]   [CRITICAL | HIGH | MEDIUM | MINOR | QUESTION]
Location: index.html line N-M

[Body]
```

If round 2 finds zero new issues and both round-1 findings CLOSED,
the report MUST state "Phase 1A readiness: READY TO COMMIT" at the
top.

## Out of scope

- Re-walking Categories B, D-L, O (already cleared in round 1).
- Phase 1B / 1C work.
- Spec edits.

=== END PROMPT ===
```
