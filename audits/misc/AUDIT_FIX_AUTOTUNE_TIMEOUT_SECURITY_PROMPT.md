# AUDIT_FIX_AUTOTUNE_TIMEOUT — SECURITY lane (R5, final value)

You are auditing PR `fix/autotune-timeout-progress` (commit `ea4f6c0`)
from the SECURITY lane. Round 5 refire because the final timeout value
is materially different from what R1 audited.

## Value history for context

R1 audited `processTimeout = 1800` (30 min). Convergence rounds
raised this through 2700 → 7260s. Final value: **7260s (2h1m)**.

## Focus this round

- Does the extended 2h1m subprocess lifetime introduce any new
  credential / secret / Keychain-session TTL concern that the
  original 30-min audit didn't cover?
- The R1 SEC-L-1 finding flagged unbounded `ProcessOutputBuffer`
  (`phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:33-50`)
  as a local DoS/OOM hardening gap under a 30-min cap. Under a
  2h1m cap, is this still a LOW or does it graduate to MEDIUM
  because a chatty stderr / stdout can accumulate more data?
  Consider realistic autotune output volume (line-per-probe JSON
  events, ~500 bytes/event × ~10 probes/candidate × ~10 candidates
  = single-digit MB; not GB).
- `sanitizedProcessEnvironment` (
  `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:126-128`)
  filters env at spawn time. Does the 2h1m runtime give any window
  for env variables to be re-introduced via a temp file / DYLD
  path / plist read? Verify against `ProcessEnvironmentSanitizer`
  behavior.
- On timeout at 7260s, `process.terminate()` sends SIGTERM. Does
  half-finished autotune leave any partial keychain slot or
  partial `config.yaml` write? (Note: onboarding state file
  hardening is out of scope.)
- Is the raised timeout an amplification of any spoofed / compromised
  `macprovider-cli` binary risk? At 30s an attacker had 30s to
  exfil; at 7260s they have 2h. Is this materially worse or is
  the code-signing check upstream (bundled CLI path) enough
  mitigation?
- Do the new tests (`AutotuneRecommendationRunnerTimeoutTests`)
  expose any private Malibu state beyond `@testable import Malibu`
  that already exposed `processTimeout` at R1?

Do NOT flag R2 CODE-M-2 (orphan child subprocess) — that is the
deferred CLI-side follow-up.
Do NOT expand scope beyond the timeout value + tests.

## Referenced context

Common context: `specs/AUDIT_FIX_AUTOTUNE_TIMEOUT_COMMON.md`.

## Output format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity: `SEC-C-1`,
`SEC-H-1`, `SEC-M-1`, `SEC-L-1`, etc. Each finding must cite the
file:line and concrete evidence.
