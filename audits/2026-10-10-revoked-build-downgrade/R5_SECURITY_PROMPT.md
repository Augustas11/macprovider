# Revoked-build downgrade audit — R5 (VERIFICATION ONLY), SECURITY lane

Repository: current working directory, branch `cli/revoked-build-downgrade`
(head b647fe97a, rebased onto origin/main). Do not edit
files. Do not run network commands.

Operator-approved verification round for exactly two R4 findings. The fix
diff is `audits/2026-10-10-revoked-build-downgrade/R5_FIX.diff` (the R4 fix commit before the rebase; the same
changes are in HEAD). Read the diff and only the surrounding code needed to
judge it. No discovery sweep; do not report anything outside these two
findings and the changed lines.

## Findings to verify

F1 (R4 Code lane, MEDIUM, PARTIAL): tests did not exercise the SPEC-020-R007
authorization being withdrawn (a) during the drain and (b) after the
pre-restart eviction. Required: each must abort the downgrade with no
activation and no restart into the older release, and must emit the abort
event. Fix: `AutoUpdateTests.runR007Downgrade(withdraw:)` drives a full
`handleCoordinatorRecommendation` downgrade (1.8.233 -> 1.8.232) through
drain, swap, eviction and restart using a DEBUG-only
`AutoUpdater.preparedReleaseForTest` seam that stands in for release
resolution and verified preparation (compiled out of release builds);
tests `testRevokedBuildDowngradeAbortsWhenAuthorizationIsWithdrawnDuringDrain`,
`testRevokedBuildDowngradeAbortsWhenAuthorizationIsWithdrawnAfterEviction`
(after activation, the restart critical section refuses; the swap is rolled
back and the only restart is the rollback's restart of the restored revoked
build), and the control `testRevokedBuildDowngradeHarnessCompletesWhileAuthorized`.

F2 (R4 Architecture lane, MEDIUM, PARTIAL): the rollback step checked only
that P's id commit matches tag v<P>, not P's full signed
compatibility_set_id. Required: verify the full id against P's signed release
metadata (pearl-release.json + .sig, verified with the same key and digest
the train uses), refuse on any mismatch, with an ops test. Fix:
`signed_release_compat_id` in `scripts/ops/cli-release.sh` downloads
v<P>'s pearl-release.json and .sig, verifies with
`openssl dgst -sha256 -verify ops/pearl-updater/release-signing-public.pem`,
requires tag == v<P>, release_version == P, a canonical repository and
40-hex commit, and `decide_rollback` refuses unless
`repository:tag@commit` equals `CLI_ROLLBACK_TO_ID` (before mutation and
before reporting done). Ops tests in `scripts/ops/test-entrypoints.sh`
(mismatched signed id, tampered metadata, missing signature) with a
`gh release download` stub in `scripts/ops/tests/gh_stub.py`.

## Lane focus

Does the DEBUG-only seam leak into release builds or weaken verification? Can the rollback step's signed-identity check be bypassed (signature verification, key, parsing, comparison, shell quoting)? Any regression in the changed lines.

## Output

`F1 — FIXED|PARTIAL|NOT FIXED — evidence (file:line)` and the same for F2,
then any regression in the changed lines as `SEVERITY — file:line — problem —
fix`. End with exactly one line: `VERDICT: C=<n> H=<n> M=<n> L=<n>` counting
only unfixed findings and regressions in the changed lines.
