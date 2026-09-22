# Round 2 re-audit — AC-25 Phase A

Worktree `/Users/augstar/macprovider-ac25-m2`, branch
`campaign/ac25-m2-api-lifecycle`, based on `origin/main` @ `b9b20fe4`.

Review the **FULL combined diff as it will land**: `git diff origin/main..HEAD`
(commits `9a5eecfd`, `1181ccf2`, `a32aec7c`). Not the round-2 delta alone —
the earlier findings were interactions, so judge the whole change.

Round 1 returned 0 CRITICAL / 2 HIGH / 4 MEDIUM / 1 LOW across three lanes.
All are addressed in `a32aec7c`:

- **F-1 HIGH** stale queue-wait wake cleared the deadline during admission,
  so a `capacityExceeded` requeue could wait forever. `expireQueueWait` now
  guards on deadline presence, deadline elapsed, and membership in `waiting`
  before touching state. It is `internal` rather than `private` so the test can
  drive the stale wake directly; the reachable interleaving is only a wake
  landing on the actor in the same turn the pump pulls the request into
  admission.
- **F-2 HIGH** per-channel disconnect pointer was overwritten under
  pipelining. Now a list, all marked on `channelInactive`. Note: the
  "refuse a pipelined head" option was implemented and proved unreachable —
  `configureHTTPServerPipeline` sets `withPipeliningAssistance: true`, which
  buffers the second request until the first response ends — so it was
  reverted as dead code.
- **F-3 MEDIUM** durable replay claim now released on queue-wait expiry, via
  a new fingerprint-guarded, best-effort `release(_:)` on
  `ContinuousBatchSchedulerReplayAuthority` and its four conformers.
- **F-4 MEDIUM** `Retry-After` now emitted centrally in
  `ResponseWriter.writeAPIError` for the two queue-pressure codes, derived
  from the configured queue-wait timeout. The streaming path rejects after the
  SSE head is on the wire, so it carries the bound as an HTTP trailer on
  `writeSSEDone`.
- **F-5 LOW** carried-code status is now an explicit 17-entry table with a
  source-scanning test that fails on any unclassified code.

Verify the fixes are correct and complete, and hunt for anything they
introduced. Pay particular attention to:

- Is the new `expireQueueWait` guard actually sufficient, or is there another
  interleaving (cancel, drain, capacityExceeded, completion) that strands a
  request with no deadline or expires an admitted one?
- Is `release(_:)` safe? Can it delete a claim that still guards a running or
  replayable request? What happens on partial store failure, and is
  "fails toward 409" actually true on every path?
- Does the disconnect-state list leak — is anything ever removed, and can a
  long-lived channel accumulate states?
- Is the `Retry-After` trailer on the SSE path a wire-contract change that any
  consumer (relay, gateway, SDK) could choke on?
- Any concurrency defect in the actor/eventloop boundaries touched.

Gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**. State explicitly if you find none.
Do not propose SPEC edits. Findings as CRITICAL/HIGH/MEDIUM/LOW/INFO with
file:line, a concrete failure scenario, and a fix.

## Lane: ARCHITECTURE REVIEW — is the claim-release semantic the right one of
the three options? Is a trailer the right vehicle for streaming retry
guidance? Is the direct-HTTP/relay contract divergence acceptable to ship?
