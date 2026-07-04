# Audit Prompt — Identity Custody Code R1

You are auditing branch `fix/deepsec-provider-identity-token-custody`.
Return findings only, grouped by severity: CRITICAL, HIGH, MEDIUM, LOW.
The pass condition is 0 CRITICAL / 0 HIGH / 0 MEDIUM; LOW is allowed.

Review for correctness, test adequacy, edge cases, and maintainability in:

- `phase4-coordinator/internal/pool/provider.go`
- `phase4-coordinator/internal/pool/provider_test.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/ws/provider_token_self_serve_test.go`
- `phase4-coordinator/internal/onboarding/apptrack.go`
- `phase4-coordinator/internal/onboarding/apptrack_test.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/cmd/coordinator/main_test.go`
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `phase3-binary/Sources/MacProviderCore/ProcessEnvironmentSanitizer.swift`
- `phase3-binary/Sources/MacProviderCore/BrowserOpener.swift`
- `phase3-binary/Sources/MacProviderCore/Config.swift`
- `phase3-binary/Sources/macprovider-cli/ClaimCommand.swift`
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- `phase3-binary/Tests/macprovider-cliTests/BrowserOpenerTests.swift`
- `phase3-binary/Tests/macprovider-cliTests/ClaimCommandTests.swift`
- `phase3-binary/Tests/macprovider-cliTests/ServeCommandTests.swift`
- `phase3-binary/app/Sources/Malibu/Agent/CLIChildProcess.swift`
- `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift`
- `phase3-binary/app/Sources/Malibu/System/ProcessEnvironmentSanitizer.swift`
- `phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift`
- `phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift`
- `phase3-binary/app/Tests/MalibuTests/ProcessEnvironmentSanitizerTests.swift`
- `phase3-binary/app/Tests/MalibuTests/ProviderConfigTests.swift`
- `phase3-binary/app/Tests/MalibuTests/StartupRouteTests.swift`
- `phase3-binary/app/Tests/MalibuTests/LaunchProviderControllerTests.swift`
- `specs/SPEC-016-payout-pipeline.md`
- `specs/SPEC-026-browserless-provider-onboarding.md`
- `specs/SPEC-027-provider-proof-of-ownership.md`

Expected intent:

- Tokenless provider reconnect must not revoke or replace an active provider token.
- `self_minted` provider sessions are not routing/payout eligible until explicitly verified.
- App-track wallet binding is gated with a 501 until proof-of-ownership is specified.
- App Attest verification refuses unpinned Team ID / Bundle ID configuration.
- Malibu child/browser processes inherit only allowlisted environment variables.
- CLI path override is release-gated by signing-team validation.
- Claim refresh strips Authorization on cross-origin HTTPS redirects and rejects non-HTTPS redirects.
- Inline token argv input is rejected; `--token-file` requires a private file.
- App config import/linking has durable pending-state markers.

Do not suggest unrelated refactors. Include exact file/line references and a minimal reproducer or failing test idea for each issue.
