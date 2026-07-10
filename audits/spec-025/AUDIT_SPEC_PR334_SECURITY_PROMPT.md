# AUDIT — PR #334 (SPEC-025 native mac app + CLI wire-up) — SECURITY lane

You are a security engineer reviewing pull request
`Augustas11/macprovider#334` (branch `feat/malibu-native-app`) for
**credential-handling, deep-link, IPC, keychain, entitlement, and
code-signing risks**. The app spawns a provider daemon that holds a
bearer token pinning USDC payouts to the user's wallet. Compromise of
that token = attacker steers earnings to their own address, so this is
a money-path surface.

Working tree to audit: `/Users/augstar/macprovider-pr334-audit`
(worktree of branch `audit/pr334`, tip = `81434ca`, based on
`feat/malibu-native-app`, PR base = `main`).

Diff scope (use `git diff main...HEAD` inside the worktree):

- All new files under `phase3-binary/app/**`
- `phase3-binary/app/Malibu.entitlements`
- `phase3-binary/app/project.yml` (info-plist keys, hardened runtime,
  URL scheme registration)
- SPEC document `specs/SPEC-025-native-mac-app.md`

## Focus areas

Rank findings by severity (CRITICAL / HIGH / MEDIUM / LOW). For every
finding include: file, line range, one-sentence risk statement, and a
concrete attack scenario naming the attacker's capability and the
outcome.

1. **`malibu://link?...` URL scheme registration**
   (`phase3-binary/app/project.yml` CFBundleURLTypes,
   `URLSchemeHandler.swift`, `MalibuApp.consume`).
   - `state=<nonce>` documented but never validated. Any webpage the
     user visits can invoke `window.location = 'malibu://link?...'`
     and overwrite the pinned provider identity.
   - `MalibuApp.consume` writes to Keychain + restarts the CLI on
     any inbound URL, even when the app is already configured.
     Compare against a portal-issued redirect design (SPEC-025) —
     is there any binding between the nonce sent to the portal and
     the token returned?
   - macOS URL-scheme conflict / hijack: multiple apps can register
     the same scheme; the last-installed wins. Does the code detect
     that our handler is not the frontmost handler for `malibu://`
     before persisting sensitive state?
   - Tokens end up in `URL.query`, which macOS may log via URL
     completion / Handoff / clipboard suggestions. Real risk?

2. **Keychain configuration** (`KeychainStore.swift`)
   - `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
     — appropriate for a bearer token that must survive reboot?
     Compare against `WhenUnlocked`.
   - No `kSecUseDataProtectionKeychain` — on modern macOS this means
     legacy keychain. Any consequence for Sequoia+?
   - No `kSecAccessControl` / `SecAccessControlCreateWithFlags` — is
     the token retrievable by any app running as the user, without a
     re-auth prompt? For a token pinning USDC payouts, is that
     acceptable?
   - `hasProviderToken` matches on service only — see CODE lane §6.
     Security angle: does that let a stale token from a different
     account get replayed?
   - `deleteAllAppItems` iterates a hard-coded service list — is
     `tech.malibu.auth` and `tech.malibu.receipt` actually populated
     anywhere in the diff, or is it forward-declaration? If they are
     never written but hard-coded here, real deletions can miss a
     future service (documentation gap risk).

3. **Environment / process-argv token surface**
   (`MalibuAgent.start` reads Keychain, sets
   `MACPROVIDER_PROVIDER_TOKEN` in `extraEnvironment`.
   `CLIChildProcess.start` merges into `proc.environment`.)
   - Token in environment is visible to any child processes the CLI
     spawns (e.g. mlx-swift subprocesses). Does the CLI spawn any
     such? Grep for `Process()` or `posix_spawn` in the CLI target.
   - Token in `ProcessInfo.processInfo.environment` is inherited
     from the app parent — anything in the app's process tree
     (crash reporters, XPC helpers) reads that same env?
   - `proc.environment = env` where `env` is a full copy of the
     parent's env — leaks anything sensitive from the app's launch
     env (Apple ID, Xcode variables) into the CLI child? Minor.

4. **Config-file write semantics** (`ProviderConfig.saveProviderIdentity`)
   - Correctly `chmod 0600` after atomic write — good. But the
     atomic write goes through a temporary file (`.atomic` option).
     Is the temp file created with 0600 or default 0644 before the
     rename? Race window between write-visible and chmod?
   - The token is **explicitly not** written to disk in this file
     (comment says so) — verify no path stores the token to disk
     anywhere else in the diff. Grep for
     `provider_token:` string emission.

5. **Uninstall completeness** (`ProviderConfig.wipeAppOwnedState`,
   `KeychainStore.deleteAllAppItems`, `AppLoginItem.unregister`,
   `MalibuApp.performUninstall`)
   - `Task { try? await KeychainStore.deleteAllAppItems() }` is
     fire-and-forget; caller then invokes `NSApp.terminate` — the
     process may exit before the Task runs. Bearer token survives
     uninstall — a "delete my node" flow that leaves the pinned
     token in Keychain.
   - `try? ProviderConfig.wipeAppOwnedState()` — errors swallowed.
     A permission-denied on `~/.config/macprovider/config.yaml`
     leaves the token-hint config on disk after user pressed
     "Quit and Uninstall". Not a token leak (token isn't on disk)
     but confuses future audits.
   - Uninstall does NOT stop `SMAppService.mainApp` for the CLI's
     own launchd LaunchAgent (if the CLI track was ever used). Any
     residue?

6. **Entitlements** (`phase3-binary/app/Malibu.entitlements`)
   - `com.apple.security.cs.allow-jit`,
     `com.apple.security.cs.allow-unsigned-executable-memory`,
     `com.apple.security.cs.disable-library-validation` are all
     enabled with hardened runtime. Justify each — the app itself
     is a menu-bar SwiftUI shell that spawns a CLI child; does the
     shell need JIT and unsigned-exec-mem? Or are these only needed
     by mlx-swift inside the CLI child, which is a separate process?
     If shell doesn't need them, disable — that's a real attack
     surface reduction.
   - `com.apple.security.network.server` — the app opens a Unix
     domain socket client, not a TCP server. Does the app need
     network.server, or is that only for the CLI child?
   - No app sandbox. Explicit non-goal per SPEC-025?
     Distribution channel implication (Developer ID + notarization
     vs Mac App Store).

7. **Hardened runtime / signing chain** (`project.yml`)
   - `ENABLE_HARDENED_RUNTIME: YES` present.
   - `CODE_SIGN_STYLE: Manual` set. No signing identity pinned in
     this file, so it'll fall back to whatever `xcodebuild` picks.
     Not a defect in the source tree itself, but flag if
     release-time signing is expected to catch this.
   - The bundled CLI at `Contents/MacOS/macprovider-cli` — is it
     re-signed with the same identity + hardened runtime + a
     compatible entitlements set at build time? SPEC-025 §6.2 says
     yes; verify nothing in the diff conflicts.

8. **SMAppService / login item semantics** (`AppLoginItem.swift`)
   - `SMAppService.mainApp.register()` registers the app itself as a
     login item. On subsequent app versions with different bundle
     IDs, does macOS orphan the old entry?
   - `unregister` swallows errors silently — user pressed "Quit and
     Uninstall", we tell them everything is gone, but a login-item
     entry survived. Real risk (app auto-launches next boot even
     after "uninstall")?

9. **SPEC-025 promises vs code**
   - The PR body enumerates a Quit-and-Uninstall QA scenario. Does
     the code satisfy it? Check `performUninstall` end-to-end.
   - SPEC-025 §7 marker-file check: `wipeAppOwnedState` uses
     `.installed-by-app` correctly, but there's a documented
     scenario where the marker is missing (user ran install.sh
     first, then installed the app) — in that case the config file
     is preserved, but the Keychain token is still deleted, so the
     CLI is left with a `provider_id` on disk and no token in the
     environment. Confusing state — worth flagging?

## What to skip

- Style, naming.
- SPEC document text unless it directly enables a security defect.
- "You should also implement Sparkle signature pinning" or other
  future-scope items — flag only if a real, current attack exists.
- Duplication between app-side and CLI-side codec (P0 followup).

## Output format

```
CRITICAL findings: N
HIGH findings: N
MEDIUM findings: N
LOW findings: N

## CRITICAL

### S1 — <short title>
- File: <path>:<lines>
- Risk: <one sentence>
- Attack scenario: <attacker capability → outcome, name inputs>
- Fix: <one sentence>

(repeat per severity)
```

Return `0 CRITICAL, 0 HIGH, 0 MEDIUM` if none survive scrutiny.

Read the actual files. If a claim in the PR body contradicts the
diff, flag it under MEDIUM.
