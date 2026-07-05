# AUDIT_FIX_AUTOTUNE_TIMEOUT — ARCHITECT lane (R5, final value)

You are auditing PR `fix/autotune-timeout-progress` (commit `ea4f6c0`)
from the ARCHITECT lane. Round 5 refire because the final timeout
value is materially different from what R1 audited.

## Value history for context

R1 audited `processTimeout = 1800` (30 min). Convergence rounds
raised this through 2700 → 7260s. Final value: **7260s (2h1m)**.

CODE lane discovered during convergence that the CLI's `--recommend`
path does NOT enforce its declared `maxDuration=7200s` (only the
non-recommend path installs a deadline at
`phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:157-161`).
So 7260s is the App-side authoritative ceiling, NOT a fallback under
a CLI-enforced cap.

## Focus this round

- Is 7260s (2h1m) the RIGHT App-side ceiling given the CLI has no
  independent bound protecting the user? Or does 2h push the user
  past spinner-fatigue territory where they'll quit the app before
  autotune returns, making the value effectively useless?
- Should this PR ALSO wire `maxDuration` enforcement into the CLI
  `--recommend` path so both ends have a bound, or is that
  correctly deferred as follow-up? Consider the SPEC-026 §6.1
  state-machine contract: is `.autotuning → .failed(timedOut)` a
  reasonable terminal for 2h1m, or should the copy be updated to
  reflect the longer wait?
- The rationale comment
  (`phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:4-51`)
  cites "10 candidates × 720s = 7200s worst case" as the floor
  rationale. Is 10 candidates a defensible upper bound on catalog
  cardinality, or should the App instead depend on a CLI-signaled
  progress heartbeat (deferred)?
- The tests
  (`phase3-binary/app/Tests/MalibuTests/AutotuneRecommendationRunnerTimeoutTests.swift`)
  pin `realisticWorstCaseAutotuneSec = 7200s` and
  `untenableSpinnerCeilingSec = 2.5h`. Are those constants named
  well enough that a future dev bumping either can see the impact?
- The BUILD prompt scope-out named "heartbeat protocol on CLI
  stderr" as follow-up. Now that we've iterated through 4 rounds,
  is this PR the right shape to ship (bump-the-constant) or should
  it evolve to also add a `runAutotune(timeout:)` injection point
  for the future heartbeat work?
- Should the 2.5h ceiling really allow a 2.5h spinner, or is that
  now just permission to defer building progress UI indefinitely?

Do NOT recommend new coordinator surface or new SPECs.
Do NOT flag R2 CODE-M-2 (orphan child subprocess) — deferred to
CLI-side follow-up.

## Referenced context

Common context: `specs/AUDIT_FIX_AUTOTUNE_TIMEOUT_COMMON.md`.

## Output format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity: `ARCH-C-1`,
`ARCH-H-1`, `ARCH-M-1`, `ARCH-L-1`, etc. Each finding must cite
the file:line and concrete evidence.
