# AUDIT — Fix iss-189 R2 SECURITY re-audit

## Scope

Same as R1: the two scoped Swift files. Read `git diff
origin/main..HEAD`.

## R1 findings now claimed FIXED

R1 SECURITY summary was `0/0/2/1/2`. Fixes applied:

1. **R1 SECURITY MEDIUM #1 (watchdog only tracks local send success)**
   **FIX:** `handle(_:)` now calls `recordHeartbeatSuccess()` on
   EVERY received frame, before any further processing. Inbound
   coordinator activity is the real liveness signal we want; if the
   coord stops talking back, this no longer keeps the watchdog
   quiet. Conversely, fresh inbound traffic keeps the watchdog
   silent during normal operation. New test
   `testHandleBumpsHeartbeatSuccessOnInboundActivity` exercises this
   directly: a stale-seeded timestamp is reset to fresh after a
   single handled frame.

2. **R1 SECURITY MEDIUM #2 (TaskGroup can't bound uncooperative send)**
   **FIX:** same as R1 CODE HIGH — the timeout child force-cancels
   the captured `webSocket` reference before throwing. This makes
   the send child unwind via URLSession's transport error path,
   bounding the wrapper at 5s in production.

3. **R1 SECURITY LOW (watchdog active during drain)**
   **FIX:** both `drainAndExit` (SIGTERM handler) and
   `drainFromCoordinator` (coordinator-requested drain) now cancel
   `heartbeatWatchdogTask` at ENTRY, before any drain_status
   sends. A watchdog firing mid-drain can no longer race with the
   drain sequence.

## Your job (R2)

Re-audit for:

- Does the inbound-bump in `handle(_:)` introduce a forgeability
  risk? E.g. an attacker sending unauthenticated frames before
  auth completes could keep the watchdog quiet. (Where in the
  receive path is `handle` called? After hello/auth, or before?)
- Does force-canceling the WS from the timeout child create a
  cancellation cascade that interferes with an in-flight orderly
  close (e.g. a `drain_status complete` send happening
  simultaneously)?
- The drain-entry cancellation: is the order correct? If a
  watchdog had already fired Darwin.exit(1) BEFORE drain entry,
  the cancel is moot — confirm there's no read-then-modify race.
- Confirm no TLS / auth regression on the receive path now that
  `recordHeartbeatSuccess` is the first thing done in `handle`.

Bar: **0 CRIT / 0 HIGH / 0 MEDIUM**.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
