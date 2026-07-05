# AUDIT_FIX_AUTOTUNE_TIMEOUT — CODE lane (R2)

You are auditing PR `fix/autotune-timeout-progress` (commit `017f505`,
was `ae23d48` at R1) from the CODE lane. This is round 2 after R1
returned `CODE-M-1` on the per-candidate timeout math.

## R1 CODE-M-1 (what was fixed)

The R1 audit correctly found that the per-candidate math was
under-counted. Stage1Prober runs THREE HTTP calls per candidate, not
two:

- `readyTimeoutSec = 120s` (MLX model load)
- prewarm `probeOnce` = `probeIdleTimeoutSec = 300s` (Track A3 at
  `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift:474`)
- measured replicate `probeOnce` = `probeIdleTimeoutSec = 300s` per
  replicate (default `stage1Replicates = 1` from
  `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:35-37`)

Per-candidate worst case = 120 + 300 + 300 = **720s**.
3-candidate worst case = **2160s**.

## R2 changes to audit

1. `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:36`
   raises `processTimeout` from `1800` (30 min) to `2700` (45 min).
2. Rationale comment at
   `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:4-35`
   updated to reflect the corrected per-candidate math and reference
   the CLI's outer `AutotuneCommand.maxDuration = 7200s` boundary.
3. `phase3-binary/app/Tests/MalibuTests/AutotuneRecommendationRunnerTimeoutTests.swift:31`
   raises `cliPerCandidateWorstCaseSec` from `420` to `720`.

## Focus this round

- Is `processTimeout = 2700s` (45 min) enough headroom above the
  strict 3-candidate worst case of 2160s to survive minor CLI-side
  drift (e.g. an extra HTTP retry on `waitForReady`)?
- Does the R2 rationale comment now correctly describe the CLI's
  three timing sources per candidate (readyTimeout + prewarm probe +
  measured probe), or did I still miss a step in
  `Stage1Iterator.swift`?
- Do the pinning tests
  (`AutotuneRecommendationRunnerTimeoutTests`) with the new 720s
  constant still cover the invariant, or does the 60-min upper-bound
  test now leave too little margin between the cap (2700s) and the
  ceiling (3600s)?
- The polling loop `Thread.sleep(forTimeInterval: 0.05)` inside a
  `while process.isRunning && Date() < deadline` in
  `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:93-95`
  now runs up to 2700s of wall-clock. Is this still tolerable, or
  does the 20×/sec wake-up start being a measurable CPU/battery cost
  over 45 minutes on Apple silicon?
- Does the raised timeout expose any new resource-management issue
  (file handles, keychain sessions, process-group orphans) that
  the R1 30s value previously masked and R1 didn't catch?
- Are there any other callers of `AutotuneRecommendationRunner.run`
  that would be surprised by a 90× longer max wait vs the original
  30s (e.g. Swift Concurrency task priority, test injection paths)?

Do NOT recommend adding progress UI or stderr tailing — those are
explicitly deferred to a follow-up PR.
Do NOT re-audit visibility (`static let`) — that was accepted at R1.

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
