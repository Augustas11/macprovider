# SPEC-025 — Native Mac App (signed `.dmg` + menu bar wrapper)

Status: DRAFT v0.15 · Owner: augstar · Target: 2026 Q3

**Change log v0.15 (2026-07-16, SPEC-034 referral recovery).** Malibu may
collect bounded referral input and pass it to the signed installed CLI through a
supported versioned onboarding request. The CLI performs registration and all
authenticated coordinator referral operations, retains identity and bearer
custody, and projects sanitized coordinator-authored referral state under a
capability such as `referral_status_v1`. Malibu never receives the bearer, calls
referral coordinator APIs directly, infers serving/invite eligibility, or starts
a provider child. Malibu and CLI marketing versions are independent; local
protocol capabilities and schema versions, not marketing-version equality,
govern referral UI availability.

**Change log v0.14 (2026-07-15, issue #585 bootstrap trust continuity).**
Stable Malibu 1.8.39 is the only CLI-owned build whose signed app bundle retains
the exact `SUPublicEDKey` shipped by Malibu 1.8.32. Sparkle 2.6.4 rejects an
otherwise valid update when the target bundle removes that key, so the protected
release injects the frozen public key after unsigned app construction, before
protected bundle writes, and re-verifies it after bundling before codesigning. The
target still contains no Sparkle package/framework, feed URL, automatic-check
setting, or updater runtime; the key is inert trust metadata for the one legacy
hop. Final-DMG verification requires that exact posture, and every later Malibu
version must omit the key again.

**Change log v0.13 (2026-07-14, issue #585 Option 2 completion).** The
launchd-managed CLI is the sole provider lifecycle, credential, admission-identity,
state, update, rollback, and uninstall authority. Malibu is a non-secret observer: it
reads the versioned local HTTP lifecycle contract, reads the same-user owner-only
control-socket projection for CLI-authenticated earnings, and invokes only the signed
installed CLI's typed repair/update/uninstall transactions. A legacy App-Keychain
bearer may be read once as migration input, but is deleted only after fresh CLI custody
is proven; production Malibu cannot create a provider bearer, register an identity, or
sign coordinator admission. Sparkle, appcast publication, `latest.dmg`, and independent
App update ownership are removed. The signed compatibility set binds Malibu.app, the
CLI, launchd definitions, watchdog, catalog/resources, coordinator admission metadata,
and rollback plan; target activation commits only after exact target admission and
buyer-serving readiness, and the prior set remains until its own readiness is proven
after rollback. Auto-update opt-out applies to the entire set while explicit user update
remains available. **Every older statement below that assigns credentials, identity,
or update ownership to Malibu/Sparkle is historical and superseded by v0.13.** Physical
two-Mac, reboot/logout/locked-Keychain, interruption, #584 canary, and 24-hour soak
evidence remain rollout gates rather than claims of this repository change.

**Change log v0.12 (2026-07-14, issue #585 versioned-status and recovery slice).**
Malibu now reads a capability-gated v1 local status contract from the launchd CLI,
including bounded observation identity, exact service-instance identity, CLI-authored
lifecycle transitions, and the typed redacted credential condition. It preserves the
legacy unversioned reader path and suppresses incompatible or unadvertised typed
fields. When the CLI reports the exact `repair_from_protected_source` action, the
dashboard may invoke the validated installed CLI's `credentials repair` transaction
and wait for launchd health; Malibu never writes provider custody itself. The existing
App-Keychain compatibility bearer remains solely for shipped authenticated earnings
calls and is not justified by the new status reader; removing it requires replacing
those calls with a CLI/coordinator-owned versioned earnings surface.

**Change log v0.11 (2026-07-14, issue #585 Option 2 credential-custody
slice).** The launchd CLI, not Malibu, is now the provider-bearer authority. Malibu
invokes the installed CLI once to import the credential and a second time to verify
that a fresh CLI process reads the exact value, but keeps the live YAML source intact.
A restarted Keychain-backed CLI removes YAML only after coordinator admission.
Failure preserves the original private config and leaves the setup importable.
Existing token-bearing migrations retain a temporary App-Keychain compatibility copy
for shipped Malibu earnings calls; fresh tokenless bootstrap does not expose the CLI
credential to Malibu. A provider-ID-bound `.cli-credential-custody-v1` marker records
that the installed CLI freshly verified custody whenever that compatibility copy
exists. The exact shipped tokenless-YAML/App-only incident state is repaired by first
restoring its App bearer to private YAML, then running the ordinary installed-CLI
handoff. Secret snapshot deletion is confirmed before its journal is retired. Removing
the residual App credential dependency belongs to a later versioned earnings
replacement in issue #585; the v0.12 status reader alone does not remove it.
This v0.11 rule supersedes historical v0.4/v0.5 best-effort backup-cleanup notes.

**Change log v0.10 (2026-07-13, R9 audit-loop convergence — code source of truth).** R9
code/architect caught that the v0.9 watchdog routine/rollback boundary was fixed in §8 +
grounding table but NOT swept through the live §5 prose. v0.10 sweeps the last three
sites: the §5.2 architecture diagram, the §5.3 lifecycle sentence, and the §5.2 recovery
line now all state the boundary — the companion watchdog is a no-op on **routine** health
failures (provider-service `KeepAlive` restarts those) but **force-restarts** the provider
service during **auto-update rollback recovery** (`install.sh:4086,4113`).


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
(grace), `.bootstrap-identity-key` (current CLI admission identity; legacy service name),
`.admission-identity-key.pending`, and `.admission-identity-key.prev`, account
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
- Signed compatibility-set updates are validated, installed, admitted, committed, and
  rolled back by the launchd CLI as one exact transaction. Malibu can request the
  transaction but cannot update itself independently. "Quit and Uninstall" invokes the
  CLI transaction and reports any residue; dragging the app to Trash alone is not the
  supported uninstall path (§3.4).
- The CLI track coexists via the shared `config.yaml` + `.installed-by-app` marker (§7),
  with CLI-owned config routed to the import dialog (SPEC-026 §8). The installed CLI
  imports and fresh-process-verifies its own Keychain copy. A restarted CLI removes the
  matching YAML bearer only after coordinator admission and first state publication;
  Malibu then deletes any legacy App bearer and cannot recreate it.

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
| Local HTTP | `Sources/macprovider-cli/HTTPServer.swift` on `127.0.0.1:<port>` | Authoritative versioned lifecycle/status channel. Malibu polls `GET /v1/health` + `GET /v1/status`; unsupported older contracts degrade without false failure. |
| Control-plane IPC | `Sources/macprovider-cli/ControlSocket.swift` — typed JSON frames on an owner-only Unix socket | Read-only CLI-authenticated earnings/status projection. It never transfers a bearer or lifecycle ownership to Malibu. |
| Runtime | `mlx-swift-examples` (MLXLLM, MLXLMCommon) — pure Swift, no Python | Runs inside the **managed CLI** process, not the app; the app is a thin monitor wrapper. |
| Auth model | `provider_id` + `provider_token` bearer, per SPEC-001 / XSEC-1 | The CLI alone obtains, stores, and consumes the bearer. Malibu may read a legacy App item only long enough to migrate it into CLI custody, then deletes it. |
| Config | `~/.config/macprovider/config.yaml`, initially containing `provider_token` | A restarted CLI removes the exact matching migration source transactionally only after Keychain-backed coordinator admission. The fixed 0600 backup is the handoff snapshot; deletion is confirmed before journal retirement. |
| Provider service + watchdog LaunchAgents | `install.sh` installs BOTH the KeepAlive **provider service** `live.streamvc.macprovider` (plist `live.streamvc.macprovider.plist` — **this is the evidence the app checks**) and a SEPARATE **companion watchdog** `live.streamvc.macprovider-watchdog` (`StartInterval=60`, `install.sh:47,4264`) that health-observes the daemon; on routine ticks its restart request is a **no-op** (the provider service's `KeepAlive` performs routine restarts), except during auto-update rollback recovery where it force-restarts the provider service (`install.sh:4086,4113`) (reconciled v0.6/v0.8, §8 — the evidence plist is the provider service, NOT the watchdog). Evidence: `install_manifest.json` or the provider-service plist. | **The App track installs and relies on both** (via `install.sh`). `SMAppService.mainApp.register()` is a **separate** concern — it registers `Malibu.app` itself as a login item (`AppLoginItem.swift`), not the CLI daemon. |
| Portal | `portal.streamvc.live` (SPEC-014) — installer catalog | **Reconciled v0.2:** the wrapper does **not** open a portal URL for token issuance (removed with `malibu://`). App-track registration happens inside `install.sh` / the CLI track. |
| Release manifest / checksum | `scripts/sign-catalog.go`, `compatibility-set-manifest.py`, `compatibility-artifact-index.py`, tier2 release scripts | Binds the exact signed provider compatibility set and typed rollback plan. |
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
   When SPEC-034 referral admission is enabled, the same window may collect a
   referral code and syntax-check it as untrusted input. It MUST label validation
   as local until the coordinator accepts the CLI registration attempt.
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
     `/bin/bash <temp-copy 0700>` with **no CLI args**. Current
     `CLIInstallRunner.installerEnvironment` does **not** inherit the parent
     environment: it constructs a sanitized allowlist containing fixed
     `PATH`/`HOME`/`TMPDIR`/`LC_ALL`, `MACPROVIDER_NO_PROMPT=1`, and only its
     validated port/version values (`CLIInstallRunner.swift:92-119`).

     Referral onboarding extends that exact boundary as
     `CLIInstallRunner.run(referralCode:)`. After bounded syntax validation it
     adds one explicit `MACPROVIDER_REFERRAL_CODE` value to the sanitized install
     environment. `install.sh` immediately writes the value to the CLI-owned 0600
     journal `~/.config/macprovider/onboarding/referral-attempt-v1.json`, unsets
     it, and invokes `macprovider-cli bootstrap-auth
     --referral-code-file <journal>`. The code never appears in argv, config,
     logs, lifecycle status, or Malibu persistence. The CLI sends it only on the
     bootstrap initial/proof frames, persists the returned bearer to CLI Keychain,
     then atomically retires the plaintext journal before exit 0. That exit is the
     non-secret acknowledgement Malibu observes; the bearer never crosses back.

     Compatibility-set manifest v1 is exact-key and has no capability field; it
     MUST NOT be extended in place. For the fresh bundled path, the replacement
     Malibu build enables this UI only for its compiled-in v1 handoff. Before
     execution it hashes the exact `Contents/Resources/install.sh` regular-file
     bytes it is about to copy/run and requires equality with the signed
     manifest's `components.launchd.install_contract.sha256`, whose declared
     member is `compatibility-set-local/install.sh`. A missing, unreadable,
     symlinked, or mismatched top-level resource renders referral onboarding
     unavailable and executes nothing. For an existing installation, Malibu
     requires `referral_bootstrap_v1` in the installed CLI's versioned local
     status contract. Otherwise it renders referral onboarding unavailable while
     retaining ordinary attach/monitor behavior. No marketing-version equality
     check substitutes for either gate.
     `install.sh` performs the register + autotune (`autotune --recommend`) + model
     download + **launchd provider-service + watchdog install**; the app only surfaces a progress hint
     by scraping `ps` for the autotune stage (`:110-149`). A non-zero installer exit
     throws (installer rollback semantics).
   - **Verify CLI credential custody** (`importCLIConfigAfterInstall` →
     `ProviderConfig.importExistingCLIConfig()`, `:128`) — for an existing YAML bearer,
     save/verify the temporary App-Keychain compatibility copy, run installed-CLI
     credential import, then run a distinct fresh-process verify against one immutable
     0600 snapshot. Fresh bootstrap is already tokenless and runs verify-only against
     CLI Keychain. Malibu retains any existing YAML `provider_token`; CLI-owned
     admission cleanup removes it later. An absent CLI credential or incompatible
     installed CLI is retriable and preserves rollback state.
   - **Finalize** (`finalizeInstall`, `:165-199`): wait for the launchd provider's
     `GET /v1/health`, retry the Keychain import, then check `appIdentityConfigured`
     — which is actually `ProviderConfig.isConfigured` (config + `.installed-by-app`
     marker + provider ID, plus a matching `.cli-credential-custody-v1` marker when an
     App compatibility bearer remains, `:65`, `ProviderConfig.swift`), **NOT** the
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
- Referral UI is likewise capability-gated: Malibu renders the sanitized CLI
  projection and invokes typed CLI actions, but does not persist referral policy,
  read credentials, call coordinator referral endpoints, or award capacity.
- The dashboard also renders the compatible local status-contract version, exact
  process instance (role/PID/short instance ID), last CLI-authored lifecycle state and
  reason, and typed credential recovery guidance. A repair button is shown only for
  `recovery_action=repair_from_protected_source`; it invokes the signature-validated
  installed CLI, accepts bounded version-1 JSON stdout, discards stderr, and waits for
  launchd health after success. Locked, permission-denied, conflict, unavailable, and
  unknown/future contracts never trigger automatic mutation.
- On login: `SMAppService.mainApp.register()` starts `Malibu.app` in the background.
  No Dock icon. (This registers the **app** as a login item; the **CLI daemon** is
  owned by the launchd **provider service** `live.streamvc.macprovider` (`KeepAlive`)
  that `install.sh` set up — a separate mechanism from the app login item, §8.)

### 3.3 Updates — CLI-owned signed compatibility set

- The release artifact index binds one exact version of Malibu.app, macprovider-cli,
  launchd definitions, watchdog, catalog/resources, coordinator admission metadata,
  and rollback schema. Every compatibility-set member is hash-bound and release-role
  checked before mutation.
- The launchd CLI owns both scheduled and user-requested updates. Malibu's menu and
  dashboard invoke `macprovider-cli update`; they do not download or replace artifacts.
  Removing the Sparkle dependency/runtime and feed settings eliminates the prior
  second update authority. Stable v1.8.39 alone retains the frozen 1.8.32
  `SUPublicEDKey` in its signed target bundle because Sparkle 2.6.4 requires key
  continuity after extraction; without Sparkle code or a feed, this public key cannot
  initiate an update. Later builds must omit it.
- The updater acquires the maintenance lease, persists a phase journal and exact typed
  rollback plan, stages and validates the target, drains buyer work, installs the whole
  set, restarts launchd, and commits only after the coordinator admits that exact set
  and the provider proves buyer-serving readiness. Failure restores the prior exact set,
  including Malibu.app and launchd/watchdog resources, and retains the rollback material
  until prior-set admission and buyer-serving readiness are proven.
- `auto_update_enabled: false` suppresses scheduled mutation of every set member. It
  does not disable the explicit user action. Model caches remain outside the set unless
  a signed target explicitly declares a compatible model/catalog migration.

### 3.4 Uninstall

- **Quit and Uninstall…** is a reachable, confirmed menu action. Malibu first invokes
  the installed CLI's typed `uninstall --yes` transaction, waits for exact launchd job
  absence, unregisters its login item, removes App-owned configuration/support data,
  and reports any residue before terminating. Drag-to-trash alone is not the supported
  provider uninstall because the launchd service intentionally outlives the UI process.
- Routine uninstall preserves the CLI-Keychain provider bearer and admission identity
  so reinstall can recover the same provider and billing history. App-owned legacy
  Keychain items are removed, receipt/admission custody is not silently reset, and model
  caches remain unless a separate explicit data-reset operation is introduced.
  Routine CLI uninstall validates the managed label set, stops the watchdog before the
  provider, then proves both jobs remain absent after the complete stop phase
  (`launchctl print` service-not-found status 113; every other nonzero status is
  indeterminate and fails closed). It preserves the provider's CLI-Keychain bearer so a
  retained principal can reinstall safely; this action is not a full cryptographic
  identity reset.

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
│   │   app (+ health watchdog: routine no-op, force-kickstart on         │ │
│   │   auto-update rollback — §8)                                        │ │
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
  Info.plist                       # LSUIElement=true; no update feed or URL scheme
  MacOS/
    Malibu                         # Swift binary (wrapper)
    macprovider-cli                # REQUIRED — signed CLI copied in by release.yml:556; verify-tier2-provider-release.sh:405 rejects a bundle without it
    mlx.metallib                   # REQUIRED — MLX Metal shader library (release.yml)
  Resources/
    install.sh                     # bundled CLI-track installer (mode 755, project.yml:72-75)
    Assets.car
  _CodeSignature/
```

Note (reconciled v0.3): the **running** provider is the `macprovider-cli` that
`install.sh` installs into `~/macprovider/` (the launchd-managed location). Separately,
the release pipeline **REQUIRES** a `macprovider-cli` binary bundled in
`Contents/MacOS/`: `release.yml:544` copies it in and
`verify-tier2-provider-release.sh:405` **rejects an App bundle without it** (reconciled
v0.3 — required, not optional). The bundled copy is the signed transaction invoker and
installation source; the live daemon remains the launchd install. `Info.plist` carries **no**
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
`install.sh` installs owns the CLI's lifecycle and routine restarts (the companion
watchdog is a no-op on routine health failures, but DOES force-restart the provider
service during auto-update rollback recovery — §8).
`MalibuAgent` holds a `var child: CLIChildProcess?` but **never instantiates it** in
shipped code — `CLIChildProcess(` has no call site in `Sources` or `Tests`; the field
is only read to defensively release a child left by an *older* build
(`releaseSpawnedChildForLaunchdMonitor`, `MalibuAgent.swift:231-245`). The
`--managed-by malibu-app` / `--enable-warm-swap` argv is not exercised.

What the app actually does around lifecycle:
- **Attach/monitor:** poll `/v1/health` + the capability-gated `/v1/status`; attach to
  the owner-only control socket for CLI-authenticated earnings/status projection;
  first-attach every 2 s up to 600 s, steady every 15 s. **Reconciled v0.13:**
  a locally-ready but non-`buyer_serving` provider (or an undiagnosed connection loss)
  is surfaced as "Reconnecting" (`MalibuAgent.swift:307`); **diagnosed**
  startup/health failures and the first-attach timeout transition to **`.error`**, not
  "Reconnecting" (`MalibuAgent.swift:89,391`). Routine recovery of the daemon is the
  launchd provider service's `KeepAlive` job (the watchdog is a no-op on routine health
  but force-restarts the provider service during auto-update rollback, §8), not an in-app
  restart loop.
- **Quit:** `agent.shutdown(gracefulSeconds:)` stops only Malibu monitoring; it never
  drains or signals the launchd provider. Update/uninstall drain is owned by the CLI
  transaction.
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
No App-specific update-signing secret exists. Compatibility metadata is signed through
the release trust path already used by the provider catalog and artifact index.

### 6.2 App and compatibility-set CI steps

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
6. `hdiutil` → `Malibu-<version>.dmg`.
7. `codesign --sign "$SIGNING_ID" --timestamp Malibu-<version>.dmg`.
8. `xcrun notarytool submit Malibu-<version>.dmg --apple-id $APPLE_NOTARY_APPLE_ID --password $APPLE_NOTARY_PASSWORD --team-id $APPLE_NOTARY_TEAM_ID --wait` (this one **is** staplable — unlike the bare CLI).
9. `xcrun stapler staple Malibu-<version>.dmg` and `stapler validate`.
10. Build the exact compatibility-set manifest and typed rollback plan, then place the
    DMG and every provider runtime/policy artifact in the signed
    `compatibility-artifact-index.json`.
11. Publish only immutable versioned GitHub release artifacts; the updater discovers
    the signed exact set through the coordinator/catalog trust path. There is no mutable
    `latest.dmg` or appcast authority.

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
| CLI custody marker | `~/Library/Application Support/Malibu/.cli-credential-custody-v1` containing the exact provider ID | App-local migration evidence that an installed CLI freshly verified custody; never credential authority |
| Logs (rolling, 100 MB cap) | `~/Library/Logs/malibu/` | Shared, app tags its own lines |
| `provider_token` | Authoritative CLI Keychain service `live.streamvc.macprovider.provider-token.v1`, account `<provider_id>`; private YAML is a degraded transition fallback until admission-gated cleanup | CLI owns runtime credential. A legacy App item is migration input only and is deleted after CLI custody is proven. |
| Session receipt / admission keys | Keychain (CLI store), services `com.streamvc.macprovider.receipt-key` (current, rotatable — signs receipts), `com.streamvc.macprovider.receipt-key.prev` (receipt rotation grace), `com.streamvc.macprovider.bootstrap-identity-key` (current admission identity; legacy name), `com.streamvc.macprovider.admission-identity-key.pending`, and `.prev`, all account `<provider_id>`. Admission identity rotates/recoveries by SPEC-026 §4.3 without Malibu key custody. | Unchanged from CLI track (reuses the existing CLI key store) |

Rules (reconciled v0.2 to the shipped `StartupState.route()` + `ProviderConfig`):

- **On first run of the app:** if `config.yaml` exists AND the `.installed-by-app`
  marker does NOT → route to `.showImportDialog` ("We found a MacProvider config.
  Import it into Malibu?"). On import, `ProviderConfig.importExistingCLIConfig()`
  reads an existing YAML `provider_token`, then runs installed-CLI
  `credentials import --config` followed
  by a distinct `credentials verify --config` against one immutable snapshot. A
  tokenless config normally runs verify-only and requires the provider's CLI-Keychain
  item. The exact legacy tokenless-YAML/App-Keychain-only state first restores its
  bearer to private live YAML so launchd retains rollback custody, then follows the
  token-bearing transaction.
  After fresh CLI custody is proven, Malibu deletes and verifies deletion of any
  legacy App bearer. The CLI keeps the live migration source until launchd admission.
  A missing/old CLI or failed proof preserves the original private YAML. Never
  silent-migrate.
  (`StartupRouteTests.swift:10-12`.)
- **On Quit-and-Uninstall:** `ProviderConfig.wipeAppOwnedState()` deletes
  `config.yaml` **only if the marker is present** (`ProviderConfig.swift:478-501`).
- **`isConfigured`** = `config.yaml` present AND `.installed-by-app` marker present,
  a top-level `provider_id`, and the provider-ID-bound
  `.cli-credential-custody-v1` marker. Credential readiness is reported by the launchd CLI's
  redacted `/v1/status.credential` contract, not inferred from Malibu's Keychain.
  **Route precedence (reconciled v0.3):** a *markerless* CLI-owned `config.yaml` takes
  FIRST precedence and routes to `.showImportDialog` — even when the launchd provider is
  healthy (`LaunchProviderController.swift:352`), per the first bullet above; only when
  the marker IS present but the config identity or required custody evidence is
  incomplete does a failed `isConfigured` route to onboarding, and a fully-absent config also routes to
  onboarding. **Token custody (reconciled v0.13 — nuanced, not "never
  on disk"):** the CLI deliberately retains the live YAML `provider_token` as rollback
  state after staging Keychain custody. A restarted provider reports
  `migration_pending=true`; only its authenticated coordinator admission and first
  state update permit locked exact-value removal. The one fixed 0600 backup is also
  the immutable handoff snapshot. The importer must confirm its deletion before deleting
  `.import_pending`; a cleanup failure keeps the journal for deterministic recovery. Until
  launchd admission, the App track therefore makes no "token never on disk" claim.
- **CLI track never touches** `~/Library/Application Support/Malibu/` or the app's
  Keychain entries; it owns only its separate CLI-Keychain service.

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

## 9. Compatibility-set trust and discovery

- The compatibility artifact index is the release root for update discovery. It binds
  immutable GitHub release artifact names, SHA-256 digests, required release roles, the
  compatibility-set manifest, and rollback-plan schema.
- The CLI verifies the catalog/release trust chain, artifact-index signature, exact set
  identity, per-role uniqueness, hashes, Developer ID identity/team where applicable,
  launchd labels, and target coordinator policy before any drain or replacement.
- Malibu carries no feed URL or independent discovery channel. Stable v1.8.39
  alone carries the frozen v1.8.32 public key as inert trust-continuity metadata;
  it has no Sparkle runtime, and later builds carry no app-update public key.
  Failure to verify or fetch any required member leaves the current set running and
  emits a typed redacted update state. A staged target that cannot prove exact-set
  admission and buyer-serving readiness is rolled back as a whole.

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
