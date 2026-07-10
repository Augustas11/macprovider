# AUDIT R3 — PR #334 CODE lane

Re-audit after R2 fix pass. R2 flagged 4 HIGH findings; verify each is
closed and no new C/H/M was introduced. Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

Working tree: `/Users/augstar/macprovider-pr334-audit`
(branch `audit/pr334`, based on `feat/malibu-native-app`).

R2 findings file:
`/Users/augstar/macprovider-pr334-audit/.omc/artifacts/ask/codex-audit-r2-pr-334-code-lane-re-audit-of-the-correctness-concur-2026-07-03T07-10-27-696Z.md`

## R2 findings to verify closed

- **R2 H1 — ControlSocketClient actor deadlock**. Blocking `Darwin.read`
  was inside the actor and starved `send`/`close`. Fix in
  `phase3-binary/app/Sources/Malibu/Agent/ControlSocketClient.swift`:
  read loop now runs in a `Task.detached` capturing only the fd and
  the Sendable `AsyncStream.Continuation`; the actor is never awaited
  from the read path. `close()` also calls `shutdown(fd, SHUT_RDWR)`
  before `Darwin.close` to unblock any in-flight read. Verify:
  - Reader task cancellation vs `close()` ordering — is there a race
    where `close()` unlinks the fd while the detached loop is mid-
    `read()`? On macOS, `close(fd)` on a blocked-in-read fd wakes the
    reader with EBADF; combined with the shutdown() call this should
    be race-free.
  - Continuation is captured by value in a detached task — actor is
    still the writer of `streamContinuation`, but the reader just
    reads a nullable copy captured at attach() time. Any lifetime bug
    if the actor deallocates while the detached loop is running?
  - Max frame cap of 1 MiB now enforced. Realistic ceiling?
- **R2 H2 — Plain Quit orphaned CLI child**. Fix in `MalibuApp.swift`:
  `applicationShouldTerminate` intercepts every termination, calls
  `agent.shutdown(gracefulSeconds: 15)`, then replies via
  `NSApp.reply(toApplicationShouldTerminate:)`. `performUninstall`
  sets `isTerminating = true` before its own `NSApp.terminate` so it
  doesn't double-shutdown. Verify:
  - `applicationShouldTerminate` is only called once per termination
    attempt on macOS. Re-entry protection is `isTerminating` flag.
  - Any `NSApp.terminate` path we missed? `NSApp.terminate(nil)` in
    MenuBarController's Quit menu? Yes — but it also flows through
    `applicationShouldTerminate` because that's how macOS works.
    Confirm.
- **R2 H3 — Reconnect race with shutdown**. Fix in `MalibuAgent`:
  `isShuttingDown: Bool` flag; `start()` checks it before every suspension
  point; `shutdown()` sets it BEFORE cancelling reconnectTask. Verify:
  - After `shutdown()` sets `isShuttingDown`, a reconnect Task that
    already passed `Task.sleep` and is about to `await self?.start()`
    — start() re-checks `isShuttingDown` on entry. Confirm ordering.
  - `connectControl` post-connect also checks `isShuttingDown` and
    closes the client if shutdown began mid-connect.
- **R2 H4 — Onboarding bypass to unconfigured start**. Fix in
  `MalibuAgent.start()`: refuses to launch when
  `ProviderConfig.isConfigured == false`. Now the "Start earning"
  button surfaces "Not linked yet" instead of spawning a tokenless CLI.
  Verify:
  - Race: user clicks Start earning IMMEDIATELY after the deep-link
    callback lands and `saveProviderIdentity` completes. `isConfigured`
    reads the marker + Keychain — both are now present. OK.
  - Subsequent legit `agent.start()` calls (via reconnect after crash)
    still go through the isConfigured guard. Reconnect during a config
    corruption (marker got deleted) — we refuse to reconnect. Is that
    the right behavior?

## New surfaces since R2

- `ControlSocketClient.swift` (major rewrite — detached read loop).
- `MalibuAgent.swift` (isShuttingDown, isConfigured guard, stub-
  metrics suppression).
- `MalibuApp.swift` (applicationShouldTerminate).
- `PendingLinkState.swift` (memory-only nonce; no file writes).

## Focus for this pass

1. `Task.detached` blocking `read()` inside `blockingReadLoop`:
   - Detached task inherits no actor context; fine.
   - When `close()` executes on the actor, it cancels `readerTask`.
     Detached task's `while !Task.isCancelled` polls before entering
     the next blocking `read()`. But if we're currently inside
     `Darwin.read()`, the cancellation flag does nothing — the read
     is a syscall. `shutdown(fd, SHUT_RDWR)` unblocks the read
     synchronously, so read returns 0/error and we exit. Good.
2. `PendingLinkState` is now static-var memory-only:
   - Static-var + NSLock is Sendable-safe? XCTest and other threads
     can hit it. NSLock is fine.
   - Nonce doesn't survive app restart — is that a UX regression that
     leaves users unable to link? They just have to click "Continue
     in browser" again. Acceptable.
3. `applicationShouldTerminate` returns `.terminateLater` and calls
   `NSApp.reply(toApplicationShouldTerminate:)` from a Task. Any way
   the Task never completes (e.g. shutdown throws)? Not currently —
   shutdown is `async`, all internal throws are swallowed with `try?`.
   But if a future refactor makes it `async throws`, we need a defer.
4. Onboarding "Start earning" now can fail with "Not linked yet". Is
   the button UI still enabled without any feedback? Look at
   `OnboardingWindow.finish()` — it calls `agent.start()` and then
   `onDone()`. If start() sets snapshot.state=.error, onDone still
   closes the onboarding window, and the user is now looking at the
   menu bar with "!" and no explanation. Is that a HIGH regression?
5. Any new introduced concurrency race:
   - `applicationShouldTerminate` sets `isTerminating = true` on
     MainActor; the Task-hopped inner shutdown also runs on MainActor.
     Safe.
   - `PendingLinkState.consume` acquires `lock`, reads `pending`,
     nils it, releases lock BEFORE throwing. If `consume` is called
     twice concurrently with the same nonce — first call takes it and
     may throw or succeed, second call gets nil and throws noPendingLink.
     Safe.

## Skip

- L1/L2 from R1 unless they became MED/HIGH by R2 churn.
- Style / naming.
- SECURITY / ARCHITECT concerns.
- Same items excluded in prior rounds.

## Output format

Same as R1/R2. Return `0 CRITICAL, 0 HIGH, 0 MEDIUM` on convergence.
Read the actual files.
