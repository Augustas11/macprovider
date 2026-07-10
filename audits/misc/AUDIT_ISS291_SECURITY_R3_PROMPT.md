## Lane: SECURITY — Round 3

## Context

R2 outcomes:
- CODE 0/0/0/0 PASS (converged)
- SEC  0/0/1/1 — MED: `pwd` should be `pwd -P` (parent-dir symlink
  bypass); LOW: T25 didn't source hostile lib to prove non-sourcing
- ARCH 0/0/0/0 PASS

R2 fix-pass `ca48d69`:
- `_pearl_resolve_symlink` uses `pwd -P` at both cd sites so
  parent-DIRECTORY symlinks are physically resolved
- T25 expanded to 4 sub-tests: T25a absolute, T25b chain, T25c
  parent-dir symlink (R2 SEC MED coverage), T25d END-TO-END
  sources the resolved lib in a subshell and asserts the hostile
  sentinel var PEARL_TLS_HOSTILE_SOURCED stays UNSET

## Your job

SECURITY LANE round 3. Verify the parent-dir symlink hijack is
fully closed. Any remaining path-traversal / TOCTOU / hostile-
sourcing surface.

## Files in scope

- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/lib/pearl_tls.sh`
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/test/check_pearl_tls_test.sh`

R2→R3 diff: `git -C /Users/augstar/macprovider-iss291 show HEAD`
