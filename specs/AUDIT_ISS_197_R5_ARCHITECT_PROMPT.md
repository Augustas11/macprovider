You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), ARCHITECT lane, ROUND 5.

R4 returned 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW.

R5 fixes:

1. (R4 MEDIUM: SPEC-005 §10.4 + SPEC-002 line 1560 still said
   "out-of-process") Rewrote both to data-surface-contract phrasing.
   - SPEC-002 §11 line 1560: "support closing-the-books reconciliation
     joins to gateway `usage_events` and `audit_events` (whether run
     as out-of-process harnesses or via a future coordinator-hosted
     reconciliation endpoint)".
   - SPEC-005 §10.4: "Any reconciliation surface that performs
     closing-the-books joins between coordinator `request_log` and
     gateway `usage_events` / `audit_events` by composite reconciliation
     key — whether run as an out-of-process harness OR as a future
     coordinator-hosted reconciliation endpoint — MUST read per-key
     migration state ... and fail closed ..."

2. (R4 LOW: deprecate-and-add same-columns-different-name) Expanded the
   registry-invariant clause: the state-enum vocabulary is NOT extended;
   the OLD `key` continues to enumerate with its real state; if rename
   is cosmetic both entries share state; if shape changed the old
   entry reports `unindexed` (its index dropped) or `legacy` (its
   column dropped). SPEC change-log explicitly marks old-as-deprecated
   and names the new replacement.

3. Added a new top-level "Buyer-controlled text sanitization (v1.5.1)"
   paragraph in SPEC-002 §11 enumerating EVERY buyer-controlled
   persisted text column and its sanitizer (security architect
   visibility into the full surface).

## Verify

- Does SPEC-002 §11 + the v1.5.1 change-log + SPEC-005 v0.3.2 now
  agree consistently on the data-surface scope? `rg "out-of-process"`
  should turn up only the EXAMPLES of the in-scope set (e.g.
  "harness, OR future coordinator endpoint"), not the SCOPE itself.
- The deprecate-and-add clarification — is the cosmetic-rename
  vs shape-change distinction clear, and does it foreclose a
  future SPEC version from accidentally introducing a fourth
  state value? The state enum invariant should be airtight.
- The "Buyer-controlled text sanitization" paragraph — does it
  fully describe the security contract, and is it discoverable by
  someone reading SPEC-002 cold? Should there be a forward
  reference from FR-B9 or §17?
- Cross-spec: SPEC-006 (gateway forward contract) and SPEC-007
  (explorer) — do they need to acknowledge the v1.5.1 sanitization
  contract, or is the buyer→coordinator boundary the right place
  to enforce and SPEC-006 already does its own gateway-side
  sanitization?
- Any SPEC-001 / SPEC-003 / SPEC-004 / SPEC-016 pointers that
  reference the prior R-2 sanitization wording and need updating?

## Severity rubric

- **CRITICAL**: contradiction with another normative SPEC.
- **HIGH**: ambiguity that splits implementations.
- **MEDIUM**: cross-SPEC pointer / scope gaps.
- **LOW / NIT**: phrasing, edge cases.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
