# Revoked-build downgrade audit — R4 (VERIFICATION ONLY), SECURITY lane

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

## Findings to verify (SECURITY lane, round 3)


HIGH — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:788 — **NEW; R2 remains open.** The final authorization snapshot is consistent but does not serialize activation with the `CoordinatorClient` actor. After `liveRevocation()` returns, teardown/reconnect can clear or replace authorization before the nonisolated updater activates P. The same race exists between `beforeRestart` returning at line 864 and restart. Removing subsequent awaits does not prevent another executor from changing session state; cancellation is also unchecked. — Perform final session validation and synchronous activation/restart within the same actor-isolated critical section, checking cancellation. Test withdrawal after snapshot capture but before mutation.

HIGH — phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:972 — **PRE-EXISTING; newly identified.** Manual update’s coordinator fallback checks that requested P is newer, but GitHub tag resolution never verifies that the response names P. Controlled release metadata can induce discovery fallback and return an older authentic signed Q for `/releases/tags/vP`. Preparation validates Q against its own signed artifacts, and line 272 installs it without exact revocation, recommendation binding, or a policy check for Q. — Reject response-tag mismatch, bind the prepared version to the requested target, and enforce forward-only ordering and effective policy for the actual prepared target before activation. Add a replayed-release-object regression.

MEDIUM — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:1105 — **PRE-EXISTING; R2 remains open.** Policy is now rechecked, but persistence remains unsynchronized with activation/restart. A concurrent manual `update --check` can persist a signed revocation of P or raise the minimum immediately after this read; the held mutation lock does not constrain `updateSignedPolicy`. P can consequently activate or restart despite already-observed prohibiting policy. — Use shared interprocess synchronization for policy persistence and the final policy-check/mutation boundaries, including atomic policy read/merge/write. Test policy advancement at both boundaries.

MEDIUM — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:1069 — **PRE-EXISTING; recovery remains incomplete.** Successful in-process restoration after a post-drain activation failure leaves `awaitingPreviousReadiness` while provider status remains `.draining`. The new retry invokes admission finalization, but its local-health proof rejects draining status. The pending marker therefore still blocks subsequent attempts. — Restore local readiness under the update-only routing fence, or restart restored V, before retiring the transaction. Test activation failure followed by retry in the held session.

The R2 generation/version binding finding is fixed. Exact identity and boolean handling, canonical downgrade parsing, the floor, shared cryptographic verification, signed discovery, and ops injection/policy guards show no additional confirmed bypass.

T-4 accurately records the intended residual risk: coordinator compromise permits authentic but potentially vulnerable signed history within the floor and locally observed policy bounds. The findings above exceed those intended guarantees.

Read-only static audit of HEAD `e8c0e4296`; no edits, network commands, or tests executed.


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
