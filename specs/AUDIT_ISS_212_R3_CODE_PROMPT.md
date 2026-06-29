# AUDIT — ISS-212 R3 — CODE lens

## Task

R3 code re-audit. R2 code returned ZERO FINDINGS, but R2 architect
and security findings drove substantial new normative behavior:
the version bumped v0.2.1 → v0.3 and several SPEC + IMPL changes
landed.

Branch: `spec/iss-212-explorer-composite-pk`.

## R3 deltas (relative to R2)

- `phase5-gateway/internal/storage/sqlite/explorer.go`
  `explorerAccountIDsForRequest` extended from 3 to 5 tables
  (added feedback_events + audit_events) — addresses R2 security
  S4. New regression test in
  `phase5-gateway/internal/storage/sqlite/usage_events_pk_test.go`:
  `TestExplorerSessionDetailAmbiguityExtendedToFeedbackAndAudit`.
- `specs/SPEC-007-explorer.md` §6.4 ambiguity contract updated to
  name all 5 tables.
- `specs/SPEC-007-explorer.md` §5.6 rewritten (path-segment
  overload, `?account_id=` disambiguator, gateway-proxy rule).
- `specs/SPEC-007-explorer.md` §7.5 rewritten (intra-coordinator
  vs cross-service join split).
- `specs/SPEC-007-explorer.md` AC-7 rewritten (two-account
  collision + NULL fallback).
- Version bump v0.2.1 → v0.3 in header + body anchors.
- `specs/SPEC-007-r0-2-1-audit.md` renamed to
  `specs/SPEC-007-v0-3-audit.md` with R2 scope-expansion
  preamble.

## What to audit

1. Does the §6.4 ambiguity contract's "5 account-keyed session-detail
   tables" claim match `explorerAccountIDsForRequest`'s actual
   UNION? Verify the table list matches between SPEC and code.
2. Is the new test
   `TestExplorerSessionDetailAmbiguityExtendedToFeedbackAndAudit`
   asserting the correct contract (feedback_events alone in the
   second account triggers 409 with both accounts in the matched
   list)?
3. §5.6 says the coordinator MUST forward `external_request_id`
   (not internal `request_id`) when proxying to the gateway. The
   coordinator-side implementation is NOT in this PR's scope —
   does the SPEC text correctly describe a behavior that the
   coordinator IMPL would honor, or does it lock the contract to
   something the coordinator can't actually do?
4. Any remaining `request_id`-only join claim in SPEC-007 that
   should now be account-scoped?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
