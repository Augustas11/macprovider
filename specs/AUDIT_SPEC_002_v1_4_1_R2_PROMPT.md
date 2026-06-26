# SPEC-002 v1.4.1 Audit Prompt — Round 2 (closure verification)

You are a SPEC auditor running ROUND 2 on the SPEC-002 v1.4.1 additive
delta. Round 1 produced `specs/SPEC-002-v1-4-1-audit.md` with 0 CRITICAL,
0 HIGH, 3 MEDIUM, 2 LOW, 2 QUESTIONS. The author has fixed the findings.
Your job is **closure verification**, not a fresh audit:

1. For each round-1 finding (M1, M2, M3, L1, L2, Q1, Q2), state PASS /
   PARTIAL / FAIL based on the current `specs/SPEC-002-coordinator.md`
   text on the branch.
2. Re-audit fresh — surface any NEW issue the v1.4.1 delta introduces
   that round 1 did not flag (especially: regressions caused by the
   fixes, ambiguities introduced by the new wording).

## Branch / commit
- Branch: `fix/gateway-poolz-auth-state`
- Worktree: `../macprovider-gateway-poolz-auth-state`
- Read: `git diff origin/main -- specs/SPEC-002-coordinator.md`

## Round-1 findings to verify closure on

- **M1.** `mint_failed` documented as `/poolz` row enum even though
  current WS flow never publishes such a row.
  - Fix expected: state that `mint_failed` is a defined/reserved
    AuthState not currently emitted on registered `/poolz` rows, OR
    change the coordinator to publish an observable row.
- **M2.** Aggregation rule omitted provider-count counters that the
  gateway already excludes.
  - Fix expected: extend exclusion rule to top-level
    `Pool.TotalProviders` and per-model `ProviderCount`, or define
    them as raw operator-visible counts and align the IMPL.
- **M3.** Summary-fallback ambiguity — coordinator `summary` could
  reintroduce excluded rows.
  - Fix expected: explicit rule that auth-state-aware consumers MUST
    NOT use coordinator `summary` to repopulate excluded counters
    when `/poolz.pool` rows are present.
- **L1.** SPEC-003 dependency line misattributed full enum to v0.8.3.
  - Fix expected: split provenance — base enum from v0.8.3,
    `mint_failed` from v0.8.4.
- **L2.** SPEC-006 stale for new `/v1/status` aggregation invariant.
  - Fix expected: a pointer / deferred follow-up.
- **Q1.** What does `Pool.TotalProviders` on `/v1/status` mean?
  - Resolution expected: explicit decision (buyer = routable-eligible;
    operator = raw).
- **Q2.** Is `mint_failed` operator-visible on `/poolz`?
  - Resolution expected: explicit answer about current behavior.

## Audit lenses for fresh issues (apply briefly)

- Consistency: does the new aggregation rule and the summary-fallback
  prohibition agree with the FR-O2 example and the `auth_state`
  paragraph below it?
- Wording: is "buyer-facing" / "operator-facing" usage tight enough
  that an implementer reading only v1.4.1 knows which surface a given
  counter belongs to?
- Cross-version: did the change-log entry style still match v1.4.0
  and v1.4 conventions?

## Output format

```
CLOSURE on round-1 findings:
  M1: PASS|PARTIAL|FAIL — <one line>
  M2: ...
  M3: ...
  L1: ...
  L2: ...
  Q1: ...
  Q2: ...

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
`specs/SPEC-002-v1-4-1-r2-audit.md`.

If all round-1 findings closed (PASS or PARTIAL with explicit
justification) AND zero NEW CRITICAL/HIGH/MEDIUM, end the report with:
`VERDICT: READY TO LOCK v1.4.1`
