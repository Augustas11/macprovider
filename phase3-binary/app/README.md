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
2. **CLI-side handler semantics.** Frames + wire format are wired end-to-end (`feat(control-socket): add metrics/pause/resume/shutdown frames`), but the server-side handlers are stubs — `pause_ack`/`resume_ack` return `accepted:false, reason:"not_implemented"` and `metrics_response` returns zeros. Real earnings / uptime source + pause gating land in P1.
3. **URL scheme state validation.** `URLSchemeHandler` currently accepts any well-formed `malibu://link`. Add nonce challenge tied to the outbound portal URL.
4. **CLI-track config migration dialog.** If `~/.config/macprovider/config.yaml` exists without the App-track marker, `ProviderConfig` currently overwrites `provider_id` lines silently. Add the migration dialog described in SPEC-025 §7.
5. **Sparkle** not wired up yet — separate P3 pass.
6. **Signed release pipeline** — extends `.github/workflows/release.yml` per SPEC-025 §6.2. Not part of this skeleton.
