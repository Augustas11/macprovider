# AUDIT_FIX_AUTOTUNE_TIMEOUT — CODE lane (R4)

You are auditing PR `fix/autotune-timeout-progress` (commit `d96ee95`)
from the CODE lane. This is R4 after R3 returned one MEDIUM finding.

## R3 finding recap

- **R3 CODE-M-1**: The R3 rationale claimed 7260s mirrored CLI's
  outer `maxDuration=7200s`, but the `--recommend` code path does
  NOT enforce `maxDuration`. `runAutotuneRecommend()` at
  `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:131-139`
  returns before the deadline is created at :157-161. So 7260s is
  the App-side authoritative ceiling, not a fallback under a
  CLI-enforced cap. Fixed in R4 by rewriting rationale + tests to
  describe the timeout as an App-owned ceiling with 7200s realistic
  worst case as the floor.

## R4 changes to audit

1. `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:26-51`
   rationale rewritten. Value unchanged at 7260s. Now explains 4
   reasons: below 10-candidate × 720s worst case, above empirical
   2-5 min median, aligned with CLI's declared (unenforced)
   maxDuration for future coincidence, below 2.5h untenable-spinner
   ceiling.
2. `phase3-binary/app/Tests/MalibuTests/AutotuneRecommendationRunnerTimeoutTests.swift`
   rewritten again. Two tests:
   - `testProcessTimeoutCoversRealisticWorstCaseAutotune` — floor is
     `realisticWorstCaseAutotuneSec = 7200s` (10 candidates × 720s
     per candidate).
   - `testProcessTimeoutIsNotUntenable` — ceiling
     `untenableSpinnerCeilingSec = 2.5h`.

## Focus this round

- Is the R4 rationale comment now accurate about the CLI's
  `--recommend` path NOT enforcing `maxDuration`? Verify against
  `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:131-161`
  and `AutotuneRecommend.swift` (specifically the entry point to
  `AutotuneRecommendationBenchmarker.benchmarks`).
- Is `realisticWorstCaseAutotuneSec = 7200s` (10 candidates × 720s
  per candidate) a defensible floor? Are there catalog configs that
  could plausibly exceed 10 candidates, making 7200s too low?
- Is the `untenableSpinnerCeilingSec = 2.5h` ceiling appropriate,
  or should it be lower (e.g. 2h) given the CLI has no independent
  bound to protect the user?
- Does the polling loop
  `Thread.sleep(forTimeInterval: 0.05)` at
  `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:120-122`
  running up to 7260s of wall-clock (~145K wake-ups over 2h1m)
  produce measurable CPU/battery cost on Apple silicon, or is this
  still acceptable? Consider whether it should wait on the process
  handle instead — but that is out of scope unless the current
  poll is materially problematic.
- Are there any other consumers of
  `AutotuneRecommendationRunner.processTimeout` (test injection,
  alternate entry points) that would break with the 7260s value?

Do NOT flag R2 CODE-M-2 (orphan child subprocess on SIGTERM) — it
is explicitly deferred to a CLI-side follow-up PR.
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
