# AUDIT_FIX_AUTOTUNE_TIMEOUT — SECURITY lane

You are auditing PR `fix/autotune-timeout-progress` (commit `ae23d48`) from
the SECURITY lane.

Focus:

- Is there any secret / token / credential-lifetime concern introduced by
  keeping the autotune subprocess alive for up to 30 min instead of 30 s?
  E.g. Keychain session leases, provider-token cache validity, sanitized
  process environment TTL.
- Does the longer timeout give more window for a malicious/wedged
  subprocess to exfiltrate data before Malibu.app terminates it?
  Consider: what if `macprovider-cli` is compromised or spoofed —
  does the extra 29 minutes of running matter more than it did at 30 s?
- `sanitizedProcessEnvironment` still filters env at spawn time — verify
  the extra runtime doesn't reintroduce env variables (e.g. via
  `read_environment` from a temp file).
- The subprocess writes to stdout/stderr pipes. At 1800 s worst case,
  could a chatty error path fill the pipe buffer + deadlock the
  parent? Malibu's `ProcessOutputBuffer` is unbounded — is that a
  memory-safety concern (OOM ⇒ crash ⇒ open onboarding state file
  half-written)?
- On failure, is any keychain slot / config.yaml write left half-done
  such that a retry after the 30-min window creates duplicated /
  inconsistent state?
- Does the new test file `AutotuneRecommendationRunnerTimeoutTests`
  expose any private state (`@testable import Malibu`) beyond what was
  visible before making `processTimeout` non-private?

Do NOT expand scope. Just audit the security surface of the timeout
bump + new tests.

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
