# Revoked-build downgrade audit — R4 (VERIFICATION ONLY), ARCHITECTURE lane

Repository: current working directory, branch `cli/revoked-build-downgrade`.
Do not edit files. Do not run network commands.

This is an operator-approved verification round, not a discovery sweep.
Anchor diff: `git diff e8c0e4296..e5af59e27` (the round-3-audited head to the
current head). Read the changed lines and only the surrounding code needed to
judge them.

For EACH finding listed below, answer only:
1. Is it fixed correctly by the named commit(s)? (FIXED / NOT FIXED / PARTIAL, with file:line evidence)
2. Did the fix introduce a regression in the changed lines? (cite file:line)

Do not report new findings outside the changed lines. Pre-existing issues
outside this anchor diff are out of scope.

## Findings to verify (ARCHITECTURE lane, round 3)


HIGH — phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:6401 — **PRE-EXISTING; R2 recovery finding still open:** Retry invokes restoration cleanup without restoring local readiness. `autoupdateDrain` sets the provider to `draining`; in-process activation/guard-failure restoration neither restarts nor resets that state. The health proof at line 5152 accepts only `ready`, `busy`, or `degraded`, so cleanup retains the marker and subsequent attempts hit `transactionPending`. — **Concrete fix:** Reconcile local readiness and keepalive after restoration, preserving the coordinator’s update-only routing fence, then prove restored health and retire the transaction. Test failure followed by retry without reconnecting.

MEDIUM — scripts/ops/cli-release.sh:440 — **NEW:** Rollback checks that P is published but never verifies that the supplied target compatibility ID matches P’s signed release identity. A wrong commit suffix can revoke V successfully, report completion, and strand providers when P’s manifest fails the exact-set check. — **Concrete fix:** Verify the supplied ID against P’s signed compatibility manifest before mutation and completion; test a published P with a mismatched commit suffix.

MEDIUM — scripts/ops/cli-release.sh:427 — **NEW:** An interrupted rollback cannot resume through the entrypoint after config installation but before restart. `release-registrations.py:403` recognizes only seed additions as pending revocations; adding V therefore produces a policy mismatch that blocks rollback, despite the config helper supporting unapplied-config recovery. — **Concrete fix:** Recognize the exact requested P-target/V-revocation edit as pending, preserve unrelated-mismatch refusal, and test interruption followed by `next --run`.


## Carried findings (all lanes) — also verify

C1 (pre-existing MEDIUM, fixed in e5af59e27): a timed-out receipt-rotation
restore that fails later called global `cleanupConnection()`, which could
cancel a newer connection and erase its recommendation/revocation. Fix:
`connectionEpoch` bumped by every teardown; the restore error path calls
`cleanupConnection(ifEpoch:)` with the epoch captured when it began
(`CoordinatorClient.swift`).

C2 (pre-existing MEDIUM, fixed in e5af59e27): signed-policy persistence (e.g.
a concurrent manual `update --check`) was not serialized with the
downgrade's final policy check and activation. Fix:
`AutoUpdateMarkerStore.withSignedPolicyLock` (exclusive flock on
`signed-policy.lock`); `updateSignedPolicy` read-merge-write runs under it,
and the downgrade critical section (`AutoUpdater.downgradeCriticalSection`)
performs the policy read and activation/restart under it.

## Fix commits

- 4c3475ac3: activation and restart into the older release run inside the
  coordinator session actor's critical section (`LiveRevocation` takes a
  synchronous body; `withLiveDowngradeAuthorization`); held revoked session
  restores local state/keepalive after an unfinished attempt
  (`reconcileRevokedSessionAfterUnfinishedAutoupdate`) and retries only with
  no pending transaction; `resolveReleaseByTags` refuses a release object
  naming another tag; rollback step checks the P id against the commit of tag
  v<P> and treats its own unapplied edit as pending (resume); tests
  `testDowngradeActivationRunsOnlyInsideTheLiveAuthorizationSection`,
  `testSelfUpdateRefusesAReleaseObjectNamingAnotherTag`, ops entrypoint
  cases.
- e5af59e27: C1 and C2 above, tests
  `testStaleRestoreCleanupDoesNotClearANewerConnection`,
  `testSignedPolicyPersistWaitsForTheSignedPolicyLock`.

## Output

One line per finding: `ID — FIXED|PARTIAL|NOT FIXED — evidence`. Then any
regression in the changed lines as
`SEVERITY — file:line — problem — fix`. End with exactly one line:
`VERDICT: C=<n> H=<n> M=<n> L=<n>` counting only unfixed findings and new
regressions in the changed lines.
