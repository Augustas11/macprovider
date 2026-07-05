import ArgumentParser
import CryptoKit
import Darwin
import Dispatch
import Foundation
import MacProviderCore

@main
struct MacProviderCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macprovider-cli",
        abstract: "OpenAI-compatible Mac Provider inference CLI.",
        version: CoordinatorClient.binaryVersion,
        subcommands: [ServeCommand.self, SelfTestCommand.self, StatusCommand.self, ClaimCommand.self, UpdateCommand.self, UninstallCommand.self, ModelsCommand.self, AutotuneCommand.self, RotateKeyCommand.self, Spec028CanaryCommand.self],
        defaultSubcommand: ServeCommand.self
    )
}

struct ServeCommand: AsyncParsableCommand {
    // SPEC-028 AC-8: the bundled coordinator decoder and state-update path
    // accept these optional heartbeat fields without changing routing,
    // trust, settlement, or admission behavior. Pinned by coordinator tests:
    // TestParseHeartbeatAcceptsSpecDecodeOptInFieldsAsForwardCompatible and
    // TestHeartbeatSpecDecodeOptInFieldsPreserveStatePath.
    static let bundledCoordinatorAcceptsSpecDecodeTelemetry = true

    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the local inference server and coordinator client."
    )

    @Option(help: "Local HTTP port to bind. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Optional speculative decoding draft model identifier or local path. Overrides MACPROVIDER_DRAFT_MODEL and config key draft_model.")
    var draftModel: String?

    @Option(help: "Lowercase SHA-256 artifact hash for the draft model snapshot. Overrides MACPROVIDER_DRAFT_MODEL_ARTIFACT_SHA256 and config key draft_model_artifact_sha256.")
    var draftModelArtifactSha256: String?

    @Option(help: "Speculative decoding draft tokens per verification round. Default 3 when --draft-model is set; valid range 1...16.")
    var numDraftTokens: Int?

    @Flag(name: .customLong("publish-spec-decode-telemetry"), inversion: .prefixedNo, help: "Opt into publishing SPEC-028 speculative decoding telemetry on coordinator heartbeats after compatibility is verified. Default off.")
    var publishSpecDecodeTelemetry: Bool?

    @Option(help: "Coordinator WebSocket URL. Overrides MACPROVIDER_COORDINATOR_URL and config file coordinator_url.")
    var coordinator: String?

    @Option(help: "Stable provider identifier sent in the coordinator hello message. Must match the coordinator's config.providers[] entry. Overrides MACPROVIDER_PROVIDER_ID and config file provider_id. If unset, a per-instance UUID is generated (suitable for dev/test only).")
    var providerID: String?

    @Option(help: "Public HTTPS endpoint for HTTP-forwarding mode. If omitted, the provider defaults to WS-tunneled mode unless config overrides it.")
    var endpointURL: String?

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Log level: trace, debug, info, notice, warning, error, critical.")
    var logLevel: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths) this provider can serve. Overrides MACPROVIDER_SUPPORTED_MODELS and config key supported_models. When unset, the binary publishes supported_models: [model_id] (single-entry, per SPEC-010 v1.5 R-3.6.2).")
    var supportedModels: String?

    @Flag(name: .customLong("publish-supported-models"), inversion: .prefixedNo, help: "Opt into publishing the supported_models catalog to the coordinator's /v1/status echo (SPEC-010 v1.5 R-3.6.4). Default off.")
    var publishSupportedModels: Bool?

    @Flag(name: .customLong("enable-warm-swap"), inversion: .prefixedNo, help: "Opt into the operator-pushed warm model swap workflow (SPEC-011 v0.5). Default off. When off, the binary follows the SPEC-001 v1.2.4 synchronous-load path; no control socket is opened.")
    var enableWarmSwap: Bool?

    @Flag(name: .customLong("enable-receipts"), inversion: .prefixedNo, help: "Opt into SPEC-015 non-streaming receipt emission. Default off for v0.1.x rollout.")
    var enableReceipts: Bool?

    @Option(help: "Drain timeout in seconds for an in-flight warm swap (SPEC-011 v0.5 §3.4 / §3.9). Default 30. Only meaningful when --enable-warm-swap is set.")
    var swapDrainTimeoutSeconds: Int?

    @Option(help: "Control socket path. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock. Only meaningful when --enable-warm-swap is set.")
    var ctlSocketPath: String?

    // Phase 1E reads/writes this path for the cooldown soft guard; Phase 1C only plumbs it.
    @Option(help: "CLI-side cooldown state file. Overrides MACPROVIDER_SWITCH_STATE_PATH and config switch_state_path. Default $HOME/Library/Application Support/macprovider-cli/last-switch.ts. Cooldown soft guard lands in Phase 1E.")
    var switchStatePath: String?

    @Option(name: [.customLong("provider-token"), .customLong("token")], help: "Deprecated inline provider token. This is rejected because argv is visible to same-user process inspection; use MACPROVIDER_PROVIDER_TOKEN, provider_token in a 0600 config file, or --token-file.")
    var providerToken: String?

    @Option(help: "Read provider authentication token from a 0600 file. Overrides MACPROVIDER_PROVIDER_TOKEN and config key provider_token without exposing the token in process arguments.")
    var tokenFile: String?

    @Option(help: "Marks this binary as spawned by an outer manager (SPEC-025). Setting this to 'malibu-app' disables the CLI's own AutoUpdater so Sparkle in Malibu.app owns whole-bundle updates. Overrides MACPROVIDER_MANAGED_BY and config key managed_by. Unset for the standalone CLI track.")
    var managedBy: String?

    @Option(help: "KV-cache quantization precision in bits (4 or 8). When set, forwarded to mlx-swift GenerateParameters.kvBits — quantizes the KV cache to reduce per-token memory footprint at a small accuracy cost. Unset (default) keeps the mlx-swift default of no KV quantization. Overrides MACPROVIDER_KV_BITS and config key kv_bits.")
    var kvBits: Int?

    @Option(help: "Maximum prompt context length (tokens) this provider will accept. Prompts whose tokenized length exceeds this cap are rejected with HTTP 413 context_length_exceeded. Also wired to mlx-swift GenerateParameters.maxKVSize, capping KV-cache allocation. Unset defers to the per-tier default (8GB:20000, 16GB:50000, 32GB:120000, 64GB+:200000). Overrides MACPROVIDER_MAX_CONTEXT_OVERRIDE and config key max_context_override.")
    var maxContext: Int?

    @Option(help: "Maximum concurrent in-flight inferences. Defaults to 1 (single-slot, the only safe value while mlx-swift parallel generation remains unproven). Lifting this above 1 is an autotune knob — the binary itself does not enforce safety beyond the AsyncSemaphore. Overrides MACPROVIDER_MAX_CONCURRENCY_OVERRIDE and config key max_concurrency_override.")
    var maxBatch: Int?

    @Flag(name: .customLong("idle-prewarm"), inversion: .prefixedNo, help: "Enable provider-side idle MLX Metal prewarm. Default on.")
    var idlePrewarm: Bool?

    @Option(name: .customLong("idle-prewarm-idle-threshold-s"), help: "Seconds of no real requests before idle prewarm may fire. Default 30; range 5...3600.")
    var idlePrewarmIdleThresholdSeconds: Double?

    @Option(name: .customLong("idle-prewarm-tick-s"), help: "Idle prewarm check interval in seconds. Default 5; range 1...60.")
    var idlePrewarmTickSeconds: Double?

    @Option(name: .customLong("idle-prewarm-max-tokens"), help: "Synthetic warmup max tokens. Default 1; range 1...8.")
    var idlePrewarmMaxTokens: Int?

    @Option(name: .customLong("idle-prewarm-prompt"), help: "Synthetic warmup prompt. Default 'warm'; range 1...64 UTF-8 bytes.")
    var idlePrewarmPrompt: String?

    @Flag(name: .customLong("idle-prewarm-on-battery"), inversion: .prefixedNo, help: "Allow idle prewarm while running on battery. Default off.")
    var idlePrewarmRunOnBattery: Bool?

    @Flag(help: "Run only the local HTTP server; do not establish a coordinator WebSocket session.")
    var noJoin = false

    static func runSupportedModelsPreflight(_ resolved: inout AppConfig) throws {
        if resolved.supportedModels != nil {
            do {
                let catalog = try SupportedModels.validate(
                    model: resolved.model ?? "",
                    supportedModels: resolved.supportedModels
                )
                resolved.supportedModels = catalog
            } catch let error as SupportedModelsValidationError {
                FileHandle.standardError.write(Data(("\(error)\n").utf8))
                throw ExitCode(2)
            }
        }
    }

    static func runDrainTimeoutPreflight(_ resolved: AppConfig) throws {
        if !(5...600).contains(resolved.swapDrainTimeoutSeconds) {
            FileHandle.standardError.write(Data((
                "--swap-drain-timeout-seconds \(resolved.swapDrainTimeoutSeconds) out of range 5...600\n"
            ).utf8))
            throw ExitCode(2)
        }
    }

    // SPEC-013 autoresearch serving knobs: fail loud at serve start
    // instead of mid-inference when an operator passes a value mlx-swift
    // does not accept.
    static func runServingKnobsPreflight(_ resolved: AppConfig) throws {
        if let kvBits = resolved.kvBitsOverride, kvBits != 4 && kvBits != 8 {
            FileHandle.standardError.write(Data((
                "--kv-bits \(kvBits) invalid; must be 4 or 8\n"
            ).utf8))
            throw ExitCode(2)
        }
        if let maxContext = resolved.maxContextOverride, maxContext < 1 {
            FileHandle.standardError.write(Data((
                "--max-context \(maxContext) must be >= 1\n"
            ).utf8))
            throw ExitCode(2)
        }
        if let maxBatch = resolved.maxConcurrencyOverride, maxBatch < 1 {
            FileHandle.standardError.write(Data((
                "--max-batch \(maxBatch) must be >= 1\n"
            ).utf8))
            throw ExitCode(2)
        }
        if !(1...16).contains(resolved.numDraftTokens) {
            FileHandle.standardError.write(Data((
                "--num-draft-tokens \(resolved.numDraftTokens) out of range 1...16\n"
            ).utf8))
            throw ExitCode(2)
        }
        if let draftModel = resolved.draftModel,
           draftModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            FileHandle.standardError.write(Data("--draft-model must be non-empty\n".utf8))
            throw ExitCode(2)
        }
        if let hash = resolved.draftModelArtifactSHA256,
           hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) == nil {
            FileHandle.standardError.write(Data("draft_model_artifact_sha256 must be 64 lowercase hex characters\n".utf8))
            throw ExitCode(2)
        }
    }

    static func runSpecDecodeHeartbeatCompatibilityPreflight(
        _ resolved: AppConfig,
        coordinatorAcceptsSpecDecodeTelemetry: Bool
    ) throws {
        guard resolved.publishesSpecDecodeTelemetry else {
            return
        }
        guard coordinatorAcceptsSpecDecodeTelemetry else {
            FileHandle.standardError.write(Data((
                "spec_decode_heartbeat_incompatible: coordinator does not accept speculative decode heartbeat fields\n"
            ).utf8))
            throw ExitCode(2)
        }
    }

    static func runSpecDecodeCapacityPreflight(_ resolved: inout AppConfig) throws {
        guard resolved.draftModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        let defaultContext = ProviderCapacity.defaultContextTokensForCurrentHost()
        let requestedContext = resolved.maxContextOverride ?? defaultContext
        let draftCap = ProviderCapacity.draftContextCapForCurrentHost()
        let effectiveContext = min(requestedContext, draftCap)
        if let explicit = resolved.maxContextOverride, explicit > effectiveContext {
            FileHandle.standardError.write(Data("draft_model_capacity_shortfall: --max-context \(explicit) exceeds draft-enabled cap \(effectiveContext)\n".utf8))
            throw ExitCode(2)
        }
        if let explicit = resolved.maxConcurrencyOverride, explicit > 1 {
            FileHandle.standardError.write(Data("draft_model_capacity_shortfall: --max-batch \(explicit) exceeds draft-enabled cap 1\n".utf8))
            throw ExitCode(2)
        }
        resolved.maxContextOverride = effectiveContext
        resolved.maxConcurrencyOverride = 1
    }

    static func runDraftModelArtifactPreflight(
        _ resolved: AppConfig,
        joiningCoordinator: Bool = true
    ) throws -> String? {
        guard let draftModel = resolved.draftModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !draftModel.isEmpty else {
            return nil
        }
        guard let expected = resolved.draftModelArtifactSHA256 else {
            if joiningCoordinator || resolved.enableReceipts {
                FileHandle.standardError.write(Data("draft_model_unverified_artifact: coordinator or receipt-capable serve requires draft_model_artifact_sha256\n".utf8))
                throw ExitCode(2)
            }
            return draftModel
        }
        guard expected.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            FileHandle.standardError.write(Data("draft_model_artifact_sha256 must be 64 lowercase hex characters\n".utf8))
            throw ExitCode(2)
        }
        do {
            let directory = try ModelRuntime.localModelDirectory(for: draftModel)
            let actual = try ModelArtifactVerifier.canonicalArtifactHash(directory: directory)
            guard actual == expected else {
                FileHandle.standardError.write(Data("draft_model_unverified_artifact: draft model artifact hash mismatch for \(directory.path)\n".utf8))
                throw ExitCode(2)
            }
            return directory.standardizedFileURL.path
        } catch let exit as ExitCode {
            throw exit
        } catch {
            FileHandle.standardError.write(Data("draft_model_unverified_artifact: draft model artifact verification failed for \(draftModel): \(error)\n".utf8))
            throw ExitCode(2)
        }
    }

    static func runModelArtifactPreflight(
        _ resolved: AppConfig,
        joiningCoordinator: Bool = true,
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs(),
        artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver()
    ) async throws {
        guard let expected = resolved.modelArtifactSHA256 else {
            if resolved.modelArtifactPath != nil {
                FileHandle.standardError.write(Data("model_artifact_path requires model_artifact_sha256 for a verified local snapshot\n".utf8))
                throw ExitCode(2)
            }
            if resolved.donorMode {
                FileHandle.standardError.write(Data("donor_mode requires model_artifact_sha256 for a verified local snapshot\n".utf8))
                throw ExitCode(2)
            }
            if joiningCoordinator {
                FileHandle.standardError.write(Data("coordinator join requires model_artifact_sha256 from autotune --recommend --apply\n".utf8))
                throw ExitCode(2)
            }
            return
        }
        guard expected.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            FileHandle.standardError.write(Data("model_artifact_sha256 must be 64 lowercase hex characters\n".utf8))
            throw ExitCode(2)
        }
        let artifactPath = resolved.modelArtifactPath ?? ((resolved.donorMode || joiningCoordinator) ? nil : resolved.model)
        guard let artifactPath, artifactPath.hasPrefix("/") else {
            FileHandle.standardError.write(Data("model_artifact_sha256 requires model_artifact_path to be a verified local snapshot path\n".utf8))
            throw ExitCode(2)
        }
        let actual: String
        do {
            actual = try ModelArtifactVerifier.canonicalArtifactHash(directory: URL(fileURLWithPath: artifactPath))
            guard actual == expected else {
                FileHandle.standardError.write(Data("model artifact hash mismatch for \(artifactPath)\n".utf8))
                throw ExitCode(2)
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            FileHandle.standardError.write(Data("model artifact verification failed for \(artifactPath): \(error)\n".utf8))
            throw ExitCode(2)
        }
        if resolved.donorMode || joiningCoordinator {
            try await runModelCatalogPreflight(
                resolved,
                modelPath: artifactPath,
                actualArtifactSHA256: actual,
                requireRecommendable: !resolved.donorMode,
                staticInputs: staticInputs,
                artifactResolver: artifactResolver
            )
        }
    }

    private static func runModelCatalogPreflight(
        _ resolved: AppConfig,
        modelPath: String,
        actualArtifactSHA256: String,
        requireRecommendable: Bool,
        staticInputs: AutotuneStaticInputs,
        artifactResolver: CachedModelArtifactResolver
    ) async throws {
        guard let key = resolved.modelCatalogKey,
              let modelID = resolved.modelCatalogModelID,
              let revision = resolved.modelCatalogRevision,
              let catalogSHA256 = resolved.modelCatalogSHA256,
              let version = resolved.modelCatalogVersion,
              let storedCatalogHash = resolved.modelCatalogHash,
              !key.isEmpty,
              !modelID.isEmpty,
              !revision.isEmpty,
              !catalogSHA256.isEmpty,
              !version.isEmpty,
              !storedCatalogHash.isEmpty
        else {
            FileHandle.standardError.write(Data("model_artifact_sha256 requires model_catalog_* provenance from autotune --recommend --apply\n".utf8))
            throw ExitCode(2)
        }

        let expectedPublicModel: String
        if requireRecommendable {
            let rateCard = await staticInputs.loadRateCard()
            guard let match = rateCard.value.rowForRecommendation(modelKey: key) else {
                FileHandle.standardError.write(Data("model artifact is not admitted by the signed rate card\n".utf8))
                throw ExitCode(2)
            }
            // v1.7.6 Track A1: when the rate-card row resolves via the
            // "default" fallthrough, the pricing key is `"default"` but
            // the served-model identity remains the catalog key — matches
            // AutotuneRecommend's servedModel split. Without this mirror,
            // paid serve preflight would reject any default-tier install.
            if match.key == "default", key != "default" {
                expectedPublicModel = key
            } else {
                expectedPublicModel = match.key
            }
        } else {
            expectedPublicModel = key
        }
        guard resolved.model == expectedPublicModel else {
            FileHandle.standardError.write(Data("model must match model_catalog_key/rate-card key from autotune --recommend --apply\n".utf8))
            throw ExitCode(2)
        }

        let expectedSnapshot = artifactResolver
            .snapshotURL(modelID: modelID, revision: revision)
            .standardizedFileURL
            .path
        let configuredSnapshot = URL(fileURLWithPath: modelPath).standardizedFileURL.path
        guard configuredSnapshot == expectedSnapshot else {
            FileHandle.standardError.write(Data("model must be the catalog-pinned Hugging Face snapshot path\n".utf8))
            throw ExitCode(2)
        }

        let catalog = await staticInputs.loadCandidateCatalog()
        let actualCatalogHash = AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalog.selectedBytes)
        guard catalog.value.version == version, actualCatalogHash == storedCatalogHash else {
            FileHandle.standardError.write(Data("model catalog provenance is stale; rerun autotune --recommend --apply\n".utf8))
            throw ExitCode(2)
        }
        guard let row = catalog.value.rows[key],
              (requireRecommendable ? row.runtimeStatus == "recommendable" : ["candidate", "listed", "recommendable"].contains(row.runtimeStatus)),
              row.modelID == modelID,
              row.modelRevision == revision,
              row.modelSHA256 == catalogSHA256,
              catalogSHA256 == actualArtifactSHA256
        else {
            FileHandle.standardError.write(Data("model artifact is not admitted by the signed candidate catalog\n".utf8))
            throw ExitCode(2)
        }
    }

    static func makeCoordinatorClient(
        noJoin: Bool,
        donorMode: Bool = false,
        factory: () -> CoordinatorClient?
    ) -> CoordinatorClient? {
        guard !noJoin else { return nil }
        guard !donorMode else { return nil }
        return factory()
    }

    func run() async throws {
        var resolved = try ConfigLoader.load(
            cli: CLIOverrides(
                port: port,
                model: model,
                draftModel: draftModel,
                draftModelArtifactSHA256: draftModelArtifactSha256,
                numDraftTokens: numDraftTokens,
                publishesSpecDecodeTelemetry: publishSpecDecodeTelemetry,
                coordinatorURL: coordinator,
                providerID: providerID,
                endpointURL: endpointURL,
                configPath: config,
                logLevel: logLevel,
                supportedModels: SupportedModels.parseCSV(supportedModels),
                publishesSupportedModels: publishSupportedModels,
                enableWarmSwap: enableWarmSwap,
                enableReceipts: enableReceipts,
                swapDrainTimeoutSeconds: swapDrainTimeoutSeconds,
                ctlSocketPath: ctlSocketPath,
                switchStatePath: switchStatePath,
                providerToken: providerToken,
                providerTokenFile: tokenFile,
                managedBy: managedBy,
                kvBits: kvBits,
                maxContext: maxContext,
                maxBatch: maxBatch,
                idlePrewarmEnabled: idlePrewarm,
                idlePrewarmIdleThresholdSeconds: idlePrewarmIdleThresholdSeconds,
                idlePrewarmTickSeconds: idlePrewarmTickSeconds,
                idlePrewarmMaxTokens: idlePrewarmMaxTokens,
                idlePrewarmPrompt: idlePrewarmPrompt,
                idlePrewarmRunOnBattery: idlePrewarmRunOnBattery
            )
        )

        // AUDIT R1 SECURITY S2 fix (PR #334): drop MACPROVIDER_PROVIDER_TOKEN
        // from the process env immediately after we've resolved it. Under
        // Malibu.app the token arrives via env (see SPEC-025 §7 followup:
        // eventually via Keychain read here). Same-user malware inspecting
        // `ps -E <cli-pid>` would otherwise see a payout-bearing bearer token
        // for the lifetime of the process. Config resolution has already
        // captured it into `resolved.providerToken`; the env slot is unused
        // downstream.
        unsetenv("MACPROVIDER_PROVIDER_TOKEN")

        try Self.runSupportedModelsPreflight(&resolved)
        try Self.runDrainTimeoutPreflight(resolved)
        try Self.runServingKnobsPreflight(resolved)
        try Self.runSpecDecodeHeartbeatCompatibilityPreflight(
            resolved,
            coordinatorAcceptsSpecDecodeTelemetry: Self.bundledCoordinatorAcceptsSpecDecodeTelemetry
        )
        try Self.runSpecDecodeCapacityPreflight(&resolved)
        try await Self.runModelArtifactPreflight(resolved, joiningCoordinator: !noJoin)
        let verifiedDraftModelLoadPath = try Self.runDraftModelArtifactPreflight(resolved, joiningCoordinator: !noJoin)

        printResolvedConfiguration(resolved)

        let modelRuntime = try await ModelRuntime(
            modelID: resolved.model,
            modelLoadPath: resolved.modelArtifactPath,
            draftModelID: resolved.draftModel,
            draftModelLoadPath: verifiedDraftModelLoadPath,
            numDraftTokens: resolved.numDraftTokens,
            maxContextTokensOverride: resolved.maxContextOverride,
            kvBitsOverride: resolved.kvBitsOverride,
            maxBatch: resolved.maxConcurrencyOverride ?? 1,
            warmSwapEnabled: resolved.enableWarmSwap,
            swapDrainTimeoutSeconds: resolved.swapDrainTimeoutSeconds
        )
        // The serve runtime defaults `--max-batch` to 1 (the prior
        // single-slot behavior). Operators opting in via --max-batch >1
        // own the safety check; we surface the configured value in
        // capacity so the coordinator's view stays consistent.
        let capacityDefaults = ProviderCapacity(
            maxContextOverride: resolved.maxContextOverride,
            maxConcurrencyOverride: resolved.maxConcurrencyOverride ?? 1
        )
        let throughputEstimate = await modelRuntime.measureStartupThroughput()
        let thermalGate = ThermalGate()
        // `slots_free` in the log reflects the throttle-driven free-slot
        // ceiling (configured `maxConcurrency` when unthrottled, 0 when
        // throttled). The exact heartbeat value still subtracts in-flight
        // requests; this log marker is for transition forensics.
        let configuredSlots = capacityDefaults.maxConcurrency
        await thermalGate.setTransitionLogger { old, new in
            let throttled = ThermalGate.shouldThrottle(new)
            let slots = throttled ? 0 : configuredSlots
            print("event=thermal_state_changed from=\(old.label) to=\(new.label) throttled=\(throttled) slots_free=\(slots)")
        }
        await thermalGate.startObserving()
        let providerStatus = ProviderStatus(
            modelID: resolved.model,
            modelLoaded: await modelRuntime.isLoaded,
            capacity: capacityDefaults.withThroughputEstimate(throughputEstimate),
            modelHash: await modelRuntime.loadedModelHash,
            thermalGate: thermalGate,
            specDecodeDraftModelID: resolved.draftModel,
            specDecodeNumDraftTokens: resolved.numDraftTokens
        )
        await modelRuntime.setProviderStatus(providerStatus)
        let idlePrewarmer = IdlePrewarmer(
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            thermalGate: thermalGate,
            powerSource: SystemPowerSourceReporter(),
            config: IdlePrewarmConfig(appConfig: resolved)
        )
        let receiptKeyStore = KeychainReceiptKeyStore()
        let receiptRuntime = try Self.makeReceiptRuntime(config: resolved, keyStore: receiptKeyStore)
        if resolved.donorMode {
            FileHandle.standardError.write(Data("DONOR MODE: coordinator join disabled; serving local HTTP only.\n".utf8))
        }
        // SPEC-026 §7: shared bridge for the App-track identity-signature
        // handshake. CoordinatorClient enqueues signature requests here
        // when building the auth_request proof stage; ControlSocketServer
        // drains them onto the connected Malibu.app control socket.
        let identityBridge = IdentitySignatureBridge()
        let coordinatorClient = Self.makeCoordinatorClient(noJoin: noJoin, donorMode: resolved.donorMode) {
            CoordinatorClient(
                config: resolved,
                modelRuntime: modelRuntime,
                providerStatus: providerStatus,
                attestationGenerator: ManagedDeviceAttestationGenerator(artifactPath: resolved.tier2MDAArtifactPath),
                providerReceiptPublicKey: receiptRuntime.publicKeyBase64,
                receiptBuilder: receiptRuntime.builder,
                identityBridge: identityBridge
            )
        }
        let controlSocket: ControlSocketServer?
        let receiptRotator: (@Sendable () async throws -> Void)?
        if resolved.enableReceipts,
           let providerID = resolved.providerID,
           !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let coordinatorClient {
            receiptRotator = {
                try await RotateKeyCommand.rotateActiveProvider(
                    providerID: providerID,
                    keyStore: receiptKeyStore,
                    coordinatorClient: coordinatorClient
                )
            }
        } else {
            receiptRotator = nil
        }
        if resolved.enableWarmSwap || receiptRotator != nil {
            let socketURL = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
            controlSocket = ControlSocketServer(
                socketPath: socketURL,
                modelRuntime: modelRuntime,
                supportedModels: resolved.supportedModels,
                receiptRotator: receiptRotator,
                receiptRotationProviderID: resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                identityBridge: identityBridge
            )
            do {
                try await controlSocket?.start()
            } catch {
                if let serverError = error as? ControlSocketServerError,
                   serverError != .staleSocket(path: socketURL.path) {
                    FileHandle.standardError.write(Data(("\(serverError.description)\n").utf8))
                }
                throw ExitCode(1)
            }
        } else {
            controlSocket = nil
        }
        await coordinatorClient?.start()
        await idlePrewarmer.start()
        let server = HTTPServer(
            config: resolved,
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            receiptBuilder: receiptRuntime.builder,
            idlePrewarmer: idlePrewarmer
        )
        let terminationHandlers = installTerminationHandlers(coordinatorClient: coordinatorClient, controlSocket: controlSocket, idlePrewarmer: idlePrewarmer)
        defer {
            Task {
                await idlePrewarmer.stop()
                await controlSocket?.stop()
                await coordinatorClient?.stop()
            }
            terminationHandlers.forEach { $0.cancel() }
        }
        try withExtendedLifetime(terminationHandlers) {
            try server.run()
        }
    }

    static func makeReceiptBuilder(
        config: AppConfig,
        keyStore: ReceiptKeyStoring = KeychainReceiptKeyStore()
    ) throws -> ReceiptBuilder? {
        try makeReceiptRuntime(config: config, keyStore: keyStore).builder
    }

    static func makeReceiptRuntime(
        config: AppConfig,
        keyStore: ReceiptKeyStoring = KeychainReceiptKeyStore()
    ) throws -> (builder: ReceiptBuilder?, publicKeyBase64: String?) {
        guard config.enableReceipts,
              let providerID = config.providerID,
              !providerID.isEmpty else {
            return (nil, nil)
        }
        let cachingStore = CachedReceiptKeyStore(keyStore)
        let privateKey = try cachingStore.loadOrGenerate(providerId: providerID)
        return (
            ReceiptBuilder(keyStore: cachingStore),
            Data(privateKey.publicKey.rawRepresentation).base64EncodedString()
        )
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show local provider status."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Local HTTP port to query. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    func run() async throws {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(port: port, configPath: config)
        )
        let status = try await LocalStatusClient.fetch(port: resolved.port)
        let latest = try? await SelfUpdate(currentVersion: CoordinatorClient.binaryVersion, releasesAPIURL: nil).latestVersionCached()
        let staleSince = await Self.staleRecommendationSince(providerID: resolved.providerID)
        print(LocalStatusFormatter.format(status, latestVersion: latest, ownerLogin: OwnerFileReader.githubLogin(configPath: resolved.configPath), donorMode: resolved.donorMode, staleRecommendationSince: staleSince))
    }

    static func staleRecommendationSince(
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs(),
        fingerprint: MachineFingerprint = MachineFingerprinter().sample(),
        providerID: String? = nil,
        hmacSecretURL: URL = AutotuneHMACSecretStore.defaultPath,
        stateURL: URL = RecommendationStateStore.defaultURL,
        now: Date = Date()
    ) async -> Date? {
        await RecommendationFreshnessChecker(
            staticInputs: staticInputs,
            fingerprint: fingerprint,
            providerID: providerID,
            hmacSecretURL: hmacSecretURL,
            stateURL: stateURL,
            now: now
        ).staleRecommendationSince()
    }
}

struct SelfTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-test",
        abstract: "Load the configured model and run a startup inference smoke test."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    static func modelLoadPath(for resolved: AppConfig) -> String? {
        resolved.modelArtifactPath
    }

    func run() async throws {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(model: model, configPath: config)
        )
        try await ServeCommand.runModelArtifactPreflight(resolved, joiningCoordinator: false)
        let runtime = try await ModelRuntime(
            modelID: resolved.model,
            modelLoadPath: Self.modelLoadPath(for: resolved),
            maxContextTokensOverride: resolved.maxContextOverride
        )
        guard await runtime.isLoaded else {
            throw ValidationError("Model not loaded")
        }
        let throughput = await runtime.measureStartupThroughput(maxTokens: 4)
        guard throughput > 0 else {
            throw ValidationError("Startup inference self-test produced no tokens")
        }
        print("self-test passed: throughput_tps=\(throughput)")
    }
}

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for or install the latest macprovider-cli release."
    )

    @Flag(help: "Check for updates without downloading or replacing the binary.")
    var check = false

    @Option(help: "GitHub latest-release API URL. Defaults to the public macprovider release repository.")
    var releasesAPIURL: String?

    func run() async throws {
        try await SelfUpdate(
            currentVersion: CoordinatorClient.binaryVersion,
            releasesAPIURL: releasesAPIURL
        ).run(checkOnly: check)
        let resolvedConfig = try? ConfigLoader.load(cli: CLIOverrides())
        if let staleSince = await RecommendationFreshnessChecker(providerID: resolvedConfig?.providerID).staleRecommendationSince() {
            FileHandle.standardError.write(Data("""

            Recommendation stale: recommendation inputs changed since \(ISO8601DateFormatter.autotuneInternet.string(from: staleSince)).
            Run: macprovider-cli autotune --recommend

            """.utf8))
        }
    }
}

private func installTerminationHandlers(
    coordinatorClient: CoordinatorClient?,
    controlSocket: ControlSocketServer?,
    idlePrewarmer: IdlePrewarmer?
) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            Task {
                await idlePrewarmer?.stop()
                await controlSocket?.stop()
                await coordinatorClient?.drainAndExit(reason: "\(signalName(signalNumber)) received")
                Darwin.exit(0)
            }
        }
        source.resume()
        return source
    }
}

private func signalName(_ signalNumber: Int32) -> String {
    switch signalNumber {
    case SIGTERM:
        return "SIGTERM"
    case SIGINT:
        return "SIGINT"
    default:
        return "signal \(signalNumber)"
    }
}

private func printResolvedConfiguration(_ config: AppConfig) {
    print("macprovider-cli config")
    print("  port: \(config.port)")
    print("  model: \(config.model ?? "<unset>")")
    print("  draft_model: \(config.draftModel ?? "<unset>")")
    print("  num_draft_tokens: \(config.numDraftTokens)")
    print("  publishes_spec_decode_telemetry: \(config.publishesSpecDecodeTelemetry)")
    print("  coordinator_url: \(config.coordinatorURL ?? "<unset>")")
    print("  provider_id: \(config.providerID ?? "<unset, will use per-instance UUID>")")
    print("  endpoint_url: \(config.endpointURL ?? "<unset, WS-tunneled>")")
    print("  config: \(config.configPath)")
    print("  log_level: \(config.logLevel.rawValue)")
    print("  log_format: \(config.logFormat.rawValue)")
    print("  tier2_mda_artifact_path: \(config.tier2MDAArtifactPath ?? "<unset>")")
    print("  kv_bits: \(config.kvBitsOverride.map(String.init) ?? "<unset, mlx default>")")
    print("  max_context: \(config.maxContextOverride.map(String.init) ?? "<unset, per-tier default>")")
    print("  max_batch: \(config.maxConcurrencyOverride.map(String.init) ?? "1")")
    print("  enable_receipts: \(config.enableReceipts)")
    print("  idle_prewarm.enabled: \(config.idlePrewarmEnabled)")
    print("  idle_prewarm.idle_threshold_seconds: \(config.idlePrewarmIdleThresholdSeconds)")
    print("  idle_prewarm.tick_seconds: \(config.idlePrewarmTickSeconds)")
    print("  idle_prewarm.max_tokens: \(config.idlePrewarmMaxTokens)")
    print("  idle_prewarm.prompt: \(config.idlePrewarmPrompt)")
    print("  idle_prewarm.run_on_battery: \(config.idlePrewarmRunOnBattery)")
}
