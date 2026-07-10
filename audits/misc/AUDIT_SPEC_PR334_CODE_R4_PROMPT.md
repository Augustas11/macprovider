# AUDIT R4 — PR #334 CODE lane

Re-audit after R3 fix pass. R3 flagged 2 MEDIUM and 1 LOW; verify all
three are closed and no new C/H/M was introduced. Bar: 0 CRITICAL,
0 HIGH, 0 MEDIUM.

Working tree: `/Users/augstar/macprovider-pr334-audit`
(branch `audit/pr334`, based on `feat/malibu-native-app`).

R3 findings file:
`/Users/augstar/macprovider-pr334-audit/.omc/artifacts/ask/codex-audit-r3-pr-334-code-lane-re-audit-after-r2-fix-pass-r2-flag-2026-07-03T07-20-24-563Z.md`

SECURITY and ARCHITECT lanes already converged at 0/0/0 in R3 and are
NOT being re-audited here — no code in their scope changed except the
CODE fixes below.

## R3 findings to verify closed

- **R3 M1 (MEDIUM) — Quit-during-uninstall race**. `performUninstall`
  only set `isTerminating = true` at the END, so a concurrent
  Cmd-Q / logout during shutdown/wipe entered
  `applicationShouldTerminate`, replied `true`, and terminated the
  process mid-Keychain-wipe. R4 fix in
  `phase3-binary/app/Sources/Malibu/MalibuApp.swift`:
  - New `uninstallTask: Task<Void, Never>?` tracks the in-flight
    uninstall.
  - `handle(.quitAndUninstall)` sets `uninstallTask = Task { … await
    performUninstall() }` and refuses to start a second one.
  - `applicationShouldTerminate`: if `uninstallTask != nil`, its
    Task awaits `uninstall.value` FIRST, then replies. Never
    replies terminateNow while uninstall is still cleaning up.
  - `performUninstall` no longer forcibly calls `NSApp.terminate` if
    `isTerminating` is already true — the caller (Terminate driver)
    completes termination via `NSApp.reply`.

- **R3 M2 (MEDIUM) — Onboarding closed on refused start**. R4 fix
  in `phase3-binary/app/Sources/Malibu/Onboarding/OnboardingWindow.swift`:
  `finish()` now checks `ProviderConfig.isConfigured` FIRST. If the
  deep-link callback has not landed, it sets `self.error = "Not
  linked yet — click Continue in browser…"` and returns WITHOUT
  registering the login item or closing the window. The registration
  + `agent.start()` + `onDone()` only run when config + Keychain
  token are actually present.

- **R3 L1 (LOW) — Swift-6 strict-concurrency warning on
  `PendingLinkState.pending`**. R4 fix in
  `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift`:
  marked `nonisolated(unsafe) private static var pending: Pending?`
  with a comment justifying that every access is serialized through
  `lock: NSLock`, and `Pending` is a value type of `String + Date`.

## Focus for this pass

1. R3 M1 verification — the uninstall race:
   - Set of possible orderings between user "Quit and Uninstall"
     and macOS-driven "Quit"; enumerate them and verify each ends
     in "cleanup completes AND process exits".
   - Ordering A: user hits Uninstall alone. performUninstall runs
     to completion (no isTerminating set externally), then sets
     isTerminating and calls NSApp.terminate. applicationShouldTerminate
     sees isTerminating=true, returns terminateNow. Exit. ✓
   - Ordering B: user hits Quit alone. applicationShouldTerminate
     sees isTerminating=false, sets true, kicks off Task that awaits
     agent.shutdown (uninstallTask is nil), replies terminateNow. Exit. ✓
   - Ordering C: user hits Uninstall, then Quit during drain.
     performUninstall is mid-shutdown. Quit triggers
     applicationShouldTerminate; isTerminating=false → sets true;
     Task awaits uninstallTask.value; uninstallTask completes
     (residue reported, isTerminating already true so it returns
     without re-terminating); Task replies terminateNow. Exit. ✓
   - Ordering D: user hits Quit, then Uninstall during drain.
     applicationShouldTerminate ran first, set isTerminating=true,
     is awaiting agent.shutdown (or uninstallTask if it exists yet).
     User hits Uninstall — handle(.quitAndUninstall) sets
     uninstallTask to run performUninstall. Two shutdown paths now
     run concurrently: applicationShouldTerminate's inline await, AND
     performUninstall's shutdown call. Both are idempotent (agent.shutdown
     sets isShuttingDown; subsequent calls no-op). Which one replies
     terminateNow? Whichever finishes first, since NSApp.reply cannot
     be undone.
   - Is Ordering D a problem? The first shutdown finishes, replies
     terminateNow, macOS exits BEFORE performUninstall gets to Keychain
     wipe. That would re-open R3 M1.
   - Look at the code — does applicationShouldTerminate's Task check
     `uninstallTask` at await time, so if uninstallTask appears
     mid-flight it awaits it? Yes: it reads `if let uninstall = self.uninstallTask { await uninstall.value }` — but that's checked ONCE at Task-start time, not re-checked. If uninstallTask was nil at Task-start and gets set later, the check misses it.
   - Verify: is this a real defect, or is Ordering D unreachable
     given menu-bar UX (menus are dismissed while another modal
     is active)? Concurrent Quit + Uninstall clicks are hard to
     produce for a normal user but possible via AppleScript.

2. R3 M2 verification — onboarding refusal path:
   - `finish()` `guard await ProviderConfig.isConfigured else { ... }`
     is checked AFTER `busy = true` and BEFORE
     `AppLoginItem.register()`. On refusal, `busy = false` (defer)
     runs, `self.error` shows, window stays open. ✓
   - Is the error message shown to the user? Yes — the OnboardingRootView
     renders `Text(error).font(.callout).foregroundStyle(.red)`. ✓

3. R3 L1 verification:
   - `nonisolated(unsafe)` disables the strict-concurrency check.
     The manual `NSLock` provides the safety. Any residual thread-
     safety issue? All reads and writes to `pending` happen inside
     `lock.lock() … lock.unlock()`. ✓

4. New surfaces since R3:
   - `MalibuApp.uninstallTask` field.
   - Modified `applicationShouldTerminate`.
   - Modified `performUninstall` (conditional NSApp.terminate).
   - Modified `handle(.quitAndUninstall)` (Task capture).
   - Modified `OnboardingWindow.finish` (isConfigured guard).
   - Modified `PendingLinkState.swift` (nonisolated(unsafe)).

## Skip

- SECURITY / ARCHITECT scope; those lanes are already converged.
- L1/L2 from R1 unless promoted.
- Style / naming.

## Output format

Same as prior rounds. Return `0 CRITICAL, 0 HIGH, 0 MEDIUM` on
convergence.
