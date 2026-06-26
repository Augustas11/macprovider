# ARC-3 nested-query unwind — CODE-lane audit, Round 2 (closure verification)

You are the **code** lane of a three-lane audit. Round 1 produced
`specs/ARC_3_NESTED_QUERIES_CODE_audit.md` with 0 CRITICAL / 0 HIGH /
1 MEDIUM / 2 LOW / 1 QUESTION. The author has applied fixes. Verify
closure and re-audit fresh for new issues introduced by the fixes.

## Branch / commit
- Branch: `fix/arc-3-nested-queries`
- Worktree: `../macprovider-arc-3-nested-queries`
- Read: `git diff origin/main -- phase4-coordinator/ specs/SPEC-005-billing.md`

## Round-1 findings to verify closure on

- **C1 (MEDIUM).** `rebuildLegacyConfigSnapshots` cap=1 regression
  test did not actually exercise the legacy nested-cursor path.
  - Fix expected: plant a UNIQUE(config_hash) index BEFORE calling
    rebuildLegacyConfigSnapshots so the inner PRAGMA index_info
    runs after the outer cursor closes; also verify the rebuild
    drops the index.
- **L1.** buyerEquivalentCredits deadlock regression used only one
  request_log row.
  - Fix expected: multi-row scan + at least one 503 + malformed-ts
    row to lock the r2 timestamp-filter behavior.
- **L2.** buyerEquivalentCredits test comment described parsed-time
  even though r2 carries raw tsText.
  - Fix expected: comment now describes the raw-tsText + filter-
    before-parse shape.
- **Q1.** requestlog.OpenStore comment mentioned "admission" without
  an admission package existing.
  - Fix expected: "admission" removed; comment reads requestlog +
    billing only.

## NOTE: bigger refactor landed in this round

Per the convergent security + architect MEDIUMs (admin reads
starving money-path at cap=1 + the N+1 anti-pattern entrenchment),
the `providers` handler was refactored AGAIN from two-pass to a
single grouped LEFT JOIN. That's a larger code change than just the
round-1 test-fix scope — apply the full code-lane audit to it as a
fresh diff:
- Pagination semantics still equivalent to origin/main?
- LEFT JOIN preserves the COALESCE-to-zero shape when no
  ledger_payout_ready row exists?
- Aggregated subquery (`SELECT provider_id, SUM(...) GROUP BY
  provider_id`) — does it correctly handle providers that appear in
  ledger_payout_ready but not in ledger_request_credits (the outer
  table) and vice versa? Trace the join semantics.
- `rows.Err()` check added at end of the new loop — correct?
- Any error-handling path leaking the cursor?

## Audit lenses for fresh issues (apply briefly)

- The new `providers` handler is now a single query; the
  `rebuildLegacyConfigSnapshots` two-pass + the `buyerEquivalent-
  Credits` two-pass remain. Did the round-2 changes accidentally
  introduce drift to either of those?
- The post-condition assertion in the new
  TestRebuildLegacyConfigSnapshots test (`pragma_index_list` count
  check) — is it actually verifying the rebuild dropped the index?
- The `request_log` INSERT in the new
  TestBuyerEquivalentCredits 503-malformed-ts case includes all
  NOT NULL columns?

## Output format

```
CLOSURE on round-1 findings:
  C1 (MEDIUM): PASS|PARTIAL|FAIL — <one line>
  L1: ...
  L2: ...
  Q1: ...

NEW FINDINGS (round 2):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write the report to
`specs/ARC_3_NESTED_QUERIES_CODE_r2_audit.md`.

If all round-1 findings closed AND zero NEW CRITICAL/HIGH/MEDIUM,
end with: `VERDICT: code lane READY TO MERGE`
