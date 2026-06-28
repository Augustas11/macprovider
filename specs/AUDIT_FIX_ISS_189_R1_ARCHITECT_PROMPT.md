# AUDIT — Fix iss-189 (heartbeat watchdog + bounded send) — R1 ARCHITECT lane

## Scope (what to audit)

Branch `fix/iss-189-ws-watchdog` (worktree
`/Users/augstar/macprovider-fix-189`). Diff scope is exactly:

- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`

Read the diff and the surrounding context. The issue body is at
GitHub issue #189.

## Context

Issue #189 reports the Swift provider's WS connection wedging silently
for ~42h, with no logs and no outbound TCP, while the process stays
alive. The proposed fix has two complementary probes:

1. **Bounded send (probe 3)**: wrap each heartbeat send in a 5s
   throwable timeout; on throw, route through the existing
   `closeWebSocketAfterKeepaliveFailure` → `runReconnectLoop` path.
2. **Watchdog task (probe 2)**: a separate task observes a
   `lastHeartbeatSuccessNanoseconds` timestamp; if no successful
   heartbeat in `3 × intervalSeconds`, invoke a `watchdogExitHook`
   that defaults to `Darwin.exit(1)` so launchd respawns the
   process.

The issue suggests probes 1, 2, OR 3 individually as acceptable. This
PR implements 2 + 3 (not 1, the `MACPROVIDER_KEEPALIVE_DEBUG=1`
investigation flow, which already exists).

## You are the ARCHITECT auditor

Score CRITICAL / HIGH / MEDIUM / LOW / NOTE. Bar is **zero
C/H/M**.

Focus on whether the design holds up over time, composes with other
recovery mechanisms, and doesn't paper over a deeper root cause.

Specifically check:

1. **Root cause vs mitigation.** Probe 3 turns a wedged URLSession
   send into a self-recovering condition. Probe 2 turns a starved
   Task scheduler into a launchd-restart. Neither diagnoses why
   App Nap is suspending the scheduler. Should we file a follow-up
   to capture diagnostics (e.g. `os_log` markers + a process
   activity assertion via `NSProcessInfo.beginActivity`) so we can
   tell apart "App Nap" vs "URLSession queue-stall" in production?
2. **Layering vs the external watchdog.** The issue body mentions
   an external LaunchAgent watchdog (`ops/macprovider-watchdog/`)
   already deployed. Does the in-process watchdog (probe 2)
   compose well with that, or does it create a duplicate-restart
   risk (in-process exits, then external watchdog also kickstarts)?
3. **Tolerance choice.** 3 × intervalSeconds. Production heartbeat
   interval is configured by the coordinator (typically 10s →
   30s tolerance), with a coordinator-side
   `provider_inactive_threshold` of 90s. Does the choice align?
   What if a coordinator pushes a 60s interval — tolerance becomes
   180s, larger than the inactivity drop. Is that fine because the
   coordinator's drop already triggers reconnect, and the watchdog
   is just last-resort?
4. **5s send timeout choice.** Document the budget reasoning. Is
   it on the side of "too aggressive" (false positives on a slow
   transcontinental wifi reconnect) or "too lax" (slow to recover
   from a wedge)? Is the value plausibly tunable later if needed?
5. **Test coverage shape.** Three new tests:
   - `testHeartbeatBoundedSendThrowsWhenSendHangs` — covers probe 3
   - `testHeartbeatWatchdogFiresExitHookOnStaleness` — covers probe 2 fire path
   - `testHeartbeatWatchdogDoesNotFireWhenSendsAreRecent` — covers probe 2 no-fire
   Is there a meaningful integration-level test missing? E.g. the
   probe-3 timeout firing → `closeWebSocketAfterKeepaliveFailure`
   being called → `runReconnectLoop` retrying — currently each is
   tested in isolation.
6. **Interaction with `warm_swap_heartbeat`.** The warm-swap
   completion path also calls `sendHeartbeat()` (line ~298) and is
   NOT bounded. Is that intentional? Could a wedge in the warm-swap
   completion path leave the swap state-machine stuck without the
   probe-3 protection?
7. **Public API churn.** Adding the `watchdogExitHook:` parameter
   to `CoordinatorClient.init` is a default-value addition — does
   it break any non-test caller? (Grep the codebase.)
8. **Naming / readability.** Two pairs of timestamps
   (`secondsSinceWindowReset`, `lastHeartbeatSuccessNanoseconds`)
   plus a tolerance and a check interval all live in the same
   function family. Is the cognitive load reasonable? Anything
   obviously fixable by a rename?

Out of scope: anything outside the two files in the diff. Do not
propose unrelated improvements.

## Output format

Same as the CODE prompt — per-finding SEVERITY / Location / What /
Why it matters / Suggested fix, then `SUMMARY: <C>/<H>/<M>/<L>/<N>`.
