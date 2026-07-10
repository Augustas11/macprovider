# AUDIT R2 — PR #334 CODE lane

Re-audit of the correctness/concurrency/lifecycle surface after the R1
fix pass. Confirm that each R1 CODE finding is closed AND that no new
CRITICAL / HIGH / MEDIUM defects were introduced by the fix. Loop
until 0 CRITICAL, 0 HIGH, 0 MEDIUM.

Working tree: `/Users/augstar/macprovider-pr334-audit`
(branch `audit/pr334`, based on `feat/malibu-native-app`, PR base = `main`).

The R1 audit results file:
`/Users/augstar/macprovider-pr334-audit/.omc/artifacts/ask/codex-audit-pr-334-spec-025-native-mac-app-cli-wire-up-code-lane-y-2026-07-03T06-46-13-069Z.md`

## R1 findings to verify closed

- **H1** — Crash reconnect never relaunches child (`MalibuAgent.start()`
  `guard child == nil else { return }` short-circuited when the crash-
  handler forgot to nil `child`). R1 fix: nil `self.child` in
  `onUnexpectedExit` before scheduling reconnect.
- **H2** — Clean shutdown scheduled a new daemon because
  `terminationHandler` fired on intentional stop. R1 fix: `isStopping`
  flag on `CLIChildProcess`; `MalibuAgent.shutdown` cancels any pending
  `reconnectTask` before nulling `child`.
- **H3** — Deep-link identity replay. R1 fix: `PendingLinkState`
  nonce-store, required `state` param, single-use, expires in 15 min,
  refused if app is already configured. See also SECURITY S1.
- **H4** — `isConfigured` was true for the wrong Keychain account.
  R1 fix: `isConfigured` now reads `provider_id` from config,
  requires the `.installed-by-app` marker, and looks up the Keychain
  token bound to that exact account.
- **M1** — CRLF config file corrupted `provider_id` lookup. R1 fix:
  split on `\r`|`\n` + `.whitespacesAndNewlines` trim.
- **M2** — Uninstall Keychain wipe was not awaited. R1 fix:
  `wipeAppOwnedState` is now `async` returning `UninstallResidue`;
  `performUninstall` awaits it and surfaces residue via NSAlert
  before `NSApp.terminate`.
- **L1/L2** — Read-buffer cap and silent decode-drop. Not fixed in
  R1 (accepted LOW). Note if these are now HIGH/MEDIUM because of
  the R1 fix churn.

## New surfaces to audit

The following are new since R1 — review for correctness with the same
severity bar:

- `phase3-binary/app/Sources/Malibu/Agent/AgentSnapshot.swift` (split
  data type + `AgentSnapshotPresenter`).
- `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift`
  (new nonce store).
- `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift` (rewrite
  covers H1, H2, A1, A5, A7).
- `phase3-binary/app/Sources/Malibu/Agent/CLIChildProcess.swift` (added
  `isStopping` + `markStopping()`; removed
  `scheduleRestartWithBackoff` — reconnect now owned by MalibuAgent's
  `ReconnectPolicy`).
- `phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift`
  (marker check + collision throw + async residue).
- `phase3-binary/app/Sources/Malibu/System/KeychainStore.swift`
  (removed `hasProviderToken()`; strengthened `deleteAllAppItems`).
- `phase3-binary/app/Sources/Malibu/MalibuApp.swift` (rewired consume
  + performUninstall + startup provenance log).
- `phase3-binary/app/Sources/Malibu/System/URLSchemeHandler.swift`
  (event carries `state` now).
- `phase3-binary/app/Sources/Malibu/Onboarding/OnboardingWindow.swift`
  (nonce generation before opening portal).
- `phase3-binary/app/Sources/Malibu/System/AppLoginItem.swift`
  (unregister-with-error path).
- `phase3-binary/app/Sources/Malibu/Dashboard/DashboardWindow.swift`
  (Optional earnings display).
- `phase3-binary/app/Sources/Malibu/MenuBar/MenuBarController.swift`
  (uses `AgentSnapshotPresenter`).
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
  (`unsetenv("MACPROVIDER_PROVIDER_TOKEN")` immediately after
  `ConfigLoader.load`).
- New tests at
  `phase3-binary/app/Tests/MalibuTests/*.swift`.

## Focus areas (unchanged from R1 but re-scoped to the new tree)

1. Concurrency / actor isolation — with the new
   `reconnectTask` / `metricsPoller` cancellation order and the
   `isStopping` flag, verify:
   - Termination handler race: can `terminationHandler` fire after
     `shutdown()` has already set `isStopping` but before it's read?
     Both write and read happen on the MainActor via a Task hop, so
     ordering should be preserved.
   - `reconnectTask` cancellation: the `Task.sleep` inside the
     reconnect closure won't throw on cancellation (uses `try?`);
     we then check `Task.isCancelled` before calling `start()`.
     Any way the sleep completes normally + cancellation flag
     lands between `!Task.isCancelled` and `await self?.start()`?
   - `ReconnectPolicy` is a mutating struct on `@MainActor` — safe.
2. Uninstall order: `agent.shutdown` → `unregister` → `discard nonce`
   → `wipeAppOwnedState` → alert if residue → `NSApp.terminate`.
   Fatal path (throw during shutdown) — do we still surface residue?
3. `PendingLinkState.consume`: `defer { removeItem }` always fires,
   even on `alreadyConfigured` throw before validation of nonce/age.
   Is that the desired policy (discard on ANY exit)? Yes; the file
   holds only a nonce, single-use is the whole point.
4. `PendingLinkState.beginLink`: `setAttributes` after `write` is a
   race window where the file briefly has 0644 default permissions.
   Real defect vs LOW? Contains only a random nonce, not a secret.
5. `MalibuAgent.pause/resume` — no longer flips state optimistically.
   Do UI elements (menu bar, dashboard) that previously expected the
   instant flip get stuck? Review consume() ack handling.
6. CLI-side: `unsetenv("MACPROVIDER_PROVIDER_TOKEN")` runs AFTER
   `ConfigLoader.load(cli:)`. Is the default-parameter env-snapshot
   taken before or after `unsetenv` on Swift `AsyncParsableCommand`?
   Verify by reading how `run()` receives the env.
7. New AgentSnapshot fields (all `Optional` numerics + a
   `pauseAcknowledged: Bool`) — anything reading these that assumed
   non-optional and force-unwraps? Grep the diff.

## Skip

- Style/naming.
- The two-codec duplication concern (SPEC-025 §12 followup).
- L1/L2 unless promoted to MED/HIGH by R1 fix churn.
- Anything covered by the SECURITY or ARCHITECT lane.

## Output format

```
CRITICAL findings: N
HIGH findings: N
MEDIUM findings: N
LOW findings: N

## CRITICAL
(none, or per severity)

### C1 — <title>
- File: <path>:<lines>
- Defect: <sentence>
- Failure scenario: <concrete input → wrong output>
- Fix: <sentence>
```

Return `0 CRITICAL, 0 HIGH, 0 MEDIUM` when the tree converges. Read the
actual files.
