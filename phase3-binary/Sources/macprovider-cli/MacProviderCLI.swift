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
        subcommands: [ServeCommand.self, SelfTestCommand.self, StatusCommand.self, ClaimCommand.self, UpdateCommand.self, UninstallCommand.self, ModelsCommand.self, AutotuneCommand.self, BootstrapAuthCommand.self, RotateKeyCommand.self, CredentialsCommand.self, LifecycleStateCommand.self, LifecycleLeaseCommand.self, Spec028CanaryCommand.self, Spec028BenchmarkCommand.self, LegacySpec028CanaryCommand.self, LegacySpec028BenchmarkCommand.self, DecodeBenchCommand.self, EnrollCommand.self, ReleasePayloadPreflightCommand.self, KVCacheCommand.self, DoctorCommand.self, PayoutAddressCommand.self],
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
    static let pagedKVStrictStartupRejectEvent =
        "event=paged_kv_attach status=rejected reason=paged_preflight_reject detail=strict_runtime_proof_unavailable"

    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the local inference server and coordinator client."
    )

    @Option(help: "Local HTTP port to bind. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model. When this disagrees with config model_artifact_path, the CLI model wins and the configured artifact binding is cleared (#745).")
    var model: String?

    @Option(name: .customLong("model-artifact-sha256"), help: "Lowercase SHA-256 artifact hash for the model snapshot. Used by isolated autotune candidates to bind the child load to the bytes selected by the parent probe.")
    var modelArtifactSha256: String?

    @Option(name: .customLong("model-artifact-path"), help: "Absolute local model snapshot path paired with --model-artifact-sha256. Used by isolated autotune candidates after hashing the selected bytes.")
    var modelArtifactPath: String?

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

    @Option(help: "Continuous batching mode: off, canary, or on. Default off. Strict on fails closed unless the requested tuple is advertised by the local paged-KV engine. Overrides MACPROVIDER_CONTINUOUS_BATCHING and config key continuous_batching.")
    var continuousBatching: String?

    @Option(help: "Bounded continuous-batching waiting queue limit. Default 2 * active slots. Overrides MACPROVIDER_CONTINUOUS_BATCH_QUEUE_LIMIT and config key continuous_batch_queue_limit.")
    var continuousBatchQueueLimit: Int?

    // SPEC-037 FR-KVP11 — encrypted KV survival disk-tier CLI flags (MEDIUM-5). Each is
    // an Optional so absence defers to the environment / YAML / default; the resolver
    // (KVDiskCacheConfigResolver) applies CLI-wins precedence and fails closed on any
    // invalid value. --kv-disk-cache-allow-buyer-keys reaching the resolver as true is
    // rejected (precondition error) and forces the tier off.
    @Flag(name: .customLong("kv-disk-cache-enabled"), inversion: .prefixedNo, help: "Enable the encrypted KV-cache survival disk tier. Overrides MACPROVIDER_KV_DISK_CACHE_ENABLED and config key kv_disk_cache.enabled. Default off.")
    var kvDiskCacheEnabled: Bool?

    @Flag(name: .customLong("kv-disk-cache-allow-buyer-keys"), inversion: .prefixedNo, help: "Permit buyer-supplied conversation keys in the KV disk tier. Rejected in v0.1 (fails closed, tier disabled). Overrides MACPROVIDER_KV_DISK_CACHE_ALLOW_BUYER_KEYS and config key kv_disk_cache.allow_buyer_keys.")
    var kvDiskCacheAllowBuyerKeys: Bool?

    @Option(name: .customLong("kv-disk-cache-dir"), help: "KV disk-tier directory (absolute; leading ~ expanded). Overrides MACPROVIDER_KV_DISK_CACHE_DIR and config key kv_disk_cache.directory.")
    var kvDiskCacheDir: String?

    @Option(name: .customLong("kv-disk-cache-max-bytes"), help: "KV disk-tier namespace byte cap (>0). Overrides MACPROVIDER_KV_DISK_CACHE_MAX_BYTES and config key kv_disk_cache.max_bytes.")
    var kvDiskCacheMaxBytes: Int?

    @Option(name: .customLong("kv-disk-cache-max-entries"), help: "KV disk-tier max entries (>0). Overrides MACPROVIDER_KV_DISK_CACHE_MAX_ENTRIES and config key kv_disk_cache.max_entries.")
    var kvDiskCacheMaxEntries: Int?

    @Option(name: .customLong("kv-disk-cache-max-entry-bytes"), help: "KV disk-tier per-entry byte cap (>0). Overrides MACPROVIDER_KV_DISK_CACHE_MAX_ENTRY_BYTES and config key kv_disk_cache.max_entry_bytes.")
    var kvDiskCacheMaxEntryBytes: Int?

    @Option(name: .customLong("kv-disk-cache-retention-minutes"), help: "KV disk-tier entry retention in minutes (>0). Overrides MACPROVIDER_KV_DISK_CACHE_RETENTION_MINUTES and config key kv_disk_cache.retention_minutes.")
    var kvDiskCacheRetentionMinutes: Int?

    @Option(name: .customLong("kv-disk-cache-staging-max-bytes"), help: "KV disk-tier read/promotion staging ceiling (>0, ≤256 MiB). Overrides MACPROVIDER_KV_DISK_CACHE_STAGING_MAX_BYTES and config key kv_disk_cache.staging_max_bytes.")
    var kvDiskCacheStagingMaxBytes: Int?

    @Option(name: .customLong("kv-disk-cache-write-staging-max-bytes"), help: "KV disk-tier write/snapshot staging ceiling (>0, ≤1 GiB). Overrides MACPROVIDER_KV_DISK_CACHE_WRITE_STAGING_MAX_BYTES and config key kv_disk_cache.write_staging_max_bytes.")
    var kvDiskCacheWriteStagingMaxBytes: Int?

    @Option(name: .customLong("kv-disk-cache-min-free-bytes"), help: "KV disk-tier minimum free-space floor (≥1 GiB). Overrides MACPROVIDER_KV_DISK_CACHE_MIN_FREE_BYTES and config key kv_disk_cache.min_free_bytes.")
    var kvDiskCacheMinFreeBytes: Int?

    @Option(name: .customLong("kv-disk-cache-promotion-max-s"), help: "KV disk-tier promotion decode deadline in seconds (>0). Overrides MACPROVIDER_KV_DISK_CACHE_PROMOTION_MAX_S and config key kv_disk_cache.promotion_max_seconds.")
    var kvDiskCachePromotionMaxSeconds: Int?

    @Option(name: .customLong("kv-disk-cache-shutdown-drain-s"), help: "KV disk-tier graceful-shutdown drain budget in seconds (≥0). Overrides MACPROVIDER_KV_DISK_CACHE_SHUTDOWN_DRAIN_S and config key kv_disk_cache.shutdown_drain_seconds.")
    var kvDiskCacheShutdownDrainSeconds: Int?

    @Flag(name: .customLong("paged-kv-enabled"), inversion: .prefixedNo, help: "Opt into the provider-local paged KV engine. Default off; activation still requires attach/parity/packaging gates.")
    var pagedKVEnabled: Bool?

    @Option(name: .customLong("paged-kv-block-size-tokens"), help: "Paged KV fixed block size in tokens (>0). Overrides MACPROVIDER_PAGED_KV_BLOCK_SIZE_TOKENS and config key paged_kv.block_size_tokens.")
    var pagedKVBlockSizeTokens: Int?

    @Option(name: .customLong("paged-kv-max-physical-blocks"), help: "Paged KV pool capacity in physical blocks (>0). Overrides MACPROVIDER_PAGED_KV_MAX_PHYSICAL_BLOCKS and config key paged_kv.max_physical_blocks.")
    var pagedKVMaxPhysicalBlocks: Int?

    @Option(name: .customLong("paged-kv-fallback-policy"), help: "Paged KV fallback policy: permissive or strict. Overrides MACPROVIDER_PAGED_KV_FALLBACK_POLICY and config key paged_kv.fallback_policy.")
    var pagedKVFallbackPolicy: String?

    /// SPEC-037 FR-KVP11 (MEDIUM-5): the KV disk-tier CLI overrides assembled from the
    /// parsed `--kv-disk-cache-*` flags. Exposed so tests can assert the flag → override
    /// wiring (and CLI-wins precedence / allow_buyer_keys rejection) without running serve.
    var kvDiskCacheCLIOverrides: KVDiskCacheCLIOverrides {
        KVDiskCacheCLIOverrides(
            enabled: kvDiskCacheEnabled,
            allowBuyerKeys: kvDiskCacheAllowBuyerKeys,
            directory: kvDiskCacheDir,
            maxBytes: kvDiskCacheMaxBytes,
            maxEntries: kvDiskCacheMaxEntries,
            maxEntryBytes: kvDiskCacheMaxEntryBytes,
            retentionMinutes: kvDiskCacheRetentionMinutes,
            stagingMaxBytes: kvDiskCacheStagingMaxBytes,
            writeStagingMaxBytes: kvDiskCacheWriteStagingMaxBytes,
            minFreeBytes: kvDiskCacheMinFreeBytes,
            promotionMaxSeconds: kvDiskCachePromotionMaxSeconds,
            shutdownDrainSeconds: kvDiskCacheShutdownDrainSeconds
        )
    }

    var pagedKVCLIOverrides: PagedKVCLIOverrides {
        PagedKVCLIOverrides(
            enabled: pagedKVEnabled,
            blockSizeTokens: pagedKVBlockSizeTokens,
            maxPhysicalBlocks: pagedKVMaxPhysicalBlocks,
            fallbackPolicy: pagedKVFallbackPolicy
        )
    }

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

    /// Round-2 code MEDIUM-3: autotune candidates must not use speculative
    /// decoding. The serve-stream speculative path (`collectSpeculativeText`)
    /// owns its own decode loop and never fires the outer `decodeTimer`, so a
    /// candidate launched with a configured draft model would emit
    /// `macprovider_generation_ms: null` and the Stage 1/2 probe would silently
    /// fall back to client timing (which cannot see a reasoning model's
    /// suppressed decode window). Force speculative decoding OFF for candidates
    /// by clearing the resolved draft model so the probe always exercises the
    /// main, timed decode path. Incumbent serve is untouched.
    static func applyAutotuneCandidateDraftSuppression(
        _ resolved: inout AppConfig,
        autotuneCandidate: Bool
    ) {
        guard autotuneCandidate else { return }
        resolved.draftModel = nil
        resolved.draftModelArtifactSHA256 = nil
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
        if let maxBatch = resolved.maxConcurrencyOverride,
           maxBatch > ProviderCapacity.maxConcurrencyOverrideLimit {
            FileHandle.standardError.write(Data((
                "--max-batch \(maxBatch) must be <= \(ProviderCapacity.maxConcurrencyOverrideLimit)\n"
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
        if resolved.continuousBatching != .off {
            if let queueLimit = resolved.continuousBatchQueueLimit, queueLimit < 1 {
                FileHandle.standardError.write(Data((
                    "--continuous-batch-queue-limit \(queueLimit) must be >= 1\n"
                ).utf8))
                throw ExitCode(2)
            }
            let maximumContinuousBatchQueueLimit = ContinuousBatchingPolicy.maximumQueueLimit(
                maxActiveRows: resolved.maxConcurrencyOverride ?? 1
            )
            if let queueLimit = resolved.continuousBatchQueueLimit,
               queueLimit > maximumContinuousBatchQueueLimit {
                FileHandle.standardError.write(Data((
                    "--continuous-batch-queue-limit \(queueLimit) must be <= \(maximumContinuousBatchQueueLimit) for the configured max batch\n"
                ).utf8))
                throw ExitCode(2)
            }
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
        for error in resolved.pagedKV.errors {
            FileHandle.standardError.write(Data(("paged_kv: \(error)\n").utf8))
        }
        if resolved.pagedKV.effectiveEnabled && resolved.pagedKV.fallbackPolicy == .strict {
            FileHandle.standardError.write(Data((
                "\(Self.pagedKVStrictStartupRejectEvent)\n"
                + "paged_kv strict fallback is unavailable until packaged metallib, kernel, parity, and sizing proof are installed\n"
            ).utf8))
            throw ExitCode(2)
        }
    }

    static func runContinuousBatchingPreflight(_ resolved: AppConfig) throws {
        let capability = ContinuousBatchingPolicy.configurationCapability(
            mode: resolved.continuousBatching,
            maxBatch: resolved.maxConcurrencyOverride ?? 1,
            queueLimit: resolved.continuousBatchQueueLimit,
            kvBits: resolved.kvBitsOverride,
            draftConfigured: resolved.draftModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        )
        if resolved.continuousBatching == .canary {
            ContinuousBatchingPolicy.logSerialRouteIfNeeded(capability)
        }
        do {
            try ContinuousBatchingPolicy.validateStrictStartup(capability)
        } catch let error as APIError {
            FileHandle.standardError.write(Data("\(error.code): \(error.message)\n".utf8))
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

        let pairedRecommendationInputs = requireRecommendable
            ? await staticInputs.loadRecommendationInputs()
            : nil
        let expectedPublicModel: String
        if requireRecommendable {
            let rateCard = pairedRecommendationInputs!.rateCard
            let rateCardTrustBlockingWarnings: Set<AutotuneRecommendWarning> = [
                .rateCardIntegrityFailure,
                .rateCardUpdateRequired,
            ]
            if !rateCardTrustBlockingWarnings.isDisjoint(with: rateCard.warnings) {
                let state = rateCard.warnings.contains(.rateCardIntegrityFailure)
                    ? "rate_card_integrity_failure"
                    : "rate_card_update_required"
                FileHandle.standardError.write(Data("\(state): refusing coordinator join with an untrusted or incompatible rate-card release\n".utf8))
                throw ExitCode(2)
            }
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

        let catalog: AutotuneStaticSelection<CandidateCatalog>
        if let pairedRecommendationInputs {
            catalog = pairedRecommendationInputs.candidate
        } else {
            catalog = await staticInputs.loadCandidateCatalog()
        }
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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        candidateRootDirectory: URL? = nil
    ) -> ProviderLifecycleStateStore {
        let url: URL
        if autotuneCandidate, let candidateRootDirectory {
            url = ProviderLifecycleStateStore.candidateURL(rootDirectory: candidateRootDirectory)
        } else if autotuneCandidate {
            url = ProviderLifecycleStateStore.candidateURL(homeDirectory: homeDirectory)
        } else {
            url = ProviderLifecycleStateStore.defaultURL(homeDirectory: homeDirectory)
        }
        return ProviderLifecycleStateStore(url: url)
    }

    /// Make a fresh owner-only root for one candidate process. The random
    /// final component prevents a same-user process from pre-seeding a
    /// predictable lifecycle, lease, or control path in the temporary area.
    static func makeCandidateIsolationRoot(
        // macOS AF_UNIX paths are capped at 104 bytes. The system temporary
        // directory is often nested under a long per-user path, so use the
        // short system temp root for the fresh random leaf.
        temporaryDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    ) throws -> URL {
        let root = temporaryDirectory.appendingPathComponent(
            "macprovider-autotune-" + UUID().uuidString.lowercased(),
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw NSError(
                domain: "ServeCommand",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "candidate isolation directory creation failed"]
            )
        }
        var info = stat()
        guard lstat(root.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(
                domain: "ServeCommand",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "candidate isolation directory is unsafe"]
            )
        }
        return root
    }

    /// Candidate providers are short-lived local probe processes. Give them
    /// their own control/switch paths so an autotune run cannot bind the
    /// incumbent's operator socket or mutate its model-switch marker.
    static func candidateControlSocketPath(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        processID: Int32 = getpid()
    ) -> String {
        temporaryDirectory
            .appendingPathComponent("macprovider-cli", isDirectory: true)
            .appendingPathComponent("autotune-candidate-\(processID).ctl.sock")
            .path
    }

    static func candidateControlSocketPath(rootDirectory: URL) -> String {
        rootDirectory.appendingPathComponent("control.sock").path
    }

    static func candidateSwitchStatePath(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        processID: Int32 = getpid()
    ) -> String {
        temporaryDirectory
            .appendingPathComponent("macprovider-cli", isDirectory: true)
            .appendingPathComponent("autotune-candidate-\(processID).switch.ts")
            .path
    }

    static func candidateSwitchStatePath(rootDirectory: URL) -> String {
        rootDirectory.appendingPathComponent("switch.ts").path
    }

    func run() async throws {
        // #616/#610: repair a stale PATH regular-file entrypoint to install
        // authority, then re-exec into that canonical binary when this process
        // was launched from a non-canonical path. PATH repair alone does not
        // replace the already-running stale inode; identity must freeze on the
        // binary that matches the signed set's provider_cli member.
        let serveMarkerStore = AutoUpdateMarkerStore()
        if !autotuneCandidate,
           let canonical = try serveMarkerStore.ensurePathEntrypointMatchesInstallAuthority(),
           let launched = Bundle.main.executableURL?.standardizedFileURL,
           launched.path != canonical.standardizedFileURL.path {
            try execCanonicalInstall(canonical)
        }

        // v1.8.53 can leave its one-shot reload helper alive long enough to
        // restart the newly installed target repeatedly. The target fences that
        // helper before configuration/model work, but only while two durable
        // authorities agree that this exact executable is the intended
        // self-update child. Ordinary launches never touch reload jobs.
        let startupReloadFenceAuthorized = autotuneCandidate
            ? false
            : try Self.fenceAuthorizedSelfUpdateReloadJobsAtStartup()

        var resolved = try ConfigLoader.load(
            cli: CLIOverrides(
                port: port,
                model: model,
                modelArtifactPath: modelArtifactPath,
                modelArtifactSHA256: modelArtifactSha256,
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
                prefillStepSize: prefillStepSize,
                // SPEC-037 FR-KVP11 (MEDIUM-5): forward the KV disk-tier flags so the
                // triple-source config surface (CLI → env → YAML) is complete.
                kvDiskCache: kvDiskCacheCLIOverrides,
                continuousBatching: continuousBatching,
                continuousBatchQueueLimit: continuousBatchQueueLimit,
                pagedKV: pagedKVCLIOverrides
            )
        )

        // Reject invalid invocation-only model catalogs before startup writes
        // lifecycle state or touches credential custody. The complete startup
        // preflight bundle repeats this idempotent check after acquiring its
        // dependencies so direct callers retain the same validation contract.
        try Self.runSupportedModelsPreflight(&resolved)

        // Round-2 code MEDIUM-3: clear the resolved draft model for autotune
        // candidates so the speculative route is never taken and the probe
        // exercises the main, timed decode path. Applied before the draft-model
        // capacity/artifact preflights and ModelRuntime construction so nothing
        // downstream sees a draft model for a candidate.
        Self.applyAutotuneCandidateDraftSuppression(&resolved, autotuneCandidate: autotuneCandidate)

        let candidateIsolationRoot = autotuneCandidate
            ? try Self.makeCandidateIsolationRoot()
            : nil
        defer {
            if let candidateIsolationRoot {
                try? FileManager.default.removeItem(at: candidateIsolationRoot)
            }
        }

        if autotuneCandidate {
            // A candidate must be a local, credential-free subprocess. Its
            // parent may use the production YAML for model/catalog inputs, but
            // the child must never resolve provider identity, bearer custody,
            // receipts, coordinator URLs, or incumbent control paths.
            resolved.providerID = nil
            resolved.providerToken = nil
            resolved.coordinatorURL = nil
            resolved.enableReceipts = false
            guard let candidateIsolationRoot else {
                throw ValidationError("candidate isolation root unavailable")
            }
            resolved.ctlSocketPath = Self.candidateControlSocketPath(rootDirectory: candidateIsolationRoot)
            resolved.switchStatePath = Self.candidateSwitchStatePath(rootDirectory: candidateIsolationRoot)
        }

        // Candidate lifecycle, lease, and singleton-lock files all live under
        // the fresh owner-only root. This keeps a probe from fencing,
        // replacing, or being mistaken for the installed provider.
        let lifecycleStateStore = Self.lifecycleStateStore(
            autotuneCandidate: autotuneCandidate,
            candidateRootDirectory: candidateIsolationRoot
        )
        let lifecycleLeaseStore = candidateIsolationRoot.map {
            ProviderLifecycleLeaseStore(url: ProviderLifecycleLeaseStore.candidateURL(rootDirectory: $0))
        } ?? ProviderLifecycleLeaseStore()
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
        let credentialStatus: ProviderCredentialStatus
        if autotuneCandidate {
            _ = try lifecycleStateStore.transition(
                to: .importingCredentials,
                reasonCode: "candidate_credentials_skipped",
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
            credentialStatus = .unconfigured
        } else {
            _ = try lifecycleStateStore.transition(
                to: .importingCredentials,
                reasonCode: "resolving_cli_keychain_custody",
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
            credentialStatus = try ProviderCredentialResolver.resolve(
                config: &resolved,
                store: credentialStore
            )
        }
        if !autotuneCandidate {
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
                acquireServeLock: { candidateConfig in
                    try Self.acquireProviderServeLock(
                        candidateConfig,
                        directory: candidateIsolationRoot?.appendingPathComponent("locks", isDirectory: true)
                            ?? ProviderServeLock.defaultDirectory()
                    )
                },
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
            FileHandle.standardError.write(Data(("provider startup preflight failed: \(error)\n").utf8))
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
                pagedKVConfig: resolved.pagedKV,
                prefillStepSize: resolved.prefillStepSize,
                maxBatch: resolved.maxConcurrencyOverride ?? 1,
                continuousBatchingMode: resolved.continuousBatching,
                continuousBatchQueueLimit: resolved.continuousBatchQueueLimit,
                warmSwapEnabled: resolved.enableWarmSwap,
                swapDrainTimeoutSeconds: resolved.swapDrainTimeoutSeconds,
                catalogModelIDAlias: catalogModelIDAlias,
                verifiedModelArtifactSHA256: resolved.modelArtifactSHA256,
                // MEDIUM-5 (FR-KVP4): thread the catalog REVISION separately from the
                // artifact SHA so the cold-tier envelope carries both as distinct identity
                // fields; nil ⇒ cold tier treats identity as unavailable (no promote/persist).
                verifiedModelCatalogRevision: resolved.modelCatalogRevision
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
            FileHandle.standardError.write(Data(("provider model load failed: \(error)\n").utf8))
            throw error
        }
        // SPEC-037 stage 5 (FR-KVP7/KVP11) — activate the encrypted KV survival
        // disk tier when enabled, then hand the serve-owned, lock-holding store to
        // the model runtime (data path) and the control socket (in-process
        // purge/status). Fail-closed: activation failure leaves the tier off and
        // never blocks the serve loop. A disabled tier is not activated here, so a
        // standalone `macprovider-cli kv-cache` invocation can acquire the free
        // namespace lock itself.
        // LOW (FR-KVP11): surface resolver errors that force the tier off BEFORE the
        // effectiveEnabled guard. When effectiveEnabled is false because errors were
        // recorded (e.g. allow_buyer_keys=true, or an out-of-bound knob), activation is
        // skipped entirely — so the only logging site (inside activateForServeDetailed)
        // never runs and the operator gets no signal. Emit each error here so a
        // fail-closed disable (incl. the allow_buyer_keys precondition text) is visible.
        if !resolved.kvDiskCache.errors.isEmpty {
            for error in resolved.kvDiskCache.errors {
                FileHandle.standardError.write(Data(("kv_disk_cache config error: \(error)\n").utf8))
            }
        }
        var kvDiskTier: KVDiskTier?
        if resolved.kvDiskCache.effectiveEnabled,
           let kvProviderID = resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !kvProviderID.isEmpty {
            let kvTTL = Int(ConversationCache.Config.fromEnvironment().ttlSeconds)
            let tier = KVDiskTier(config: resolved.kvDiskCache, namespaceID: kvProviderID, eligibilityTTLSeconds: kvTTL)
            switch await tier.activateForServeDetailed() {
            case .activated:
                await modelRuntime.attachKVDiskTier(tier)
                kvDiskTier = tier
            case .dormantLock, .dormantKeychain:
                // FR-KVP7 (M-13): the namespace lock is held by another writer, OR
                // (Item 6 / FR-KVP6) the Keychain is unavailable pre-unlock — keep the
                // tier and retry with bounded backoff in the background, running full
                // recovery and attaching once the condition clears.
                kvDiskTier = tier
                Task { [modelRuntime] in
                    await tier.retryActivationUntilAcquired { await modelRuntime.attachKVDiskTier(tier) }
                }
            case .quarantined, .disabled:
                break
            }
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
        let installedCompatibilityManifest: CompatibilitySetManifest? = autotuneCandidate
            ? nil
            : try { () throws -> CompatibilitySetManifest? in
                let launched = Bundle.main.executableURL
                let canonical = serveMarkerStore.resolveCanonicalInstallBinary(launchedExecutableURL: launched)
                if let installed = CompatibilitySetManifest.loadInstalledPreferringInstallAuthority(
                    launchedExecutableURL: launched,
                    canonicalBinaryURL: canonical,
                    expectedVersion: CoordinatorClient.binaryVersion,
                    allowProviderVersionMismatch: false
                ) {
                    return installed
                }
                // Fail closed when a sibling/canonical manifest exists but is invalid.
                let authority = canonical ?? CompatibilitySetManifest.resolvedExecutableURL(launched)
                guard let directory = CompatibilitySetManifest.payloadDirectory(for: authority) else { return nil }
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
        let socketURL = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        let watchdogCleanup = ControlSocketWatchdogCleanup(socketPath: socketURL)
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
                operatorPausedInitially: operatorPausedInitially,
                watchdogExitPreparation: {
                    watchdogCleanup.prepareForWatchdogExit()
                }
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
            resumeProvider: resumeProvider,
            watchdogCleanup: coordinatorClient == nil ? nil : watchdogCleanup,
            kvDiskTier: kvDiskTier
        )
        do {
            try await controlSocket?.start()
        } catch {
            if let serverError = error as? ControlSocketServerError,
               serverError != .staleSocket(path: socketURL.path) {
                FileHandle.standardError.write(Data(("\(serverError.description)\n").utf8))
            } else if !(error is ControlSocketServerError) {
                FileHandle.standardError.write(Data(("provider control socket failed: \(error)\n").utf8))
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
        let terminationHandlers = installTerminationHandlers(coordinatorClient: coordinatorClient, controlSocket: controlSocket, idlePrewarmer: idlePrewarmer, kvDiskTier: kvDiskTier)
        defer {
            Task { [kvDiskTier] in
                await idlePrewarmer.stop()
                await controlSocket?.stop()
                await coordinatorClient?.stop()
                // M-A: flush queued cold writes + release the namespace lock on the
                // normal serve-teardown path as well.
                await kvDiskTier?.shutdown()
            }
            terminationHandlers.forEach { $0.cancel() }
        }
        try withExtendedLifetime(terminationHandlers) {
            do {
                try server.run()
            } catch {
                FileHandle.standardError.write(Data(("provider HTTP server stopped: \(error)\n").utf8))
                throw error
            }
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

    static func acquireProviderServeLock(
        _ config: AppConfig,
        directory: URL = ProviderServeLock.defaultDirectory()
    ) throws -> ProviderServeLock {
        do {
            return try ProviderServeLock.acquire(
                providerID: config.providerID,
                port: config.port,
                directory: directory
            )
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
        acquireServeLock: (AppConfig) throws -> ProviderServeLock = { config in
            try Self.acquireProviderServeLock(config)
        },
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
        acquireServeLock: (AppConfig) throws -> ProviderServeLock = { config in
            try Self.acquireProviderServeLock(config)
        }
    ) throws -> ProviderServeLock {
        try Self.runSupportedModelsPreflight(&resolved)
        try Self.runDrainTimeoutPreflight(resolved)
        try Self.runServingKnobsPreflight(resolved)
        try Self.runSpecDecodeHeartbeatCompatibilityPreflight(
            resolved,
            coordinatorAcceptsSpecDecodeTelemetry: coordinatorAcceptsSpecDecodeTelemetry
        )
        try Self.runSpecDecodeCapacityPreflight(&resolved)
        try Self.runContinuousBatchingPreflight(resolved)

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

    @Flag(help: "Print the raw local status JSON for diagnostics and support.")
    var json = false

    func run() async throws {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(port: port, configPath: config)
        )
        let status = try await LocalStatusClient.fetch(port: resolved.port)
        if json {
            try Self.writeJSON(status)
            return
        }
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

    static func writeJSON(_ payload: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
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

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model. When this disagrees with config model_artifact_path, the CLI model wins and the configured artifact binding is cleared (#745).")
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
        // #616/#610: converge PATH, then hand off to the canonical install binary
        // when this process was launched from a divergent PATH copy so update
        // runs with sibling compatibility-set.json and matching provider_cli.
        let updateMarkerStore = AutoUpdateMarkerStore()
        if let canonical = try updateMarkerStore.ensurePathEntrypointMatchesInstallAuthority(),
           let launched = Bundle.main.executableURL?.standardizedFileURL,
           launched.path != canonical.standardizedFileURL.path {
            try execCanonicalInstall(canonical)
        }
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

/// Replaces this process with the canonical install binary and the same argv
/// after PATH entrypoint repair (#616). Used by serve/update when launched from
/// a stale `~/.local/bin` regular-file copy.
private func execCanonicalInstall(_ canonical: URL) throws -> Never {
    let argv = [canonical.path] + Array(CommandLine.arguments.dropFirst())
    let cArgs = argv.map { strdup($0) } + [nil]
    defer {
        for pointer in cArgs where pointer != nil {
            free(pointer)
        }
    }
    _ = execv(canonical.path, cArgs)
    throw ValidationError(
        "failed to hand off to canonical install at \(canonical.path) (errno=\(errno))"
    )
}

private func installTerminationHandlers(
    coordinatorClient: CoordinatorClient?,
    controlSocket: ControlSocketServer?,
    idlePrewarmer: IdlePrewarmer?,
    kvDiskTier: KVDiskTier?
) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            Task {
                await idlePrewarmer?.stop()
                await controlSocket?.stop()
                await coordinatorClient?.drainAndExit(reason: "\(signalName(signalNumber)) received")
                // M-A: drain queued cold writes (bounded by shutdownDrainSeconds) and
                // release the namespace lock BEFORE exit, on the signal path too.
                await kvDiskTier?.shutdown()
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
    print("  continuous_batching: \(config.continuousBatching.rawValue)")
    print("  continuous_batch_queue_limit: \(config.continuousBatchQueueLimit.map(String.init) ?? "<unset, 2 * max_batch>")")
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
