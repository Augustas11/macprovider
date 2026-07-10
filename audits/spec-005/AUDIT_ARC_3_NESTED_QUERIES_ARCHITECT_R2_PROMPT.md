# ARC-3 nested-query unwind — ARCHITECT-lane audit, Round 2 (closure verification)

You are the **architect** lane of a three-lane audit. Round 1 produced
`specs/ARC_3_NESTED_QUERIES_ARCHITECT_audit.md` with 0 CRITICAL /
0 HIGH / 1 MEDIUM / 2 LOW / 1 QUESTION. The author applied fixes.

## Branch / commit
- Branch: `fix/arc-3-nested-queries`
- Worktree: `../macprovider-arc-3-nested-queries`
- Read: `git diff origin/main -- phase4-coordinator/ specs/SPEC-005-billing.md`

## Round-1 findings to verify closure on

- **M1 (MEDIUM).** Providers endpoint preserved a directly-joinable
  N+1 aggregate as the new nested-query pattern.
  - Fix expected: fold `pending_payout_credits` into the SELECT via
    a grouped LEFT JOIN on `ledger_payout_ready`. Convergent with
    security M1.
- **L1.** Connection-cap policy was code-consistent but under-
  documented as a cross-store invariant — three sites set the cap
  locally, SPEC-005 didn't mention it.
  - Fix expected: one-line SPEC-005 §10.1 operational note that
    coordinator SQLite write handles use `MaxOpenConns(1)` +
    `MaxIdleConns(1)`, plus the nested-cursor + in-tx prohibitions.
- **L2.** Requestlog cap assertion lived in billing tests instead
  of the requestlog package.
  - Fix expected: pool-stats assertion moved into
    `internal/requestlog/store_test.go` next to the constructor
    that owns the cap. The nested-cursor regression tests stay in
    `internal/billing/` (they exercise billing-side behavior).
- **Q1.** Should coordinator adopt the gateway's separate read-only
  handle pattern if explorer/admin read traffic becomes high-volume?
  - Resolution: deferred per the audit's own suggestion (out of
    scope for this PR; revisit if production traffic motivates it).
  - Verify: is the deferral mentioned in the PR description /
    follow-up tracking, or is it just dropped on the floor?

## Audit lenses for fresh issues (apply briefly)

- The SPEC-005 §10.1 addition — is it placed correctly (next to the
  existing WAL clause), or does it deserve its own subsection?
- The grouped LEFT JOIN in providers — is it the architectural
  RIGHT shape, or does it just look like a SQL fix? (I.e. does
  this preserve module boundaries or smuggle ledger_payout_ready
  schema knowledge into the providers handler?)
- The `snapshotQueryer` interface stays from round 1 — does
  round-2's broader refactor change whether it's at the right
  altitude?
- Did any of the round-1 LOWs / QUESTIONS get inadvertently
  enshrined as anti-patterns in round 2? (E.g. the two-pass
  pattern is now used in only TWO sites — rebuildLegacyConfig +
  buyerEquivalentCredits — instead of three. Cleaner architectural
  story.)

## Output format

```
CLOSURE on round-1 findings:
  M1 (MEDIUM): PASS|PARTIAL|FAIL — <one line>
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

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/ARC_3_NESTED_QUERIES_ARCHITECT_r2_audit.md`.

If all round-1 findings closed AND zero NEW C/H/M, end with:
`VERDICT: architect lane READY TO MERGE`
