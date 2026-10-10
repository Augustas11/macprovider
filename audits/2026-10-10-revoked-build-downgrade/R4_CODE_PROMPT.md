# Revoked-build downgrade audit — R4 (VERIFICATION ONLY), CODE lane

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

## Findings to verify (CODE lane, round 3)


HIGH — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:6401` — **NEW, exposed by pre-existing drain behavior.** In-process rollback restores V’s bytes but leaves local status `draining`. The new restored-build health proof accepts only `ready`, `busy`, or `degraded`, so finalization retains `awaiting_previous_readiness`. Retry ignores that failure and hits `transactionPending`, blocking recovery. — **Fix:** safely restore local readiness and keepalive while preserving the coordinator revocation fence; require successful marker retirement before retrying. Test activation failure followed by cooldown expiry and successful same-session recovery.

MEDIUM — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:2209` — **PRE-EXISTING; R1/R2 cleanup race remains.** Timeout cancels the restore task without awaiting termination. Its later error path also invokes global cleanup (`:2244`), which can cancel a newer socket and erase its recommendation/revocation. The new cancellation check fixes stale notice publication, but does not fence cleanup. — **Fix:** await cancelled restore work and bind cleanup to socket/session identity. Test a delayed restore resuming after a replacement session is accepted.

MEDIUM — `phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:3885` — **NEW; required boundary behavior remains untested.** Generation/version mismatches fail at initial eligibility; the policy-change case fails before release resolution. None exercises authorization withdrawal during drain, at swap, or after eviction before restart. Removing those later checks would leave these tests passing. — **Fix:** suspend an otherwise valid downgrade at those boundaries, change the live session or policy, and assert no activation before swap, restored bytes after swap, and correct pending-marker cleanup.

Whitespace checks, shell syntax, and all seven Python config tests passed. Swift/Go tests were not run. No edits or network commands were performed.


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
