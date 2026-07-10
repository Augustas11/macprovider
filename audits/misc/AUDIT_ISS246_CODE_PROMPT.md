# AUDIT — Issue #246 — CODE lane

## Goal
CODE-quality audit on commit `707ee49` (branch `fix/iss246-explorer-helpers-index-plan`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `phase5-gateway/internal/storage/sqlite/explorer.go`
  - new `explorerDetailWhere(accountID, requestID, from, to)` helper (~line 880)
  - 5 refactored helpers: `explorerUsageEvents`, `explorerQuotaReservations`, `explorerConcurrencyReservations`, `explorerFeedbackEvents`, `explorerAuditEvents` (lines ~704-840)
  - confirm `timeParam` is removed (no remaining callers)
- `phase5-gateway/internal/storage/sqlite/iss246_explain_test.go` (new) — `TestExplorerDetailHelpers_UnscopedUsesIndex`

## Context

Pre-#246: each of the 5 helpers used the `(? = '' OR col = ?)` optional-predicate pattern repeated 4× (account_id, request_id, created_at >=, created_at <) so one prepared statement could serve both scoped and unscoped paths. SQLite cannot use a normal index plan against compound `OR` predicates — EXPLAIN QUERY PLAN reported `SCAN`.

Post-#246: a single `explorerDetailWhere` helper builds the WHERE clause + args slice from only the parameters whose value is non-empty / non-zero. SQLite plans against the available indexes (composite PK / `idx_*_request` / `idx_*_account_*`).

## Lens — CODE

- House-style fit: do the 5 refactored helpers all share the same shape (`where, args := explorerDetailWhere(...); args = append(args, limit); s.db.QueryContext(ctx, "... " + where + " ...", args...)`)? Any divergence?
- Concrete-string SQL via Go `+` concatenation — the where clause is built from a hard-coded `clauses []string` slice and `strings.Join` (no user input). Verify there's no path from caller-supplied data into the SQL string itself (only into `?` placeholders).
- `args = append(args, limit)` — this APPENDS to the slice returned by `explorerDetailWhere`. If that slice has remaining capacity, the append is in-place; if the caller later passed `args` to a goroutine and another caller mutated it, sharing risk? In this code each helper's `args` is local and never escapes, so fine. Confirm.
- `timeParam` deletion — grep `phase5-gateway/` for any straggling callers.
- Naming: `where` vs `whereClause` — bikeshed; flag if you disagree.
- Test quality: does the new EXPLAIN test actually exercise the produced query shape, or does it just hard-code a similar shape? Verify the test's SQL matches what `explorerDetailWhere(accountID="", requestID=X, from=zero, to=zero)` would emit.
- Branch coverage on `explorerDetailWhere`: the test covers `accountID=="" AND requestID!=""`. What about `accountID!="" AND requestID==""` (buyer-detail path) and the all-empty case? Are existing tests in other files exercising those?

## Out of scope

- Security (SECURITY lane) — SQL injection, predicate ordering bypass
- Index choice / SPEC alignment (ARCHITECT lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk: <why>
Recommendation: <concrete fix>
```

End: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M: `ACCEPT — 0 C/H/M`.
