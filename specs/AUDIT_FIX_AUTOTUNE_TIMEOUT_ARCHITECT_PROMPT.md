# AUDIT_FIX_AUTOTUNE_TIMEOUT — ARCHITECT lane

You are auditing PR `fix/autotune-timeout-progress` (commit `ae23d48`) from
the ARCHITECT lane.

Focus:

- Is 1800 s (30 min) the RIGHT number, or should it be pinned to the
  CLI's own budget (`Stage1Prober.readyTimeoutSec × N + Stage1Prober.probeIdleTimeoutSec × N`)
  in code so it drifts together?
- Should the App-side timeout live in the App at all, or should the
  CLI signal completion / progress and the App just wait indefinitely
  with a UI cancel? Consider the SPEC-026 §6.1 state-machine
  contract.
- Is there a better place to draw the "give up on autotune" line —
  e.g. a heartbeat protocol on the CLI's stderr, so a wedged
  subprocess is caught faster than 30 minutes but a healthy one gets
  unlimited runway?
- The BUILD prompt scope-out named this as follow-up. Is now the right
  time to just bump the constant, or should this PR also open the
  door for the follow-up work by adding a `runAutotune(timeout:)`
  parameter for future injection?
- Does 30 min (or the 60-min upper bound in tests) exceed the
  spinner-fatigue threshold beyond which users will assume the app is
  hung and quit? Is that acceptable for this PR, or does the fix
  create a NEW UX problem (silent multi-minute spinner) worse than
  the one it's solving?
- Is `.failed(autotuning, retryable: true, ...)` the right terminal
  state for a 30-min timeout, or should the message copy be updated
  to reflect the longer wait (currently the copy is generic)?
- Are the new tests (`AutotuneRecommendationRunnerTimeoutTests`)
  correctly modeling the CLI's budget — specifically, does the
  `cliPerCandidateWorstCaseSec = 420` constant drift risk break
  the test's usefulness if SPEC-023's timings change?

Do NOT recommend new coordinator surface, new SPECs, or expanding
this PR's scope beyond the timeout constant + tests.

## Referenced context

Common context: `specs/AUDIT_FIX_AUTOTUNE_TIMEOUT_COMMON.md`.

## Output format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity: `ARCH-C-1`,
`ARCH-H-1`, `ARCH-M-1`, `ARCH-L-1`, etc. Each finding must cite the
file:line and concrete evidence.
