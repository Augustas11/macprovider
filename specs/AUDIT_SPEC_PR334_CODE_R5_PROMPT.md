# AUDIT R5 — PR #334 CODE lane

Re-audit after R4 fix pass. R4 flagged 1 MEDIUM (re-entrant
`applicationShouldTerminate` returning `.terminateNow` on subsequent
calls could bypass the in-flight cleanup drain). Verify closed and
no new C/H/M. Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

Working tree: `/Users/augstar/macprovider-pr334-audit`
(branch `audit/pr334`, based on `feat/malibu-native-app`).

R4 findings file:
`/Users/augstar/macprovider-pr334-audit/.omc/artifacts/ask/codex-audit-r4-pr-334-code-lane-re-audit-after-r3-fix-pass-r3-flag-2026-07-03T07-26-51-052Z.md`

SECURITY and ARCHITECT lanes are already converged (R3 verdicts:
0 / 0 / 0). Only CODE files changed in R4.

## R4 finding to verify closed

- **R4 M1** — `applicationShouldTerminate` used to guard on a plain
  `isTerminating: Bool`. On re-entry (double Cmd-Q, logout on top of
  Quit menu) it returned `.terminateNow`, bypassing the first drain's
  Keychain/config cleanup.
  R5 fix in
  `phase3-binary/app/Sources/Malibu/MalibuApp.swift`:
  - Replaced the flag with `terminationDrain: Task<Void, Never>?`.
  - First call spawns the drain Task. Subsequent calls short-circuit
    the spawn (the Task already exists) and ALSO return
    `.terminateLater`. Every request waits on the same
    `NSApp.reply(toApplicationShouldTerminate: true)` — which is
    idempotent — issued at the end of the single drain.
  - `performUninstall` end-of-function now checks
    `terminationDrain != nil` (was `isTerminating`) to decide
    whether to call `NSApp.terminate(nil)` or defer to the drain.

## Focus for this pass

1. Verify that on re-entry (2nd, 3rd terminate request), the drain is
   never started twice and the reply is never issued twice.
2. Confirm every previously enumerated ordering (A/B/C/D from the
   header comment) still ends in "cleanup completes before exit":
   - A: Uninstall only. `performUninstall` completes, then
     `terminationDrain == nil` → calls `NSApp.terminate(nil)`.
     macOS calls applicationShouldTerminate → drain spawned →
     agent.shutdown (no-op), uninstallTask completes (already
     done, `.value` returns immediately), NSApp.reply(true).
   - B: Quit only. First ASF spawns drain. Second ASF (from
     macOS logout stacking) hits `terminationDrain != nil`, does
     nothing, returns terminateLater. First drain finishes,
     replies true, both terminates resolve.
   - C: Uninstall then Quit. Uninstall's Task is in-flight. User
     Cmd-Q. ASF spawns drain. Drain awaits agent.shutdown then
     awaits uninstallTask.value. Both complete. Reply.
   - D: Quit then Uninstall. ASF spawns drain. Drain awaits
     agent.shutdown (which suspends for up to 15s). Mid-shutdown
     user hits Uninstall — `handle` sets uninstallTask. Drain
     resumes from shutdown, checks self.uninstallTask (now set),
     awaits it. Reply.
3. Any way `terminationDrain` is set but the Task never runs (e.g.
   Task cancellation from a `weak self` decay)? MalibuApp lives for
   the app's lifetime; weak-self decay to nil only happens after
   NSApp.terminate has already run. In that case the drain's Task
   body captures `guard let self else { NSApp.reply(true); return }`
   — reply always fires. ✓
4. Re-check the R3 M2 and L1 closures are unaffected (they should
   be — those touch OnboardingWindow and PendingLinkState, which R4
   did not modify).
5. Any concurrency issue with the new `terminationDrain` field:
   - Read + write are only on MainActor (both call sites are
     MainActor-bound). No lock needed.
   - `Task<Void, Never>?` is Sendable. ✓
6. Warn if the drain's Task blocks the main thread. `agent.shutdown`
   internally awaits `child?.stop(gracePeriod:)` which is a
   busy-sleep loop (200ms), plus `control?.close()` synchronous.
   Neither blocks MainActor for longer than ~200ms at a time. ✓

## Skip

- Anything already converged in earlier rounds and not touched here.
- LOW/INFO items.

## Output format

Same as prior rounds. Return `0 CRITICAL, 0 HIGH, 0 MEDIUM` on
convergence. Read the actual files.
