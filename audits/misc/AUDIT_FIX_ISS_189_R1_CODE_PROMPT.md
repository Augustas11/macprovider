# AUDIT — Fix iss-189 (heartbeat watchdog + bounded send) — R1 CODE lane

## Scope (what to audit)

Branch `fix/iss-189-ws-watchdog` (worktree
`/Users/augstar/macprovider-fix-189`). Diff scope is exactly:

- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`

Read the diff (`git diff origin/main..HEAD`) and the surrounding
context in those two files. Read `phase3-binary/Package.swift` only if
you need to confirm Swift version / target. The issue body is at
GitHub issue #189 (provider WS reconnect loop wedges silently).

## Context

The Swift provider's WebSocket to the coordinator can wedge silently:
process up, no outbound TCP, no logs for ~42h. Two hypotheses:
(a) macOS App Nap starves the heartbeat Task scheduler; (b) URLSession
`send()` queues frames without surfacing TCP half-open.

This PR adds two probes:
1. **Bounded send**: every `sendHeartbeat()` call from the keepalive
   loop is wrapped in `sendHeartbeatBounded(resetWindow:)` with a 5s
   throwable timeout (`CoordinatorHeartbeatSendTimeout`). On throw,
   the existing `closeWebSocketAfterKeepaliveFailure()` →
   `runReconnectLoop` path fires.
2. **Watchdog task**: a separate `heartbeatWatchdogTask` checks
   `lastHeartbeatSuccessNanoseconds` every ~0.5 × intervalSeconds. If
   the elapsed time exceeds 3 × intervalSeconds (`tolerance`), it
   invokes `watchdogExitHook`, which defaults to writing a FATAL line
   to stderr and calling `Darwin.exit(1)` so launchd respawns. The
   hook is injectable for tests.

Both helpers are torn down in `stop()`, `cleanupConnection()`, and
`drainFromCoordinator(reason:)` alongside the heartbeat task.

## You are the CODE auditor

Score severities CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **zero
CRITICAL, zero HIGH, zero MEDIUM** on diff-introduced surface. Focus
only on the changes; do NOT propose drive-by refactors of unchanged
code.

Specifically check:

1. **Cancellation correctness.** `withThrowingTaskGroup` race in
   `sendHeartbeatBounded` — does `defer { group.cancelAll() }` plus
   `try await group.next()` correctly cancel the loser? Could the
   send task leak when the timeout wins (URLSession sends are not
   freely cancellable)? Is the actor isolation around `webSocket?`
   safe under cancellation?
2. **Race conditions on `lastHeartbeatSuccessNanoseconds`.** The
   writer (`recordHeartbeatSuccess`) runs on the actor; the reader
   (`nanosecondsSinceLastHeartbeatSuccess`) runs on the actor; the
   watchdog task hops into the actor on each check via `await`. Are
   reads/writes correctly synchronized? Could a stale read happen
   that fires the watchdog incorrectly during a busy actor?
3. **Watchdog teardown.** Three teardown paths touch
   `heartbeatWatchdogTask?.cancel()` + `= nil`: `stop()`,
   `cleanupConnection()`, `drainFromCoordinator()`. Any path missed?
   What about `startHeartbeat()` itself — it cancels the prior
   watchdog before starting a new one; is that ordering right?
4. **Tolerance / check-interval math.**
   - `tolerance = max(1, intervalSeconds * 3) * 1e9` — when
     `intervalSeconds <= 0`?
   - `checkNanoseconds = max(1, intervalSeconds) * 0.5e9` — same.
   - Could overflow occur with large intervalSeconds (e.g. operator
     misconfig at INT_MAX)?
   - Seeded `lastHeartbeatSuccessNanoseconds = DispatchTime.now()`
     in startHeartbeat — does this race with the watchdog task's
     first check?
5. **Timeout boundary.** 5s timeout vs production heartbeat tick =
   `keepaliveTickCeilingSeconds = 5`. Is the timeout long enough?
   Could a slow but functional send (e.g. handshake) trigger a false
   timeout? Is the timeout aligned with the coordinator's 90s
   `provider_inactive_threshold`?
6. **Exit hook contract.** Default hook writes to stderr then
   `Darwin.exit(1)`. Are we leaking file descriptors / partial state
   on exit? Is `Darwin.exit` correct here vs `exit(EXIT_FAILURE)`?
   In tests, the hook is `@Sendable` and the test spawns a
   `Task { await captured.set(reason) }` from inside the hook — is
   that safe under structured concurrency?
7. **Behavior preservation.** Was there any behavior of the
   pre-existing heartbeat loop that is now different (frame
   ordering, debug logging, error propagation)? In particular, the
   existing `keepaliveDebug("keepalive_send_error error=...")` line
   still fires on timeout — desired?
8. **Test seam pollution.** Five new `*ForTest` methods were added
   on the actor. Are they correctly marked (not `private`) but not
   accidentally exposed to production callers?

Out of scope: anything outside the two files in the diff. Do NOT
propose changes to the broader reconnect loop or unrelated WS plumbing.

## Output format

For each finding:

- **SEVERITY** (CRITICAL/HIGH/MEDIUM/LOW/NOTE)
- **Location** (file:line)
- **What** (one sentence)
- **Why it matters** (one sentence)
- **Suggested fix** (one or two lines)

End with a single line:
`SUMMARY: <C>/<H>/<M>/<L>/<N>`

If you find nothing, say `SUMMARY: 0/0/0/0/0` and stop.
