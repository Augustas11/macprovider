## Lane: SECURITY — Round 2

## Context

R1 outcomes:
- CODE 0/0/1/2 — MED classify-rc; LOWs on T09
- SEC  0/0/1/2 — MED symlink hijack; LOWs on probe-comment drift + T24 bash lookup
- ARCH 0/0/1/1 — MED coverage

R1 fix-pass `14e9bb2` (SEC-relevant slice):
- Added `_pearl_resolve_symlink` in deploy-pearl-vps.sh — walks
  symlink chain (macOS bash 3.2 has no `readlink -f`) so sourcing
  always resolves to the REAL script's dist/lib/pearl_tls.sh, not
  the symlink's parent dir
- T25 test: plants a hostile `lib/pearl_tls.sh` next to a symlink
  and asserts the resolver picks the real dist/, not the decoy
- T24 hardened: `_bash_exe="${BASH:-/bin/bash}"` (skips PATH
  lookup) + absolute-path assertion

## Your job

SECURITY LANE round 2. Verify symlink-hijack path is fully closed,
including edge cases: relative-symlink chains, symlink-to-symlink
chains, symlinks with `..` segments.

## Files in scope

- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/lib/pearl_tls.sh`
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/test/check_pearl_tls_test.sh`

R1→R2 diff: `git -C /Users/augstar/macprovider-iss291 show HEAD`
