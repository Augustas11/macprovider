## Lane: ARCHITECT — Round 1

## Context

Issue #291: extract 4-state TLS classifier (HAVE / RENEW / EXPIRED /
MISSING) + planner + messaging out of
`phase4-coordinator/dist/deploy-pearl-vps.sh` (steps 4b–6c) into
`phase4-coordinator/dist/lib/pearl_tls.sh`, add fixture tests, wire
into `make test-dist`.

Origin: #244 R2 ARCH M3 + R3 ARCH "Architectural Verdict" + R6 ARCH
recurring recommendation.

Fix in commit `871dd31`. Design:
- Bash 3.2 compatible (operator Mac); no `declare -A`, no `mapfile`.
- Parallel-array pattern preserved (2-4 domain scale, linear scan
  acceptable).
- Functions mutate documented global arrays instead of returning
  values (bash idiom, consistent with the surrounding script).
- Functions return non-zero instead of exit-ing — caller decides
  whether the failure is fatal (deploy: yes; test: assert on stderr
  and continue).
- Sourcing pattern: `. "$(dirname BASH_SOURCE)/lib/pearl_tls.sh"` at
  script top, before any array is referenced.

## Your job

ARCHITECT LANE round 1. Evaluate:
- Is the lib's API surface sound? Is the parallel-array + mutation
  contract clear to future readers, or would a struct-style pattern
  (e.g. echoing `KEY=VAL` lines to be `eval`'d) be worth the
  bash-3.2 pain?
- Is the split boundary in the right place? Should more of the
  certbot loop / stub install move into the lib for testability,
  or does the SSH boundary correctly stop where it does?
- Is fixture-test coverage complete relative to the 32-cell matrix
  described in the issue (HAVE/RENEW/EXPIRED/MISSING × cert-ok/fail
  × primary/non-primary)?
- Does the sourced-lib pattern scale to a future 3rd hostname
  (per-N-hostname loop or hardcoded pair)?

## Files in scope

- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/lib/pearl_tls.sh` (NEW, ~241 lines)
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/test/check_pearl_tls_test.sh` (NEW, ~330 lines)
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/deploy-pearl-vps.sh` (MODIFIED, ~150 lines removed, ~15 added)
- `/Users/augstar/macprovider-iss291/Makefile` (MODIFIED, +1 line)

Diff: `git -C /Users/augstar/macprovider-iss291 show HEAD`
