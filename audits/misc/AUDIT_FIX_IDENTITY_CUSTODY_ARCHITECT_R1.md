# Audit Prompt — Identity Custody Architect R1

You are architecture-auditing branch `fix/deepsec-provider-identity-token-custody`.
Return findings only, grouped by severity: CRITICAL, HIGH, MEDIUM, LOW.
The pass condition is 0 CRITICAL / 0 HIGH / 0 MEDIUM; LOW is allowed.

Review whether the implementation boundaries and specifications are coherent
across coordinator auth, App-track onboarding, Swift token custody, and local
crash consistency.

Files:

- `phase4-coordinator/internal/pool/provider.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/onboarding/apptrack.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
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

Architecture questions:

- Is trust-state ownership centralized enough to prevent caller-by-caller drift?
- Do the spec gates and handler behavior line up, including nginx routing?
- Are Swift environment/path/token-file policies reusable without creating conflicting allowlists?
- Does App-track import/link recovery have a clear state machine and idempotent retry behavior?
- Are deferred SPEC-027 proof mechanisms isolated without leaving accidental live paths?

Do not require implementation of the full SPEC-027 proof protocol. Report concrete boundary or contract risks with file/line references.
