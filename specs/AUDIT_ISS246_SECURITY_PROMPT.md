# AUDIT — Issue #246 — SECURITY lane

## Goal
Adversarial SECURITY audit on commit `707ee49` (branch `fix/iss246-explorer-helpers-index-plan`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `phase5-gateway/internal/storage/sqlite/explorer.go::explorerDetailWhere`
- 5 refactored helpers + their callers (`ExplorerBuyerDetail` lines 170-214, `ExplorerSessionDetail` lines 335-360)
- New `iss246_explain_test.go`

## Threat model

The helpers serve the operator-only `/admin/explorer/sessions/...` and `/admin/explorer/buyers/...` endpoints. Authentication is bearer-gated; the threat is NOT random web traffic. The threats are:

1. **SQL injection via the new WHERE-building path** — `explorerDetailWhere` returns a string that's `+`-concatenated into the SQL. If any caller-controlled string reaches the clause text (not just `?` placeholders), it's a vector.
2. **Predicate-bypass / cross-account leak** — pre-#246 the `(? = '' OR col = ?)` shape guaranteed that if a caller passed `accountID == ""` the helper would scan all rows. Post-#246 the empty-account branch drops the account_id predicate entirely. Is there any caller path that ends up with `accountID == ""` UNINTENTIONALLY (e.g. a typo, a missing nil check) when the operator meant to scope to a specific account? Such a regression would return ALL accounts' data via a 200 instead of returning no data.
3. **Order-of-checks**: at the handler layer (`router/explorer.go::handleExplorerSessionDetail`), the 409 ambiguity probe runs BEFORE the helper fetches details. Verify the v0.4 contract (ambiguity probe returns ALL matching accounts on the unscoped path) still works post-#246; the probe doesn't go through `explorerDetailWhere` but its callers do.
4. **Edge: all-empty WHERE** — `explorerDetailWhere("", "", time.Time{}, time.Time{})` returns `("", nil)`. The caller appends `LIMIT ?` and runs `SELECT ... LIMIT ?` with no WHERE at all. Is there a caller path that hits this? If yes, it's an unbounded read (LIMIT-capped but cross-account). Find it or rule it out.
5. **Time-zone / parsing**: pre-#246, `timeParam` returned `encodeTime(t)` for non-zero times AND `""` for zero. Post-#246, `encodeTime` is called directly only when `!t.IsZero()`. Confirm no zero-time path slips through.

## Lens — SECURITY

For each of the 5 helpers + each caller, trace:
- Where does `accountID` come from? Can it be empty unintentionally?
- Where does `requestID` come from? Can it be empty unintentionally?
- Is the test coverage adequate for the empty-account branch (most-dangerous regression surface)?

Specific must-check:
1. `ExplorerBuyerDetail` (line ~170): passes `accountID` from the URL path. If a caller could somehow trigger this with `accountID == ""` we'd return all buyers' usage. Is there a guard?
2. `ExplorerSessionDetail` (line ~335): passes `accountID` from `?account_id=` query param (may be ""). Verify the unscoped 200 path here is bounded by `requestID` (which IS asserted non-empty by the v0.5 untyped-400 gate).
3. The new EXPLAIN test does NOT seed rows — it tests only the QUERY PLAN. Should there be a runtime test asserting that the empty-account branch returns ONLY the rows for the supplied request_id (not all accounts' rows)?

## Out of scope

- Code style (CODE lane)
- Index/plan choice optimality (ARCHITECT lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk: <why, cite threat model>
Recommendation: <concrete fix>
```

End: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M: `ACCEPT — 0 C/H/M`.
