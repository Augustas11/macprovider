# Malibu.app — P0 skeleton

Swift + SwiftUI menu-bar wrapper around `macprovider-cli`. See [SPEC-025](../../specs/SPEC-025-native-mac-app.md).

## Layout

```
app/
├── project.yml                    # XcodeGen input — generates Malibu.xcodeproj
├── Malibu.entitlements
├── scripts/
│   └── generate-app-icon.sh       # SVG → 10 PNG sizes via qlmanage (no deps)
└── Sources/Malibu/
    ├── MalibuApp.swift            # @main + AppDelegate + menu/onboarding routing
    ├── Info.plist                 # merged with keys from project.yml
    ├── Resources/
    │   ├── Brand/malibu-icon.svg  # canonical brand mark, mirrors malibu.tech/favicon.svg
    │   └── Assets.xcassets/       # AppIcon.appiconset (10 PNGs, generated)
    ├── MenuBar/
    │   ├── MenuBarController.swift
    │   └── BrandMark.swift        # MalibuBrandTile + MalibuMenuBarIcon (template) + palette
    ├── Agent/
    │   ├── MalibuAgent.swift      # ObservableObject; snapshot published to menu bar + dashboard
    │   ├── ControlSocketClient.swift  # read-only owner-local CLI projection client
    │   └── ControlSocketFrame.swift   # wire-format mirror of CLI's frames (DUPLICATED — see below)
    ├── Onboarding/
    │   ├── LaunchProviderController.swift # browserless provider launch state machine
    │   └── OnboardingWindow.swift         # SwiftUI onboarding
    ├── Dashboard/
    │   └── DashboardWindow.swift  # SwiftUI dashboard
    └── System/
        ├── ProviderPaths.swift    # ~/.config/macprovider/... vs ~/Library/Application Support/Malibu/...
        ├── ProviderConfig.swift   # reads shared config, migrates legacy custody to CLI
        ├── ProviderCredentialHandoffRunner.swift # invokes CLI-owned credential transactions
        └── ProviderDiagnosticsBundle.swift       # read-only support export
```

## Build

Prereqs:

```
brew install xcodegen
```

Generate + build:

```
cd phase3-binary/app
xcodegen generate                        # produces Malibu.xcodeproj
open Malibu.xcodeproj                    # or:
xcodebuild -project Malibu.xcodeproj -scheme Malibu -configuration Release
```

## Running against a locally-built CLI

The `.app` looks for `macprovider-cli` at `Contents/MacOS/macprovider-cli` first, then falls back to `$MALIBU_CLI_PATH`. For local dev:

```
# from repo root
swift build -c release --package-path phase3-binary
export MALIBU_CLI_PATH="$PWD/phase3-binary/.build/release/macprovider-cli"
open build/Release/Malibu.app
```

## Issue 585 lifecycle contract

1. **One lifecycle owner.** The launchd-managed CLI owns provider credentials,
   admission identity, persisted lifecycle state, pause/resume, updates, rollback,
   repair, and uninstall. Malibu observes that state and invokes CLI transactions;
   it does not keep a provider bearer or independently mutate provider state.
2. **Operational control surface.** The owner-only control socket reports status,
   metrics, provider earnings, and lifecycle acknowledgements. Pause/resume is
   committed by the CLI state machine before Malibu presents the new state.
3. **Restart-safe import.** Existing CLI configs route through the SPEC-026
   migration surface. The protected legacy credential is retained until a
   restarted launchd instance proves coordinator admission from CLI Keychain
   custody.
4. **Exact-set updates.** The CLI validates the signed compatibility set, obtains
   the coordinator admission gate, holds a maintenance lease, drains work, and
   replaces Malibu, the CLI, launchd, watchdog, catalog/policy material, and
   rollback metadata as one transaction.
5. **Signed release pipeline.** After a reviewed commit is merged to `main`, an
   operator creates its protected `vX.Y.Z` tag and manually dispatches
   `release.yml` from `main`. The protected workflow ships the stapled
   `Malibu-{tag}.dmg` and the exact provider compatibility set bound by the
   signed `compatibility-artifact-index.json`.

The App and CLI currently compile separate representations of the newline JSON
control frames. Cross-target codec parity tests lock the wire contract; extracting
those representations into a small shared module remains a maintenance cleanup,
not a second lifecycle or state authority.

## Uninstall (Malibu + CLI)

Malibu **Quit and Uninstall** runs, in order:

1. `macprovider-cli uninstall --yes` (stops launchd, removes CLI binary/plists/manifest)
2. Malibu login item unregister
3. App Keychain slots + App Support wipe

CLI-only uninstall remains:

```bash
bash <(curl -fsSL https://get.malibu.tech/uninstall.sh)
# or
macprovider-cli uninstall --yes
```

CLI uninstall does **not** remove `~/Library/Application Support/Malibu`; use Malibu's
confirmed **Quit and Uninstall…** action for the complete App-owned cleanup. Provider
credentials and admission identity remain in CLI Keychain custody so reinstall can
recover the same provider ownership.

Malibu uninstall does **not** remove Hugging Face model caches (`~/.cache/huggingface/`) — same as CLI uninstall.

Fresh-Mac validation checklist: `scratchpad/fresh-mac-smoke-v1.8.13.md`.
