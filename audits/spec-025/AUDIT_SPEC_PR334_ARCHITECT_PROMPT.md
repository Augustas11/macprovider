# AUDIT — PR #334 (SPEC-025 native mac app + CLI wire-up) — ARCHITECT lane

You are a senior architect reviewing pull request
`Augustas11/macprovider#334` (branch `feat/malibu-native-app`) for
**abstraction quality, layering, invariant preservation, and
long-term maintainability**. This PR ships the P0 skeleton of a new
distribution track (native Mac app) alongside the existing CLI track;
your job is to identify architectural time-bombs that will cost the
team disproportionately in the next 3–6 months.

Working tree to audit: `/Users/augstar/macprovider-pr334-audit`
(worktree of branch `audit/pr334`, tip = `81434ca`, based on
`feat/malibu-native-app`, PR base = `main`).

Diff scope (use `git diff main...HEAD` inside the worktree):

- `phase3-binary/app/**` (SwiftUI menu-bar app)
- CLI-side additions in
  `phase3-binary/Sources/macprovider-cli/ControlSocket.swift`,
  `MacProviderCLI.swift`,
  `CoordinatorClient.swift`
- `phase3-binary/Sources/MacProviderCore/Config.swift`
- `specs/SPEC-025-native-mac-app.md`

## Focus areas

Rank findings by severity (CRITICAL / HIGH / MEDIUM / LOW). For every
finding include: file, line range, one-sentence architectural
concern, and a **12-month trajectory sketch** (what breaks if we
merge as-is and iterate for two quarters).

1. **Two-codec problem**. `ControlSocketFrame.swift` (app side) and
   `ControlSocket.swift` (CLI side) each independently encode/decode
   the same wire format. The PR body promises a shared
   `MacProviderControl` library target as followup.
   - Is the duplication *actually* wire-compatible today? Enumerate
     any field-name / required-ness / default divergences (I already
     flagged CODE lane concerns — check independently).
   - Is there a migration path that doesn't force a coordinated app
     + CLI release? What version-negotiation story exists for the
     new frames (metrics/pause/resume/shutdown)?
   - The CLI acks `pause_ack accepted:false reason:"not_implemented"`
     and `metrics_response earnings_usdc:0`. The app UI shows those
     values as authoritative earnings. What does a user see on day 1?

2. **`managed_by` as an escape hatch**. The CLI's AutoUpdater
   short-circuits on `managedBy == "malibu-app"`. This creates a
   parallel update-authority regime (Sparkle in the app vs CLI's
   own updater).
   - Sparkle updates the whole app bundle, which contains the CLI
     binary. But the CLI is also distributed independently at
     `get.streamvc.live`. Two tracks now update the same binary via
     different code paths.
   - What's the version story: does the CLI's `binaryVersion`
     constant get read by both tracks? Do we now need a dual-track
     matrix in release-notes for the same version number?
   - What signals when the "managed" CLI diverges in behavior from
     the standalone CLI (e.g. a bug fix that ships in
     get.streamvc.live/install.sh but hasn't been rolled into a
     Sparkle appcast)? Any observability?

3. **Layering / responsibility boundaries** in `MalibuAgent`:
   - Single class owns: (a) CLI child process, (b) control socket
     client, (c) reconnect + backoff policy, (d) UI state
     (`AgentSnapshot`). At 178 lines it's manageable; but the next
     PR that adds "graceful drain, metrics history, pause reason
     UI" will push past 400. Is there a natural split
     (Supervisor / Client / Presenter) that we should draw now?
   - `AgentSnapshot` mixes wire types (`String` model ID, raw
     `Double` earnings) with UI-formatted strings (`stateLine`,
     `earningsLine`). Formatting-in-model is a common time-bomb:
     locale, currency conversion, MALIBU token decimals will all
     hit this in the next quarter.
   - Reconnect policy hard-codes seconds `[1, 2, 5, 15, 60]` in
     `CLIChildProcess`. Should coordinator advise? SPEC-023 handles
     rate-card advice via server; is there prior art the app should
     match?

4. **Config layout & ownership**:
   - Shared `~/.config/macprovider/config.yaml` between CLI track
     and App track, differentiated by `.installed-by-app` marker.
     The marker is not written on migration from CLI→App or
     App→CLI — the two tracks silently overwrite each other's
     config on install collisions. Documented plan for that?
   - Provider token: app-track stores in Keychain, CLI-track stores
     in config-file (per its own convention). A user who switches
     tracks has to re-onboard. Is that OK for P0, and does the SPEC
     say so? If yes, cite it; if no, flag.
   - `provider_id` is written on-disk in both tracks. If the user
     changes their wallet address in the portal, does the marker
     let us reason about which side is source of truth?

5. **URL scheme as the identity-transport**:
   - `malibu://link?state=X&provider_id=Y&token=Z` — the entire
     identity is passed via a URL scheme. This makes the app + the
     browser + the portal a triangle for a bearer-token flow. What
     failure modes are anticipated (browser blocks scheme, another
     app hijacks scheme, user pastes URL into wrong app)?
   - No alternative flow (e.g. type a code, scan a QR). If URL
     scheme fails on macOS 27, the app is undeployable. Worth a
     backup plan in the SPEC?

6. **Uninstall == "quit + best effort"** in `performUninstall`:
   - Fire-and-forget `Task { … deleteAllAppItems() }` immediately
     followed by `NSApp.terminate` guarantees a race. Even ignoring
     the security angle (CODE/SEC lanes), from an architecture POV
     this is telling: uninstall wasn't modeled as a state machine.
     What's the invariant post-uninstall? Who verifies it?
   - `wipeAppOwnedState` and `Keychain.deleteAllAppItems` and
     `AppLoginItem.unregister` each have their own error handling
     — one central "uninstall failed, here's the residue" reporter
     would age better.

7. **CLI child binary discovery** in
   `MalibuAgent.resolveCLIExecutable`:
   - Looks in `Bundle.main.bundleURL/Contents/MacOS/macprovider-cli`
     (production) with an env-var override (`MALIBU_CLI_PATH`). What
     happens if a user runs an old app version whose bundled CLI
     doesn't understand `--managed-by` — the CLI errors on unknown
     flag, and the app enters an infinite reconnect loop (see
     restart-backoff). Is there compatibility negotiation?
   - No PATH fallback / no discovery of a system-installed
     `macprovider-cli` (from `get.streamvc.live/install.sh`).
     Intentional? Documented?

8. **Test surface**:
   - Only the CLI-side codec has tests
     (`phase3-binary/Tests/macprovider-cliTests/ControlSocketTests.swift`).
     No tests for the app-side codec, `MalibuAgent`,
     `ProviderConfig`, `KeychainStore`, `URLSchemeHandler`, or
     uninstall flow. For a money-path-adjacent module this is
     under-specified. What's the minimum test set that must land
     before we call this beta?
   - CLI-side integration test for `managed_by` skip event is
     explicitly deferred per commit message
     (`975e935`). What's the risk of it staying deferred past P1?

9. **SPEC-025 vs code drift**:
   - Read `specs/SPEC-025-native-mac-app.md` §5, §6, §7, §11 and
     compare against the code. Report every promise the SPEC makes
     that the code does not yet satisfy AND is not explicitly
     called out as a followup in the PR body.
   - Any promise the code makes that the SPEC doesn't cover?
   - The SPEC's own "conflict registry" (§12) — does the code
     resolve each numbered conflict or defer? For deferrals, does
     the PR body list them?

## What to skip

- Cosmetic naming issues.
- "Should also test X" beyond the explicit list in §8.
- Sparkle appcast implementation (SPEC-025 §11 P3, not in scope).
- Release pipeline changes (SPEC-025 §11 P2, not in scope).
- Portal-side redirect (SPEC-025 §11 P4, not in scope).

## Output format

```
CRITICAL findings: N
HIGH findings: N
MEDIUM findings: N
LOW findings: N

## CRITICAL

### A1 — <short title>
- File: <path>:<lines>
- Concern: <one sentence>
- 12-month trajectory: <what breaks if we merge as-is and iterate>
- Fix: <one sentence>

(repeat per severity)
```

Return `0 CRITICAL, 0 HIGH, 0 MEDIUM` if none survive scrutiny.

Read the actual files — the SPEC is a contract, the code is the
implementation, and the PR body is the delta. Report divergences.
