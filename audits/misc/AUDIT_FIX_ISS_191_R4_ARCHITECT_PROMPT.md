# AUDIT — Fix iss-191 R4 ARCHITECT re-audit

## Scope

Same files as R3. Read `git diff origin/main..HEAD` AND `git ls-files
--error-unmatch scripts/test-watchdog-inline-drift.sh`.

## R3 ARCHITECT findings now claimed FIXED

R3 was `0/0/2M/0/0`. Fixes applied:

1. **R3 MED #1 (kern.boottime NTP-mutable)** — `current_boot_id`
   now sources from `sysctl -n kern.bootsessionuuid` (Apple-
   provided per-boot UUID; immutable across NTP / wall-clock
   adjustments per XNU). Verified live: writes
   `A888CD8B-2A5D-49CE-BDE8-6C4690A2FE13` to the armed marker.

2. **R3 MED #2 (drift script untracked)** — `scripts/test-watchdog-inline-drift.sh`
   will be `git add`ed in the same commit as the rest of the PR.
   Verify via `git ls-files --error-unmatch
   scripts/test-watchdog-inline-drift.sh` returning 0 in the
   audited tree.

## Your job (R4)

- Confirm both R3 findings are resolved.
- Final sanity: any new defect introduced by switching to
  kern.bootsessionuuid (e.g. is it ever empty on supported macOS
  versions in scope — the operator fleet runs macOS 14-26)?

Bar: **0 C/H/M** on the R4 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
