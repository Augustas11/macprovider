# Phase 5 Gateway `auth_state` IMPL Audit Prompt — Round 2 (closure verification)

You are an IMPL auditor running ROUND 2 on the gateway-side `/poolz`
decode + capacity aggregation change. Round 1 produced
`specs/PHASE5_GATEWAY_AUTH_STATE_IMPL_audit.md` with 0 CRITICAL, 0 HIGH,
1 MEDIUM, 2 LOW, 1 QUESTION. The author has fixed the findings. Your job
is **closure verification**, not a fresh audit:

1. For each round-1 finding (M1, L1, L2, Q1), state PASS / PARTIAL /
   FAIL based on the current branch state.
2. Re-audit fresh — surface any NEW issue the fix introduces.

## Branch / commit
- Branch: `fix/gateway-poolz-auth-state`
- Worktree: `../macprovider-gateway-poolz-auth-state`
- Read: `git diff origin/main -- phase5-gateway/`

## Round-1 findings to verify closure on

- **M1.** Summary fallback can reintroduce excluded ready capacity
  after all detailed rows are skipped.
  - Fix expected: gate the fallback on `len(poolz.Pool) == 0` (no
    detailed rows present) instead of
    `out.Pool.TotalProviders == 0` (no rows after filtering). Add a
    regression test with all-bearerless pool + non-zero
    `summary.ready`.
- **L1.** `mint_failed` and unknown future auth states not pinned by
  tests.
  - Fix expected: table test covering empty / `bearer_validated` /
    `self_minted` / `mint_failed` / unknown / `bearerless_duplicate`.
- **L2.** Gateway mirrors coordinator enum with an unguarded string
  literal.
  - Fix expected: extract a named const + a drift-prevention test
    pinning the const value to the SPEC-002 v1.4.1 normative literal.
- **Q1.** Should `Pool.TotalProviders` be a routable count or a
  present-provider count?
  - Resolution expected: documented in SPEC-002 v1.4.1 round-2
    rewrite (this is a SPEC question; IMPL audit verifies IMPL
    matches whatever the SPEC says).

## Audit lenses for fresh issues (apply briefly)

- Does the new fallback gate (`len(poolz.Pool) == 0`) handle ALL the
  pre-existing scenarios the old gate handled? (Coordinator returns
  only summary block; coordinator returns empty pool array.)
- Does the new table test actually exercise the IMPL — e.g. is it
  asserting Ready correctly per case?
- Is the drift-prevention test on the const useful, or is it tautology
  (asserting the const equals the same literal)?

## Output format

```
CLOSURE on round-1 findings:
  M1: PASS|PARTIAL|FAIL — <one line>
  L1: ...
  L2: ...
  Q1: ...

NEW FINDINGS (round 2):
CRITICAL (N):
  ...
HIGH (N):
  ...
MEDIUM (N):
  ...
LOW (N):
  ...
QUESTIONS (N):
  ...
```

Use CRITICAL/HIGH/MEDIUM/LOW severity. Write the round-2 report to
`specs/PHASE5_GATEWAY_AUTH_STATE_IMPL_r2_audit.md`.

If all round-1 findings closed AND zero NEW CRITICAL/HIGH/MEDIUM, end
the report with:
`VERDICT: READY TO MERGE phase5-gateway auth_state IMPL`
