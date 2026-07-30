You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), CODE lane, ROUND 3.

R2 returned 0 CRITICAL / 0 HIGH / 0 MEDIUM and 1 LOW (dead-code
`same_request_count` subquery + scan + `_ = sameRequestCount`).

R3 fixes the LOW:
- Removed `same_request_count` SELECT subquery from `recovery.go`.
- Removed `sameRequestCount` from the rows.Scan target list.
- Removed `_ = sameRequestCount` placeholder.

Also (cross-lane LOW cleanup from architect):
- SPEC-007 design notes `[GAP]` for stored `attempt_n` updated to `[GAP-CLOSED]` pointing at SPEC-002 v1.5.2 / issue #168.
- SPEC-002 backfill live-safety wording: removed the "tens of ms"
  empirical claim; replaced with "operators who have measured the
  UPDATE wall-clock against their corpus on representative storage
  and observed it completes within their 6s INSERT budget MAY run
  it live; uncertain or unmeasured runs SHOULD use a maintenance
  window."
- SPEC-005 v0.3.3 change-log: added an explicit "operators MUST NOT
  execute direct `UPDATE ledger_request_credits SET quarantined=0`
  SQL" sentence to close the side-channel resolution path.

## Verify

- Dead-code removal: are there any remaining references to
  `sameRequestCount` or `same_request_count` anywhere in the
  recovery.go / billing tests / SPEC docs?
- The `recovery.go::Scan` argument count now matches the SELECT
  column count? Build + targeted test would fail if not.
- Full coordinator suite + race detector still green?
- Any other code paths that would benefit from the held-conn pattern
  applied to `Store.Insert`? (e.g. other Store methods that do
  multi-statement work over `s.db`)

## Severity rubric

- **CRITICAL**: regression.
- **HIGH**: any R1/R2 finding still open.
- **MEDIUM**: SPEC↔IMPL divergence; missed MUST.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
