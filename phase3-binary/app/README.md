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
    │   ├── CLIChildProcess.swift  # owns the macprovider-cli child + restart backoff
    │   ├── ControlSocketClient.swift  # unix-socket JSON framing client
    │   └── ControlSocketFrame.swift   # wire-format mirror of CLI's frames (DUPLICATED — see below)
    ├── Onboarding/
    │   ├── LaunchProviderController.swift # browserless provider launch state machine
    │   └── OnboardingWindow.swift         # SwiftUI onboarding
    ├── Dashboard/
    │   └── DashboardWindow.swift  # SwiftUI dashboard
    └── System/
        ├── ProviderPaths.swift    # ~/.config/macprovider/... vs ~/Library/Application Support/Malibu/...
        ├── ProviderConfig.swift   # writes shared config.yaml, tracks App-track ownership marker
        ├── KeychainStore.swift    # provider_token in Keychain, service tech.malibu.provider
        ├── ProviderIdentity.swift # App-track Ed25519 identity in Keychain
        └── AppLoginItem.swift     # SMAppService.mainApp wrapper
        ├── MalibuUpdateConfiguration.swift  # Sparkle feed URL + Ed25519 public key
        └── SparkleUpdaterController.swift     # SPUStandardUpdaterController wrapper
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

## Known P0 gaps (tracked in SPEC-025 §12)

1. **`ControlFrame` is duplicated**, not shared. Extract the wire-format frames from `phase3-binary/Sources/macprovider-cli/ControlSocket.swift` into a new `MacProviderControl` library target so both CLI and app import one source of truth.
2. **CLI-side handler semantics.** Frames + wire format are wired end-to-end (`feat(control-socket): add metrics/pause/resume/shutdown frames`), but the server-side handlers are stubs — `pause_ack`/`resume_ack` return `accepted:false, reason:"not_implemented"` and `metrics_response` returns zeros. Real earnings / uptime source + pause gating land in P1.
3. **CLI-track config migration dialog.** If `~/.config/macprovider/config.yaml` exists without the App-track marker, the App routes to the SPEC-026 migration surface instead of overwriting it silently.
5. **Sparkle in-app updates** — wired via `SparkleUpdaterController` + `https://download.malibu.tech/appcast.xml`. Release CI signs appcast entries with `SPARKLE_EDDSA_PRIVATE_KEY`; publish with `scripts/publish-malibu-latest-dmg.sh` uploads `appcast.xml` beside `latest.dmg`. CLI self-update stays disabled under `--managed-by malibu-app`.
6. **Signed release pipeline** — after a reviewed commit is merged to `main`, an operator creates its protected `vX.Y.Z` tag and manually dispatches `release.yml` from `main`. The protected workflow ships stapled `Malibu-{tag}.dmg` (primary) and optional `Malibu-{tag}.pkg`, captures signed provenance plus numeric GitHub release/asset IDs, and publishes `latest.dmg` + `appcast.xml` from the same workflow files. Manual Pearl recovery uses `scripts/recover-malibu-publication.sh`; tag-based redownload is not a recovery path.

## Uninstall (Malibu + CLI)

Malibu **Quit and Uninstall** runs, in order:

1. `macprovider-cli uninstall --yes` (stops launchd, removes CLI binary/plists/manifest)
2. Malibu login item unregister
3. App Keychain slots + App Support wipe

CLI-only uninstall remains:

```bash
bash <(curl -fsSL https://get.streamvc.live/uninstall.sh)
# or
macprovider-cli uninstall --yes
```

CLI uninstall does **not** remove `~/Library/Application Support/Malibu` or Malibu Keychain tokens — use Malibu uninstall or delete App Support manually.

Malibu uninstall does **not** remove Hugging Face model caches (`~/.cache/huggingface/`) — same as CLI uninstall.

Fresh-Mac validation checklist: `scratchpad/fresh-mac-smoke-v1.8.13.md`.
