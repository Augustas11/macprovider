# AUDIT — Fix iss-189 (heartbeat watchdog + bounded send) — R1 SECURITY lane

## Scope (what to audit)

Branch `fix/iss-189-ws-watchdog` (worktree
`/Users/augstar/macprovider-fix-189`). Diff scope is exactly:

- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`

Read the diff (`git diff origin/main..HEAD`) and the surrounding
context. The issue body is at GitHub issue #189.

## Context

Same as the CODE prompt: provider WS reconnect wedges silently for
~42h; this PR adds a 5s bounded heartbeat send and a separate
watchdog task that triggers `Darwin.exit(1)` (via injected
`watchdogExitHook`) when no successful heartbeat has happened within
`3 × intervalSeconds`.

## You are the SECURITY auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **zero
C/H/M**.

The provider is the money-path — receipts, attestations, signed
state updates. A liveness mechanism that can be tricked into firing
or into NOT firing is a security concern.

Specifically check:

1. **Forced-restart DoS.** Can a remote actor (or a compromised
   coordinator) cause the provider to restart on demand by holding
   the WS `send()` open or stalling the read loop? The watchdog
   only observes successful heartbeat sends; if the coordinator can
   delay our sends past `3 × intervalSeconds`, we restart. Is that
   a meaningful new DoS lever vs the pre-existing one (coordinator
   could already drop us via `provider_inactive_threshold`)?
2. **Process-crash hidden state loss.** `Darwin.exit(1)` runs
   without unwinding actors / closing files. Are any
   security-sensitive flushes lost?
   - In-flight receipts not yet committed
   - Drain notifications not sent (coordinator thinks we're up)
   - Sleep assertion (`caffeinate`) leaked
   - In-flight receipt key rotation (rotateKey flow)
   What's the worst case from a tier1/tier2 audit-trail standpoint?
3. **Log-line injection / forgery.** The watchdog hook writes a
   `FATAL ...` line to stderr including the elapsed time. Is the
   reason string subject to any attacker-influenced content? (At
   the moment it looks like only an integer-second value.)
4. **Test-seam abuse in production.** Five `*ForTest` methods on
   `CoordinatorClient` (sendHeartbeatBoundedForTest,
   startHeartbeatWatchdogForTest, seedLastHeartbeatSuccessForTest,
   cancelHeartbeatWatchdogForTest). Could a malicious caller in
   the same process reach in and disable the watchdog?
5. **`Darwin.exit` from an actor.** Exiting from inside a watchdog
   `Task` skips any pending `drainAndExit` flows. Is there a
   misuse / TOCTOU scenario where the watchdog races with a normal
   SIGTERM-driven drain and the receipt-archive is corrupted?
6. **5s send timeout fast-fail.** Can a network adversary cause the
   provider to thrash reconnects (timeout → close → reconnect →
   timeout → ...) by holding TCP RTT just above 5s? Compare to the
   existing `runReconnectLoop` exponential backoff — is it
   sufficient to absorb the storm?
7. **Watchdog-during-drain.** During `drainFromCoordinator`, the
   heartbeat is canceled before `sendDrainStatus(phase:"complete")`
   is sent. Could the watchdog observe `last >= 3 * interval` ago
   and fire `Darwin.exit(1)` mid-drain, dropping the
   `drain_status` final frame? (Look at the explicit cancel order
   in that function.)
8. **No TLS / auth concerns introduced.** Confirm the changes do
   NOT touch the auth path (token, attestation, ECDH) or the
   `NoRedirectURLSessionDelegate` redirect-refusal logic.

Out of scope: anything outside the two files in the diff.

## Output format

Same as the CODE prompt — per-finding SEVERITY / Location / What /
Why it matters / Suggested fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
