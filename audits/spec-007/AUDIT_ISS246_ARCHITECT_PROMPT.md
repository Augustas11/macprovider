# AUDIT — Issue #246 — ARCHITECT lane

## Goal
ARCHITECT / index-plan-soundness audit on commit `707ee49` (branch `fix/iss246-explorer-helpers-index-plan`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `phase5-gateway/internal/storage/sqlite/explorer.go::explorerDetailWhere` + 5 refactored helpers
- `phase5-gateway/internal/storage/sqlite/migrate.go` — indexes available on the 5 tables (idx_usage_request, idx_quota_request, idx_concurrency_request, idx_feedback_request, idx_audit_request; plus the composite-PK indexes)
- `specs/SPEC-007-explorer.md` §6.4 + §5.6 — the window-contract / index-bounded promises

## Background

SPEC-007 v0.4 (#231) added `idx_*_request` on the 5 detail tables to fix a SCAN class on the ambiguity probe. The downstream detail-fetch helpers retained the `(? = '' OR col = ?)` optional-predicate shape, which prevented SQLite from using those indexes on the unscoped session-detail 200 path. Issue #246 closes that gap.

## Lens — ARCHITECT

- **Index-plan completeness**: the new EXPLAIN test exercises `accountID="" AND requestID!=""` (idx_*_request). What about the other shapes?
  - `accountID!="" AND requestID!=""` should plan against the composite PK on tables that have one. Does it? Verify by EXPLAIN on the actual SQL `WHERE account_id = ? AND request_id = ?`.
  - `accountID!="" AND requestID==""` (buyer-detail) should plan against `idx_*_account_*` if one exists, else fall back to SCAN with a time filter. Is the test coverage adequate? (Not blocking — the issue body explicitly scopes the test to the unscoped session-detail path.)
- **Index naming convention**: idx_quota_request, idx_concurrency_request, idx_feedback_request, idx_audit_request, idx_usage_request — all 5 share the `idx_<table>_request` shape. Codifying that convention in SPEC-007 §6.4 (or §7) would make future detail-fetch additions discover it. Worth proposing.
- **Helper placement**: `explorerDetailWhere` lives at the bottom of `explorer.go` near `encodeListID`. Is that the right home, or should it live in a separate file (e.g. `explorer_query.go`) given that it might grow as more detail tables are added?
- **API shape**: `(string, []any)` return — could equivalently be a struct or an exported builder. Bikeshed but flag if you think it should be a named type.
- **SPEC alignment**: §6.4 v0.5 says the unscoped path is "index-bounded" (paraphrasing). Does this PR's change need to update SPEC text to name the specific indexes / `idx_*_request` invariant, or is that overspecification?
- **Generality of explorerDetailWhere**: the helper is hard-coded to 4 predicates (account_id, request_id, created_at >=, created_at <). Future detail tables might want more (e.g. status). Is the design extensible enough, or does it lock in a shape?
- **Test architecture**: the EXPLAIN test uses ad-hoc SQL that mirrors what `explorerDetailWhere` produces. If `explorerDetailWhere` changes its SQL shape, the test won't catch it. Should the test instead build the SQL via the helper itself + EXPLAIN it? (More principled but more coupling.)

## Out of scope

- CODE style (CODE lane)
- SQL injection / predicate bypass (SECURITY lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk / Concern: <why, architectural>
Recommendation: <concrete fix>
```

End: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M: `ACCEPT — 0 C/H/M`.
