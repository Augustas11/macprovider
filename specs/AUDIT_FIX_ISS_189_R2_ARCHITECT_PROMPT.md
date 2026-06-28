# AUDIT — Fix iss-189 R2 ARCHITECT re-audit

## Scope

Same as R1: the two scoped Swift files. Read `git diff
origin/main..HEAD`.

## R1 findings now claimed FIXED

R1 ARCHITECT summary was `0C/1H/1M/1L/1N`. Fixes applied:

1. **R1 ARCHITECT HIGH (TaskGroup can't bound non-cooperative send)**
   **FIX:** see R2 CODE prompt — timeout child force-cancels the
   captured WS task, URLSession surfaces a transport error on the
   send, group unwinds.

2. **R1 ARCHITECT MEDIUM (warm-swap heartbeat not bounded)**
   **FIX:** `consumeSwapSignals` `.completed` branch now calls
   `sendHeartbeatBounded(resetWindow: true)` and routes errors
   through `closeWebSocketAfterKeepaliveFailure()` for symmetry
   with the keepalive tick path. Adds `recordHeartbeatSuccess()`
   on the success path so this heartbeat also keeps the watchdog
   quiet.

3. **R1 ARCHITECT LOW (tolerance vs 90s drop)**
   **FIX:** tolerance is now computed from `tickSeconds` (capped at
   5s) instead of intervalSeconds. Tolerance is bounded at 15s
   regardless of coordinator-supplied interval, always firing well
   before the 90s coord drop.

4. **R1 ARCHITECT NOTE (diagnostics follow-up)**
   ACK — to be filed as a separate tracking issue (not in this PR).

## Your job (R2)

- Did bounding warm-swap break any guarantee of the warm-swap
  protocol? The warm-swap state machine expects a final heartbeat
  to publish the new model hash; if that heartbeat now times out,
  we call `closeWebSocketAfterKeepaliveFailure` — is that the
  right composition with warm-swap, or do we leave the
  swap-completed state un-published until reconnect?
- Tolerance-from-tickSeconds: with intervalSeconds=30 and
  tickSeconds=5, tolerance becomes 15s. The watchdog check fires
  every 2.5s. Worst-case detection time is 15s + ε. Is this
  consistent with the broader recovery story (RTT-bounded
  reconnect)?
- Naming / cognitive load: `lastHeartbeatSuccessNanoseconds`,
  `nanosecondsSinceLastHeartbeatSuccess`, `recordHeartbeatSuccess`,
  plus the new inbound-bump call in `handle()`. Is the API
  surface still readable, or has it crossed a threshold where
  factoring into a small `HeartbeatLivenessClock` helper would
  help future readers?
- Composition with external LaunchAgent watchdog
  (ops/macprovider-watchdog/): does the inbound-bump change
  anything about duplicate-restart risk?

Bar: **0 CRIT / 0 HIGH / 0 MEDIUM**.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
