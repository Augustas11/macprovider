# Round 3 — CODE lane (omc ask codex)


HIGH — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:6401` — **NEW, exposed by pre-existing drain behavior.** In-process rollback restores V’s bytes but leaves local status `draining`. The new restored-build health proof accepts only `ready`, `busy`, or `degraded`, so finalization retains `awaiting_previous_readiness`. Retry ignores that failure and hits `transactionPending`, blocking recovery. — **Fix:** safely restore local readiness and keepalive while preserving the coordinator revocation fence; require successful marker retirement before retrying. Test activation failure followed by cooldown expiry and successful same-session recovery.

MEDIUM — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:2209` — **PRE-EXISTING; R1/R2 cleanup race remains.** Timeout cancels the restore task without awaiting termination. Its later error path also invokes global cleanup (`:2244`), which can cancel a newer socket and erase its recommendation/revocation. The new cancellation check fixes stale notice publication, but does not fence cleanup. — **Fix:** await cancelled restore work and bind cleanup to socket/session identity. Test a delayed restore resuming after a replacement session is accepted.

MEDIUM — `phase3-binary/Tests/macprovider-cliTests/AutoUpdateTests.swift:3885` — **NEW; required boundary behavior remains untested.** Generation/version mismatches fail at initial eligibility; the policy-change case fails before release resolution. None exercises authorization withdrawal during drain, at swap, or after eviction before restart. Removing those later checks would leave these tests passing. — **Fix:** suspend an otherwise valid downgrade at those boundaries, change the live session or policy, and assert no activation before swap, restored bytes after swap, and correct pending-marker cleanup.

Whitespace checks, shell syntax, and all seven Python config tests passed. Swift/Go tests were not run. No edits or network commands were performed.

VERDICT: C=0 H=1 M=2 L=0
