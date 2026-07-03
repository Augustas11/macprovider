# AUDIT — PR #334 (SPEC-025 native mac app + CLI wire-up) — CODE lane

You are a senior Swift/macOS engineer reviewing pull request
`Augustas11/macprovider#334` (branch `feat/malibu-native-app`) for
**correctness, concurrency, and resource-lifecycle defects**. Money-path
proximity: the child CLI process this app spawns is the provider daemon
that connects to the coordinator and settles USDC — a lifecycle bug
here surfaces as invisible earnings loss or double-spawns.

Working tree to audit: `/Users/augstar/macprovider-pr334-audit`
(worktree of branch `audit/pr334`, tip = `81434ca`, based on
`feat/malibu-native-app`, PR base = `main`).

Diff scope (use `git diff main...HEAD` inside the worktree):

- New app skeleton at `phase3-binary/app/Sources/Malibu/**`
- New CLI wire-format additions in
  `phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
- New `managed_by` config triple in
  `phase3-binary/Sources/MacProviderCore/Config.swift`
  and consumer in
  `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  (function `runAutoupdateIfEligible`)
- New CLI flag `--managed-by` in
  `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- SPEC document at `specs/SPEC-025-native-mac-app.md` (informational)

## Focus areas

Rank findings by severity (CRITICAL / HIGH / MEDIUM / LOW). Report
only real defects — not stylistic nits, not "should also do X" scope
expansion. For every finding include: file, line range,
one-sentence defect, and a failure scenario with concrete inputs.

1. **Concurrency & actor isolation** in `MalibuAgent`,
   `CLIChildProcess`, `ControlSocketClient`. Watch for:
   - Retain cycles / `[weak self]` gaps in `Task` closures that own
     child processes or sockets.
   - `terminationHandler` invoked on an arbitrary thread hopping onto
     `@MainActor` — is `onUnexpectedExit` fired at most once? Does
     `stop()` racing with `terminationHandler` double-invoke reconnect?
   - `ControlSocketClient` is an actor with a `DispatchQueue.global()`
     escape for `connect()` — does `attach(fd:)` race with `close()` or
     `send()` when the connect callback fires after a caller cancelled?
   - `metricsPoller` and `eventStreamTask` cancellation: does
     `shutdown()` actually stop them before nulling the actor? Any
     lingering `Task` referencing a dead fd?
2. **Restart-backoff / reconnect correctness** in
   `CLIChildProcess.scheduleRestartWithBackoff` +
   `MalibuAgent.scheduleReconnect`:
   - `restartAttempts` resets to 0 on every successful `start()`, so a
     flapping child that alternates start/exit at short intervals
     never escalates its backoff. Is that a DoS on the coordinator?
   - What happens if the user hits Pause during a reconnect delay?
   - `onUnexpectedExit` fires even on clean `stop()`-initiated
     terminations because `terminate()` still triggers
     `terminationHandler`. Do we double-restart when quitting?
3. **Control-socket framing** (`ControlSocketClient.readLoop` +
   `ControlSocketFrame.swift` app-side codec vs CLI-side codec in
   `phase3-binary/Sources/macprovider-cli/ControlSocket.swift`):
   - Wire-format divergence between the two codecs (field names,
     required vs optional, type coercion). The app codec accepts
     `Double?` where the CLI codec requires `Double` (see
     `metrics_response.earnings_usdc`) — does a stub-server zero
     survive a round-trip, and is the divergence lossy?
   - `readLoop` buffer growth: no cap. A malformed peer that never
     emits `\n` will grow `buffer` unbounded until OOM. Realistic
     attack surface, given the socket lives in the user's own
     `Application Support/`?
   - JSON decode errors are silently swallowed
     (`guard … try? … else { continue }`) — hides protocol drift.
4. **Process lifecycle** in `CLIChildProcess`:
   - `stop()` sends `SIGTERM` then, if still running past the grace,
     `SIGKILL`. But `logHandle` is closed AFTER `SIGKILL`, and the
     child inherits the writable file descriptor via
     `standardOutput`/`standardError`. Does a still-writing child
     race with the close?
   - `try proc.run()` throw semantics — does `process` stay non-nil
     if run fails after we assigned earlier state? (It doesn't, because
     the guard is at the top and `process = proc` happens after
     `try proc.run()`. Verify.)
   - `httpPort` is `nil` in `MalibuAgent`, but `--port` is passed only
     when non-nil. If a user's shared config.yaml sets a port, does
     the app path collide with the CLI's expectations?
5. **Config & path handling** in `ProviderConfig` /
   `ProviderPaths`:
   - `readProviderID` string parsing splits on `\n` only — a CRLF
     config file (Windows-linebreaks pasted by user) breaks parsing
     silently, then the app spawns the CLI with no
     `MACPROVIDER_PROVIDER_TOKEN`, and the child hits the coordinator
     unauthenticated. What does the coordinator do with that?
   - `saveProviderIdentity` reads existing config, filters out
     `provider_id:` and `provider_token:` lines, appends new one,
     rewrites atomically. Is there a race with the CLI having the
     file open? Do inline `#` comments on the same line as
     `provider_id:` survive? (They get preserved verbatim — check.)
   - `wipeAppOwnedState` deletes `configFile` only if
     `appMarkerFile` exists. But `appMarkerFile` lives inside
     `appSupport`, which is deleted unconditionally afterwards —
     is the ordering correct on repeated uninstall calls?
   - `wipeAppOwnedState` fires an unstructured
     `Task { try? await KeychainStore.deleteAllAppItems() }` — the
     caller (`AppDelegate.performUninstall`) calls `NSApp.terminate`
     immediately after. The Keychain wipe may not complete before the
     process exits.
6. **Keychain semantics** in `KeychainStore`:
   - `hasProviderToken` matches on `service` alone, no account. If
     the user has multiple provider IDs pinned historically,
     "configured?" returns true even when the current provider_id
     has no token, and `MalibuAgent.start` proceeds with no token
     in env — silent-fail identical to §5 above.
   - `saveProviderToken` calls `SecItemDelete` then `SecItemAdd` (not
     `SecItemUpdate`) — the delete has no `kSecAttrAccount` filter?
     (It does — check.) But between the delete and the add, is there
     a window where a concurrent `readProviderToken` returns nil?
   - `deleteAllAppItems` iterates a hard-coded services list; if a
     future keychain service is added and this list is not updated,
     uninstall leaks residue. Real defect or documentation gap?
7. **URL scheme handling** in `URLSchemeHandler`:
   - No state-nonce validation despite the doc-comment naming
     `state=<nonce>` as a required param. Anyone who can persuade
     the user to click a `malibu://link?provider_id=X&token=Y`
     URL (email, chat, malicious webpage) hijacks the provider
     identity. Severity depends on whether the app is already
     configured (existing identity should not be overwritten
     silently — check `consume` in `MalibuApp.swift`).
   - `consume` overwrites config unconditionally — a second
     `malibu://link?...` after onboarding replaces provider_id AND
     issues a fresh CLI restart.
8. **--managed-by wiring** (CLI-side):
   - `runAutoupdateIfEligible` early-returns for
     `managedBy == "malibu-app"`. Is there any code path that reaches
     an auto-update decision BEFORE that check runs (a pre-warmed
     update, cached artifact, scheduled restart)? Grep for other
     entry points to the update machinery.
   - `parsedTarget` uses `"<unvalidated>"` sentinel when the
     recommendation is invalid — is that string later read by any
     dashboard/query that expects a semver?
9. **Test coverage sufficiency for the additive frames** in
   `phase3-binary/Tests/macprovider-cliTests/ControlSocketTests.swift`
   — round-trip and optional-field-omission tests exist; anything
   critical missing (malformed input, negative graceSeconds,
   duplicate ack)?

## What to skip

- Style, naming, formatting.
- Missing docstrings on private methods.
- "You should also test X" scope creep beyond the diff.
- Anything about the SPEC document unless it contradicts the
  implementation.
- Duplication between `ControlSocketFrame.swift` (app-side) and
  `ControlSocket.swift` (CLI-side) — this is explicitly a P0-known
  followup per the SPEC and the PR body. **Only flag if the two
  codecs are wire-incompatible in a way that breaks a real
  scenario** (e.g. different field name, different required-ness).

## Output format

```
CRITICAL findings: N
HIGH findings: N
MEDIUM findings: N
LOW findings: N

## CRITICAL

### C1 — <short title>
- File: <path>:<lines>
- Defect: <one sentence>
- Failure scenario: <concrete input → observed wrong output>
- Fix: <one sentence>

(repeat per severity)
```

Return `0 CRITICAL, 0 HIGH, 0 MEDIUM` if none survive scrutiny.
LOW/INFO items are welcome as a shipping punch-list.

Read the actual files, do not assume — the tests
(`phase3-binary/Tests/macprovider-cliTests/ControlSocketTests.swift`)
are also part of the diff scope.
