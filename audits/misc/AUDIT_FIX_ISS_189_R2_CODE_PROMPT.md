# AUDIT — Fix iss-189 R2 CODE re-audit

## Scope

Same as R1: `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
and `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`.
Read `git diff origin/main..HEAD` to see the current snapshot of fixes
applied since R1.

## R1 findings now claimed FIXED

R1 CODE summary was `0C/1H/0M/2L/0N`. The fixes applied this round:

1. **R1 CODE HIGH** — `sendHeartbeatBounded` TaskGroup could not unblock a
   wedged `URLSession.send()`. **FIX:** the timeout child now captures
   `socketRef = webSocket` BEFORE racing, and calls
   `socketRef?.cancel(with: .goingAway, reason: nil)` to force the
   in-flight send to error out before throwing the timeout. URLSession
   surfaces a transport error on the orphaned send, the racing send
   child unwinds, the TaskGroup returns. See lines around
   `sendHeartbeatBounded` for the inline comment block explaining the
   non-cooperative-cancellation reasoning.

2. **R1 CODE LOW (overflow)** — tolerance math could overflow for
   pathological `intervalSeconds`. **FIX:** tolerance now derives from
   `tickSeconds = max(1, min(intervalSeconds, 5))`, which is bounded
   by `keepaliveTickCeilingSeconds = 5`. The product
   `tickSeconds * heartbeatWatchdogToleranceMultiplier` (= 3) is at
   most 15s — well within UInt64 nanosecond range, no overflow path.

3. **R1 CODE LOW (90s ordering)** — at intervalSeconds=30 the watchdog
   tolerance equaled the coordinator's 90s drop threshold and used
   `>` instead of `>=`. **FIX:** comparison is now `>=`, AND tolerance
   is bounded at ≤15s as in (2), so the watchdog always fires before
   coord drop.

Additional fixes inspired by other lanes (cross-audit, no
duplication needed in your re-audit but listed so you understand the
total diff):
- Warm-swap heartbeat callsite now uses `sendHeartbeatBounded` (R1
  architect MEDIUM).
- `handle(_:)` now bumps `recordHeartbeatSuccess()` on inbound (R1
  security MEDIUM).
- Watchdog canceled at drain ENTRY in `drainAndExit` and
  `drainFromCoordinator` (R1 security LOW).

## Your job (R2)

Re-audit the **current** diff against these claims. Confirm each R1
CODE finding is genuinely resolved. Surface any new code defects
introduced by the fixes — Sendable correctness in the new
`socketRef?.cancel(...)` capture, race between the `recordHeartbeatSuccess()`
calls from the receive path vs the heartbeat tick path, etc.

Bar is **0 CRIT / 0 HIGH / 0 MEDIUM** on R2 diff-introduced surface.

## Output format

Per-finding SEVERITY / Location / What / Why it matters / Suggested
fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
