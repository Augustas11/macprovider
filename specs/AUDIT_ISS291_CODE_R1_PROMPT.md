## Lane: CODE — Round 1

## Context

Issue #291: extract the 4-state TLS classifier + planner + messaging
out of `phase4-coordinator/dist/deploy-pearl-vps.sh` (steps 4b–6c,
~150 lines) into `phase4-coordinator/dist/lib/pearl_tls.sh`, plus add
fixture tests in `phase4-coordinator/dist/test/check_pearl_tls_test.sh`.

Fix in commit `871dd31`:
- New: `lib/pearl_tls.sh` — 7 pure functions, bash 3.2 compatible,
  parallel-array pattern preserved from original.
- New: `test/check_pearl_tls_test.sh` — 46 assertions across 24 test
  cases (full HAVE/RENEW/EXPIRED/MISSING matrix, primary/non-primary
  cert-failure classifier, validation error paths, bash 3.2 empty-
  array-under-set-u guard, real-openssl fixture tests for the remote
  probe script).
- `deploy-pearl-vps.sh` — sources the lib, replaces inline heredoc +
  classification loop + certbot-fail messaging + primary-abort block
  with function calls. Behavior byte-preserved (same log lines, same
  exit codes, same array shapes).
- `Makefile` — `test-dist` target runs the new suite (already wired
  into the CI `dist-tooling` job).

## Your job

CODE LANE round 1. This is a money-adjacent refactor — the deploy
script is the sole path to shipping the coordinator binary to Pearl,
and the TLS state machine determines whether HTTPS keeps working
after a deploy. Standard severity-graded findings.

Focus areas:
- Did any behavior drift between the original inline blocks and the
  extracted functions?
- Did I introduce any race between `set -e` in the caller and
  `return N` in the lib functions?
- Did the array-mutation contract stay consistent (all callers still
  see the same DOMAINS_HAVE_CERT/NEED_CERT/etc. arrays)?
- Is bash 3.2 compatibility preserved everywhere?
- Do the fixture tests actually exercise the assertions their names
  claim, or is there a false-positive shape?

## Files in scope

- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/lib/pearl_tls.sh` (NEW)
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/test/check_pearl_tls_test.sh` (NEW)
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/deploy-pearl-vps.sh` (MODIFIED)
- `/Users/augstar/macprovider-iss291/Makefile` (MODIFIED)

Diff: `git -C /Users/augstar/macprovider-iss291 show HEAD`

Base state: `git -C /Users/augstar/macprovider-iss291 show HEAD:phase4-coordinator/dist/deploy-pearl-vps.sh` (main-side original before extraction)
