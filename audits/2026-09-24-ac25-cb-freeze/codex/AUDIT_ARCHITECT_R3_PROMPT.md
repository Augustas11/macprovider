# Codex round 3: PR #1716, one scheduler fix after the gate (`b332156b`)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads.

Worktree: `/Users/augstar/macprovider-ac25-m2`. PR #1716 met the Codex gate
(round 1 code; round 2 security and architecture). After the gate, CI exposed a
race in the AC-25 bounded admission wait. The only new code is `b332156b`
(`git show b332156b`), 11 lines in
`ContinuousBatchScheduler.admitWaitingRows`.

The race: a request is re-queued by a `capacityExceeded` bounce after its
absolute queue-wait deadline has already passed. `armQueueWaitTimeout` then
schedules a zero-delay timeout task, but the pump can pull the request back
into admission before that task runs, so the request is admitted after its
bound.

The fix: before `waiting.removeFirst()`, if the head request's deadline has
passed, call `expireQueueWait` synchronously and `continue`.

Check:
- Actor reentrancy across the `await expireQueueWait`: can `waiting` change so
  that `waiting[0]` is empty or different?
- Interaction with cancellation, draining and the stale-wake guard in
  `expireQueueWait`.
- Replay-claim release.
- Settlement: none for an expired request.
- Whether the loop can spin without making progress.
- Tests: `testAC25*` in `ContinuousBatchSchedulerTests`.

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line and a
failure scenario. End with `VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: ARCHITECTURE (spec conformance, contracts, rollout safety)

Check:
- SPEC-038, SPEC-039, and SPEC-001 text versus the code, including
  `specs/CONFORMANCE.json` and `AUTHORITY.json` consistency.
- FR-CB10 tuple fail-closed behavior.
- Canary vs on vs off semantics.
- First-turn-only hybrid scope enforcement.
- Coupling of the new knobs.
- Whether the one-tuple canary enable is safe to ship on a signed candidate:
  rollback path and what an operator must set.
