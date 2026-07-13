# SPEC-025 — Native Mac App (signed `.dmg` + menu bar wrapper)

Status: DRAFT v0.9 · Owner: augstar · Target: 2026 Q3

**Change log v0.9 (2026-07-13, R8 audit-loop convergence — code source of truth).** R8
code caught that the R7 "watchdog never restarts" was too absolute: the companion
watchdog is a no-op for **routine** health failures (KeepAlive restarts those), but it
DOES force-restart the provider service during **auto-update rollback recovery**
(`launchctl kickstart`, `install.sh:4086,4113`). §8 + grounding table now state the
routine/rollback boundary.

**Change log v0.8 (2026-07-13, R7 audit-loop convergence — code source of truth).** R7
architect/code caught the watchdog-ownership tail and a bundle-layout invention: the
companion watchdog `live.streamvc.macprovider-watchdog` **does not restart the CLI for
routine health failures** — its routine restart request is a no-op
(`note_provider_restart_request`, `install.sh:3575`); the launchd **provider service**
`live.streamvc.macprovider` (`KeepAlive`) performs routine restarts (v0.8 further nuanced
in v0.9: the watchdog CAN force-restart during auto-update rollback recovery,
`install.sh:4086,4113`). Swept §0/§2/§5/§8 topology + ASCII diagram + lifecycle +
grounding table; §5.1 bundle tree lists **only** `Sparkle.framework` as embedded (the
app depends solely on Sparkle — `project.yml:21-24`; MLX runs in the CLI, `mlx.metallib`
sits in `MacOS/` beside the executable, not as an embedded framework).

**Change log v0.7 (2026-07-13, R6 audit-loop convergence — code source of truth).** R6
architect/code caught the last app-side twins: **§8 now documents THREE launchd
registrations** — the KeepAlive provider service `live.streamvc.macprovider` (the plist
the app's evidence gate checks), the SEPARATE companion watchdog
`live.streamvc.macprovider-watchdog` (`StartInterval=60`, `install.sh:47,4264`), and
`SMAppService` — previously "two" with the provider-service plist mislabeled as the
watchdog (grounding table + §0 CLI-track def aligned); §12 CLI self-update authority is
the coordinator-driven `AutoUpdater` (`CoordinatorClient.swift:2756`), NOT
`install.sh`/watchdog (matches §3.3); §4 `.pkg` build uses `pkgbuild` + `productsign`
(not `productbuild`/component plist, `release.yml:635`).

**Change log v0.6 (2026-07-13, R5 audit-loop convergence — code source of truth).** R5
architect/code caught remaining app-side twins: §3.3 BSDiff **delta updates marked
design-intent only** (shipped generator stages one full DMG, `generate-malibu-appcast.sh:67`,
consistent with §9); §7 receipt/admission Keychain services spelled out in full with
lifetimes — `com.streamvc.macprovider.receipt-key` (rotatable), `.receipt-key.prev`
(grace), `.bootstrap-identity-key` (stable admission identity, never rotates), account
`<provider_id>` (`ReceiptKeyStore.swift:22-25,58-92`); §4 distribution facts corrected —
`hdiutil` DMG (not `create-dmg`) and the optional signed App `.pkg` (`tech.malibu.app.installer`)
is already emitted, not a backlog item (`release.yml:599,616`); §13 backlog narrowed to
broader MDM/enterprise packaging.

**Change log v0.5 (2026-07-13, R4 audit-loop convergence — code source of truth).** R4
architect/code caught app-side build/distribution twins: §2 token-backup documented as
best-effort/may-persist (aligned to §7); §4 `.dmg` table — post-install runs `install.sh`
(SMAppService only registers the app login item, §8), and the pipeline already emits an
optional signed App `.pkg`; §5.1 bundle tree adds the **required** `macprovider-cli` +
`mlx.metallib` under `Contents/MacOS/` (`release.yml:556`,
`verify-tier2-provider-release.sh:405`); §6.2 CI recipe bannered as design-intent
(`release.yml` authoritative — archive-copy + `hdiutil`, not `-exportArchive`/`create-dmg`);
§7 receipt-key Keychain coordinates corrected to `com.streamvc.macprovider.receipt-key`
(+`.prev`/`.bootstrap-identity-key`), account `<provider_id>`; §9 Sparkle trust anchor is
`SUPublicEDKey` in `Info.plist` (no `appcast-key.pub`), with deltas/phased-rollout marked
design-not-shipped (`generate-malibu-appcast.sh:67`).

**Change log v0.4 (2026-07-13, R3 audit-loop deep-tail convergence — code source of
truth).** R3 architect/code caught remaining "two live definitions" contradictions: §1
coexistence "unchanged" now carries the post-import token-custody caveat (launchd CLI
bearerless on restart); §2 config table corrected — the wrapper DOES rewrite the live
`config.yaml` to strip the token (`ProviderConfig.swift:312`); §3.3 states there ARE two
update authorities (Sparkle for `.app`; the CLI's own coordinator-driven `AutoUpdater`,
enabled by default — `AutoUpdateTrustState.swift:148`), not "no second authority"; §5.1
bundle layout — the bundled `macprovider-cli` in `Contents/MacOS/` is **required** by
the release pipeline (`release.yml:544`, `verify-tier2-provider-release.sh:405`), not
optional; §7 token backup documented as not-guaranteed-transient (best-effort delete,
recovery retains).

**Change log v0.3 (2026-07-13, R2 audit-loop straggler sweep — code source of truth).**
The v0.2 reconciliation left live sections asserting the pre-#418 model that the R2
codex 3-lane audit (code / security / architect) surfaced. v0.3 sweeps them to match
shipped code: §2 token custody nuanced (transient 0600 import-backup, not "never on
disk"); §3.1 normal stage order is `.idle→.runningCLIInstall→.startingAgent→.live`
(`.importingProviderIdentity` is deferred-retry-only), the installer env is inherited
(NOT sanitized; `PATH` set only when empty), and finalize gates on
`ProviderConfig.isConfigured` (bearer), NOT an App Ed25519 identity; §3.2 removes the
unshipped popover / earnings chart / "Copy diagnostics" / "Quit and Uninstall" (menu is
plain Quit; left-click opens Dashboard), and refines "Reconnecting" (diagnosed failures
+ attach timeout → `.error`); §7 states the markerless-CLI-owned first-precedence
`.showImportDialog` route; §12 corrects #2 (the app does NOT invoke `CLIUpdateRunner` —
`.updateCLI` maps to Sparkle); per-gate launch-error messages distinguished.

**Change log v0.2 (2026-07-13, CLI-wrapper architecture reconciliation — spec matched
to shipped code; code is source of truth):** The **CLI-wrapper refactor (PR #418,
2026-07-06)** inverted the v0.1 architecture. v0.1's §3.1 `malibu://` portal deep-link
onboarding and §5 "wrapper spawns a bundled CLI child; `MalibuAgent` owns the child
lifecycle; the App track does NOT install the watchdog" were **superseded**. Shipped
reality (`phase3-binary/app/Sources/Malibu/`): **Malibu is a monitor-only wrapper.**
Onboarding runs the bundled CLI-track `install.sh` (which registers the provider,
autotunes, downloads the model, and installs the launchd watchdog); the app then
**adopts and monitors** the launchd-managed `macprovider-cli` over local HTTP
(`/v1/health` + `/v1/status`) — it does **not** spawn a CLI child, and the
control-socket / in-app-register / in-app-autotune machinery still compiles but has
**no production caller** (retained only as test/legacy surface). The `malibu://`
scheme, `RegisterClient.postRegister` in-app registration, and the in-app
register→autotune→spawn path are gone from the live flow. v0.2 rewrites §3.1 and §5 to
the shipped monitor-only model, reconciles §2/§7/§8, and marks the compiled-but-dead
paths as legacy. No code change. **See the paired SPEC-026 v0.14** (same PR #418
reconciliation, client-onboarding side).

Earlier honesty note (v0.1, 2026-07-10): flagged the same supersession and pointed at
SPEC-026 §6/§7 + the Malibu sources as source of truth pending this v0.2 revision.

## 0. Terminology

- **CLI track** — existing `macprovider-cli` binary + `install.sh` + the launchd **provider service** `live.streamvc.macprovider` and its separate companion watchdog `live.streamvc.macprovider-watchdog` (§8). Developer-facing.
- **App track** — new `Malibu.app` (this spec). Non-developer-facing; brand is Malibu (see [malibu-branding memory]). User-visible strings never say "MacProvider" or `streamvc.live`.
- **Wrapper** — the Swift/SwiftUI code added by this spec (`Malibu.app`).
- **Managed CLI** — the existing `macprovider-cli` binary, installed and run by the
  **launchd provider service** `live.streamvc.macprovider` (`KeepAlive`) that `install.sh`
  sets up (plus a companion health watchdog, §8). The wrapper
  **adopts and monitors** it; it does **not** launch it. (Reconciled v0.2 — v0.1
  called this the "CLI child" spawned by the wrapper; that spawn path is gone,
  §5.)

Both tracks must coexist and produce identical on-chain behavior.

## 1. Goal

Ship a **click-and-forget provider experience** for non-developer Mac users. Replace the terminal-only path (`curl … | bash` at `malibu.tech/host/`) with a signed, notarized `.dmg` containing `Malibu.app` — a menu bar wrapper around the existing `macprovider-cli` binary.

### Success criteria

- Non-technical Apple Silicon user goes from `malibu.tech/host` → running provider in **≤ 3 minutes**, zero terminal.
- Same coordinator behavior, same receipts as the CLI track (the shipped app onboards a **CLI-track** provider via `install.sh` — SPEC-026 §6.1; no separate App-track registration).
- Auto-update ships silently (Sparkle, the whole `.app`). **Uninstall goal NOT met as shipped (reconciled v0.2):** the "Quit and Uninstall" action is compiled but unreachable, so **drag-to-trash leaves the launchd `macprovider-cli` behind** (§3.4). Zero-leftover is a carried gap.
- The CLI track coexists via the shared `config.yaml` + `.installed-by-app` marker (§7), with the CLI-owned config routed to the import dialog (SPEC-026 §8). **Caveat (reconciled v0.3):** "unchanged" holds only until an App import — importing strips the `provider_token` from `config.yaml`, leaving the launchd-managed CLI **bearerless on unattended restart** (documented token-custody gap, §7); a pure CLI user who never imports is unaffected.

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
| Local HTTP | `Sources/macprovider-cli/HTTPServer.swift` on `127.0.0.1:<port>` | **Wrapper's SOLE steady-state channel (reconciled v0.2):** it polls `GET /v1/health` + `GET /v1/status` to monitor the managed CLI (`InstalledProviderMonitor.swift:39-117`). Port read from `config.yaml` (`ProviderConfig.readHTTPPort`). |
| Control-plane IPC | `Sources/macprovider-cli/ControlSocket.swift` — typed JSON frames on Unix socket | **NOT used in the shipped monitor-only flow (reconciled v0.2).** `ControlSocketClient` / `MalibuAgent.connectControl` compile but have no production call site — legacy/test surface only. The wrapper does not open the control socket (§5.2). |
| Runtime | `mlx-swift-examples` (MLXLLM, MLXLMCommon) — pure Swift, no Python | Runs inside the **managed CLI** process, not the app; the app is a thin monitor wrapper. |
| Auth model | `provider_id` + `provider_token` bearer, per SPEC-001 / XSEC-1 | **Reconciled v0.2:** `install.sh` obtains the token; the wrapper **imports** it from `config.yaml` into the app Keychain via `ProviderConfig.importExistingCLIConfig()` (`ProviderConfig.swift:280-352`), stripping it from `config.yaml`. The wrapper never receives a token from a portal deep-link (that `malibu://` path is removed). |
| Config | `~/.config/macprovider/config.yaml`, secret in `provider_token` field | **Reconciled v0.2/v0.3:** `install.sh` writes the *initial* `config.yaml` (shared with the CLI track). The wrapper does **not** create it, but on import it **DOES rewrite** the live `config.yaml` to strip the `provider_token` (`ProviderConfig.swift:312`); it reads `provider_id`/model/port and moves the token to Keychain. **Token custody (reconciled v0.3/v0.4 — nuanced, see §7):** the import writes a token-bearing 0600 `config.yaml.import-backup`; its deletion is **best-effort** (delete errors are ignored, and one recovery branch retains it — §7, `ProviderConfig.swift:336,354`), so the backup can persist on disk. The *live* `config.yaml` ends token-free. |
| Provider service + watchdog LaunchAgents | `install.sh` installs BOTH the KeepAlive **provider service** `live.streamvc.macprovider` (plist `live.streamvc.macprovider.plist` — **this is the evidence the app checks**) and a SEPARATE **companion watchdog** `live.streamvc.macprovider-watchdog` (`StartInterval=60`, `install.sh:47,4264`) that health-observes the daemon; on routine ticks its restart request is a **no-op** (the provider service's `KeepAlive` performs routine restarts), except during auto-update rollback recovery where it force-restarts the provider service (`install.sh:4086,4113`) (reconciled v0.6/v0.8, §8 — the evidence plist is the provider service, NOT the watchdog). Evidence: `install_manifest.json` or the provider-service plist. | **The App track installs and relies on both** (via `install.sh`). `SMAppService.mainApp.register()` is a **separate** concern — it registers `Malibu.app` itself as a login item (`AppLoginItem.swift`), not the CLI daemon. |
| Portal | `portal.streamvc.live` (SPEC-014) — installer catalog | **Reconciled v0.2:** the wrapper does **not** open a portal URL for token issuance (removed with `malibu://`). App-track registration happens inside `install.sh` / the CLI track. |
| Release manifest / checksum | `scripts/sign-catalog.go`, tier2 release scripts | Feeds the same manifest that Sparkle appcast references |
| Signing + notarization pipeline | `.github/workflows/release.yml` "Sign + notarize binary" step + `phase3-binary/dist/release-signing-runbook.md` | Reuse the existing keychain-import / codesign / `notarytool submit --wait` / `stapler` pattern verbatim; extend to sign the `.app` and `.dmg` |
| Signed `.pkg` delivery container | Same workflow, `pkgbuild` + `productsign` with **Developer ID Installer** cert, identifier `live.streamvc.macprovider.cli`, preinstall blocks direct GUI install | Do **not** confuse with the App-track `.pkg`, which the pipeline **already emits** as an OPTIONAL scriptless flat package, identifier `tech.malibu.app.installer` (reconciled v0.5, `release.yml:616,635,641`) — this CLI one is a delivery container for `install.sh`, not a user-facing installer |

**README is stale.** `README.md` says signing is "planned for a future release." The actual state (as of `release.yml`): full pipeline exists, activates conditionally on secret presence — driven by the macOS 26.3.1+ launchd/AMFI change that rejects adhoc-signed binaries (see memory `macprovider-launchd-amfi-blocker-macos-26`). This spec **extends** that pipeline; it does not build it from scratch. README needs a follow-up correction.

## 3. User flows

### 3.1 First-run (cold install) — reconciled v0.2 to the shipped CLI-wrapper flow

1. `malibu.tech/host` → **Download for Mac** → `Malibu.dmg`.
2. Open `.dmg` → drag `Malibu.app` to `Applications`. Standard Finder UX.
3. Launch `Malibu.app`. Gatekeeper checks the stapled notarization ticket, no scary dialog.
4. Menu bar icon appears (`NSStatusItem`, `LSUIElement=true` — no Dock icon;
   `Info.plist:25-26`). On launch, `applicationDidFinishLaunching` runs
   `handleStartup()`, which routes on disk state via `StartupState.detect().route()`
   → `.startAgent` / `.showOnboarding` / `.showImportDialog` / `.quit`
   (`MalibuApp.swift:30-140`, `LaunchProviderController.swift:302-372`). A fresh Mac
   (no config, no launchd evidence) routes to onboarding: a single window with a
   coral **Launch Provider** button (no wallet field, no node-link step, no browser).
5. User clicks **Launch Provider** → `LaunchProviderController.launch()` drives a
   stage machine whose normal-success order is
   `.idle → .runningCLIInstall → .startingAgent → .live(model, tier)`
   (or `.failed`); `.importingProviderIdentity` is a **deferred
   missing-token retry** stage entered only after `.startingAgent`, NOT
   on the happy path (reconciled v0.3 —
   `LaunchProviderController.swift:14-21,117,165`). There is **no** in-app
   register / autotune / spawn step. The stages are:
   - **Short-circuit:** if a local provider is already healthy, skip the installer
     and just attach (`:79-87,144-163`).
   - **Run the bundled `install.sh`** (`runCLIInstall`, `:117-125`). The installer
     is bundled at `Contents/Resources/install.sh` (copied from
     `phase3-binary/dist/install.sh` at build time, `project.yml:72-75`), run via
     `/bin/bash <temp-copy 0700>` with **no CLI args** — behavior is env-driven:
     the runner **inherits the full parent environment** and sets
     `MACPROVIDER_NO_PROMPT=1`, `HOME`, optional `MACPROVIDER_PORT` (from a free-port
     probe when unset), and a default `PATH` **only when the inherited one is empty**
     (NOT sanitized — reconciled v0.3, `CLIInstallRunner.swift:42-51`).
     `install.sh` performs the register + autotune (`autotune --recommend`) + model
     download + **launchd provider-service + watchdog install**; the app only surfaces a progress hint
     by scraping `ps` for the autotune stage (`:110-149`). A non-zero installer exit
     throws (installer rollback semantics).
   - **Import the token to Keychain** (`importCLIConfigAfterInstall` →
     `ProviderConfig.importExistingCLIConfig()`, `:128`) — moves `provider_token`
     out of `config.yaml` into the app Keychain; a not-yet-written token is a
     **retriable** deferred error (`:126-137`).
   - **Finalize** (`finalizeInstall`, `:165-199`): wait for the launchd provider's
     `GET /v1/health`, retry the Keychain import, then check `appIdentityConfigured`
     — which is actually `ProviderConfig.isConfigured` (config + `.installed-by-app`
     marker + Keychain **bearer**, `:65`, `ProviderConfig.swift:503-511`), **NOT** the
     app Ed25519 identity (reconciled v0.3) — attach the `MalibuAgent` monitor, then
     `SMAppService.mainApp.register()` the login item and mark
     `.live(…, tier: .provisional)`. The login item is registered **only after** a
     successful attach (`testAttachFailureDoesNotRegisterLoginItemOrMarkLive`).

Time budget: a few seconds of UI + `install.sh`'s own register/autotune/download
time (60–240 s for the first model) in the background.

### 3.2 Steady state

- Menu bar icon: state glyph (idle · serving · error) + today's USDC. "Serving"
  requires BOTH the managed CLI's local `/v1/health` readiness AND
  `network_state == "buyer_serving"` from `/v1/status`; a bare local-ready state is
  shown as "Reconnecting" (`MalibuAgent.swift:307-355`). Steady-state health poll
  every 15 s (`:381-407`); first-attach polls every 2 s up to 600 s (`:188-226`).
- Menu (reconciled v0.3): the shipped menu-bar left-click opens the Dashboard
  window directly — there is **no popover** with USDC/MALIBU/uptime/GPU/latency in
  the shipped build (`MenuBarController.swift:56`); the menu exposes a plain **Quit**
  only, with **no "Quit and Uninstall"** item (`MenuBarController.swift:108`).
- Dashboard (SwiftUI window, reconciled v0.3): earnings/wallet/tier **panels** +
  live **log tail** (`DashboardWindow.swift:22`) — read-only from `EarningsClient` /
  `MalibuAccrualClient`. The shipped dashboard has **no earnings chart, no "Copy
  diagnostics" action, and no "Quit and Uninstall" control** (those are designed, not
  shipped). The wallet card's "Set payout wallet" button is **disabled**
  (SPEC-027-gated, `DashboardWindow.swift:59`). The model-swap-over-ControlSocket
  affordance is **not** wired in the monitor-only flow (the control socket is never
  connected, §5.2); model selection is owned by `install.sh` / autotune and the CLI,
  not an in-app `switch_request`.
- On login: `SMAppService.mainApp.register()` starts `Malibu.app` in the background.
  No Dock icon. (This registers the **app** as a login item; the **CLI daemon** is
  owned by the launchd **provider service** `live.streamvc.macprovider` (`KeepAlive`)
  that `install.sh` set up — a separate mechanism from the app login item, §8.)

### 3.3 Updates — Sparkle 2.x

- Appcast at `https://download.malibu.tech/appcast.xml`, EdDSA-signed (reconciled v0.2 to shipped `MalibuUpdateConfiguration.swift:5-10` / `Info.plist:34-39`; v0.1's `updates.malibu.tech` is stale).
- Model weights live outside `.app` and are never re-downloaded on update. **BSDiff delta updates are design-intent only (reconciled v0.5):** the shipped appcast generator stages a single full `.dmg` with no delta configuration (`generate-malibu-appcast.sh:67`; see §9).
- **Only the Sparkle whole-`.app` update is wired (reconciled v0.2).** Sparkle
  (`SPUStandardUpdaterController`, auto-checks daily) updates the `.app` from appcast
  `https://download.malibu.tech/appcast.xml` (`Malibu-<tag>.dmg`, `SUPublicEDKey`
  Ed25519 — `MalibuUpdateConfiguration.swift:5-22`), draining the provider via
  `agent.shutdown(gracefulSeconds: 15)` first (`SparkleUpdaterController.swift:36-38`;
  in monitor mode there is no child to kill — the drain is a graceful monitoring
  pause). The menu bar and dashboard expose **only** the Sparkle update check
  (`MenuBarController.swift:93-95`, `DashboardWindow.swift:81-84`).
- **The in-app CLI-updater is present but UNWIRED (reconciled v0.2 — carried gap).**
  `CLIUpdateRunner` (invoke `macprovider-cli update`) and `MalibuAgent.updateCLINow()`
  exist (`CLIUpdateRunner.swift:30-60`, `MalibuAgent.swift:130-155`) but have **no
  production caller**; even the unused `.updateCLI` handler maps to Sparkle
  (`MalibuApp.swift:89-90`). **Reconciled v0.3 — there ARE two live update authorities
  for separate artifacts:** Sparkle owns `Malibu.app`; the launchd-managed CLI updates
  ITSELF via its own coordinator-driven `AutoUpdater`, enabled by default
  (`AutoUpdateTrustState.swift:148`, `CoordinatorClient.swift:2710`) — NOT via the app's
  (unwired) `CLIUpdateRunner`. The launchd args do not set `managed_by=malibu-app`
  (`install.sh:3425`), so the app never drives CLI updates.

### 3.4 Uninstall

- Drag `Malibu.app` → Trash. Because `SMAppService` is registered by the app bundle, macOS auto-cleans the launchd registration on next login.
- **Quit and Uninstall is compiled but UNREACHABLE in the shipped UI (reconciled
  v0.2 — carried gap).** The teardown handler exists (`MalibuApp.swift:83-95,188-208`)
  but **no menu item or dashboard control emits it**: the menu bar exposes only plain
  **Quit** (`MenuBarController.swift:73-116`) and the dashboard has no uninstall control
  (`DashboardWindow.swift:22-106`). So **drag-to-trash removes only `Malibu.app` and
  its `SMAppService` login item — the launchd-managed `macprovider-cli` and its
  `config.yaml` remain.** The v0.1 "zero leftover LaunchAgent" promise does **not**
  hold as shipped. Wiring the action is a carried follow-up.
- If/when the action is wired, the handler's teardown does
  (`MalibuApp.swift:161-208`): drain monitoring via `agent.shutdown(gracefulSeconds:)`;
  remove the launchd CLI via `macprovider-cli uninstall --yes`
  (`CLIInstallTeardown.swift:33-34`); `SMAppService.mainApp.unregister()`;
  `ProviderConfig.wipeAppOwnedState()` (removes `config.yaml` **only if the
  `.installed-by-app` marker is present**, `ProviderConfig.swift:478-501`, plus the app
  support dir; it **preserves receipt keys** — not "all `tech.malibu.*`",
  `KeychainStore.swift:68-85`); delete the app Ed25519 identity key
  (`ProviderIdentity.deleteFromKeychain`).

The CLI track's `uninstall.sh` is unaffected and remains the developer-facing path.

## 4. Distribution — `.dmg` (not `.pkg`)

Recommendation: **`.dmg`**.

| Concern | `.dmg` (chosen) | `.pkg` |
|---|---|---|
| Non-dev familiarity | High (Slack, Signal, Tailscale) | Medium |
| Requires elevation | No | Yes (or user-scope pkgs, clunky) |
| Post-install steps | App runs the bundled `install.sh` on first Launch (installs the launchd CLI); `SMAppService` only registers the app's own login item after attach (reconciled v0.4, §8) | Installer scripts (extra attack surface) |
| Update path | Sparkle replaces `.app` in place | Works but clunkier |
| CI complexity | `hdiutil` DMG build (reconciled v0.5, `release.yml:599`; the earlier `create-dmg` framing is superseded) | `pkgbuild` + `productsign` (reconciled v0.6 — the shipped optional App `.pkg` uses this, NOT `productbuild`/component plist; `release.yml:635`) |
| MDM/enterprise | Weaker | Stronger |

Ship `.dmg` for v1. **Reconciled v0.4:** the pipeline already emits an **optional signed App `.pkg`** alongside the `.dmg` (`release.yml:599,616`); the earlier "later, enterprise/MDM only" framing is superseded — content is the same `.app`.

## 5. Wrapper ↔ CLI: architecture (reconciled v0.2 — monitor-only)

**Shipped model:** `Malibu.app` is a **thin monitor wrapper**. `install.sh` (bundled
in `Contents/Resources/`) sets up a **launchd provider-service-managed** `macprovider-cli`
(`live.streamvc.macprovider`, `KeepAlive`) plus a companion health watchdog (§8);
the app then adopts and **observes** it over local HTTP. The app never spawns the CLI
and never opens the control socket in the live flow.

```
┌───────────────────────────── Malibu.app ─────────────────────────────┐
│  MenuBarController (NSStatusItem)  ◄──►  DashboardWindow (SwiftUI)    │
│                    │                          │                       │
│                    └──────────┬───────────────┘                       │
│                               ▼                                       │
│   LaunchProviderController (onboarding)   MalibuAgent (steady state)  │
│    · runs Contents/Resources/install.sh    · MONITORS via HTTP poll   │
│    · imports token → Keychain              · never spawns a child     │
│    · registers SMAppService (APP login item)                         │
│                               │ GET /v1/health + /v1/status           │
│                               ▼ (127.0.0.1:<port from config.yaml>)   │
│   ┌── launchd provider service live.streamvc.macprovider (KeepAlive) ─┐ │
│   │   macprovider-cli   ← owned/restarted by launchd KeepAlive, NOT the │ │
│   │   app (+ separate health watchdog, no-op restart — §8)             │ │
│   └──────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
  MalibuAgent.start() gate (in order, MalibuAgent.swift:64-87):
    provider_id present  AND  launchd install evidence exists  AND  Keychain token
  → monitorInstalledProviderIfPresent()   (never instantiates CLIChildProcess)
```

`MalibuAgent.start()` **refuses to poll** unless `provider_id` is set, launchd
install evidence exists (`install_manifest.json` or
`live.streamvc.macprovider.plist`, `LaunchProviderController.swift:374-380`), and a
Keychain token is bound. **Reconciled v0.3 — the message is per-gate**
(`MalibuAgent.swift:64-87`): a missing `provider_id` or a failed `isConfigured` shows
"Not set up yet. Click Launch Provider to activate."; only missing launchd evidence
shows "…to run the installer." A legacy app-marker config with no launchd
evidence routes to onboarding, not a reconnect loop (`route()`
`LaunchProviderController.swift:352-372`; `StartupRouteTests.swift:9`).

### 5.1 Bundle layout

```
Malibu.app/Contents/
  Info.plist                       # LSUIElement=true; SUFeedURL / SUPublicEDKey
                                   # (Sparkle); NO CFBundleURLSchemes (malibu:// removed)
  MacOS/
    Malibu                         # Swift binary (wrapper)
    macprovider-cli                # REQUIRED — signed CLI copied in by release.yml:556; verify-tier2-provider-release.sh:405 rejects a bundle without it
    mlx.metallib                   # REQUIRED — MLX Metal shader library (release.yml)
  Resources/
    install.sh                     # bundled CLI-track installer (mode 755, project.yml:72-75)
    Assets.car
  Frameworks/
    Sparkle.framework              # the ONLY embedded framework (reconciled v0.7 — the app target depends only on Sparkle, project.yml:21-24). MLX runs inside the CLI, not the app; mlx.metallib sits beside the executable in MacOS/ (above), not here.
  _CodeSignature/
```

Note (reconciled v0.3): the **running** provider is the `macprovider-cli` that
`install.sh` installs into `~/macprovider/` (the launchd-managed location). Separately,
the release pipeline **REQUIRES** a `macprovider-cli` binary bundled in
`Contents/MacOS/`: `release.yml:544` copies it in and
`verify-tier2-provider-release.sh:405` **rejects an App bundle without it** (reconciled
v0.3 — required, not optional). The bundled copy backs `CLIUpdateRunner` (itself
unwired, §3.3); the live daemon remains the launchd install. `Info.plist` carries **no**
`malibu://` URL scheme (removed by PR #418; tombstone at `MalibuApp.swift:35-38`).

### 5.2 IPC: the shipped monitor path is HTTP-poll only

**Reconciled v0.2 — the control socket is NOT used in the shipped flow.** Steady-state
monitoring is entirely `GET http://127.0.0.1:<port>/v1/health` +
`GET /v1/status` against the launchd-managed CLI (`InstalledProviderMonitor.swift:39-117`;
port from `config.yaml`). Health readiness = `status ∈ {ready, busy}`; "serving"
additionally requires `/v1/status.network_state == "buyer_serving"`
(`MalibuAgent.swift:307-322`).

The v0.1 design — the wrapper as a `ControlSocket` **client** using
`status_request` / `switch_request` / `rotate_receipt_key_request` and new
`metrics_request` / `pause_request` / `shutdown_request` frames — **did not ship as a
live path.** `ControlSocketClient` and `MalibuAgent.connectControl(...)` compile and
are unit-tested but have **no production call site** (`MalibuAgent.swift:409-463`, no
callers). Treat those frames and the "unix socket over HTTP for metrics" rationale as
**legacy/test surface**, superseded by the HTTP-poll monitor. (The `agent.sock` path
is still reserved under the app support dir, `ProviderPaths.swift`, but not connected.)

### 5.3 CLI lifecycle: launchd owns it, the app monitors

**Reconciled v0.2/v0.7 — the wrapper does NOT spawn, restart, or SIGTERM a CLI child.**
The launchd **provider service** `live.streamvc.macprovider` (`KeepAlive`) that
`install.sh` installs owns the CLI's lifecycle and restarts (the companion watchdog only
health-observes; its restart request is a no-op — §8).
`MalibuAgent` holds a `var child: CLIChildProcess?` but **never instantiates it** in
shipped code — `CLIChildProcess(` has no call site in `Sources` or `Tests`; the field
is only read to defensively release a child left by an *older* build
(`releaseSpawnedChildForLaunchdMonitor`, `MalibuAgent.swift:231-245`). The
`--managed-by malibu-app` / `--enable-warm-swap` argv is not exercised.

What the app actually does around lifecycle:
- **Attach/monitor:** poll `/v1/health` + `/v1/status`; first-attach every 2 s up to
  600 s, steady every 15 s (`MalibuAgent.swift:188-226,381-407`). **Reconciled v0.3:**
  a locally-ready but non-`buyer_serving` provider (or an undiagnosed connection loss)
  is surfaced as "Reconnecting" (`MalibuAgent.swift:307`); **diagnosed**
  startup/health failures and the first-attach timeout transition to **`.error`**, not
  "Reconnecting" (`MalibuAgent.swift:89,391`). Recovery of the daemon is the launchd
  provider service's `KeepAlive` job (the watchdog only health-observes, §8), not an
  in-app restart loop.
- **Drain (app quit / Sparkle update):** `agent.shutdown(gracefulSeconds:)` pauses
  monitoring (`MalibuApp.swift:57-74`, `SparkleUpdaterController.swift:36-38`) — there
  is no child process to signal.
- **Uninstall:** delegate to `macprovider-cli uninstall --yes` (§3.4).

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

> **Reconciled v0.4 — `release.yml` is authoritative.** The shipped pipeline differs in
> mechanics from the recipe below: it copies the archive product directly rather than
> running `-exportArchive` (`release.yml:184,194`), builds the `.dmg` with `hdiutil`
> (not `create-dmg`), and additionally emits an **optional signed App `.pkg`**
> (`release.yml:599,616`). Treat the steps below as design intent; the exact commands
> live in `.github/workflows/release.yml`.

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
11. `sign_update` (Sparkle CLI) → EdDSA signature; render appcast item; publish `https://download.malibu.tech/appcast.xml` (reconciled v0.2).

Reuse `cleanup_signing_material` trap from the existing job.

### 6.3 Entitlements (`Malibu.entitlements`)

> **The shipped `Malibu.entitlements` is an EMPTY dictionary (reconciled v0.2).** The
> build points `CODE_SIGN_ENTITLEMENTS` at `Malibu.entitlements` (`project.yml:46-68`),
> whose plist has **no keys** (`Malibu.entitlements:1-5`). None of the five entitlements
> below are in the shipped file. This is consistent with the monitor-only architecture
> (the app no longer runs MLX inference or spawns/loads the signed CLI in-process — the
> managed CLI is launchd-owned), so most of the v0.1 rationale is moot. The block below
> is the v0.1 proposal, retained for provenance; the shipped entitlement set is empty.

```xml
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
```

Rationale:

- `allow-jit` + `allow-unsigned-executable-memory` — retained for any in-app MLX use;
  note the heavy MLX inference now runs in the **managed CLI** process, not the app
  (reconciled v0.2).
- `network.client` — the app polls the managed CLI's `127.0.0.1` HTTP endpoints
  (`/v1/health`, `/v1/status`) and reaches the Sparkle appcast / GitHub release feed.
- `disable-library-validation` — retained for embedded frameworks; the app spawns
  `/bin/bash` to run the bundled `install.sh` during onboarding (not a signed child
  CLI daemon — that is launchd-owned). Verify at P0 whether same-TeamID signing lets
  this be dropped.
- `network.server` — retained; note the provider's `HTTPServer` binds `127.0.0.1`
  inside the **managed CLI**, and the app is its client.

**Not requested (would be trust-drops):** Accessibility, Full Disk Access, Screen Recording, Camera, Microphone. If any of these surface as required during P0, escalate immediately.

## 7. Storage, config, and CLI-track coexistence

The single biggest risk in this spec is stomping a config that a developer previously created via `install.sh`. Resolution:

| Data | Location | Owned by |
|---|---|---|
| Provider daemon config | `~/.config/macprovider/config.yaml` | **Shared** with CLI track |
| Wrapper preferences (window sizes, opt-ins) | `~/Library/Application Support/Malibu/prefs.json` | App track only |
| App-track marker | `~/Library/Application Support/Malibu/.installed-by-app` (**empty file**, reconciled v0.2 — not dated; `ProviderConfig.swift:513-518`) | App track only |
| Logs (rolling, 100 MB cap) | `~/Library/Logs/malibu/` | Shared, app tags its own lines |
| `provider_token` | Keychain, service `tech.malibu.provider`, account `<provider_id>` | App track; CLI track keeps YAML |
| Session receipt / admission keys | Keychain (CLI store), services `com.streamvc.macprovider.receipt-key` (current, rotatable — signs receipts), `com.streamvc.macprovider.receipt-key.prev` (rotation grace), `com.streamvc.macprovider.bootstrap-identity-key` (stable admission identity — **never rotates**; verifies `mp-*` `identity_signature`), all account `<provider_id>` (reconciled v0.5 to `ReceiptKeyStore.swift:22-25,58-92,232-249`) | Unchanged from CLI track (reuses the existing CLI key store) |

Rules (reconciled v0.2 to the shipped `StartupState.route()` + `ProviderConfig`):

- **On first run of the app:** if `config.yaml` exists AND the `.installed-by-app`
  marker does NOT → route to `.showImportDialog` ("We found a MacProvider config.
  Import it into Malibu?"). On import, `ProviderConfig.importExistingCLIConfig()`
  reads the YAML's `provider_token`, moves it to the app Keychain (via
  `KeychainStore`), sets the marker, and keeps the YAML minus the secret
  (`ProviderConfig.swift:280-352`). Never silent-migrate. (`StartupRouteTests.swift:10-12`.)
- **On Quit-and-Uninstall:** `ProviderConfig.wipeAppOwnedState()` deletes
  `config.yaml` **only if the marker is present** (`ProviderConfig.swift:478-501`).
- **`isConfigured`** = `config.yaml` present AND `.installed-by-app` marker present
  AND a Keychain token bound to the config's `provider_id` (`ProviderConfig.swift:503-511`).
  **Route precedence (reconciled v0.3):** a *markerless* CLI-owned `config.yaml` takes
  FIRST precedence and routes to `.showImportDialog` — even when the launchd provider is
  healthy (`LaunchProviderController.swift:352`), per the first bullet above; only when
  the marker IS present but the bearer/config is otherwise incomplete does a failed
  `isConfigured` route to onboarding, and a fully-absent config also routes to
  onboarding. **Token custody (reconciled v0.2 — nuanced, not "never
  on disk"):** the import strips `provider_token` from `config.yaml` and adds a
  `link_state` key (`ProviderConfig.swift:312-335`), so the *live* `config.yaml` holds
  no token — **but** the import also writes a token-bearing `config.yaml.import-backup`
  (0600), so the token IS on disk there. **The backup is not guaranteed transient
  (reconciled v0.3):** deletion is best-effort — the delete error is ignored
  (`ProviderConfig.swift:336`), and exceptional recovery paths remove the marker while
  **retaining** the backup (`ProviderConfig.swift:354`), so a token-bearing 0600 backup
  can persist. Stripping the token from `config.yaml` also leaves the launchd-managed
  CLI unable to re-authenticate on restart (it reads the bearer from `config.yaml`;
  SPEC-026 §6.1 token-custody gap). So the App track is not a clean "token never on
  disk" win.
- **CLI track never touches** `~/Library/Application Support/Malibu/` or the app's
  Keychain entries.

## 8. LaunchAgent — three distinct mechanisms (reconciled v0.2/v0.6)

There are **three** launchd-adjacent registrations in the shipped App track (v0.1
conflated them; v0.6 splits the provider service from its watchdog):

1. **The provider service — `live.streamvc.macprovider`** (plist
   `~/Library/LaunchAgents/live.streamvc.macprovider.plist`). The KeepAlive launchd job
   that runs the CLI daemon itself (`serve --config`, `install.sh:3423`). **This is the
   plist the app's evidence gate checks** (`launchdInstallEvidenceExists` — that plist OR
   `install_manifest.json`, `LaunchProviderController.swift:374-380`); the app refuses to
   monitor without it (§5).

2. **The companion watchdog — `live.streamvc.macprovider-watchdog`** (a SEPARATE
   `StartInterval=60` launchd job that runs the watchdog binary, `install.sh:47,4264`).
   Distinct from the provider service. **Reconciled v0.7/v0.8 — it does NOT restart the
   CLI for routine health failures:** on a routine unhealthy tick it only records a kick
   request that is a **no-op** (`note_provider_restart_request` logs "skipped: launchd
   KeepAlive is the sole runtime manager", `install.sh:3575-3577,4198-4225`) — the
   provider service's launchd **`KeepAlive`** performs routine restarts. **The one
   exception:** each watchdog tick first runs `autoupdate_recovery_tick`
   (`install.sh:4192`), whose rollback path restores a rolled-back binary and DOES
   force-restart the provider service via `launchctl bootstrap` + `kickstart -k`
   (`install.sh:4086,4113`). So: routine health → KeepAlive; auto-update rollback →
   watchdog force-kickstart. `install.sh` (run by the app during onboarding) installs
   **both** the provider service and this watchdog — v0.1's claim that the App track does
   NOT install the watchdog was false.

3. **The app login item — `SMAppService.mainApp`.** Registers `Malibu.app` itself to
   launch at login (`AppLoginItem.swift:6-30`), called at the end of a successful
   onboarding (`LaunchProviderController.swift:197`). About the **app UI** auto-starting,
   not the CLI daemon.

```swift
try SMAppService.mainApp.register()   // the APP login item, not the CLI daemon
```

- Apple surfaces the login item in **System Settings → Login Items**.
- `SMAppService` authors no `.plist`; the app's presence/status is
  `SMAppService.mainApp.status == .enabled` (`AppLoginItem.swift`). The **CLI**
  watchdog's plist is authored by `install.sh`, separately.
- Because the App track installs the same launchd CLI as the CLI track, coexistence
  is by the shared `config.yaml` + `.installed-by-app` marker (§7), not by "only one
  track installs a daemon."

## 9. Sparkle appcast

> **Reconciled v0.4 to shipped tooling.** The trust anchor is `SUPublicEDKey` in
> `Info.plist` (`project.yml:61`; verified by `verify-malibu-sparkle-signature.py:54`) —
> there is **no** `Contents/Resources/appcast-key.pub`. The shipped appcast generator
> stages a **single full `.dmg`** and configures **neither BSDiff delta updates nor
> phased rollout** (`generate-malibu-appcast.sh:67`); the delta/phased items below are
> DESIGN intent, not shipped behavior.

- Public key: `SUPublicEDKey` (Ed25519) in `Info.plist`. Private key lives in a CI secret; rotate quarterly, keeping the previous key valid for one grace release.
- Appcast entries include: version, min OS, download URL (signed `.dmg`), EdDSA signature, release notes URL. (Phased-rollout percentage and BSDiff deltas are Sparkle-2 features the shipped generator does not yet configure — DESIGN, per banner.)
- Failure handling: if a download fails its signature check or transfer, keep running the current version and retry on the next check.

## 10. Landing page changes (`malibu.tech/host/`)

- Above the fold: big coral **Download for Mac** button → `https://download.malibu.tech/latest.dmg`. Same button also emits the SHA-256 next to it for the paranoid.
- Below the button: disclosure toggle "**Prefer terminal?**" → reveals current `curl -fsSL https://get.streamvc.live/install.sh | bash` block. Devs keep their flow; the surface area for non-devs is a single button.
- Step section rewritten: "Download → Open → Earn." **There is no GitHub sign-in
  (reconciled v0.2):** onboarding is browserless — one **Launch Provider** click runs
  `install.sh` (SPEC-026 is explicit that no browser/GitHub step exists). v0.1's
  "GitHub sign-in is now inside the app" is removed.
- Requirements card unchanged.
- New troubleshoot page at `malibu.tech/host/troubleshoot` covering: Gatekeeper block (very rare post-notarization), `SMAppService` denied, first-model-download stuck, uninstall.

This landing page change is **file-level small** (`host/index.html` in the malibu repo) and non-blocking on the app itself.

## 11. Rollout plan

**Historical (reconciled v0.2).** This table is the original pre-#418 build plan and
is retained for provenance. It shipped, but the architecture inverted: P0's "spawns
bundled `macprovider-cli`" + the P0 `metrics_request`/`shutdown_request` control-socket
frames and P1's `malibu://` portal deep-link were **superseded** by the CLI-wrapper
model (run `install.sh`, monitor over HTTP). See §3.1 and §5 for the shipped flow.

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

**Historical + reconciled v0.2.** These were pre-P0 open questions. How PR #418
resolved them: **#1 CLI/App collision** — resolved by making the App track *use the
same* launchd install (`install.sh`) and coexist via the shared `config.yaml` +
`.installed-by-app` marker (§7); the app adopts an existing healthy provider rather
than running a second one. **#2 auto-update fights** — MOOT: the app never spawns a
child with `--managed-by malibu-app`; instead Sparkle updates the `.app`
(`.updateCLI` also maps to Sparkle — `MalibuApp.swift:90`), while the launchd CLI
self-updates via its own coordinator-driven `AutoUpdater` (`CoordinatorClient.swift:2756`,
enabled by default — §3.3), NOT via `install.sh`/the watchdog. **Reconciled v0.3:**
`CLIUpdateRunner` / `MalibuAgent.updateCLINow()` compile but have **no production caller**
(§3.3) — the app
does NOT invoke `macprovider-cli update` at runtime. **#5 portal deep-link
handshake** — MOOT: the `malibu://` scheme and portal token handoff were removed;
registration happens inside `install.sh`. **#4/#3 (library validation / linking)** and
**#6/#7 (weights path / login-item rejection)** remain as build details. The list
below is the original text.

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

- Broader MDM/enterprise packaging. **Reconciled v0.5:** a basic optional signed App `.pkg` (`tech.malibu.app.installer`) is **already emitted** by the pipeline (`release.yml:616`); only fuller MDM/enterprise packaging (config profiles, managed deployment) remains backlog.
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
- Portal (SPEC-014) surface — **unchanged (reconciled v0.2).** v0.1 proposed a
  `client=mac` query param + `malibu://` redirect target; PR #418 removed the
  `malibu://` onboarding entirely, so the App track requires **no** portal-side
  change.

## 15. README correction (follow-up ticket)

`README.md`:

> The binary is checksum-verified against a signed release manifest. macOS quarantine (`xattr`) is cleared with your approval during install. Developer ID signing and notarization are planned for a future release.

Last clause is false as of `release.yml`'s "Sign + notarize binary" step. Update to describe the actual state (conditional signing when operator secrets are populated, driven by macOS 26.3.1+ AMFI requirement) and cross-link `phase3-binary/dist/release-signing-runbook.md`.
