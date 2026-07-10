# Audit Prompt — Identity Custody Security R1

You are security-auditing branch `fix/deepsec-provider-identity-token-custody`.
Return findings only, grouped by severity: CRITICAL, HIGH, MEDIUM, LOW.
The pass condition is 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW.

Focus exclusively on bearer-token custody, identity trust, redirect leakage,
environment leakage, App Attest pinning, and crash/retry states in:

- `phase4-coordinator/internal/pool/provider.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/ws/provider_token_self_serve_test.go`
- `phase4-coordinator/internal/onboarding/apptrack.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `phase3-binary/Sources/MacProviderCore/ProcessEnvironmentSanitizer.swift`
- `phase3-binary/Sources/MacProviderCore/BrowserOpener.swift`
- `phase3-binary/Sources/MacProviderCore/Config.swift`
- `phase3-binary/Sources/macprovider-cli/ClaimCommand.swift`
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- `phase3-binary/app/Sources/Malibu/Agent/CLIChildProcess.swift`
- `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift`
- `phase3-binary/app/Sources/Malibu/System/ProcessEnvironmentSanitizer.swift`
- `phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift`
- `phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift`
- `specs/SPEC-016-payout-pipeline.md`
- `specs/SPEC-026-browserless-provider-onboarding.md`
- `specs/SPEC-027-provider-proof-of-ownership.md`

Security invariants to verify:

- No unauthenticated/tokenless flow can rotate, revoke, replace, or capture an existing provider bearer.
- Unverified self-minted provider state cannot route buyer work or qualify for payout.
- No bearer token is placed in process arguments, browser child environment, URL scheme parameters, logs, or cross-origin redirect headers.
- App-track App Attest validation fails closed when Team ID / Bundle ID pins are unset.
- Release builds do not send Keychain-provided bearer tokens to arbitrary `MALIBU_CLI_PATH` binaries.
- Token import/link retry markers do not create a rollback, duplicate-token, or stale-state bypass.

For each finding, include attacker preconditions, exploit path, affected file/line, and a concrete fix.
