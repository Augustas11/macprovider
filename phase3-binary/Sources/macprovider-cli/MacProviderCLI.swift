import ArgumentParser
import CryptoKit
import Darwin
import Dispatch
import Foundation
import MacProviderCore

enum AdmissionIdentityStartupTopology: Equatable {
    case currentOnly
    case duplicatePending
    case rotationPending
    case recoveryPending
    case recoveryCommittedCleanup
    case invalidRecoveryMarker

    static func resolve(
        currentPublicKey: Data,
        pendingPublicKey: Data?,
        recoveryMarkerPublicKey: Data?
    ) -> Self {
        guard let pendingPublicKey else {
            guard let recoveryMarkerPublicKey else { return .currentOnly }
            return recoveryMarkerPublicKey == currentPublicKey
                ? .recoveryCommittedCleanup
                : .invalidRecoveryMarker
        }
        if let recoveryMarkerPublicKey {
            guard recoveryMarkerPublicKey == pendingPublicKey else {
                return .invalidRecoveryMarker
            }
            return .recoveryPending
        }
        return pendingPublicKey == currentPublicKey ? .duplicatePending : .rotationPending
    }
}

@main
struct MacProviderCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macprovider-cli",
        abstract: "OpenAI-compatible Mac Provider inference CLI.",
        version: CoordinatorClient.binaryVersion,
        subcommands: [ServeCommand.self, SelfTestCommand.self, StatusCommand.self, ClaimCommand.self, UpdateCommand.self, UninstallCommand.self, ModelsCommand.self, AutotuneCommand.self, BootstrapAuthCommand.self, RotateKeyCommand.self, CredentialsCommand.self, LifecycleStateCommand.self, LifecycleLeaseCommand.self, Spec028CanaryCommand.self, Spec028BenchmarkCommand.self, LegacySpec028CanaryCommand.self, LegacySpec028BenchmarkCommand.self, DecodeBenchCommand.self, EnrollCommand.self, ReleasePayloadPreflightCommand.self],
        defaultSubcommand: ServeCommand.self
    )
}

struct LifecycleStateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lifecycle-state",
        abstract: "Read or transition the CLI-owned persisted provider lifecycle state.",
        shouldDisplay: false,
        subcommands: [LifecycleStateStatusCommand.self, LifecycleStateTransitionCommand.self]
    )
}

struct LifecycleStateStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Read the exact persisted lifecycle transition without changing it."
    )

    @Option(help: "Require the current transition ID to match exactly.")
    var expectedTransitionID: String?

    func run() throws {
        switch ProviderLifecycleStateStore().inspect() {
        case .missing:
            try Self.writeJSON(["version": ProviderLifecycleStateRecord.schemaVersion, "state": "missing"])
        case .invalid(let reason):
            try Self.writeJSON([
                "version": ProviderLifecycleStateRecord.schemaVersion,
                "state": "invalid",
                "invalid_reason": reason,
            ])
            throw ExitCode.failure
        case .valid(let record):
            guard expectedTransitionID == nil || expectedTransitionID == record.transitionID else {
                throw ExitCode.failure
            }
            var payload = try Self.jsonObject(record)
            payload["record_state"] = "valid"
            try Self.writeJSON(payload)
        }
    }

    static func jsonObject(_ record: ProviderLifecycleStateRecord) throws -> [String: Any] {
        let data = try JSONEncoder().encode(record)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderLifecycleStateError.invalidRecord("json_encoding_failed")
        }
        return object
    }

    static func writeJSON(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}

struct LifecycleStateTransitionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transition",
        abstract: "Persist one validated lifecycle transition as the signed CLI authority."
    )

    @Option(help: "Lifecycle state to persist.")
    var state: ProviderLifecycleState

    @Option(help: "Stable machine-readable reason code.")
    var reasonCode: String

    @Option(help: "Component asking the signed CLI to author this transition.")
    var writer: ProviderLifecycleWriter

    @Option var providerID: String?
    @Option var modelID: String?
    @Option var compatibilitySetID: String?
    @Option var operationID: String?

    func run() throws {
        let record = try ProviderLifecycleStateStore().transition(
            to: state,
            reasonCode: reasonCode,
            writer: writer,
            providerID: providerID,
            modelID: modelID,
            compatibilitySetID: compatibilitySetID,
            operationID: operationID
        )

        try LifecycleStateStatusCommand.writeJSON(LifecycleStateStatusCommand.jsonObject(record))
    }
}

struct LifecycleLeaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lifecycle-lease",
        abstract: "Inspect the CLI-owned provider lifecycle lease.",
        shouldDisplay: false,
        subcommands: [LifecycleLeaseStatusCommand.self]
    )
}

struct LifecycleLeaseStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Validate the bounded startup or maintenance lease without changing it."
    )

    @Option(help: "Require the valid lease to belong to this exact process ID.")
    var expectedPID: Int32?

    @Option(help: "Require the valid lease kind to be startup or maintenance.")
    var expectedKind: ProviderLifecycleLeaseKind?

    func run() throws {
        guard case .valid(let record) = ProviderLifecycleLeaseStore().inspect(),
              expectedPID == nil || record.owner.pid == expectedPID,
              expectedKind == nil || record.kind == expectedKind
        else {
            throw ExitCode.failure
        }
        let payload: [String: Any] = [
            "version": ProviderLifecycleLeaseRecord.schemaVersion,
            "state": "valid",
            "kind": record.kind.rawValue,
            "operation_id": record.operationID,
            "owner_pid": Int(record.owner.pid),
            "expires_wall_ms": record.expiresWallMilliseconds,
        ]
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}

struct ServeCatalogPreflightError: Error {
    let underlying: Error
}

enum SelfUpdateStartupFenceError: Error, Equatable, CustomStringConvertible {
    case authorizationMismatch(String)

    var description: String {
        switch self {
        case .authorizationMismatch(let reason):
            return "self-update startup reload fence authorization mismatch: \(reason)"
        }
    }
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

    @Flag(name: .customLong("publish-spec-decode-telemetry"), inversion: .prefixedNo, help: "Opt into publishing speculative-decoding performance telemetry after provider software is verified. Default off.")
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

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths) this provider can serve. Overrides MACPROVIDER_SUPPORTED_MODELS and config key supported_models. When unset, only the configured model is advertised.")
    var supportedModels: String?

    @Flag(name: .customLong("publish-supported-models"), inversion: .prefixedNo, help: "Opt into publishing the supported model list to the network status service. Default off.")
    var publishSupportedModels: Bool?

    @Flag(name: .customLong("enable-warm-swap"), inversion: .prefixedNo, help: "Opt into switching models without a full provider restart. Default off. When off, no model-control socket is opened.")
    var enableWarmSwap: Bool?

    @Flag(name: .customLong("enable-receipts"), inversion: .prefixedNo, help: "Opt into signed non-streaming request receipts. Default off for staged rollout.")
    var enableReceipts: Bool?

    @Option(help: "Drain timeout in seconds for an in-flight model switch. Default 30. Only meaningful when --enable-warm-swap is set.")
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

    @Option(help: "Records the installation origin for diagnostics. This never transfers lifecycle, credential, identity, or update authority away from the launchd-managed CLI. Overrides MACPROVIDER_MANAGED_BY and config key managed_by.")
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

    @Option(help: "Number of content-token deltas to accumulate before emitting one SSE/WS frame. Default 1 (one frame per token, current behaviour). Set to 4 to match upstream production batching — reduces WS send calls by ~75% with first-chunk latency ≤ N token periods. Overrides MACPROVIDER_STREAM_INTERVAL and config key stream_interval.")
    var streamInterval: Int?

    @Option(
        name: .customLong("prefill-step-size"),
        help: "Chunked prefill window (mlx-swift GenerateParameters.prefillStepSize). Default 512. Larger values (e.g. 2048, 4096) reduce TTFT on long cold prefills. Overrides MACPROVIDER_PREFILL_STEP_SIZE and config key prefill_step_size."
    )
    var prefillStepSize: Int?

    @Flag(help: "Run only the local HTTP server; do not establish a coordinator WebSocket session.")
    var noJoin = false

    // Internal marker for CandidateProviderRunner. Stage 1 owns warmup and
    // throughput measurement for these non-joining subprocesses.
    @Flag(name: .customLong("autotune-candidate"), help: .private)
    var autotuneCandidate = false

    mutating func validate() throws {
        guard !autotuneCandidate || noJoin else {
            throw ValidationError("--autotune-candidate requires --no-join")
        }
    }

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
        if resolved.streamInterval < 1 {
            FileHandle.standardError.write(Data((
                "--stream-interval \(resolved.streamInterval) must be >= 1\n"
            ).utf8))
            throw ExitCode(2)
        }
        if resolved.prefillStepSize < 1 {
            FileHandle.standardError.write(Data((
                "--prefill-step-size \(resolved.prefillStepSize) must be >= 1\n"
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

    struct CatalogRuntimeTrust: Sendable {
        let state: String
        let releaseID: String
        let digest: String
        let signerKeyID: String?
        let source: String
        let policyVersion: String?
        let rowIdentity: String?
        let modelSHA256: String?

        init(
            state: String,
            releaseID: String,
            digest: String,
            signerKeyID: String?,
            source: String,
            policyVersion: String? = nil,
            rowIdentity: String? = nil,
            modelSHA256: String? = nil
        ) {
            self.state = state
            self.releaseID = releaseID
            self.digest = digest
            self.signerKeyID = signerKeyID
            self.source = source
            self.policyVersion = policyVersion
            self.rowIdentity = rowIdentity
            self.modelSHA256 = modelSHA256
        }
    }

    static func runModelArtifactPreflight(
        _ resolved: AppConfig,
        joiningCoordinator: Bool = true,
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs(),
        artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver()
    ) async throws -> CatalogRuntimeTrust? {
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
            return nil
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
            return try await runModelCatalogPreflight(
                resolved,
                modelPath: artifactPath,
                actualArtifactSHA256: actual,
                requireRecommendable: !resolved.donorMode,
                staticInputs: staticInputs,
                artifactResolver: artifactResolver
            )
        }
        return nil
    }

    private static func runModelCatalogPreflight(
        _ resolved: AppConfig,
        modelPath: String,
        actualArtifactSHA256: String,
        requireRecommendable: Bool,
        staticInputs: AutotuneStaticInputs,
        artifactResolver: CachedModelArtifactResolver
    ) async throws -> CatalogRuntimeTrust {
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
            expectedPublicModel = rateCard.value.servedModelKey(modelKey: key, rateCardKey: match.key)
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
        let trustBlockingWarnings: Set<AutotuneRecommendWarning> = [
            .candidateCatalogIntegrityFailure,
            .candidateCatalogUpdateRequired,
        ]
        if requireRecommendable && !trustBlockingWarnings.isDisjoint(with: catalog.warnings) {
            let state = catalog.warnings.contains(.candidateCatalogIntegrityFailure)
                ? "catalog_integrity_failure"
                : "catalog_update_required"
            FileHandle.standardError.write(Data("\(state): refusing coordinator join with an untrusted or incompatible catalog release\n".utf8))
            throw ExitCode(2)
        }
        // Row admission against the *current* signed catalog is the security gate.
        // The stored model_catalog_version/hash envelope records which autotune --apply
        // revision wrote config.yaml; a coordinator catalog publish that only adds or
        // edits unrelated rows must not crash-loop providers whose model row is unchanged.
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
        if catalog.value.version != version || actualCatalogHash != storedCatalogHash {
            let storedPrefix = String(storedCatalogHash.prefix(8))
            let currentPrefix = String(actualCatalogHash.prefix(8))
            FileHandle.standardError.write(Data(
                ("model catalog provenance envelope is stale (stored \(version)/\(storedPrefix)…, "
                    + "current \(catalog.value.version)/\(currentPrefix)…); "
                    + "row still admitted — run macprovider-cli autotune --recommend --apply to refresh config\n")
                .utf8
            ))
        }
        let state: String
        if catalog.warnings.contains(.candidateCatalogIntegrityFailure) {
            state = "catalog_integrity_failure"
        } else if catalog.warnings.contains(.candidateCatalogUpdateRequired) {
            state = "catalog_update_required"
        } else if catalog.usedFallback {
            state = "safe_offline_fallback"
        } else {
            state = "live_verified"
        }
        return CatalogRuntimeTrust(
            state: state,
            releaseID: catalog.value.version,
            digest: actualCatalogHash,
            signerKeyID: catalog.signerKeyID,
            source: catalog.usedFallback ? "baked" : "coordinator",
            policyVersion: catalog.value.policyVersion,
            rowIdentity: catalog.value.rowIdentity(for: key),
            modelSHA256: row.modelSHA256
        )
    }

    static func makeCoordinatorClient(
        noJoin: Bool,
        donorMode: Bool = false,
        catalogTrustState: String? = nil,
        factory: () -> CoordinatorClient?
    ) -> CoordinatorClient? {
        guard !noJoin else { return nil }
        guard !donorMode else { return nil }
        guard catalogTrustState != "catalog_integrity_failure",
              catalogTrustState != "catalog_update_required" else { return nil }
        return factory()
    }

    static func startupThroughputEstimate(
        autotuneCandidate: Bool,
        measure: () async -> Double
    ) async -> Double {
        guard !autotuneCandidate else { return 0 }
        return await measure()
    }

    /// Route the serve command's lifecycle store by mode. Autotune candidates
    /// persist to the candidate-scoped store so they never overwrite the
    /// incumbent's Malibu-visible `state-v1.json` (ARCHITECT finding); the
    /// incumbent (non-candidate) path is unchanged. Pure and side-effect free so
    /// it can be unit-tested with an injected home directory.
    static func lifecycleStateStore(
        autotuneCandidate: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProviderLifecycleStateStore {
        let url = autotuneCandidate
            ? ProviderLifecycleStateStore.candidateURL(homeDirectory: homeDirectory)
            : ProviderLifecycleStateStore.defaultURL(homeDirectory: homeDirectory)
        return ProviderLifecycleStateStore(url: url)
    }

    func run() async throws {
        // v1.8.53 can leave its one-shot reload helper alive long enough to
        // restart the newly installed target repeatedly. The target fences that
        // helper before configuration/model work, but only while two durable
        // authorities agree that this exact executable is the intended
        // self-update child. Ordinary launches never touch reload jobs.
        let startupReloadFenceAuthorized =
            try Self.fenceAuthorizedSelfUpdateReloadJobsAtStartup()

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
                idlePrewarmRunOnBattery: idlePrewarmRunOnBattery,
                streamInterval: streamInterval,
                prefillStepSize: prefillStepSize
            )
        )

        // Reject invalid invocation-only model catalogs before startup writes
        // lifecycle state or touches credential custody. The complete startup
        // preflight bundle repeats this idempotent check after acquiring its
        // dependencies so direct callers retain the same validation contract.
        try Self.runSupportedModelsPreflight(&resolved)

        // Autotune candidates (`--autotune-candidate`, always with `--no-join`)
        // share the incumbent's lifecycle directory but persist to a distinct
        // candidate-scoped store so a successful candidate reaching
        // `degraded_serving` never overwrites the installed incumbent's
        // Malibu-visible `state-v1.json` (ARCHITECT finding). The transition
        // graph is still enforced against the candidate's own history; only the
        // persistence file changes. Incumbent serve is untouched: same path,
        // schema, and fields.
        let lifecycleStateStore = Self.lifecycleStateStore(autotuneCandidate: autotuneCandidate)
        let lifecycleLeaseStore = ProviderLifecycleLeaseStore()
        let existingLifecycle: ProviderLifecycleStateRecord?
        let operatorPausedInitially: Bool
        if case .valid(let record) = lifecycleStateStore.inspect() {
            existingLifecycle = record
            operatorPausedInitially = record.operatorPauseRequested
        } else {
            existingLifecycle = nil
            operatorPausedInitially = false
        }
        // A compatibility-set updater can durably hand its maintenance lease to
        // one exact launchd child. Carry that operation ID through the full
        // startup transition chain; ordinary starts get a fresh serve ID.
        let startupHandoffOperationID = Self.startupHandoffOperationID(in: lifecycleLeaseStore)
        let lifecycleOperationID = startupHandoffOperationID
            ?? "serve:\(UUID().uuidString.lowercased())"
        let startupReason: String
        if startupHandoffOperationID != nil {
            startupReason = "maintenance_handoff_restart"
        } else if existingLifecycle?.writer == .watchdog {
            startupReason = "watchdog_recovery_restart"
        } else {
            startupReason = "launchd_service_started"
        }
        _ = try lifecycleStateStore.transition(
            to: .startingProvider,
            reasonCode: startupReason,
            writer: .serve,
            providerID: resolved.providerID,
            modelID: resolved.model,
            operationID: lifecycleOperationID
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

        let credentialStore = KeychainProviderCredentialStore()
        _ = try lifecycleStateStore.transition(
            to: .importingCredentials,
            reasonCode: "resolving_cli_keychain_custody",
            writer: .serve,
            providerID: resolved.providerID,
            modelID: resolved.model,
            operationID: lifecycleOperationID
        )
        let credentialStatus = try ProviderCredentialResolver.resolve(
            config: &resolved,
            store: credentialStore
        )
        switch credentialStatus.state {
        case .locked, .notLoggedIn, .permissionDenied, .keychainFailure, .incompatible, .unavailable:
            _ = try lifecycleStateStore.transition(
                to: .keychainUnavailable,
                reasonCode: "credential_\(credentialStatus.state.rawValue)",
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
        case .missing, .unconfigured:
            _ = try lifecycleStateStore.transition(
                to: .authenticationRequired,
                reasonCode: "credential_\(credentialStatus.state.rawValue)",
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
        case .conflict, .corrupt:
            _ = try lifecycleStateStore.transition(
                to: .identityMigrationRequired,
                reasonCode: "credential_\(credentialStatus.state.rawValue)",
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
        case .ready, .degraded:
            break
        }
        try Self.validateCoordinatorCredential(
            config: resolved,
            credentialStatus: credentialStatus,
            noJoin: noJoin
        )
        let credentialStatusRuntime = ProviderCredentialStatusRuntime(credentialStatus)

        _ = try lifecycleStateStore.transition(
            to: .validatingCatalog,
            reasonCode: "startup_preflight",
            writer: .serve,
            providerID: resolved.providerID,
            modelID: resolved.model,
            operationID: lifecycleOperationID
        )
        let startupPreflight: Self.ServeStartupPreflightResult
        let startupProviderID = resolved.providerID
        var acquiredStartupLease: ProviderLifecycleLeaseRecord?
        do {
            startupPreflight = try await Self.runServeStartupPreflights(
                &resolved,
                joiningCoordinator: !noJoin,
                afterServeLockAcquired: {
                    acquiredStartupLease = try Self.acquireStartupLifecycleLease(
                        store: lifecycleLeaseStore,
                        operationID: lifecycleOperationID,
                        providerID: startupProviderID,
                        duration: 30 * 60,
                        allowAdoptedHandoffRecovery: startupReloadFenceAuthorized
                    )
                }
            )
        } catch {
            let lifecycleState: ProviderLifecycleState
            let lifecycleReason: String
            if error is ProviderLifecycleLeaseError {
                lifecycleState = .failed
                lifecycleReason = "startup_lease_unavailable"
            } else if error is ServeCatalogPreflightError {
                lifecycleState = .catalogIncompatible
                lifecycleReason = "startup_catalog_incompatible"
            } else {
                lifecycleState = .failed
                lifecycleReason = "startup_preflight_failed"
            }
            _ = try? lifecycleStateStore.transition(
                to: lifecycleState,
                reasonCode: lifecycleReason,
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
            if error is ProviderLifecycleLeaseError {
                FileHandle.standardError.write(Data("provider startup lease unavailable: \(error)\n".utf8))
            }
            if let catalogError = error as? ServeCatalogPreflightError {
                throw catalogError.underlying
            }
            throw error
        }
        let serveLock = startupPreflight.serveLock
        defer { serveLock.release() }
        guard let startupLease = acquiredStartupLease else {
            throw ProviderLifecycleLeaseError.currentOwnerUnavailable
        }
        defer {
            _ = try? Self.clearStartupLifecycleLeaseUnlessUpdatePending(
                startupLease,
                store: lifecycleLeaseStore
            )
        }
        let verifiedDraftModelLoadPath = startupPreflight.verifiedDraftModelLoadPath

        printResolvedConfiguration(resolved)

        // T3-03: apply family-based KV-quant default when the operator has
        // not set an explicit override. Explicit config/env/CLI always wins.
        let effectiveKVBits = resolved.kvBitsOverride
            ?? KVQuantRecommendation.recommendedKVBits(for: resolved.model ?? "")
        // The coordinator advertises config.modelCatalogModelID as this
        // provider's model_id while inference is served locally under
        // config.model. Accept the advertised catalog id as a serve alias so
        // relayed buyer requests carrying it are not 404'd. Trimmed here to
        // match CoordinatorClient's catalogModelIDForCoordinator normalization;
        // nil/empty → no alias.
        let catalogModelIDAlias: String? = resolved.modelCatalogModelID.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        _ = try lifecycleStateStore.transition(
            to: .loadingModel,
            reasonCode: "catalog_preflight_passed",
            writer: .serve,
            providerID: resolved.providerID,
            modelID: resolved.model,
            operationID: lifecycleOperationID
        )
        let modelRuntime: ModelRuntime
        do {
            modelRuntime = try await ModelRuntime(
                modelID: resolved.model,
                modelLoadPath: resolved.modelArtifactPath,
                draftModelID: resolved.draftModel,
                draftModelLoadPath: verifiedDraftModelLoadPath,
                numDraftTokens: resolved.numDraftTokens,
                maxContextTokensOverride: resolved.maxContextOverride,
                kvBitsOverride: effectiveKVBits,
                prefillStepSize: resolved.prefillStepSize,
                maxBatch: resolved.maxConcurrencyOverride ?? 1,
                warmSwapEnabled: resolved.enableWarmSwap,
                swapDrainTimeoutSeconds: resolved.swapDrainTimeoutSeconds,
                catalogModelIDAlias: catalogModelIDAlias,
                verifiedModelArtifactSHA256: resolved.modelArtifactSHA256
            )
        } catch {
            _ = try? lifecycleStateStore.transition(
                to: .failed,
                reasonCode: "model_load_failed",
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
            throw error
        }
        // The serve runtime defaults `--max-batch` to 1 (the prior
        // single-slot behavior). Operators opting in via --max-batch >1
        // own the safety check; we surface the configured value in
        // capacity so the coordinator's view stays consistent.
        let capacityDefaults = ProviderCapacity(
            maxContextOverride: resolved.maxContextOverride,
            maxConcurrencyOverride: resolved.maxConcurrencyOverride ?? 1
        )
        let throughputEstimate = await Self.startupThroughputEstimate(
            autotuneCandidate: autotuneCandidate,
            measure: { await modelRuntime.measureStartupThroughput() }
        )
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
            modelHashAlgorithm: await modelRuntime.loadedModelHashAlgorithm,
            weightsManifestSHA256: await modelRuntime.loadedWeightsManifestSHA256,
            thermalGate: thermalGate,
            specDecodeDraftModelID: resolved.draftModel,
            specDecodeNumDraftTokens: resolved.numDraftTokens,
            providerID: resolved.providerID
        )
        if operatorPausedInitially {
            await providerStatus.setState(.unavailable, reason: "operator_pause_restored")
        }
        await modelRuntime.setProviderStatus(providerStatus)
        let receiptKeyStore = KeychainReceiptKeyStore()
        let admissionIdentitySigningKeyCandidates: [Curve25519.Signing.PrivateKey]
        let persistAdmissionIdentitySigningKey: (@Sendable (Curve25519.Signing.PrivateKey) throws -> Void)?
        let providerAdmissionNextPublicKey: String?
        let providerAdmissionRecovery: Bool
        let admissionIdentityWasPersisted: Bool
        let commitAdmissionIdentityPublicKey: (@Sendable (Data, Date?) throws -> Void)?
        if let providerID = resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerID.isEmpty,
           resolved.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            // Enforce the bounded rollback-key retention even on the normal
            // healthy-current path, where no recovery candidate is otherwise
            // loaded during startup.
            _ = try receiptKeyStore.loadPreviousAdmissionIdentity(providerId: providerID)
            if let persistedIdentity = try receiptKeyStore.loadAdmissionIdentity(providerId: providerID) {
                admissionIdentityWasPersisted = true
                let pending = try receiptKeyStore.loadPendingAdmissionIdentity(providerId: providerID)
                let topology = try AdmissionIdentityStartupTopology.resolve(
                    currentPublicKey: persistedIdentity.publicKey.rawRepresentation,
                    pendingPublicKey: pending?.publicKey.rawRepresentation,
                    recoveryMarkerPublicKey: receiptKeyStore.loadAdmissionIdentityRecoveryMarker(
                        providerId: providerID
                    )
                )
                switch topology {
                case .currentOnly:
                    admissionIdentitySigningKeyCandidates = [persistedIdentity]
                    providerAdmissionNextPublicKey = nil
                    providerAdmissionRecovery = false
                    commitAdmissionIdentityPublicKey = nil
                case .duplicatePending:
                    try receiptKeyStore.cancelAdmissionIdentityRotation(providerId: providerID)
                    admissionIdentitySigningKeyCandidates = [persistedIdentity]
                    providerAdmissionNextPublicKey = nil
                    providerAdmissionRecovery = false
                    commitAdmissionIdentityPublicKey = nil
                case .rotationPending:
                    guard let pending else {
                        throw ValidationError("admission identity rotation candidate disappeared during startup")
                    }
                    admissionIdentitySigningKeyCandidates = [persistedIdentity, pending]
                    providerAdmissionNextPublicKey = Data(pending.publicKey.rawRepresentation).base64EncodedString()
                    providerAdmissionRecovery = false
                    commitAdmissionIdentityPublicKey = { expectedPublicKey, previousValidUntil in
                        _ = try receiptKeyStore.commitAdmissionIdentityRotation(
                            providerId: providerID,
                            expectedPublicKey: expectedPublicKey,
                            previousValidUntil: previousValidUntil
                        )
                    }
                case .recoveryPending:
                    guard let pending else {
                        throw ValidationError("admission identity recovery candidate disappeared during startup")
                    }
                    admissionIdentitySigningKeyCandidates = [pending]
                    providerAdmissionNextPublicKey = nil
                    providerAdmissionRecovery = true
                    commitAdmissionIdentityPublicKey = { expectedPublicKey, _ in
                        _ = try receiptKeyStore.commitAdmissionIdentityRecovery(
                            providerId: providerID,
                            expectedPublicKey: expectedPublicKey
                        )
                    }
                case .recoveryCommittedCleanup:
                    _ = try receiptKeyStore.commitAdmissionIdentityRecovery(
                        providerId: providerID,
                        expectedPublicKey: persistedIdentity.publicKey.rawRepresentation
                    )
                    admissionIdentitySigningKeyCandidates = [persistedIdentity]
                    providerAdmissionNextPublicKey = nil
                    providerAdmissionRecovery = false
                    commitAdmissionIdentityPublicKey = nil
                case .invalidRecoveryMarker:
                    throw ValidationError(
                        "admission identity recovery marker does not match the staged candidate; run credentials repair"
                    )
                }
                persistAdmissionIdentitySigningKey = nil
            } else {
                admissionIdentityWasPersisted = false
                // A missing dedicated slot is either first legacy enrollment or
                // partial Keychain loss. Offer only keys already held locally and
                // let the coordinator's durable hint select one. A fresh candidate
                // is persisted only when the server explicitly challenges it;
                // an existing unknown binding therefore fails closed.
                var candidates: [Curve25519.Signing.PrivateKey] = []
                func appendCandidate(_ key: Curve25519.Signing.PrivateKey?) {
                    guard let key,
                          !candidates.contains(where: { $0.rawRepresentation == key.rawRepresentation }) else {
                        return
                    }
                    candidates.append(key)
                }
                let pendingRecovery = try receiptKeyStore.loadPendingAdmissionIdentity(providerId: providerID)
                let recoveryMarker = try receiptKeyStore.loadAdmissionIdentityRecoveryMarker(providerId: providerID)
                if let recoveryMarker,
                   recoveryMarker != pendingRecovery?.publicKey.rawRepresentation {
                    throw ValidationError(
                        "admission identity recovery marker does not match the staged candidate; run credentials repair"
                    )
                }
                appendCandidate(pendingRecovery)
                appendCandidate(try receiptKeyStore.loadPreviousAdmissionIdentity(providerId: providerID))
                appendCandidate(try receiptKeyStore.loadCurrent(providerId: providerID))
                appendCandidate(try receiptKeyStore.loadPrevious(providerId: providerID))
                if candidates.isEmpty {
                    candidates.append(Curve25519.Signing.PrivateKey())
                }
                admissionIdentitySigningKeyCandidates = candidates
                providerAdmissionRecovery = recoveryMarker != nil
                if providerAdmissionRecovery {
                    persistAdmissionIdentitySigningKey = nil
                    commitAdmissionIdentityPublicKey = { expectedPublicKey, _ in
                        _ = try receiptKeyStore.commitAdmissionIdentityRecovery(
                            providerId: providerID,
                            expectedPublicKey: expectedPublicKey
                        )
                    }
                } else {
                    persistAdmissionIdentitySigningKey = { key in
                        _ = try receiptKeyStore.loadOrStoreAdmissionIdentity(
                            providerId: providerID,
                            candidate: key
                        )
                    }
                    commitAdmissionIdentityPublicKey = nil
                }
                providerAdmissionNextPublicKey = nil
            }
        } else {
            admissionIdentitySigningKeyCandidates = []
            persistAdmissionIdentitySigningKey = nil
            providerAdmissionNextPublicKey = nil
            providerAdmissionRecovery = false
            admissionIdentityWasPersisted = false
            commitAdmissionIdentityPublicKey = nil
        }
        let previousAdmissionIdentityState: AdmissionIdentityPreviousKeyState? = try {
            guard let providerID = resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !providerID.isEmpty else { return nil }
            return try receiptKeyStore.loadPreviousAdmissionIdentityState(providerId: providerID)
        }()
        let receiptRuntime = try Self.makeReceiptRuntime(config: resolved, keyStore: receiptKeyStore)
        let providerReceiptPublicKey = receiptRuntime.publicKeyBase64
        let providerAdmissionPublicKey = admissionIdentitySigningKeyCandidates.first
            .map { Data($0.publicKey.rawRepresentation).base64EncodedString() }
        let admissionIdentityStatus: ProviderAdmissionIdentityStatusContext = {
            guard let key = admissionIdentitySigningKeyCandidates.first else {
                return ProviderAdmissionIdentityStatusContext(
                    source: "none",
                    state: resolved.providerID == nil ? "unconfigured" : "missing",
                    publicKeySHA256: nil
                )
            }
            let digest = SHA256.hash(data: Data(key.publicKey.rawRepresentation))
                .map { String(format: "%02x", $0) }
                .joined()
            let pendingDigest = providerAdmissionRecovery
                ? digest
                : providerAdmissionNextPublicKey
                    .flatMap { Data(base64Encoded: $0) }
                    .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            let previousDigest = previousAdmissionIdentityState.map {
                SHA256.hash(data: Data($0.privateKey.publicKey.rawRepresentation))
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
            let previousValidUntil = previousAdmissionIdentityState.map { state in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.string(from: state.validUntil)
            }
            return ProviderAdmissionIdentityStatusContext(
                source: providerAdmissionRecovery ? "cli_keychain_pending" : (admissionIdentityWasPersisted ? "cli_keychain" : "local_recovery_candidate"),
                state: providerAdmissionRecovery
                    ? "recovery_pending"
                    : (admissionIdentityWasPersisted
                        ? (providerAdmissionNextPublicKey == nil ? "ready" : "rotation_pending")
                        : "identity_migration_required"),
                publicKeySHA256: digest,
                pendingPublicKeySHA256: pendingDigest,
                previousPublicKeySHA256: previousDigest,
                previousValidUntil: previousValidUntil,
                recoveryAction: providerAdmissionRecovery
                    ? "obtain_operator_recovery_approval_then_restart"
                    : (admissionIdentityWasPersisted ? "none" : "connect_to_enroll_or_run_recover_admission_identity")
            )
        }()
        let admissionIdentityStatusRuntime = ProviderAdmissionIdentityStatusRuntime(admissionIdentityStatus)
        let installedCompatibilityManifest: CompatibilitySetManifest? = try { () throws -> CompatibilitySetManifest? in
            guard let directory = CompatibilitySetManifest.payloadDirectory(
                for: Bundle.main.executableURL
            ) else { return nil }
            let manifestURL = directory.appendingPathComponent(CompatibilitySetManifest.fileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            return try CompatibilitySetManifest.loadValidated(
                from: directory,
                expectedProviderVersion: CoordinatorClient.binaryVersion
            )
        }()
        if resolved.donorMode {
            FileHandle.standardError.write(Data("DONOR MODE: coordinator join disabled; serving local HTTP only.\n".utf8))
        }
        let coordinatorClient = Self.makeCoordinatorClient(
            noJoin: noJoin,
            donorMode: resolved.donorMode,
            catalogTrustState: startupPreflight.catalogTrust?.state
        ) {
            CoordinatorClient(
                config: resolved,
                modelRuntime: modelRuntime,
                providerStatus: providerStatus,
                attestationGenerator: {
                    #if arch(arm64)
                    if let seGen = SecureEnclaveAttestationGenerator.loadIfAvailable() {
                        return seGen
                    }
                    #endif
                    return ManagedDeviceAttestationGenerator(artifactPath: resolved.tier2MDAArtifactPath)
                }(),
                providerReceiptPublicKey: providerReceiptPublicKey,
                providerAdmissionPublicKey: providerAdmissionPublicKey,
                providerAdmissionNextPublicKey: providerAdmissionNextPublicKey,
                providerAdmissionRecovery: providerAdmissionRecovery,
                commitAdmissionIdentityPublicKey: commitAdmissionIdentityPublicKey,
                receiptBuilder: receiptRuntime.builder,
                catalogReleaseID: startupPreflight.catalogTrust?.releaseID,
                catalogPolicyVersion: startupPreflight.catalogTrust?.policyVersion,
                catalogCandidateSHA256: startupPreflight.catalogTrust?.digest,
                catalogSignerKeyID: startupPreflight.catalogTrust?.signerKeyID,
                catalogRowIdentity: startupPreflight.catalogTrust?.rowIdentity,
                catalogModelSHA256: startupPreflight.catalogTrust?.modelSHA256,
                receiptIdentitySigningKeyCandidates: admissionIdentitySigningKeyCandidates,
                persistReceiptIdentitySigningKey: persistAdmissionIdentitySigningKey,
                providerCredentialStore: credentialStore,
                credentialStatusRuntime: credentialStatusRuntime,
                admissionIdentityStatusRuntime: admissionIdentityStatusRuntime,
                lifecycleStateStore: lifecycleStateStore,
                lifecycleOperationID: lifecycleOperationID,
                operatorPausedInitially: operatorPausedInitially
            )
        }
        let idlePrewarmLogger = IdlePrewarmLogger { object in
            IdlePrewarmLogger.stdout.emit(object)
            guard let event = object["event"] as? String else { return }
            let reason = object["reason"] as? String
            guard let coordinatorClient else { return }
            Task {
                await coordinatorClient.sendIdlePrewarmEvent(event: event, reason: reason)
            }
        }
        let idlePrewarmer = IdlePrewarmer(
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            thermalGate: thermalGate,
            powerSource: SystemPowerSourceReporter(),
            config: IdlePrewarmConfig(appConfig: resolved),
            logger: idlePrewarmLogger
        )
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
        let lifecycleControlProviderID = resolved.providerID
        let lifecycleControlModelID = resolved.model
        let lifecycleControlCompatibilitySetID = installedCompatibilityManifest?.compatibilitySetID
        let lifecycleControlDrainTimeout = resolved.drainTimeoutSeconds
        let pauseProvider: @Sendable () async -> ProviderControlCommandResult
        let resumeProvider: @Sendable () async -> ProviderControlCommandResult
        if let coordinatorClient {
            pauseProvider = { await coordinatorClient.pauseByOperator() }
            resumeProvider = { await coordinatorClient.resumeByOperator() }
        } else {
            pauseProvider = {
                await providerStatus.setState(.draining, reason: "operator_pause_draining")
                guard await providerStatus.waitUntilDrained(timeoutSeconds: lifecycleControlDrainTimeout) else {
                    await providerStatus.setState(.ready, reason: "operator_pause_drain_timeout")
                    return .rejected("drain_timeout")
                }
                do {
                    _ = try lifecycleStateStore.transition(
                        to: .pausedByOperator,
                        reasonCode: "operator_pause_confirmed",
                        writer: .operatorCommand,
                        providerID: lifecycleControlProviderID,
                        modelID: lifecycleControlModelID,
                        compatibilitySetID: lifecycleControlCompatibilitySetID,
                        operationID: "operator-pause:\(UUID().uuidString.lowercased())",
                        operatorPaused: true
                    )
                } catch {
                    await providerStatus.setState(.ready, reason: "operator_pause_persistence_failed")
                    return .rejected("lifecycle_state_persistence_failed")
                }
                await providerStatus.setState(.unavailable, reason: "operator_paused")
                return .accepted
            }
            resumeProvider = {
                do {
                    _ = try lifecycleStateStore.transition(
                        to: .degradedServing,
                        reasonCode: "operator_resume_local_only",
                        writer: .operatorCommand,
                        providerID: lifecycleControlProviderID,
                        modelID: lifecycleControlModelID,
                        compatibilitySetID: lifecycleControlCompatibilitySetID,
                        operationID: "operator-resume:\(UUID().uuidString.lowercased())",
                        operatorPaused: false
                    )
                } catch {
                    return .rejected("lifecycle_state_persistence_failed")
                }
                await providerStatus.setState(.ready, reason: "operator_resumed")
                return .accepted
            }
        }
        // Every serve instance exposes the same owner-only control contract.
        // Malibu must not lose lifecycle/earnings visibility merely because
        // warm swap or receipt rotation is disabled for this provider.
        let socketURL = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        let providerEarningsClient = resolved.providerID.flatMap {
            try? ProviderEarningsClient(
                coordinatorURL: resolved.coordinatorURL,
                providerID: $0
            )
        }
        let referralCoordinatorService: ReferralCoordinatorService? = {
            guard let providerID = resolved.providerID,
                  let providerToken = resolved.providerToken,
                  let client = try? ReferralCoordinatorClient(
                      coordinatorURL: resolved.coordinatorURL,
                      providerID: providerID,
                      bearerToken: providerToken
                  ) else {
                return nil
            }
            return ReferralCoordinatorService(
                client: client,
                store: ReferralChallengeStore(url: ReferralChallengeStore.defaultURL())
            )
        }()
        let malibuAccrualClient = try? MalibuAccrualClient(coordinatorURL: resolved.coordinatorURL)
        controlSocket = ControlSocketServer(
            socketPath: socketURL,
            modelRuntime: modelRuntime,
            supportedModels: resolved.supportedModels,
            receiptRotator: receiptRotator,
            receiptRotationProviderID: resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
            providerStatus: providerStatus,
            providerEarningsClient: providerEarningsClient,
            referralCoordinatorService: referralCoordinatorService,
            malibuAccrualClient: malibuAccrualClient,
            providerToken: resolved.providerToken,
            pauseProvider: pauseProvider,
            resumeProvider: resumeProvider
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
        await idlePrewarmer.start()
        let lifecycleProviderID = resolved.providerID
        let lifecycleModelID = resolved.model
        let lifecycleCompatibilitySetID = installedCompatibilityManifest?.compatibilitySetID
        let lifecycleReadyState: ProviderLifecycleState = operatorPausedInitially
            ? .pausedByOperator
            : (coordinatorClient == nil ? .degradedServing : .locallyReadyConnecting)
        let lifecycleReadyReason = operatorPausedInitially
            ? "operator_pause_restored_after_startup"
            : (coordinatorClient == nil ? "local_http_ready_join_disabled" : "local_http_ready_awaiting_coordinator")
        let lifecycleReadyWriter: ProviderLifecycleWriter = operatorPausedInitially
            ? .operatorCommand
            : .serve
        let server = HTTPServer(
            config: resolved,
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            receiptBuilder: receiptRuntime.builder,
            idlePrewarmer: idlePrewarmer,
            catalogModelIDAlias: catalogModelIDAlias,
            catalogTrust: startupPreflight.catalogTrust,
            credentialStatusRuntime: credentialStatusRuntime,
            admissionIdentityStatusRuntime: admissionIdentityStatusRuntime,
            compatibilitySetManifest: installedCompatibilityManifest,
            lifecycleStateStore: lifecycleStateStore,
            lifecycleLeaseStore: lifecycleLeaseStore,
            onListening: {
                _ = try lifecycleStateStore.transition(
                    to: lifecycleReadyState,
                    reasonCode: lifecycleReadyReason,
                    writer: lifecycleReadyWriter,
                    providerID: lifecycleProviderID,
                    modelID: lifecycleModelID,
                    compatibilitySetID: lifecycleCompatibilitySetID,
                    operationID: lifecycleOperationID
                )
                guard try Self.clearStartupLifecycleLeaseUnlessUpdatePending(
                    startupLease,
                    store: lifecycleLeaseStore
                ) else {
                    throw ProviderLifecycleLeaseError.compareAndSwapFailed
                }
                Task {
                    await Self.clearStartupLifecycleLeaseWhenUpdateCompletes(
                        startupLease,
                        store: lifecycleLeaseStore
                    )
                }
                Self.startCoordinatorAfterListening {
                    await coordinatorClient?.start()
                }
            }
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

    static func startCoordinatorAfterListening(
        _ start: (@Sendable () async -> Void)?
    ) {
        guard let start else { return }
        Task {
            await start()
        }
    }

    static func acquireProviderServeLock(_ config: AppConfig) throws -> ProviderServeLock {
        do {
            return try ProviderServeLock.acquire(providerID: config.providerID, port: config.port)
        } catch let error as ProviderServeLockError {
            FileHandle.standardError.write(Data((
                "provider singleton conflict: \(error.description)\n"
            ).utf8))
            throw ExitCode(1)
        }
    }

    static let providerLaunchdServiceIdentity = "live.streamvc.macprovider"

    @discardableResult
    static func fenceAuthorizedSelfUpdateReloadJobsAtStartup(
        loadPending: () throws -> AutoUpdatePendingMarker? = {
            try AutoUpdateMarkerStore().readPending()
        },
        inspectLifecycleLease: () -> ProviderLifecycleLeaseInspection = {
            ProviderLifecycleLeaseStore().inspect()
        },
        currentExecutableURL: URL? = Bundle.main.executableURL,
        targetVersion: String = CoordinatorClient.binaryVersion,
        lifecycleEnvironment: ProviderLifecycleLeaseEnvironment = .live,
        executableSHA256: (URL) throws -> String = {
            try AutoUpdateMarkerStore.sha256(file: $0)
        },
        fenceReloadJobs: () throws -> Void = {
            try AutoUpdater.fenceReloadJobsIfInstalled()
        }
    ) throws -> Bool {
        guard let pending = try loadPending() else {
            return false
        }
        if pending.transactionState == .restoringPrevious
            || pending.transactionState == .awaitingPreviousReadiness
        {
            try fenceRestoredPreviousReloadJobsAtStartup(
                pending: pending,
                currentExecutableURL: currentExecutableURL,
                currentVersion: targetVersion,
                lifecycleEnvironment: lifecycleEnvironment,
                executableSHA256: executableSHA256,
                fenceReloadJobs: fenceReloadJobs
            )
            // The retained handoff names the failed target, not the restored
            // previous binary. Fence stale helpers, but do not authorize that
            // handoff's recovery; startup will replace its stale owner through
            // the ordinary invalid-lease path.
            return false
        }
        guard pending.commitOwner == "self_update"
                || pending.commitOwner == "coordinator" else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("commit_owner")
        }
        guard pending.targetVersion == targetVersion else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("target_version")
        }
        guard let executable = CompatibilitySetManifest.resolvedExecutableURL(currentExecutableURL)
        else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("current_executable")
        }
        let executableDigest = try executableSHA256(executable)
        let pendingTarget = CompatibilitySetManifest.resolvedExecutableURL(
            URL(fileURLWithPath: pending.targetPath)
        )
        guard pendingTarget == executable else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("pending_target_path")
        }

        let leaseRecord: ProviderLifecycleLeaseRecord
        let adoptedRecovery: Bool
        switch inspectLifecycleLease() {
        case .valid(let record):
            leaseRecord = record
            adoptedRecovery = false
        case .invalidOrExpired(let record?, let reason)
            where record.startupHandoff?.state == .adopted
                && Self.adoptedStartupHandoffRecoveryReasonAllowed(reason):
            // The exact launchd target can restart while the dual-authority
            // update marker is still armed. Structural/storage failures remain
            // unauthorized; stale owner, clock window, and boot-session state
            // are rebound later only after this exact target passes every
            // marker, path, digest, and launchd-PID check.
            leaseRecord = record
            adoptedRecovery = true
        case .missing, .invalidOrExpired:
            throw SelfUpdateStartupFenceError.authorizationMismatch("startup_handoff")
        }
        guard let handoff = leaseRecord.startupHandoff,
              handoff.state == .prepared || handoff.state == .adopted,
              handoff.serviceIdentity == providerLaunchdServiceIdentity
        else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("startup_handoff")
        }
        let processID = lifecycleEnvironment.processID()
        guard processID > 0,
              lifecycleEnvironment.launchdServiceProcessID(handoff.serviceIdentity) == processID
        else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("launchd_service_owner")
        }
        guard let bootSession = lifecycleEnvironment.bootSession(),
              !bootSession.isEmpty,
              leaseRecord.owner.bootSession == handoff.bootSession,
              adoptedRecovery || bootSession == handoff.bootSession else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("startup_handoff_boot_session")
        }
        let wallNow = lifecycleEnvironment.wallMilliseconds()
        let monotonicNow = lifecycleEnvironment.monotonicNanoseconds()
        if adoptedRecovery {
            guard wallNow >= leaseRecord.issuedWallMilliseconds,
                  wallNow >= handoff.issuedWallMilliseconds,
                  Self.pendingMarkerDeadlineIsFuture(pending, wallMilliseconds: wallNow),
                  bootSession != handoff.bootSession
                    || (monotonicNow >= leaseRecord.issuedMonotonicNanoseconds
                        && monotonicNow >= handoff.issuedMonotonicNanoseconds) else {
                throw SelfUpdateStartupFenceError.authorizationMismatch("startup_handoff_window")
            }
        } else {
            guard wallNow >= leaseRecord.issuedWallMilliseconds,
                  wallNow < leaseRecord.expiresWallMilliseconds,
                  monotonicNow >= leaseRecord.issuedMonotonicNanoseconds,
                  monotonicNow < leaseRecord.expiresMonotonicNanoseconds,
                  wallNow >= handoff.issuedWallMilliseconds,
                  wallNow < handoff.expiresWallMilliseconds,
                  monotonicNow >= handoff.issuedMonotonicNanoseconds,
                  monotonicNow < handoff.expiresMonotonicNanoseconds else {
                throw SelfUpdateStartupFenceError.authorizationMismatch("startup_handoff_window")
            }
        }
        let handoffTarget = CompatibilitySetManifest.resolvedExecutableURL(
            URL(fileURLWithPath: handoff.targetExecutablePath)
        )
        guard handoffTarget == executable else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("handoff_target_path")
        }
        guard handoff.targetExecutableSHA256 == executableDigest else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("handoff_target_sha256")
        }

        try fenceReloadJobs()
        return true
    }

    private static func fenceRestoredPreviousReloadJobsAtStartup(
        pending: AutoUpdatePendingMarker,
        currentExecutableURL: URL?,
        currentVersion: String,
        lifecycleEnvironment: ProviderLifecycleLeaseEnvironment,
        executableSHA256: (URL) throws -> String,
        fenceReloadJobs: () throws -> Void
    ) throws {
        guard pending.commitOwner == "self_update"
                || pending.commitOwner == "coordinator" else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("commit_owner")
        }
        guard pending.previousVersion == currentVersion else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("rollback_previous_version")
        }
        guard let executable = CompatibilitySetManifest.resolvedExecutableURL(currentExecutableURL)
        else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("current_executable")
        }
        let pendingTarget = CompatibilitySetManifest.resolvedExecutableURL(
            URL(fileURLWithPath: pending.targetPath)
        )
        guard pendingTarget == executable else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("pending_target_path")
        }
        let processID = lifecycleEnvironment.processID()
        guard processID > 0,
              lifecycleEnvironment.launchdServiceProcessID(
                providerLaunchdServiceIdentity
              ) == processID else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("launchd_service_owner")
        }
        guard try executableSHA256(executable) == pending.sha256 else {
            throw SelfUpdateStartupFenceError.authorizationMismatch("rollback_previous_sha256")
        }
        try fenceReloadJobs()
    }

    private static func adoptedStartupHandoffRecoveryReasonAllowed(
        _ reason: ProviderLifecycleLeaseInvalidReason
    ) -> Bool {
        switch reason {
        case .wallExpired, .monotonicExpired, .bootSessionChanged,
             .ownerProcessMissingOrReused:
            return true
        case .malformedRecord, .unsupportedVersion, .invalidField,
             .durationOutOfRange, .wallClockBeforeIssue,
             .monotonicClockBeforeIssue, .unsafeStorage, .storageFailure:
            return false
        }
    }

    private static func pendingMarkerDeadlineIsFuture(
        _ pending: AutoUpdatePendingMarker,
        wallMilliseconds: Int64
    ) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard wallMilliseconds > 0,
              let deadline = formatter.date(from: pending.markerDeadline) else {
            return false
        }
        return deadline.timeIntervalSince1970 * 1_000 > Double(wallMilliseconds)
    }

    static func startupLifecycleLeaseMatchesPendingUpdate(
        _ lease: ProviderLifecycleLeaseRecord,
        loadPending: () throws -> AutoUpdatePendingMarker? = {
            try AutoUpdateMarkerStore().readPending()
        },
        targetVersion: String = CoordinatorClient.binaryVersion,
        wallMilliseconds: Int64 = Int64(
            (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        )
    ) -> Bool {
        guard let handoff = lease.startupHandoff,
              handoff.state == .adopted,
              let pending = try? loadPending(),
              pending.commitOwner == "self_update"
                || pending.commitOwner == "coordinator",
              pending.targetVersion == targetVersion,
              pending.targetPath == handoff.targetExecutablePath,
              pendingMarkerDeadlineIsFuture(
                pending,
                wallMilliseconds: wallMilliseconds
              ) else {
            return false
        }
        return true
    }

    @discardableResult
    static func clearStartupLifecycleLeaseUnlessUpdatePending(
        _ lease: ProviderLifecycleLeaseRecord,
        store: ProviderLifecycleLeaseStore,
        loadPending: () throws -> AutoUpdatePendingMarker? = {
            try AutoUpdateMarkerStore().readPending()
        },
        targetVersion: String = CoordinatorClient.binaryVersion,
        wallMilliseconds: Int64 = Int64(
            (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        )
    ) throws -> Bool {
        guard !startupLifecycleLeaseMatchesPendingUpdate(
            lease,
            loadPending: loadPending,
            targetVersion: targetVersion,
            wallMilliseconds: wallMilliseconds
        ) else {
            return true
        }
        return try store.clear(ifLeaseID: lease.leaseID)
    }

    static func clearStartupLifecycleLeaseWhenUpdateCompletes(
        _ lease: ProviderLifecycleLeaseRecord,
        store: ProviderLifecycleLeaseStore,
        loadPending: @escaping () throws -> AutoUpdatePendingMarker? = {
            try AutoUpdateMarkerStore().readPending()
        },
        targetVersion: String = CoordinatorClient.binaryVersion,
        wallMilliseconds: @escaping () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        },
        sleep: @escaping () async -> Void = {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    ) async {
        while startupLifecycleLeaseMatchesPendingUpdate(
            lease,
            loadPending: loadPending,
            targetVersion: targetVersion,
            wallMilliseconds: wallMilliseconds()
        ) {
            await sleep()
        }
        _ = try? store.clear(ifLeaseID: lease.leaseID)
    }

    static func startupHandoffOperationID(in store: ProviderLifecycleLeaseStore) -> String? {
        switch store.inspect() {
        case .valid(let record):
            return record.startupHandoff?.operationID
        case .invalidOrExpired(let record, _):
            // Preserve the exact ID so adoption reports expiry/mismatch rather
            // than silently replacing the updater's prepared authorization.
            return record?.startupHandoff?.operationID
        case .missing:
            return nil
        }
    }

    static func acquireStartupLifecycleLease(
        store: ProviderLifecycleLeaseStore,
        operationID: String,
        providerID: String?,
        duration: TimeInterval,
        allowAdoptedHandoffRecovery: Bool = false
    ) throws -> ProviderLifecycleLeaseRecord {
        let trimmedProviderID = providerID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let adoptionProviderID: String
        if let trimmedProviderID, !trimmedProviderID.isEmpty {
            adoptionProviderID = trimmedProviderID
        } else {
            adoptionProviderID = "missing-provider-id"
        }
        do {
            return try store.adoptStartupHandoff(
                operationID: operationID,
                providerID: adoptionProviderID,
                serviceIdentity: providerLaunchdServiceIdentity
            )
        } catch ProviderLifecycleLeaseError.handoffNotPrepared {
            // No prepared/adopted handoff to consume: fall back to a fresh
            // startup lease. acquire() re-validates and refuses to displace a
            // VALID live foreign owner (throws .alreadyHeld) -- see below.
            return try store.acquire(
                kind: .startup,
                operationID: operationID,
                duration: duration
            )
        } catch ProviderLifecycleLeaseError.leaseNotValid {
            if allowAdoptedHandoffRecovery {
                return try store.recoverAdoptedStartupHandoff(
                    operationID: operationID,
                    providerID: adoptionProviderID,
                    serviceIdentity: providerLaunchdServiceIdentity
                )
            }
            // The on-disk record IS a matching handoff, but its OWNER identity is
            // no longer valid (adoptStartupHandoff's adopted branch,
            // ProviderLifecycleLease.swift ~620, rethrows validationFailure as
            // leaseNotValid -- e.g. .ownerProcessMissingOrReused after a crash +
            // launchd restart + PID reuse, or an expired window). That denotes an
            // invalid/expired/wrong-owner RECORD, not a live conflicting owner, so
            // it is replaceable. Fall back to fresh acquisition instead of
            // restart-looping. This is SAFE because acquire() itself re-validates
            // the record it is about to overwrite (ProviderLifecycleLease.swift
            // ~432..444): if that record is still a VALID live foreign owner it
            // throws .alreadyHeld (hard failure, unchanged startup_lease_unavailable
            // path); it only overwrites when the failure permitsReplacement
            // (.wallExpired/.monotonicExpired/.bootSessionChanged/
            // .ownerProcessMissingOrReused, ~1279..1293), and it rethrows
            // leaseNotValid for non-replaceable structural failures. So this
            // fallback cannot bypass the valid-live-owner guard. Every error kind
            // meaning "another live valid owner holds this" (.alreadyHeld,
            // .compareAndSwapFailed, .currentOwnerUnavailable, .handoffMismatch,
            // .handoffExpired, .launchdServiceOwnerMismatch, .targetExecutableMismatch,
            // storage/io) still propagates as a hard failure, unchanged.
            return try store.acquire(
                kind: .startup,
                operationID: operationID,
                duration: duration
            )
        }
    }

    static func validateCoordinatorCredential(
        config: AppConfig,
        credentialStatus: ProviderCredentialStatus,
        noJoin: Bool
    ) throws {
        guard !noJoin, !config.donorMode else { return }
        guard config.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              let configuredProviderID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !configuredProviderID.isEmpty else {
            return
        }
        throw ValidationError(
            "coordinator join credential state is \(credentialStatus.state.rawValue); action=\(credentialStatus.recoveryAction.rawValue)"
        )
    }

    struct ServeStartupPreflightResult {
        let serveLock: ProviderServeLock
        let verifiedDraftModelLoadPath: String?
        let catalogTrust: CatalogRuntimeTrust?
    }

    static func runServeStartupPreflights(
        _ resolved: inout AppConfig,
        joiningCoordinator: Bool,
        coordinatorAcceptsSpecDecodeTelemetry: Bool = Self.bundledCoordinatorAcceptsSpecDecodeTelemetry,
        portIsOpen: (Int) -> Bool = MacProviderPortProbe.isOpen,
        acquireServeLock: (AppConfig) throws -> ProviderServeLock = Self.acquireProviderServeLock,
        afterServeLockAcquired: () throws -> Void = {},
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs(),
        artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver()
    ) async throws -> ServeStartupPreflightResult {
        let serveLock = try Self.runPreModelStartupPreflights(
            &resolved,
            coordinatorAcceptsSpecDecodeTelemetry: coordinatorAcceptsSpecDecodeTelemetry,
            portIsOpen: portIsOpen,
            acquireServeLock: acquireServeLock
        )
        do {
            try afterServeLockAcquired()
            let catalogTrust: CatalogRuntimeTrust?
            do {
                catalogTrust = try await Self.runModelArtifactPreflight(
                    resolved,
                    joiningCoordinator: joiningCoordinator,
                    staticInputs: staticInputs,
                    artifactResolver: artifactResolver
                )
            } catch where joiningCoordinator || resolved.donorMode {
                throw ServeCatalogPreflightError(underlying: error)
            }
            let verifiedDraftModelLoadPath = try Self.runDraftModelArtifactPreflight(
                resolved,
                joiningCoordinator: joiningCoordinator
            )
            return ServeStartupPreflightResult(
                serveLock: serveLock,
                verifiedDraftModelLoadPath: verifiedDraftModelLoadPath,
                catalogTrust: catalogTrust
            )
        } catch {
            serveLock.release()
            throw error
        }
    }

    static func runPreModelStartupPreflights(
        _ resolved: inout AppConfig,
        coordinatorAcceptsSpecDecodeTelemetry: Bool = Self.bundledCoordinatorAcceptsSpecDecodeTelemetry,
        portIsOpen: (Int) -> Bool = MacProviderPortProbe.isOpen,
        acquireServeLock: (AppConfig) throws -> ProviderServeLock = Self.acquireProviderServeLock
    ) throws -> ProviderServeLock {
        try Self.runSupportedModelsPreflight(&resolved)
        try Self.runDrainTimeoutPreflight(resolved)
        try Self.runServingKnobsPreflight(resolved)
        try Self.runSpecDecodeHeartbeatCompatibilityPreflight(
            resolved,
            coordinatorAcceptsSpecDecodeTelemetry: coordinatorAcceptsSpecDecodeTelemetry
        )
        try Self.runSpecDecodeCapacityPreflight(&resolved)

        let serveLock = try acquireServeLock(resolved)
        do {
            try Self.assertServePortAvailable(resolved, portIsOpen: portIsOpen)
        } catch {
            serveLock.release()
            throw error
        }
        return serveLock
    }

    static func assertServePortAvailable(
        _ config: AppConfig,
        portIsOpen: (Int) -> Bool = MacProviderPortProbe.isOpen
    ) throws {
        guard !portIsOpen(config.port) else {
            FileHandle.standardError.write(Data((
                "provider singleton conflict: 127.0.0.1:\(config.port) already has a listener\n"
            ).utf8))
            throw ExitCode(1)
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

    @Flag(help: "Show exact technical fields for diagnostics and support.")
    var advanced = false

    func run() async throws {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(port: port, configPath: config)
        )
        let status = try await LocalStatusClient.fetch(port: resolved.port)
        let latest = try? await SelfUpdate(currentVersion: CoordinatorClient.binaryVersion, releasesAPIURL: nil).latestVersionCached()
        let staleSince = await Self.staleRecommendationSince(providerID: resolved.providerID)
        print(LocalStatusFormatter.format(
            status,
            latestVersion: latest,
            ownerLogin: OwnerFileReader.githubLogin(configPath: resolved.configPath),
            donorMode: resolved.donorMode,
            staleRecommendationSince: staleSince,
            configPath: resolved.configPath,
            advanced: advanced
        ))
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
        _ = try await ServeCommand.runModelArtifactPreflight(resolved, joiningCoordinator: false)
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

    @Option(help: "Protected signed acceptance-candidate asset directory. Never fetches or publishes a release.")
    var acceptanceDirectory: String?

    @Option(help: "Exact vX.Y.Z identity of the signed acceptance candidate.")
    var acceptanceTag: String?

    @Option(help: "Exact 40-character commit identity of the signed acceptance candidate.")
    var acceptanceCommit: String?

    @Option(help: "Exact GitHub Actions run ID of the signed acceptance candidate.")
    var acceptanceRunID: String?

    @Option(help: "Exact trusted-main control commit that authorized the acceptance signature.")
    var acceptanceControlCommit: String?

    @Option(help: "Exact positive GitHub Actions run attempt that signed the candidate.")
    var acceptanceRunAttempt: Int?

    func run() async throws {
        let resolvedConfig = try? ConfigLoader.load(cli: CLIOverrides())
        let updater = SelfUpdate(
            currentVersion: CoordinatorClient.binaryVersion,
            releasesAPIURL: releasesAPIURL,
            providerID: resolvedConfig?.providerID
        )
        if acceptanceDirectory != nil || acceptanceTag != nil || acceptanceCommit != nil
            || acceptanceRunID != nil || acceptanceControlCommit != nil || acceptanceRunAttempt != nil
        {
            guard !check, releasesAPIURL == nil,
                  let acceptanceDirectory,
                  let acceptanceTag,
                  let acceptanceCommit,
                  let acceptanceRunID,
                  let acceptanceControlCommit,
                  let acceptanceRunAttempt
            else {
                throw ValidationError(
                    "all --acceptance-* identity options must be supplied together and cannot be combined with --check or --releases-api-url"
                )
            }
            try await updater.runAcceptanceCandidate(
                from: URL(fileURLWithPath: acceptanceDirectory, isDirectory: true),
                tag: acceptanceTag,
                expectedCommit: acceptanceCommit,
                expectedControlCommit: acceptanceControlCommit,
                expectedRunID: acceptanceRunID,
                expectedRunAttempt: acceptanceRunAttempt
            )
        } else {
            try await updater.run(checkOnly: check)
        }
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
    print("  stream_interval: \(config.streamInterval)")
    print("  prefill_step_size: \(config.prefillStepSize)")
}
