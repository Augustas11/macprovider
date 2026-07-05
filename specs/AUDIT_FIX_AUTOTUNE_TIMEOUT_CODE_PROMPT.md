# AUDIT_FIX_AUTOTUNE_TIMEOUT — CODE lane

You are auditing PR `fix/autotune-timeout-progress` (commit `ae23d48`) from the
CODE lane.

Focus:

- Is the 1800-second (30-minute) budget correctly rationalised against the
  CLI's own timeouts (`Stage1Prober.readyTimeoutSec=120`,
  `probeIdleTimeoutSec=300` in
  `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`)?
- Does the visibility change from `private static let` to `static let`
  create any test-only or unintended-consumer coupling risk?
- Are the three new tests
  (`AutotuneRecommendationRunnerTimeoutTests`) actually asserting the
  invariant they claim to, with the correct math?
- Is the polling loop in `runProcess` (Thread.sleep 0.05s in a while loop)
  still tolerable at a 1800s wall-clock — could it burn measurable CPU
  in the (worst case) 20-minute idle wait?
- Does the raised timeout expose any new resource-management issue
  (file handles, keychain sessions, process-group orphans) that
  30s previously masked?
- Are there any other callers of `AutotuneRecommendationRunner.run`
  that would be surprised by a 60× longer max wait (e.g. Swift
  Concurrency task priority, test injection paths)?

Do NOT recommend adding progress UI or stderr tailing — those are
explicitly deferred to a follow-up PR.

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
