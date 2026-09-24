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
## Lane: SECURITY / MONEY PATH

Look for:
- Cross-row (cross-buyer) data leakage in batched KV or Mamba state.
- Usage/billing token counts that a buyer or provider could inflate or deflate.
- Receipt and settlement interaction with batched rows and relay error codes
  (`error_queue_full` re-route vs double execution/double charge).
- Whether the lab catalog-readiness waiver can trigger outside the exact lab
  condition.
- Trace/telemetry leaking prompt content.
- Fail-open behavior on bad config.
