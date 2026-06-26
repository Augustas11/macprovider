# ARC-3 nested-query unwind — SECURITY-lane audit, Round 2 (closure verification)

You are the **security** lane of a three-lane audit. Round 1 produced
`specs/ARC_3_NESTED_QUERIES_SECURITY_audit.md` with 0 CRITICAL /
0 HIGH / 1 MEDIUM / 3 LOW / 5 QUESTIONS. The author applied fixes.

## Branch / commit
- Branch: `fix/arc-3-nested-queries`
- Worktree: `../macprovider-arc-3-nested-queries`
- Read: `git diff origin/main -- phase4-coordinator/ specs/SPEC-005-billing.md`

## Round-1 findings to verify closure on

- **M1 (MEDIUM).** Authenticated admin reads can starve money-path
  billing writes on the cap=1 shared pool — `/admin/ledger/providers
  ?limit=200` ran 1 aggregate + up to 200 inner `h.sum(...)`
  queries serialized on the only connection, while buyer-side
  billing writes have a 6s budget.
  - Fix expected (convergent with architect M1): fold
    `pending_payout_credits` into the providers SELECT via a
    grouped LEFT JOIN, eliminating the N+1; one statement = one
    connection acquisition instead of up to 201.
- **L1.** Providers second-pass payout sums not snapshot-consistent
  with the outer aggregate.
  - Fix expected: same JOIN fix — single SELECT = point-in-time
    consistent within the SQLite read tx.
- **L2.** Per-row pending_payout query errors silently → 0 because
  `h.sum` swallows errors.
  - Fix expected: same JOIN fix — errors now surface at the single
    SELECT through `writeError`, not silently zeroed.
- **L3.** Regression tests covered cap=1 deadlock shape but not
  security-relevant failure semantics (multi-provider payout
  values, fault-injection on second-pass queries).
  - Fix expected: at minimum, providers test now asserts multi-
    provider pending_payout values (one with payout row, one
    without — exercises the LEFT JOIN COALESCE).
- **Q1-Q5.** Five questions cross-referenced to architect lane —
  confirm those are addressed in the architect r2 round.

## Audit lenses for fresh issues (apply briefly)

- The grouped LEFT JOIN — does the inner subquery filter
  (`status = 'ready'`) cover the same set of payout rows the OLD
  per-row sum (`SELECT SUM(provider_credits) FROM
  ledger_payout_ready WHERE provider_id=? AND status='ready'`)
  did?
- The `COALESCE(pp.pending_payout, 0)` — could it mask a NULL that
  the OLD `nullInt(h.sum(...))` would have surfaced differently?
  (nullInt returns 0 on NULL; should be a no-op semantic match.)
- The new providers handler now reads two tables in one SELECT
  (`ledger_request_credits` + a grouped subquery on
  `ledger_payout_ready`). Could a concurrent write to either
  table during the SELECT produce a buyer-visible inconsistency?
  (SQLite WAL: the SELECT gets a read snapshot at first read; the
  question is whether the read snapshot covers both tables
  atomically. It does — that's the WAL invariant — but state it.)
- New SPEC-005 §10.1 paragraph documents the pool-cap operational
  invariant. Does it explicitly bind the nested-cursor + in-tx
  prohibitions, or is the prose too soft (an attacker / accidental
  contributor could read it as advisory)?

## Output format

```
CLOSURE on round-1 findings:
  M1 (MEDIUM): PASS|PARTIAL|FAIL — <one line>
  L1: ...
  L2: ...
  L3: ...
  Q1-Q5: noted as cross-lane (defer to architect)

NEW FINDINGS (round 2):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/ARC_3_NESTED_QUERIES_SECURITY_r2_audit.md`.

If all round-1 findings closed AND zero NEW C/H/M, end with:
`VERDICT: security lane READY TO MERGE`
