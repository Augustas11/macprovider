# AUDIT_FIX_AUTOTUNE_TIMEOUT — CODE lane (R3)

You are auditing PR `fix/autotune-timeout-progress` (commit `8063455`)
from the CODE lane. This is R3 after R2 returned two MEDIUM findings.

## R2 findings recap

- **R2 CODE-M-1**: `--recommend` iterates all non-blocked
  RAM-eligible catalog rows, not a fixed 2-3. Per-candidate × N
  under-counts on some tier. Fixed in R3 (this commit) by
  eliminating candidate-cardinality guessing.
- **R2 CODE-M-2**: `--recommend` path in CLI does not install signal
  handlers, so `process.terminate()` from App-side orphans the child
  `serve` subprocess. This is a **pre-existing CLI-side bug** at
  `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:131-137,157-161`
  that is unaffected by any App-side timeout value. **Deferred to
  follow-up PR** (would require CLI-side signal handler install).
  Documented in PR body.

## R3 changes to audit

1. `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:52`
   sets `processTimeout = 7260s` (CLI's own outer `maxDuration =
   7200s` + 60s grace).
2. Rationale comment at
   `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:4-51`
   rewritten to explain why candidate-cardinality math was the wrong
   frame and why mirroring CLI's outer budget is the only principled
   ceiling.
3. `phase3-binary/app/Tests/MalibuTests/AutotuneRecommendationRunnerTimeoutTests.swift`
   entirely rewritten. Two tests now:
   - `testProcessTimeoutMirrorsCLIOuterBudgetPlusGrace` — invariant
     is `processTimeout ≥ cliMaxDurationSec (7200) + cliDeadlineGraceSec (60)`.
   - `testProcessTimeoutIsNotUnbounded` — upper bound raised from 1h
     to 2.5h to accommodate the new 7260s value while still catching
     runaway drift.

## Focus this round

- Is `processTimeout = 7260s` (CLI maxDuration + 60s grace) the
  right ceiling, or does the grace window need to be larger (e.g.
  should we let the CLI have more time to write its exit JSON and
  drain stdout before we SIGTERM it)?
- Is mirroring `AutotuneCommand.maxDuration = 7200` from another
  SwiftPM target as a hardcoded 7200 constant in the App tests an
  acceptable coupling, or does this need a shared constant module?
- Does the polling loop `Thread.sleep(forTimeInterval: 0.05)` at
  `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:120-122`
  running up to 7260s of wall-clock (145,200 wake-ups over 2h1m)
  become a measurable CPU/battery cost on Apple silicon, or is this
  still noise? If it IS a concern, is the fix in scope for this PR
  or should it wait for the heartbeat protocol follow-up?
- Is the R3 rationale comment accurate about the `--recommend` path
  iterating "every non-blocked RAM-eligible catalog row" — verify
  against
  `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:1750-1937`.
- Does the 2.5h upper-bound test guard leave enough room for CLI's
  maxDuration to be raised without requiring test churn, or is
  there a case where a 3h CLI budget would be legitimate?
- Are there any other callers of `AutotuneRecommendationRunner.run`
  (test injection paths, alternate entry points) that would be
  surprised by the raised timeout?

Do NOT flag R2 CODE-M-2 (orphan child subprocess) again — it is
explicitly deferred to a CLI-side follow-up PR as documented above.
Do NOT recommend adding progress UI or stderr tailing.
Do NOT re-audit visibility (`static let`) — accepted at R1.

## Referenced context

Common context: `specs/AUDIT_FIX_AUTOTUNE_TIMEOUT_COMMON.md`.

## Output format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity: `CODE-C-1`,
`CODE-H-1`, `CODE-M-1`, `CODE-L-1`, etc. Each finding must cite the
file:line and concrete evidence.
