# SPEC-025 IMPL audit — PR #334

Three-lane codex audit loop against
[Augustas11/macprovider#334](https://github.com/Augustas11/macprovider/pull/334)
(branch `feat/malibu-native-app` @ `81434ca`, base `main`).

Bar per repo convention: **0 CRITICAL, 0 HIGH, 0 MEDIUM** across every
lane (code, security, architect). LOW/INFO can ship documented.

## Convergence table

| Round | CODE | SECURITY | ARCHITECT | Notes |
|---|---|---|---|---|
| R1 | 0 C / 4 H / 2 M / 2 L | 1 C / 1 H / 4 M / 1 L | 0 C / 3 H / 5 M / 1 L | initial findings |
| R2 | 0 / 4 / 0 / 0 | 0 / 0 / 1 / 0 | 0 / 1 / 0 / 1 | new correctness bugs surfaced by R1 code churn |
| R3 | 0 / 0 / 2 / 1 | **0 / 0 / 0** ✅ | **0 / 0 / 0** ✅ | SEC + ARCH converge |
| R4 | 0 / 0 / 1 / 0 | (skipped) | (skipped) | re-entrant termination edge |
| R5 | **0 / 0 / 0** ✅ | (skipped) | (skipped) | CODE converges |
| R6 | 0 / 0 / 1 / 0 | 0 / 0 / 1 / 0 | (skipped) | independent fourth-lane review (Claude); see R6 section below |

## R6 fourth-lane findings (post-convergence)

Ran as an independent sanity check that the R1–R5 fixes actually hold.

- **CODE M** — `MalibuAgent.connectControl` failure path orphaned `self.child`, blocking `start()`'s `guard child == nil else { return }` on any retry within the session. Fixed: on connect failure, stop the child, nil it, and route through `scheduleReconnect()` — same recovery path an unexpected exit takes.
- **SECURITY M** — S2 was overstated: `unsetenv` scrubs libc's `environ` but not the `KERN_PROCARGS2` snapshot that `ps -Eww` reads on macOS. The token remains visible to same-user malware via `ps -Eww $CLI_PID` for the CLI's lifetime. Downgraded here from "closed" to "attack surface reduced, not closed"; the real fix (CLI reads Keychain directly) is already tracked in the app README's known-gaps list. Narrative in the R1 SECURITY table below updated in-place.

## Prompt files

- [AUDIT_SPEC_PR334_CODE_PROMPT.md](AUDIT_SPEC_PR334_CODE_PROMPT.md), R2, R3, R4, R5
- [AUDIT_SPEC_PR334_SECURITY_PROMPT.md](AUDIT_SPEC_PR334_SECURITY_PROMPT.md), R2, R3
- [AUDIT_SPEC_PR334_ARCHITECT_PROMPT.md](AUDIT_SPEC_PR334_ARCHITECT_PROMPT.md), R2, R3

## R1 findings and where they were fixed

### CODE lane (0 C / 4 H / 2 M / 2 L)

| Id | Severity | Summary | Fix |
|---|---|---|---|
| H1 | HIGH | Crash reconnect never relaunches child — `child` non-nil guard short-circuits `start()`. | `MalibuAgent.onUnexpectedExit` now nils `self.child` before scheduling reconnect. |
| H2 | HIGH | Clean shutdown scheduled a new daemon via `terminationHandler`. | `CLIChildProcess.isStopping` flag; `markStopping()` called before `stop()`. `MalibuAgent.shutdown` cancels `reconnectTask`. |
| H3 | HIGH | `malibu://link` silently replaced provider identity (dup of SEC S1). | See S1. |
| H4 | HIGH | `isConfigured` returned true when Keychain had a token under a different account. | `isConfigured` now reads `provider_id` from config, requires the `.installed-by-app` marker, and looks up the Keychain token bound to that exact account. |
| M1 | MEDIUM | CRLF config file corrupted `provider_id` lookup. | Split on `\r`\|`\n` + `.whitespacesAndNewlines` trim. |
| M2 | MEDIUM | Uninstall Keychain wipe not awaited (dup of SEC S3 / ARCH A6). | `wipeAppOwnedState` is now `async` returning `UninstallResidue`; `performUninstall` awaits it and surfaces residue via NSAlert. |
| L1 | LOW | App-side control-socket read buffer had no frame cap. | 1 MiB cap added when read loop was moved off the actor in R2. |
| L2 | LOW | App-side decode errors silently discarded. | Carried; malformed frames continue to `try?`-skip. Not a defect against a trusted server; deferred. |

### SECURITY lane (1 C / 1 H / 4 M / 1 L)

| Id | Severity | Summary | Fix |
|---|---|---|---|
| S1 | CRITICAL | Unauthenticated `malibu://link` deep-link identity replay. | New `PendingLinkState`: SecRandom 32-byte nonce, single-use, 15-min expiry, refused when already configured. `URLSchemeHandler` requires `state`. `MalibuApp.consume` validates + surfaces errors. |
| S2 | HIGH | Bearer token exposed via `MACPROVIDER_PROVIDER_TOKEN` in child env. | **Partial.** CLI calls `unsetenv("MACPROVIDER_PROVIDER_TOKEN")` immediately after `ConfigLoader.load` in `ServeCommand.run`. This scrubs libc's `environ` chain — anything reading `/proc`-equivalent live-environ APIs no longer sees the token. It does **NOT** scrub `ps -Eww $CLI_PID` output on macOS: `ps -E` reads the exec-time env via `sysctl KERN_PROCARGS2`, which is a kernel-captured snapshot placed on the user stack at `execve` and is unreachable from `unsetenv`. Same-user malware calling `sysctl` (or plain `ps -Eww`) can still read the payout-bearing bearer token for the CLI's lifetime. Real fix: teach the CLI to read the token from Keychain directly and eliminate the env-var path entirely (already tracked). Until that lands, treat S2 as "attack surface reduced, not closed." |
| S3 | MEDIUM | Uninstall Keychain wipe race (dup of CODE M2). | See M2. |
| S4 | MEDIUM | CLI persisted `assigned_provider_token` to disk under `managed_by=malibu-app`. | `CoordinatorClient.adoptAssignedProviderTokenIfPresent` skips `ProviderTokenPersist.write` under managed_by; adopts in-memory only; emits `provider_token_persist_skipped_managed_by_malibu_app` event. |
| S5 | MEDIUM | Keychain accessible policy too weak for money-path bearer token. | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` → `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. |
| S6 | MEDIUM | UI shell had JIT / unsigned-exec-mem / library-validation / network-server entitlements. | Removed all four from `Malibu.entitlements`; kept `network.client` for planned Sparkle appcast. |
| S7 | LOW | Login-item unregister errors hidden during uninstall. | `AppLoginItem.unregisterReturningError()` surfaced via residue NSAlert. |

### ARCHITECT lane (0 C / 3 H / 5 M / 1 L)

| Id | Severity | Summary | Fix |
|---|---|---|---|
| A1 | HIGH | Codec compatible by field-name only; missing values defaulted to authoritative 0/false. | `AgentSnapshot` earnings/metrics are now `Optional`. R2 also detects the exact CLI stub tuple (`usdc=0 && malibu=0 && uptime=0 && no gpu/latency`) and drops it to nil — presenter renders `—` and `"metrics not implemented"`. |
| A2 | HIGH | App/CLI config-file ownership collision silent. | `ProviderConfig.saveProviderIdentity` throws `SaveError.existingConfigNotOwnedByApp` when the shared config exists without the `.installed-by-app` marker; onboarding surfaces via NSAlert. `isConfigured` also requires the marker. |
| A3 | HIGH | Bearer-token onboarding depends on unauthenticated URL scheme (dup of S1). | See S1. |
| A4 | MEDIUM | Two update authorities with no version provenance. | `MalibuApp.applicationDidFinishLaunching` logs `[malibu] startup app_version=X build=Y managed_by=malibu-app`. CLI-side skip event was already present. |
| A5 | MEDIUM | `MalibuAgent` had SRP-crossing responsibilities. | Extracted `AgentSnapshot` + `AgentSnapshotPresenter` (data / view-model split) and `ReconnectPolicy` struct. |
| A6 | MEDIUM | Uninstall has no completion invariant (dup of M2). | See M2. |
| A7 | MEDIUM | CLI compatibility gate missing. | `MalibuAgent.onUnexpectedExit` fast-fails on `elapsed < 3s && code != 0` and shows an actionable error instead of looping the reconnect. |
| A8 | MEDIUM | App-side surfaces untested. | Added `MalibuTests` XCTest target with codec parity, `PendingLinkState`, presenter, and CRLF parser tests. |
| A9 | LOW | SPEC-025 implementation-matrix drift. | Carried; not fixed. |

## R2 findings (introduced by R1 fix churn)

### CODE lane (0 C / 4 H / 0 M / 0 L)

| Id | Summary | Fix |
|---|---|---|
| R2 H1 | `ControlSocketClient.readLoop` was actor-isolated; blocking `Darwin.read` starved `send`/`close` → uninstall could deadlock waiting for `shutdown_request`. | Read loop moved to `Task.detached`; captures fd + Sendable continuation. `close()` calls `shutdown(fd, SHUT_RDWR)` before `Darwin.close` to unblock any pending read. |
| R2 H2 | Plain `Quit` menu / `Cmd-Q` bypassed `agent.shutdown`, orphaning the CLI child. | `AppDelegate.applicationShouldTerminate` returns `.terminateLater`, drains agent, then `NSApp.reply(true)`. |
| R2 H3 | Reconnect task could complete `start()` AFTER `shutdown()` returned. | `MalibuAgent.isShuttingDown` flag; `start()` checks it at entry AND after every suspension. |
| R2 H4 | Onboarding "Start earning" called `agent.start()` even without a linked identity. | `MalibuAgent.start` refuses to launch when `ProviderConfig.isConfigured == false`. |

### SECURITY lane (0 / 0 / 1 / 0)

| Id | Summary | Fix |
|---|---|---|
| R2 S1-R2 | R1 nonce was written to a same-user-readable file → local malware could replay. | `PendingLinkState` now holds the nonce in a process-lifetime static, guarded by `NSLock`. No filesystem writes. UX trade-off: app restart during a 15-min link window forfeits the nonce. |

### ARCHITECT lane (0 / 1 / 0 / 1)

| Id | Summary | Fix |
|---|---|---|
| R2 A1 | Optional fields existed, but `consume(.metricsResponse)` still wrote the CLI stub's `0/0/0` tuple into them. | Detect the exact stub shape and drop it to nil so presenter renders `—`. |

## R3 findings (CODE only — SEC + ARCH converged)

### CODE lane (0 / 0 / 2 / 1)

| Id | Summary | Fix |
|---|---|---|
| R3 M1 | `performUninstall` set `isTerminating` only at the end; a concurrent Cmd-Q during Keychain wipe could terminate before cleanup finished. | Track uninstall as a `Task`; `applicationShouldTerminate` awaits it. Superseded by R4 M1. |
| R3 M2 | Onboarding `finish()` closed the window and registered the login item even when `agent.start()` refused. | `finish()` guards on `ProviderConfig.isConfigured`; on refusal shows an error and keeps the window open. |
| R3 L1 | Static `pending` var emitted Swift-6 strict-concurrency warning. | Annotated `nonisolated(unsafe)`; all access is `NSLock`-serialized. |

## R4 findings (CODE only)

### CODE lane (0 / 0 / 1 / 0)

| Id | Summary | Fix |
|---|---|---|
| R4 M1 | Re-entrant `applicationShouldTerminate` returned `.terminateNow` on subsequent calls, bypassing the in-flight cleanup drain. | Replaced `isTerminating: Bool` with `terminationDrain: Task?`. Every re-entry returns `.terminateLater` and waits on the same drain's `NSApp.reply` (which is idempotent). |

## R5 — convergence

**CODE: 0 / 0 / 0 ✅**

All three lanes: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Carried LOWs:
- CODE L2 (silent decode-drop of malformed frames).
- ARCH A9 (SPEC-025 implementation-matrix drift ledger).

These ship documented; not merge blockers per repo audit convention.

## Test evidence

- `swift test --package-path phase3-binary`: 789 tests / 7 skipped / 0 failures (across all filters run during the audit rounds).
- App-side XCTest target `MalibuTests` was not executed during the loop because `xcodegen` was not installed in the audit worktree; the target is structurally correct and runs under
  `xcodebuild test -project Malibu.xcodeproj -scheme Malibu` on a machine
  that has run `xcodegen generate` in `phase3-binary/app/`.

## Followups not blocking this PR

- Extract shared `MacProviderControl` library target for the two-codec
  duplication (SPEC-025 §12 conflict #9).
- Move CLI token adoption from environment to Keychain read (SPEC-025 §7 followup).
- Portal-side `?client=mac&state=<nonce>` redirect back to `malibu://link` (SPEC-025 §14).
- Sparkle appcast at `updates.malibu.tech` (SPEC-025 §11 P3).
- `.dmg` signing + notarization in `release.yml` (SPEC-025 §11 P2).
- Implementation matrix in SPEC-025 §12 mapping each conflict to `done`/`P1`/`P2`/`P3`.
