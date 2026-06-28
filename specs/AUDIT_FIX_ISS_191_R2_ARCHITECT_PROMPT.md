# AUDIT — Fix iss-191 R2 ARCHITECT re-audit

## Scope

Same 8 files + `scripts/test-watchdog-inline-drift.sh` (new). Read
`git diff origin/main..HEAD`.

## R1 ARCHITECT findings now claimed FIXED

R1 was `0/1H/1M/2L/3N`. Fixes applied:

1. **R1 ARCH HIGH (cold-start restart loop)** — the watchdog now
   stays disarmed until it has observed at least ONE healthy
   ESTABLISHED connection (touch `$ARMED_FILE`), AND a 300s
   `KICK_GRACE_SECONDS` window separates consecutive kicks. Cold-
   start model load (10-20 min before the Swift CLI opens its
   socket) is no longer cut off, and a kick that triggers a model
   reload is not re-kicked during the warmup. Override:
   `MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS`. Applied symmetrically
   to both the standalone `ops/.../watchdog.sh` and the inlined
   heredoc in `phase3-binary/dist/install.sh:write_watchdog_script`.

2. **R1 ARCH MEDIUM (drift safeguard)** — new
   `scripts/test-watchdog-inline-drift.sh` extracts the inlined
   heredoc and asserts byte-equality with the standalone source
   after stripping comments / blank lines. Runs `bash -n` on both
   copies. Verified passing locally. The inlined heredoc was
   re-written to be a verbatim copy of the standalone so the
   drift check is straightforward to extend in future PRs.

3. **R1 ARCH LOW#1 (netstat any-process false-positive)** —
   documented in `OPS.md §11` ("Known limitation"). Tightening to
   provider PID via `lsof` is explicitly future work.

4. **R1 ARCH LOW#2 (doc completeness)** — added
   `MACPROVIDER_NO_WATCHDOG` to `install.sh --help`, clarified
   that `MACPROVIDER_NO_LAUNCHD=1` skips BOTH the provider and the
   watchdog, and added a "Recovery target" subsection in OPS.md
   stating the detection-latency / kick-grace / E2E-recovery
   numbers.

## Your job (R2)

- Confirm each R1 finding is genuinely resolved.
- Surface any NEW defect introduced by the fixes (the arming state
  file persists across reboots — is that the right semantics?
  After a reboot, is the watchdog re-armed when it first sees the
  ESTABLISHED connection, or could a stale `$ARMED_FILE` cause a
  premature kick if the provider's first post-reboot connection is
  delayed?).
- The drift safeguard normalization strips comments and blank
  lines — is that the right delineation, or should the test
  enforce exact byte-equality?

Bar: **0 C/H/M** on the R2 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
