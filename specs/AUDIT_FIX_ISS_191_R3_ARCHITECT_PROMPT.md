# AUDIT — Fix iss-191 R3 ARCHITECT re-audit

## Scope

9 files + Makefile change. Read `git diff origin/main..HEAD`.

## R2 ARCHITECT findings now claimed FIXED

R2 was `0/1H/2M/0/0`. Fixes applied:

1. **R2 HIGH (stale armed across reboot)** — the armed marker now
   contains the current boot id (`sysctl kern.boottime`'s `sec`
   field). On every tick the watchdog compares the on-disk boot
   id with the current one; mismatch ⇒ disarmed; first
   ESTABLISHED in the new boot re-arms with the new boot id. Live
   smoke-tested: `arming watchdog (boot=1782222298): ...`
   wrote `1782222298` to the armed file.

2. **R2 MED #1 (drift normalizer strips shebang)** — added an
   explicit shebang sanity check that asserts both copies start
   with `#!/usr/bin/env bash` BEFORE running the comment-strip
   normalizer. Either copy missing or mismatched on the shebang
   now fails the drift test.

3. **R2 MED #2 (drift safeguard not wired to CI)** — added
   `bash scripts/test-watchdog-inline-drift.sh` to the existing
   `test-dist` make target so the existing CI job
   `deploy tooling (check-deploy-config gate)` runs it on every
   PR. Verified locally with `bash scripts/test-watchdog-inline-drift.sh`.

## Your job (R3)

- Confirm each R2 finding is genuinely resolved.
- Validate the boot-id approach: is `sysctl kern.boottime` the
  right per-boot identifier (stable for the lifetime of a single
  boot, changes after reboot)? Is the awk-extracted `sec` value
  immune to clock skew / time-set events?
- Check the shebang sanity assertion runs BEFORE the normalizer
  so a missing shebang is caught even when the rest of the script
  is identical.

Bar: **0 C/H/M** on the R3 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
