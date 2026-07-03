# Malibu.app — P0 skeleton

Swift + SwiftUI menu-bar wrapper around `macprovider-cli`. See [SPEC-025](../../specs/SPEC-025-native-mac-app.md).

## Layout

```
app/
├── project.yml                    # XcodeGen input — generates Malibu.xcodeproj
├── Malibu.entitlements
└── Sources/Malibu/
    ├── MalibuApp.swift            # @main + AppDelegate + URL-scheme routing
    ├── Info.plist                 # merged with keys from project.yml
    ├── MenuBar/
    │   └── MenuBarController.swift
    ├── Agent/
    │   ├── MalibuAgent.swift      # ObservableObject; snapshot published to menu bar + dashboard
    │   ├── CLIChildProcess.swift  # owns the macprovider-cli child + restart backoff
    │   ├── ControlSocketClient.swift  # unix-socket JSON framing client
    │   └── ControlSocketFrame.swift   # wire-format mirror of CLI's frames (DUPLICATED — see below)
    ├── Onboarding/
    │   └── OnboardingWindow.swift # 3-step SwiftUI onboarding
    ├── Dashboard/
    │   └── DashboardWindow.swift  # SwiftUI dashboard
    └── System/
        ├── ProviderPaths.swift    # ~/.config/macprovider/... vs ~/Library/Application Support/Malibu/...
        ├── ProviderConfig.swift   # writes shared config.yaml, tracks App-track ownership marker
        ├── KeychainStore.swift    # provider_token in Keychain, service tech.malibu.provider
        ├── AppLoginItem.swift     # SMAppService.mainApp wrapper
        └── URLSchemeHandler.swift # malibu:// deep links
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
2. **CLI-side frames missing.** `metrics_request`, `pause_request`, `resume_request`, `shutdown_request` are defined here but not yet in the CLI. Add them to `ControlSocket.swift` + `ControlSocketCodec` and unit-test.
3. **`--managed-by malibu-app` CLI flag.** The wrapper passes it; the CLI must (a) accept it and (b) disable its own `AutoUpdater` when present so Sparkle owns updates end-to-end.
4. **`--control-socket <path>` CLI flag.** Confirm the CLI already accepts this; if not, add.
5. **URL scheme state validation.** `URLSchemeHandler` currently accepts any well-formed `malibu://link`. Add nonce challenge tied to the outbound portal URL.
6. **CLI-track config migration dialog.** If `~/.config/macprovider/config.yaml` exists without the App-track marker, `ProviderConfig` currently overwrites `provider_id` lines silently. Add the migration dialog described in SPEC-025 §7.
7. **Sparkle** not wired up yet — separate P3 pass.
8. **Signed release pipeline** — extends `.github/workflows/release.yml` per SPEC-025 §6.2. Not part of this skeleton.
