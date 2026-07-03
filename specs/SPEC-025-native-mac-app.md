# SPEC-025 — Native Mac App (signed `.dmg` + menu bar wrapper)

Status: DRAFT v0.1 · Owner: augstar · Target: 2026 Q3

## 0. Terminology

- **CLI track** — existing `macprovider-cli` binary + `install.sh` + `live.streamvc.macprovider-watchdog` LaunchAgent. Developer-facing.
- **App track** — new `Malibu.app` (this spec). Non-developer-facing; brand is Malibu (see [malibu-branding memory]). User-visible strings never say "MacProvider" or `streamvc.live`.
- **Wrapper** — the Swift/SwiftUI code added by this spec.
- **CLI child** — the existing `macprovider-cli` binary, launched by the wrapper.

Both tracks must coexist and produce identical on-chain behavior.

## 1. Goal

Ship a **click-and-forget provider experience** for non-developer Mac users. Replace the terminal-only path (`curl … | bash` at `malibu.tech/host/`) with a signed, notarized `.dmg` containing `Malibu.app` — a menu bar wrapper around the existing `macprovider-cli` binary.

### Success criteria

- Non-technical Apple Silicon user goes from `malibu.tech/host` → running node in **≤ 3 minutes**, zero terminal.
- Same coordinator behavior, same receipts, same portal registration as the CLI track.
- Auto-update ships silently. Uninstall is drag-to-trash with **zero leftover LaunchAgent**.
- The CLI track keeps working unchanged; both tracks can coexist on the same Mac without double-registering with the coordinator (see §12 "Conflict" — reuse existing `ProviderConflictDetector`).

### Non-goals (v1)

- Mac App Store distribution (sandbox conflicts with `mlx-swift` + long-running WS daemon).
- Windows / Linux / Intel Mac.
- In-app wallet UX beyond linking an address issued by portal.
- Fleet management across multiple Macs from one app.

## 2. What already exists (grounding)

From reading `phase3-binary/`:

| Component | Where | What we reuse |
|---|---|---|
| Provider daemon | `Sources/macprovider-cli/MacProviderCLI.swift` | Ship the compiled binary inside `Malibu.app/Contents/MacOS/` |
| Control-plane IPC | `Sources/macprovider-cli/ControlSocket.swift` — typed JSON frames on Unix socket (`switch_request`, `status_request`, `rotate_receipt_key_request`, `switch_progress`, `status_response`) | Wrapper connects as client; no new protocol |
| Local HTTP | `Sources/macprovider-cli/HTTPServer.swift` on `127.0.0.1:<port>` | Wrapper reads status + metrics |
| Runtime | `mlx-swift-examples` (MLXLLM, MLXLMCommon) — pure Swift, no Python | Ship in-process; entitlements simpler |
| Auth model | `provider_id` + `provider_token` bearer, per SPEC-001 / XSEC-1 | Wrapper receives token from portal deep-link; stores in Keychain |
| Config | `~/.config/macprovider/config.yaml`, secret in `provider_token` field | Wrapper writes the same file; keeps CLI-track compatible |
| Watchdog LaunchAgent | `ops/macprovider-watchdog/live.streamvc.macprovider-watchdog.plist` | **Not used by App track** — replaced with `SMAppService.mainApp.register()` |
| Portal | `portal.streamvc.live` (SPEC-014) — issues `provider_id` + `provider_token`, hosts installer catalog | Wrapper opens a portal URL for token issuance |
| Release manifest / checksum | `scripts/sign-catalog.go`, tier2 release scripts | Feeds the same manifest that Sparkle appcast references |
| Signing + notarization pipeline | `.github/workflows/release.yml` "Sign + notarize binary" step + `phase3-binary/dist/release-signing-runbook.md` | Reuse the existing keychain-import / codesign / `notarytool submit --wait` / `stapler` pattern verbatim; extend to sign the `.app` and `.dmg` |
| Signed `.pkg` delivery container | Same workflow, `pkgbuild` + `productsign` with **Developer ID Installer** cert, identifier `live.streamvc.macprovider.cli`, preinstall blocks direct GUI install | Do **not** confuse with the App-track `.pkg` (backlog item, distinct identifier `tech.malibu.app`) — the existing one is a delivery container for `install.sh`, not a user-facing installer |

**README is stale.** `README.md` says signing is "planned for a future release." The actual state (as of `release.yml`): full pipeline exists, activates conditionally on secret presence — driven by the macOS 26.3.1+ launchd/AMFI change that rejects adhoc-signed binaries (see memory `macprovider-launchd-amfi-blocker-macos-26`). This spec **extends** that pipeline; it does not build it from scratch. README needs a follow-up correction.

## 3. User flows

### 3.1 First-run (cold install)

1. `malibu.tech/host` → **Download for Mac** → `Malibu.dmg` (~40 MB target).
2. Open `.dmg` → drag `Malibu.app` to `Applications`. Standard Finder UX.
3. Launch `Malibu.app`. Gatekeeper checks the stapled notarization ticket, no scary dialog.
4. Menu bar icon appears (`NSStatusItem`, `LSUIElement=true` — no Dock icon). Welcome window opens with 3 steps:
   1. **Link your node** — button opens `https://portal.streamvc.live/onboard?client=mac&state=<nonce>` in the default browser. User signs in with GitHub at the portal (existing flow). Portal issues `provider_id` + `provider_token` and redirects to `malibu://link?state=<nonce>&provider_id=…&token=…`. Wrapper handles the URL scheme (`Info.plist` `CFBundleURLTypes`), validates state, stores token in Keychain (service `tech.malibu.provider`).
   2. **Wallet address** — paste-field for USDC + $MALIBU payout address, or "Same as I set at the portal" (default). Bound to `provider_id` server-side; the app just displays it.
   3. **Hardware check** — probe RAM tier via `sysctl hw.memsize`, GPU family via Metal, macOS version. Pick default model (existing recommendation logic in `AutotuneRecommend.swift` — invoke via a new subcommand, see §12).
5. **Start earning** button → wrapper:
   - writes `~/.config/macprovider/config.yaml` (respecting the CLI track's path — no schism),
   - calls `SMAppService.mainApp.register()` (macOS 13+),
   - spawns `Contents/MacOS/macprovider-cli` as a child (see §5 for lifecycle),
   - opens dashboard.

Time budget: 90 s of UI + 60–240 s for first model download in background.

### 3.2 Steady state

- Menu bar icon: state glyph (idle · serving · error) + today's USDC.
- Popover: today's USDC, today's $MALIBU, uptime, current model, GPU temp, latency p50, "Open Dashboard".
- Dashboard (SwiftUI window): earnings chart, wallet card, model swap dropdown (calls `switch_request` over ControlSocket), live log tail, "Copy diagnostics", "Quit and Uninstall".
- On login: `launchd` starts `Malibu.app` in the background per `SMAppService`. No Dock icon.

### 3.3 Updates — Sparkle 2.x

- Appcast at `https://updates.malibu.tech/appcast.xml`, EdDSA-signed.
- Delta updates (BSDiff) to keep the ~40 MB payload small. Model weights live outside `.app` and are never re-downloaded on update.
- Wrapper stops the CLI child gracefully (`shutdown` ControlSocket frame → wait for `switch_ack` acceptance or 30 s timeout → SIGTERM → SIGKILL), applies update, relaunches. The existing `AutoUpdater.swift` handles the *CLI's* self-update; the wrapper's Sparkle handles the *whole `.app`* update. They must not fight each other — see §12.

### 3.4 Uninstall

- Drag `Malibu.app` → Trash. Because `SMAppService` is registered by the app bundle, macOS auto-cleans the launchd registration on next login.
- App also ships **Quit and Uninstall** menu item that synchronously:
  - `SMAppService.mainApp.unregister()`
  - shuts down CLI child cleanly
  - removes `~/.config/macprovider/config.yaml` **only if it belongs to the App track** — see §7 for the marker bit; do not stomp a CLI-track user's config
  - removes `~/Library/Application Support/Malibu/` and `~/Library/Caches/Malibu/`
  - removes Keychain items under `tech.malibu.*`
  - offers to purge `~/Library/Logs/macprovider/` (checkbox, default off)

The CLI track's `uninstall.sh` is unaffected and remains the developer-facing path.

## 4. Distribution — `.dmg` (not `.pkg`)

Recommendation: **`.dmg`**.

| Concern | `.dmg` (chosen) | `.pkg` |
|---|---|---|
| Non-dev familiarity | High (Slack, Signal, Tailscale) | Medium |
| Requires elevation | No | Yes (or user-scope pkgs, clunky) |
| Post-install steps | App handles via `SMAppService` on first click | Installer scripts (extra attack surface) |
| Update path | Sparkle replaces `.app` in place | Works but clunkier |
| CI complexity | `create-dmg` one-liner | `pkgbuild` + `productbuild` + component plist |
| MDM/enterprise | Weaker | Stronger |

Ship `.dmg` for v1. Add signed `.pkg` **later** for enterprise/MDM only; content is the same `.app`.

## 5. Wrapper ↔ CLI: architecture

```
┌───────────────────────────── Malibu.app ─────────────────────────────┐
│                                                                      │
│  MalibuMenuBar (NSStatusItem)  ◄──►  MalibuDashboard (SwiftUI)       │
│                    │                          │                      │
│                    └──────────┬───────────────┘                      │
│                               ▼                                      │
│                     MalibuAgent (Swift actor)                        │
│                    · owns child lifecycle                            │
│                    · owns ControlSocket client                       │
│                    · owns HTTPServer polling                         │
│                    · registers SMAppService                          │
│                               │                                      │
│           stdout/stderr ──────┤──── ControlSocket (unix)             │
│           logs to             │     status/switch/rotate frames      │
│           ~/Library/Logs/…    │                                      │
│                               ▼                                      │
│          Contents/MacOS/macprovider-cli  (unchanged binary)          │
│          launched with:                                              │
│            --config ~/.config/macprovider/config.yaml                │
│            --control-socket <APPSUP>/agent.sock                      │
│            --http-port <ephemeral>                                   │
│            --managed-by malibu-app                                   │
└──────────────────────────────────────────────────────────────────────┘
```

### 5.1 Bundle layout

```
Malibu.app/Contents/
  Info.plist                       # LSUIElement=true, LSMinimumSystemVersion=14.0,
                                   # CFBundleURLTypes = [{scheme: malibu}]
  MacOS/
    Malibu                         # Swift binary (wrapper)
    macprovider-cli                # existing binary, arm64 only
  Resources/
    Assets.car
    appcast-key.pub                # Sparkle EdDSA pubkey
  Frameworks/
    Sparkle.framework
    MLX.framework                  # if not statically linked in CLI
    MLXLLM.framework
    MLXLMCommon.framework
    MacProviderCore.framework      # shared Swift Package product
  _CodeSignature/
```

**Assumption to verify:** whether `mlx-swift` can be statically linked into `macprovider-cli` or must ship as embedded frameworks. If frameworks, both wrapper and CLI child link against the same copies → smaller bundle. Verify during P0.

### 5.2 IPC: reuse `ControlSocket`, add nothing new

Wrapper acts as ControlSocket **client**. Frames used from `ControlSocket.swift` verbatim:

- `status_request` → `status_response(currentModelID, runtimeState)` — polled every 2 s while dashboard is open, every 15 s otherwise.
- `switch_request(targetModelID, requestedAtMs)` → `switch_ack` → `switch_progress` (stream).
- `rotate_receipt_key_request(providerID)` → `rotate_receipt_key_result`.

**New frames needed for the app track — additions to `ControlSocketFrame`:**

- `metrics_request` → `metrics_response(earningsUsdc, malibuAccrued, gpuC, latencyP50Ms, uptimeSec)`
- `pause_request` / `resume_request` → `pause_ack` / `resume_ack`
- `shutdown_request(graceSeconds)` → `shutdown_ack`

These are additive; CLI-track users don't see them. Wire format identical (JSON on unix socket). Add to `ControlSocketCodec.encode` / `decode` and unit-test in `MacProviderCoreTests`.

**Alternative considered and rejected:** exposing metrics via `HTTPServer` on 127.0.0.1. Rejected because localhost HTTP is trivially reachable by any process on the machine (including malicious tabs via DNS rebinding), while a unix socket in `~/Library/Application Support/Malibu/` with mode `0600` is bounded to the user's uid. The CLI already uses HTTP for coordinator-adjacent stuff and unix for control-plane — we stay in that pattern.

### 5.3 Child process lifecycle

- Wrapper spawns CLI child via `Process` with:
  - `stdout` / `stderr` piped to `~/Library/Logs/malibu/malibu-cli-YYYYMMDD.log` (rolling, 100 MB cap).
  - `--managed-by malibu-app` flag (new; CLI uses it to suppress its own auto-update logic — see §12 conflict).
- Wrapper watches child exit. On unexpected exit: exponential-backoff restart (1 s, 2 s, 5 s, 15 s, 60 s cap), surface "Reconnecting" state in menu bar. If >5 restarts in 5 min: stop and show error banner in dashboard with "View logs" and "Send diagnostics" buttons.
- On wrapper quit (Cmd-Q or logout): send `shutdown_request(graceSeconds: 30)` → wait for `shutdown_ack` or 30 s → SIGTERM → 5 s → SIGKILL.

## 6. Signing & notarization

**Extending, not building.** The CI job "Sign + notarize binary" in `.github/workflows/release.yml` already:

- imports a Developer ID Application `.p12` into a transient keychain (`security create-keychain build.keychain` → deleted on exit),
- codesigns `macprovider-cli` with `--options runtime --timestamp`,
- verifies with `codesign --verify --strict --verbose=2`,
- wraps in a transient `.zip` (Apple's rule for bare Mach-O), submits via `xcrun notarytool submit --wait`,
- re-tars the signed binary back into `phase3-binary-m4-<tag>.tar.gz`,
- if the Installer cert is present: `pkgbuild` + `productsign` → `notarytool submit --wait` → `stapler staple` → `stapler validate` → outputs signed `.pkg` (identifier `live.streamvc.macprovider.cli`, preinstall script blocks direct GUI install).

This spec **adds** an App-track job to the same workflow (or a separate `release-app.yml`) that reuses the exact same keychain-setup pattern and secrets. Do not invent new secret names — piggyback.

### 6.1 CI secrets (already defined; reuse)

| Secret | Purpose | Already used by |
|---|---|---|
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64` | Developer ID **Application** cert — signs binaries + `.app` | CLI binary signing |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | .p12 password | Same |
| `APPLE_DEVELOPER_ID_INSTALLER_CERT_P12_BASE64` | Developer ID **Installer** cert — signs `.pkg` | Existing signed `.pkg` delivery container |
| `APPLE_DEVELOPER_ID_INSTALLER_CERT_PASSWORD` | .p12 password | Same |
| `APPLE_NOTARY_APPLE_ID` | Apple ID for notarytool | Notarizing CLI + `.pkg` |
| `APPLE_NOTARY_PASSWORD` | App-specific password | Same |
| `APPLE_NOTARY_TEAM_ID` | Team ID | Same |
| **`SPARKLE_EDDSA_PRIVATE_KEY`** | New — Sparkle appcast signing (**not** a codesign identity) | This spec adds |

Only one new secret needed: the Sparkle EdDSA key.

### 6.2 New CI steps added by this spec

Runs on the same macOS runner as the existing job, after the CLI binary is signed and notarized. The signed CLI binary from the existing step is the input.

1. `xcodebuild -scheme Malibu -configuration Release archive -archivePath Malibu.xcarchive` (new Xcode project lives at `phase3-binary/app/Malibu.xcodeproj`).
2. `xcodebuild -exportArchive -archivePath Malibu.xcarchive -exportPath build/Malibu -exportOptionsPlist app/ExportOptions.plist` → `Malibu.app` (already signed by Xcode).
3. Copy the already-signed `macprovider-cli` into `Malibu.app/Contents/MacOS/`.
4. Re-sign the whole bundle bottom-up in one pass so the outer signature covers the newly-embedded CLI:
   `codesign --force --options runtime --timestamp --entitlements phase3-binary/app/Malibu.entitlements --sign "$SIGNING_ID" --deep Malibu.app`
5. `codesign --verify --strict --verbose=2 --deep Malibu.app`
6. `create-dmg` → `Malibu-<version>.dmg` (Homebrew-published tool; pin version).
7. `codesign --sign "$SIGNING_ID" --timestamp Malibu-<version>.dmg`.
8. `xcrun notarytool submit Malibu-<version>.dmg --apple-id $APPLE_NOTARY_APPLE_ID --password $APPLE_NOTARY_PASSWORD --team-id $APPLE_NOTARY_TEAM_ID --wait` (this one **is** staplable — unlike the bare CLI).
9. `xcrun stapler staple Malibu-<version>.dmg` and `stapler validate`.
10. Upload to `https://download.malibu.tech/Malibu-<version>.dmg` (immutable, versioned), atomic swap of `latest.dmg` symlink.
11. `sign_update` (Sparkle CLI) → EdDSA signature; render appcast item; publish `https://updates.malibu.tech/appcast.xml`.

Reuse `cleanup_signing_material` trap from the existing job.

### 6.3 Entitlements (`Malibu.entitlements`)

```xml
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
```

Rationale:

- `allow-jit` + `allow-unsigned-executable-memory` — `mlx-swift` compiles Metal shaders at runtime.
- `disable-library-validation` — needed to launch the child CLI binary (which has its own signature) from within the sandbox-adjacent app process. Verify at P0 whether we can avoid this by signing both with the same TeamID (should be sufficient).
- `network.server` — the CLI's `HTTPServer` binds `127.0.0.1`.

**Not requested (would be trust-drops):** Accessibility, Full Disk Access, Screen Recording, Camera, Microphone. If any of these surface as required during P0, escalate immediately.

## 7. Storage, config, and CLI-track coexistence

The single biggest risk in this spec is stomping a config that a developer previously created via `install.sh`. Resolution:

| Data | Location | Owned by |
|---|---|---|
| Provider daemon config | `~/.config/macprovider/config.yaml` | **Shared** with CLI track |
| Wrapper preferences (window sizes, opt-ins) | `~/Library/Application Support/Malibu/prefs.json` | App track only |
| App-track marker | `~/Library/Application Support/Malibu/.installed-by-app` (file with install date) | App track only |
| Logs (rolling, 100 MB cap) | `~/Library/Logs/malibu/` | Shared, app tags its own lines |
| `provider_token` | Keychain, service `tech.malibu.provider`, account `<provider_id>` | App track; CLI track keeps YAML |
| Session receipt keys | Keychain, service `tech.malibu.receipt`, account `<key_id>` | Unchanged from CLI track (reuse existing key store) |

Rules:

- **On first run of the app:** if `config.yaml` exists AND wrapper marker file does NOT exist → show migration dialog: "We found a MacProvider config. Import it into Malibu?" On import, wrapper reads the YAML's `provider_token`, moves it to Keychain, sets marker file, keeps the YAML minus the secret. Never silent-migrate.
- **On Quit-and-Uninstall:** wrapper only deletes `config.yaml` if marker file exists AND matches. Otherwise leaves it alone.
- **CLI track never touches** `~/Library/Application Support/Malibu/` or `tech.malibu.*` Keychain entries.

## 8. LaunchAgent

Use `SMAppService.mainApp` (macOS 13+; we target 14+). One line at "Start earning":

```swift
try SMAppService.mainApp.register()
```

- Apple surfaces this to the user in **System Settings → Login Items**. Prep onboarding copy so users don't panic-decline.
- No `.plist` files to author. `launchd` restarts the app on crash / reboot, controlled by macOS not by us.
- If the user disables it in Settings, the wrapper detects `SMAppService.mainApp.status == .disabled` on next foreground launch and shows a soft nudge in the dashboard. Never re-register without user click.
- **`live.streamvc.macprovider-watchdog` LaunchAgent from the CLI track is NOT installed by the App track**, and vice versa. If both exist on one machine, only one CLI child runs — see §12.

## 9. Sparkle appcast

- Public key baked into `Contents/Resources/appcast-key.pub`. Private key lives in CI secret; rotate quarterly; keep the previous key valid for one grace release.
- Appcast entries include: version, min OS, download URL (signed .dmg), EdDSA signature, release notes URL, phased rollout percentage (Sparkle 2 supports this).
- Delta updates: publish full `.dmg` + BSDiff patch from previous release. Wrapper picks whichever is smaller.
- Failure handling: if patch application fails signature check, fall back to full download. If full download fails, keep running current version and retry on next check.

## 10. Landing page changes (`malibu.tech/host/`)

- Above the fold: big coral **Download for Mac** button → `https://download.malibu.tech/latest.dmg`. Same button also emits the SHA-256 next to it for the paranoid.
- Below the button: disclosure toggle "**Prefer terminal?**" → reveals current `curl -fsSL https://get.streamvc.live/install.sh | bash` block. Devs keep their flow; the surface area for non-devs is a single button.
- Step section rewritten: "Download → Open → Earn." GitHub sign-in is now inside the app, not step 2.
- Requirements card unchanged.
- New troubleshoot page at `malibu.tech/host/troubleshoot` covering: Gatekeeper block (very rare post-notarization), `SMAppService` denied, first-model-download stuck, uninstall.

This landing page change is **file-level small** (`host/index.html` in the malibu repo) and non-blocking on the app itself.

## 11. Rollout plan

| Phase | Scope | Exit criteria |
|---|---|---|
| **P0 — Skeleton** (1 wk) | Swift menu bar app in a new Xcode project, spawns bundled `macprovider-cli`, no onboarding, hardcoded `config.yaml` copied by hand. Add `metrics_request` + `shutdown_request` frames to `ControlSocket`. | End-to-end job served through `.app` on a dev Mac. |
| **P1 — Onboarding** (1 wk) | `malibu://` URL scheme; portal deep-link flow; wallet paste; hardware autotune call; `SMAppService.register()`; dashboard read-only. | 5 friendly testers install by drag-drop and start earning without CLI. |
| **P2 — `.app`/`.dmg` signing** (0.5 wk) | **Extend** existing `release.yml` "Sign + notarize binary" step with the App-track substeps in §6.2. Verify entitlements + hardened runtime. No new secrets except `SPARKLE_EDDSA_PRIVATE_KEY`. | Gatekeeper accepts `.dmg` on a fresh macOS 14 install (no `xattr -d`); `stapler validate` passes. |
| **P3 — Sparkle + updates** (0.5 wk) | Appcast, EdDSA signing key, delta patches, phased rollout. | Live `v0.1 → v0.2` update on 5 test Macs, one via delta patch. |
| **P4 — Landing page swap** (0.5 wk) | Redesigned `host/index.html`, `download.malibu.tech` endpoint, SHA-256 sidecar, troubleshoot page. | 50/50 A/B against current curl page for 1 wk on `malibu.tech/host`. |
| **P5 — WalletConnect** (1 wk) | Alongside paste flow; opens Rainbow / MetaMask / Coinbase Wallet via deep link; nonce signature bound to provider_id server-side. | 3 wallets verified round-trip. |
| **P6 — Homebrew Cask** (0.5 wk) | `brew install --cask malibu` pulls the same signed `.dmg`. | `brew audit --cask malibu` clean, install / uninstall round-trip. |

Total: ~5 focused weeks + review. One Swift engineer + part-time CI/infra + landing-page dev.

## 12. Conflicts to resolve before coding

These are the things I'd flag as **must-decide before P0**, in priority order:

1. **CLI-track vs App-track collision on one Mac.** If a dev already ran `install.sh`, then installs `Malibu.app`, we now have two candidate CLI processes and two LaunchAgents. Use the existing `ProviderConflictDetector.swift` — on wrapper launch, detect an active CLI daemon (probe unix socket + LaunchAgent bootstate). If found, offer: (a) migrate (uninstall watchdog LaunchAgent + adopt config, see §7), (b) run side-by-side under a distinct `provider_id` suffix, or (c) abort. Default: (a). No silent takeovers.
2. **Auto-update fights.** `AutoUpdater.swift` in the CLI self-updates the binary from a signed catalog. In the App track, Sparkle updates the whole `.app` (which includes the CLI). Solution: the wrapper launches the child with `--managed-by malibu-app`; the CLI must treat this flag as a signal to **disable its own AutoUpdater** and defer to Sparkle. New CLI-side ticket.
3. **`mlx-swift` static vs dynamic linking.** If dynamic, both binaries in the bundle should share one copy in `Frameworks/` (smaller download, correct code signature). If static, each binary carries its own — larger but simpler. Decision drives the entitlements section (`disable-library-validation` may become unnecessary).
4. **`disable-library-validation` — can we drop it?** If wrapper and CLI are both signed with the same TeamID and hardened runtime, loading the child shouldn't need this. Verify empirically at P0; dropping it is a clean security win.
5. **Portal deep-link handshake for the app.** Portal today (SPEC-014) issues `provider_token` for a browser user. We need a small addition: `?client=mac&state=<nonce>` → redirect to `malibu://link?state=<nonce>&…`. State validation prevents drive-by token injection. Cross-team ticket with portal owner.
6. **Model weight storage location.** CLI track today writes to `~/.cache/…` (verify path). Wrapper should share this — model downloads are multi-GB, we don't want two copies. Confirm exact path in `ModelRuntime.swift` before P0 and either standardize on it or add a config option.
7. **`SMAppService` user rejection.** If user declines the "run at login" prompt, do we still run when the app is open? Yes — treat it as a soft state; nudge in dashboard once, then respect the choice.
8. **Sparkle key custody.** Whoever holds the EdDSA private key can push to every installed Mac. Store in 1Password shared vault, read by CI via short-lived deploy token, rotate quarterly, keep previous key valid one release.

## 13. Out of scope (backlog)

- `.pkg` for MDM/enterprise.
- Windows/Linux/Intel Mac builds.
- Multi-node fleet management.
- Fully in-app wallet (send/receive).
- iCloud-synced config between the user's Macs.
- Sparkle-based *downgrade* on rollback (Sparkle 2 supports it; not v1).

## 14. What this SPEC does NOT change

- Coordinator protocol.
- Receipt shape, signing, or verification (`macprovider-verify` still works against both tracks).
- On-chain flows, payout logic, $MALIBU emissions, staking.
- CLI-track `install.sh` / `uninstall.sh` / watchdog — unchanged, keep shipping.
- Existing CLI signing/notarization pipeline in `release.yml`. This spec **adds** steps that consume its output; it does not modify the CLI substeps or their secrets.
- Existing signed `.pkg` delivery container (`live.streamvc.macprovider.cli`, preinstall blocks GUI install). The App-track `.dmg` is a completely separate artifact.
- Portal (SPEC-014) surface, except for the new `client=mac` query param and `malibu://` redirect target.

## 15. README correction (follow-up ticket)

`README.md`:

> The binary is checksum-verified against a signed release manifest. macOS quarantine (`xattr`) is cleared with your approval during install. Developer ID signing and notarization are planned for a future release.

Last clause is false as of `release.yml`'s "Sign + notarize binary" step. Update to describe the actual state (conditional signing when operator secrets are populated, driven by macOS 26.3.1+ AMFI requirement) and cross-link `phase3-binary/dist/release-signing-runbook.md`.
