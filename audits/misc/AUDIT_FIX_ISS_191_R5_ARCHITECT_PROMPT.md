# AUDIT — Fix iss-191 R5 ARCHITECT re-audit

## Scope

Same files as R4. Read `git diff origin/main..HEAD`.

## R4 findings now claimed FIXED

R4 was `0/1H/0/1L/0`. Fixes applied:

1. **R4 HIGH (LaunchAgent PATH missing /usr/sbin)** — both the
   inlined `render_watchdog_plist` in install.sh and the standalone
   `live.malibu.provider-watchdog.plist.template` now use
   `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
   Verified live: under the fixed PATH the watchdog arms and writes
   the boot UUID; under the pre-fix PATH the watchdog silently
   exited and never created the armed file (reproducing the bug).
   Inline XML comment in both plist renders documents the fix
   reason.

2. **R4 LOW (install.sh executable bit)** — `chmod +x` restored on
   `phase3-binary/dist/install.sh`. Verified `-rwxr-xr-x` in
   working tree.

Drift check still passes.

## Your job (R5)

Final convergence check. If the diff has 0 C/H/M, declare convergence.

Look specifically for:
- Anything broken by adding `/usr/sbin:/sbin` to PATH (e.g. a
  homebrew shadow of system binaries that would break other
  invocations from the same plist).
- Anything else in this round that introduces drift between
  standalone and inlined.

Bar: **0 C/H/M** on R5 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
