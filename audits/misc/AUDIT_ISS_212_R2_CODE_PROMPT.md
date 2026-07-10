# AUDIT — ISS-212 R2 — CODE lens

## Task

R2 code re-audit of the SPEC-007 v0.2.1 composite-PK addendum.
R1 surfaced 2 MEDIUM on the code lens (both fixed inline) and
the related #211 work has since merged (PR #224, SPEC-002 v1.5.0).
The current branch picks up the merged #211 changes via a merge
commit; one stale pointer in SPEC-007-explorer-design.md §2.8
was updated to "Closed by SPEC-002 v1.5.0 / issue #211".

Branch: `spec/iss-212-explorer-composite-pk`.

## R2 scope

The PR's body is the SPEC-007 v0.2.1 addendum:
- `specs/SPEC-007-explorer.md` §6.4 rewritten with composite-PK
  identity, `?account_id=` query param, 409 `ambiguous_request_id`
  response shape, window-contract split, forbidden-fields block.
- `specs/SPEC-007-explorer.md` §6.1 endpoint-specific-error-exception
  note for the OpenAI-compatible 409 envelope.
- `specs/SPEC-007-explorer.md` change-log v0.2.1 entry.
- `specs/SPEC-007-explorer-design.md` §4.2 Sessions disambiguator
  note + §2.8 GAP-closed pointer.

The gateway IMPL behind this addendum already shipped in #196
(reviewed and audited there); this is doc-only catch-up.

## What to audit (code-lens drift between SPEC and IMPL)

1. Does the §6.4 ambiguity contract still accurately describe the
   handler behavior in
   `phase5-gateway/internal/router/explorer.go`
   `handleExplorerSessionDetail`? Specifically the 409 response
   body shape (keys, types, error subobject) and the union of
   ambiguity-source tables in
   `phase5-gateway/internal/storage/sqlite/explorer.go`
   `explorerAccountIDsForRequest`.
2. Does the underlying-tables block name all three account-keyed
   session-detail tables (usage_events, quota_reservations,
   concurrency_reservations) consistent with R1 finding C1?
3. Does the §6.1 endpoint-specific-exception note correctly
   reference §6.4 and call out the deviation from the common
   gateway error envelope?
4. Any new code drift from the recent integration of merged
   #211 changes? (Confirm the §2.8 closed-pointer matches
   SPEC-002 v1.5.0's actual contract.)

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: <what the SPEC says vs what the code does>
SUGGESTED FIX: <minimal>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

## Out of scope

- The original #196 gateway IMPL (already shipped/audited).
- Coordinator-side reconciliation (closed by #211 / PR #224).
- Style nits.
