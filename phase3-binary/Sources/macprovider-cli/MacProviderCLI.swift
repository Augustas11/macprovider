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
        commandName: "malibu-cli",
        abstract: "OpenAI-compatible Malibu (Mac Provider) inference CLI.",
        version: CoordinatorClient.binaryVersion,
        subcommands: [ServeCommand.self, SelfTestCommand.self, StatusCommand.self, ProviderCommand.self, ClaimCommand.self, CreatorCommand.self, RestartCommand.self, UpdateCommand.self, UninstallCommand.self, ModelsCommand.self, AutotuneCommand.self, BootstrapAuthCommand.self, RotateKeyCommand.self, CredentialsCommand.self, LifecycleStateCommand.self, RecoverUpdateCommand.self, LifecycleLeaseCommand.self, Spec028CanaryCommand.self, Spec028BenchmarkCommand.self, LegacySpec028CanaryCommand.self, LegacySpec028BenchmarkCommand.self, DecodeBenchCommand.self] + labSubcommands() + [MSBThroughputCommand.self, MSBLoopbackCommand.self, MSBOllamaLoopbackCommand.self, MSBPerplexityCommand.self, EnrollCommand.self, ReleasePayloadPreflightCommand.self, KVCacheCommand.self, DoctorCommand.self, PayoutAddressCommand.self, ConsumeCommand.self, RelayBlindKeyCommand.self] + fixtureSubcommands() + [PrivacyClassCommand.self],
        defaultSubcommand: ServeCommand.self
    )

    /// The relay-blind fixture exists only in debug/test builds
    /// (MACPROVIDER_TEST_FIXTURES); a release binary registers none.
    private static func fixtureSubcommands() -> [ParsableCommand.Type] {
        #if MACPROVIDER_TEST_FIXTURES
        return [RelayBlindFixtureCommand.self]
        #else
        return []
        #endif
    }

    /// Lab-only native-MTP harnesses exist only in DEBUG or explicit
    /// MACPROVIDER_LAB_HARNESS builds; a plain release binary registers none.
    private static func labSubcommands() -> [ParsableCommand.Type] {
        #if DEBUG || MACPROVIDER_LAB_HARNESS
        return [NativeMTPHardwareE2ECommand.self, NativeMTPBenchCommand.self, NativeMTPJourneyE2ECommand.self, NativeMTPRequestShapeReplayCommand.self]
        #else
        return []
        #endif
    }
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

/// F3 (#1363): a first-class, serve-independent escape from a wedged,
/// abandoned auto-update transaction. A failed self-update can leave
/// `pending.json` in `restoring_previous` and an updater-owned
/// `rollback_in_progress` lifecycle record, which fences both `serve` and
/// `update`. This command recovers the expired transaction in place — restoring
/// the previous release and translating the dead updater-owned record into an
/// installer-owned one that `serve` may leave — without needing `serve` to be
/// up. It never un-fences a genuinely in-progress update/rollback (see
/// `WedgedUpdateRecovery`).
struct RecoverUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover-update",
        abstract: "Clear a wedged, abandoned auto-update transaction (expired restoring_previous / rollback_in_progress) so the provider can serve again. Safe to run from a fresh CLI while serve is down; a genuinely in-progress update/rollback is left untouched."
    )

    func run() throws {
        let recovery = WedgedUpdateRecovery(
            markerStore: AutoUpdateMarkerStore(),
            lifecycleStore: ProviderLifecycleStateStore()
        )
        let outcome = recovery.recover()
        var payload: [String: Any] = ["command": "recover-update"]
        var failureExit: Int32?
        switch outcome {
        case .noWedge:
            payload["outcome"] = "no_wedge"
            payload["recovered"] = false
            payload["message"] = "no abandoned auto-update transaction was found; nothing to recover"
        case .ownerLive:
            payload["outcome"] = "owner_live"
            payload["recovered"] = false
            payload["message"] = "a live installer or updater holds the provider mutation lock; retry after it exits"
            failureExit = 4
        case .transactionActive:
            payload["outcome"] = "transaction_active"
            payload["recovered"] = false
            payload["message"] = "a pending update/rollback deadline is still in the future; this is not an abandoned wedge"
            failureExit = 4
        case let .recovered(markerOutcome, lifecycleUnfenced):
            payload["outcome"] = "recovered"
            payload["recovered"] = true
            payload["marker_recovered"] = markerOutcome != nil
            payload["lifecycle_unfenced"] = lifecycleUnfenced
            payload["marker_result"] = Self.describe(markerOutcome)
            payload["message"] = "recovered the abandoned transaction; run `serve` (or let launchd restart it) to return to serving"
        }
        try LifecycleStateStatusCommand.writeJSON(payload)
        if let failureExit {
            throw ExitCode(failureExit)
        }
    }

    private static func describe(_ outcome: AutoUpdateOrphanRecoveryOutcome?) -> String {
        guard let outcome else { return "none" }
        switch outcome {
        case .restored:
            return "restored_previous"
        case .restoredAwaitingReadiness:
            return "restored_previous_awaiting_readiness"
        case .markerInvalid:
            return "marker_invalid_quarantined"
        case .backupCorrupt:
            return "backup_corrupt_quarantined"
        case .rollbackTargetDisallowed:
            return "rollback_target_disallowed"
        }
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

    @Option(name: .customLong("native-mtp"), help: "Native multi-token prediction mode: off or auto. Default off. Overrides MACPROVIDER_NATIVE_MTP_MODE and config key native_mtp_mode.")
    var nativeMTP: String?

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

    @Flag(name: .customLong("relay-blind-enabled"), inversion: .prefixedNo, help: "Opt into the default-off relay-blind request encryption pilot.")
    var relayBlindEnabled: Bool?

    @Flag(name: .customLong("privacy-class-beta"), inversion: .prefixedNo, help: "Opt into the default-off operator-constrained privacy class. Requires relay-blind. Overrides MACPROVIDER_PRIVACY_CLASS_BETA and config key privacy_class_beta.")
    var privacyClassBeta: Bool?

    @Option(name: .customLong("relay-blind-state-directory"), help: "Absolute operator-owned 0700 directory outside the repository for relay-blind keys and execution journal.")
    var relayBlindStateDirectory: String?

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

    @Option(help: "Provider credential store: keychain or protected_file. Defaults to keychain. Overrides MACPROVIDER_CREDENTIAL_STORE and config key credential_store.")
    var credentialStore: String?

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

    @Option(help: "Continuous batching mode: off, canary, or on. When unset, verified signed model capability policy selects the rollout automatically. Explicit off is the emergency override. Explicit canary/on cannot bypass signed tuple authorization or local paged-KV proofs. Overrides MACPROVIDER_CONTINUOUS_BATCHING and config key continuous_batching.")
    var continuousBatching: String?

    @Option(help: "Bounded continuous-batching waiting queue limit. Default 2 * active slots. Overrides MACPROVIDER_CONTINUOUS_BATCH_QUEUE_LIMIT and config key continuous_batch_queue_limit.")
    var continuousBatchQueueLimit: Int?

    @Option(help: "Bounded continuous-batching admission wait in milliseconds. Default 30000. A request still queued when it expires is rejected pre-admission and never settles. Overrides MACPROVIDER_CONTINUOUS_BATCH_QUEUE_WAIT_TIMEOUT_MS and config key continuous_batch_queue_wait_timeout_ms.")
    var continuousBatchQueueWaitTimeoutMS: Int?

    @Option(help: "Continuous-batching prefill per-iteration token budget (across compatible rows). Default 1024. Operator tuning/observability knob: a Studio sweep found this total budget non-binding for TTFT (single-stream prefill is compute-bound; the per-row prefill_step_size is the lever), so raising it does not by itself cut large-prompt TTFT. Overrides MACPROVIDER_CONTINUOUS_BATCH_PREFILL_TOKENS_PER_ITERATION and config key continuous_batch_prefill_tokens_per_iteration.")
    var continuousBatchPrefillTokensPerIteration: Int?

    @Flag(name: .customLong("continuous-batching-cached-turns"), inversion: .prefixedNo, help: "Let a positive-cached follow-up turn with a usable retained paged-KV handoff (plus a recurrent checkpoint on hybrid models) batch instead of serial-routing. Default off. Inert while continuous batching is off. Overrides MACPROVIDER_CONTINUOUS_BATCHING_CACHED_TURNS and config key continuous_batching_cached_turns.")
    var continuousBatchingCachedTurns: Bool?

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

    @Option(name: .customLong("kv-disk-cache-staging-max-bytes"), help: "KV disk-tier read/promotion staging ceiling (>0, ≤1 GiB). Overrides MACPROVIDER_KV_DISK_CACHE_STAGING_MAX_BYTES and config key kv_disk_cache.staging_max_bytes.")
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

    @Flag(name: .customLong("isolate-lifecycle"), help: "Keep launchd/lease/control files off the live 8080 incumbent while still joining a coordinator. Requires --credential-store protected_file. Lab only.")
    var isolateLifecycle = false

    @Flag(name: .customLong("lab-identity-scope"), help: "Use an isolated privacy lab identity scope. Requires --isolate-lifecycle, protected_file credentials, a literal loopback coordinator, and an explicit 0700 relay-blind state root.")
    var labIdentityScope = false

    @Option(name: .customLong("privacy-lab-config-change-checkpoint-fd"), help: .private)
    var privacyLabConfigChangeCheckpointFD: Int?

    // Internal marker for CandidateProviderRunner. Stage 1 owns warmup and
    // throughput measurement for these non-joining subprocesses.
    @Flag(name: .customLong("autotune-candidate"), help: .private)
    var autotuneCandidate = false

    mutating func validate() throws {
        guard !autotuneCandidate || noJoin else {
            throw ValidationError("--autotune-candidate requires --no-join")
        }
        if isolateLifecycle && autotuneCandidate {
            throw ValidationError("--isolate-lifecycle is incompatible with --autotune-candidate")
        }
        if labIdentityScope && !isolateLifecycle {
            throw ValidationError("--lab-identity-scope requires --isolate-lifecycle")
        }
        if privacyLabConfigChangeCheckpointFD != nil {
            guard labIdentityScope else {
                throw ValidationError("--privacy-lab-config-change-checkpoint-fd requires --lab-identity-scope")
            }
            guard isolateLifecycle else {
                throw ValidationError("--privacy-lab-config-change-checkpoint-fd requires --isolate-lifecycle")
            }
            guard !noJoin else {
                throw ValidationError("--privacy-lab-config-change-checkpoint-fd requires coordinator join")
            }
            guard !autotuneCandidate else {
                throw ValidationError("--privacy-lab-config-change-checkpoint-fd is incompatible with --autotune-candidate")
            }
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

    /// Builds the same target authority used by `models list --json` to report
    /// local weights. A supported-model string is only a policy hint; a warm
    /// switch target also needs a signed catalog row and a locally verified
    /// artifact snapshot. Keeping this map at serve startup prevents the list
    /// command and the runtime from disagreeing about what Ready means.
    static func localRuntimeTargetAuthorities(
        supportedModels: [String]?,
        artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver(),
        onVerifiedTarget: ((_ ids: [String], _ row: CandidateCatalog.Row, _ artifact: VerifiedModelArtifact) -> Void)? = nil
    ) -> [String: ModelRuntimeTargetAuthority] {
        guard let supportedModels, !supportedModels.isEmpty,
              let catalog = try? AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(
                  Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
              ) else { return [:] }

        var authorities: [String: ModelRuntimeTargetAuthority] = [:]
        for target in supportedModels {
            let targetKey = target.lowercased(with: nil)
            guard let catalogEntry = catalog.rows.first(where: { entry in
                entry.key.lowercased(with: nil) == targetKey
                    || entry.value.modelID.lowercased(with: nil) == targetKey
            }),
            let revision = catalogEntry.value.modelRevision,
            let artifactSHA256 = catalogEntry.value.modelSHA256,
            let artifact = try? artifactResolver.verifiedExistingArtifact(for: catalogEntry.value)
            else { continue }

            let authority = ModelRuntimeTargetAuthority(
                modelArgument: artifact.modelArgument,
                artifactSHA256: artifactSHA256,
                catalogRevision: revision
            )
            authorities[target] = authority
            authorities[target.lowercased(with: nil)] = authority
            authorities[catalogEntry.value.modelID] = authority
            authorities[catalogEntry.value.modelID.lowercased(with: nil)] = authority
            authorities[catalogEntry.key] = authority
            authorities[catalogEntry.key.lowercased(with: nil)] = authority
            onVerifiedTarget?([target, catalogEntry.value.modelID, catalogEntry.key], catalogEntry.value, artifact)
        }
        return authorities
    }

    static func localRuntimeTargetModelIDs(
        supportedModels: [String]?,
        authorities: [String: ModelRuntimeTargetAuthority]
    ) -> [String] {
        guard let supportedModels else { return [] }
        var seen = Set<String>()
        return supportedModels.filter { modelID in
            let key = modelID.lowercased(with: nil)
            guard authorities[modelID] != nil || authorities[key] != nil else { return false }
            return seen.insert(key).inserted
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

    static func applySpeculativeSafetyGate(
        _ resolved: inout AppConfig,
        cacheWrapValidated: Bool
    ) {
        guard !cacheWrapValidated else { return }
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
                maxActiveRows: ProviderCapacity.servedSlotCount(maxConcurrencyOverride: resolved.maxConcurrencyOverride)
            )
            if let queueLimit = resolved.continuousBatchQueueLimit,
               queueLimit > maximumContinuousBatchQueueLimit {
                FileHandle.standardError.write(Data((
                    "--continuous-batch-queue-limit \(queueLimit) must be <= \(maximumContinuousBatchQueueLimit) for the configured max batch\n"
                ).utf8))
                throw ExitCode(2)
            }
        }
        // Validated whether or not batching is on: a supplied value that cannot
        // be applied must stop startup, never fall back to MLX's unbounded
        // default cache or an effectively unbounded admission wait.
        if let cacheLimitMB = resolved.mlxCacheLimitMB,
           !ModelRuntime.isValidMLXCacheLimitMB(cacheLimitMB) {
            FileHandle.standardError.write(Data((
                "mlx_cache_limit_mb \(cacheLimitMB) must be in 0...\(ModelRuntime.maximumMLXCacheLimitMB)\n"
            ).utf8))
            throw ExitCode(2)
        }
        if let queueWaitTimeoutMS = resolved.continuousBatchQueueWaitTimeoutMS,
           !(1 ... ContinuousBatchSchedulerConfiguration.maximumQueueWaitTimeoutMS).contains(queueWaitTimeoutMS) {
            FileHandle.standardError.write(Data((
                "--continuous-batch-queue-wait-timeout-ms \(queueWaitTimeoutMS) must be in 1...\(ContinuousBatchSchedulerConfiguration.maximumQueueWaitTimeoutMS)\n"
            ).utf8))
            throw ExitCode(2)
        }
        if let prefillBudget = resolved.continuousBatchPrefillTokensPerIteration,
           !(1 ... ContinuousBatchSchedulerConfiguration.maximumPrefillTokensPerIteration).contains(prefillBudget) {
            FileHandle.standardError.write(Data((
                "--continuous-batch-prefill-tokens-per-iteration \(prefillBudget) must be in 1...\(ContinuousBatchSchedulerConfiguration.maximumPrefillTokensPerIteration)\n"
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
            maxBatch: ProviderCapacity.servedSlotCount(maxConcurrencyOverride: resolved.maxConcurrencyOverride),
            queueLimit: resolved.continuousBatchQueueLimit,
            kvBits: resolved.kvBitsOverride,
            draftConfigured: resolved.draftModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        )
        if resolved.continuousBatching == .canary {
            ContinuousBatchingPolicy.logSerialRouteIfNeeded(capability)
        }
        if let line = continuousBatchingCachedTurnsPreflightLine(resolved) {
            FileHandle.standardError.write(Data(line.utf8))
        }
        do {
            try ContinuousBatchingPolicy.validateStrictStartup(capability)
        } catch let error as APIError {
            FileHandle.standardError.write(Data("\(error.code): \(error.message)\n".utf8))
            throw ExitCode(2)
        }
    }

    /// SPEC-038 AC-26: an opt-in cached-turns flag is always announced, and
    /// named inert when batching itself is off, so an operator never mistakes a
    /// no-op flag for enabled cached-turn batching.
    static func continuousBatchingCachedTurnsPreflightLine(_ resolved: AppConfig) -> String? {
        guard resolved.continuousBatchingCachedTurns else { return nil }
        if resolved.continuousBatching == .off {
            return "event=batching_cached_turns action=inert reason=continuous_batching_off\n"
        }
        return "event=batching_cached_turns action=enabled mode=\(resolved.continuousBatching.rawValue)\n"
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

    static func runSpecDecodeCapacityPreflight(
        _ resolved: inout AppConfig,
        physicalMemoryGB: Int = ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil).ramGB
    ) throws {
        guard resolved.draftModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        let draftCap = ProviderCapacity.draftContextCap(forPhysicalMemoryGB: physicalMemoryGB)
        if let explicit = resolved.maxContextOverride, explicit > draftCap {
            FileHandle.standardError.write(Data("draft_model_capacity_shortfall: --max-context \(explicit) exceeds draft-enabled cap \(draftCap)\n".utf8))
            throw ExitCode(2)
        }
        if let explicit = resolved.maxConcurrencyOverride, explicit > 1 {
            FileHandle.standardError.write(Data("draft_model_capacity_shortfall: --max-batch \(explicit) exceeds draft-enabled cap 1\n".utf8))
            throw ExitCode(2)
        }
        if resolved.maxContextOverride == nil {
            let unset = ProviderCapacity.unsetOverrideContext(physicalMemoryGB: physicalMemoryGB, draftModelConfigured: true)
            resolved.maxContextOverride = unset.tokens
            resolved.maxContextSource = unset.source
        }
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
        /// #1690 M9: for a loopback serve, the signed catalog row's
        /// snapshot-manifest digest, which the local MLX snapshot of the
        /// row's model id must match before its tokenizer counts a cancelled
        /// stream (SPEC-015 §N.12 item 7). Nil otherwise.
        let siblingSnapshotSHA256: String?
        /// The row's `model_revision`, which locates its verified artifact.
        let siblingSnapshotRevision: String?

        init(
            state: String,
            releaseID: String,
            digest: String,
            signerKeyID: String?,
            source: String,
            policyVersion: String? = nil,
            rowIdentity: String? = nil,
            modelSHA256: String? = nil,
            siblingSnapshotSHA256: String? = nil,
            siblingSnapshotRevision: String? = nil
        ) {
            self.state = state
            self.releaseID = releaseID
            self.digest = digest
            self.signerKeyID = signerKeyID
            self.source = source
            self.policyVersion = policyVersion
            self.rowIdentity = rowIdentity
            self.modelSHA256 = modelSHA256
            self.siblingSnapshotSHA256 = siblingSnapshotSHA256
            self.siblingSnapshotRevision = siblingSnapshotRevision
        }
    }

    static func loadContinuousBatchingPolicy(
        catalogTrust: CatalogRuntimeTrust?,
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs()
    ) async -> ContinuousBatchingPolicyLoadResult {
        guard let catalogTrust else {
            return ContinuousBatchingPolicyLoadResult(
                selection: .emptyOff,
                status: .absentFallback,
                policySHA256: nil,
                signerKeyID: nil
            )
        }
        let candidate = await staticInputs.loadCandidateCatalog()
        guard candidate.value.version == catalogTrust.releaseID,
              AutotuneStaticInputs.candidateCatalogSHA256(bytes: candidate.selectedBytes) == catalogTrust.digest,
              candidate.signerKeyID == catalogTrust.signerKeyID else {
            return ContinuousBatchingPolicyLoadResult(
                selection: .emptyOff,
                status: .updateRequiredFallback,
                policySHA256: nil,
                signerKeyID: nil
            )
        }
        return await staticInputs.loadContinuousBatchingPolicy(candidateCatalog: candidate)
    }

    struct VerifiedModelRuntimeBinding {
        let authorityPath: String
        let authoritySHA256: String
        let loadPath: String
        let loadSHA256: String
        let nativeMTPResolvedArtifactAuthority: NativeMTPResolvedArtifactAuthority?
        /// The sidecar the serve-path loader reads; nil uses the bundle lookup.
        var nativeMTPAdmissionSidecarPath: String? = nil
        /// The durable store root a fetched set's projection resolves against.
        var nativeMTPAdmissionArtifactRoot: String? = nil
    }

    struct NativeMTPResolvedAdmission {
        let authority: NativeMTPResolvedArtifactAuthority
        let sidecarPath: String?
        var artifactRoot: String? = nil
    }

    struct ModelArtifactPreflightOutcome {
        let catalogTrust: CatalogRuntimeTrust?
        let runtimeBinding: VerifiedModelRuntimeBinding?
    }

    static func runModelArtifactPreflight(
        _ resolved: inout AppConfig,
        joiningCoordinator: Bool = true,
        isolateLifecycle: Bool = false,
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs(),
        artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver(),
        persistConfigMigration: Bool = false
    ) async throws -> CatalogRuntimeTrust? {
        try await runModelArtifactPreflightOutcome(
            &resolved,
            joiningCoordinator: joiningCoordinator,
            isolateLifecycle: isolateLifecycle,
            staticInputs: staticInputs,
            artifactResolver: artifactResolver,
            persistConfigMigration: persistConfigMigration
        ).catalogTrust
    }

    static func runModelArtifactPreflightOutcome(
        _ resolved: inout AppConfig,
        joiningCoordinator: Bool = true,
        isolateLifecycle: Bool = false,
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs(),
        artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver(),
        persistConfigMigration: Bool = false
    ) async throws -> ModelArtifactPreflightOutcome {
        // #1816: a configured pool_model_id must be well formed and never
        // pinned beside a catalog identity, for every runtime.
        let servesPoolModelEntry: Bool
        do {
            servesPoolModelEntry = try PoolModelServe.validatedPoolModelID(resolved) != nil
        } catch let error as PoolModelServe.ConfigError {
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            throw ExitCode(2)
        }
        // SPEC-046-R002 / SPEC-010-R007(e) loopback serving (#1569, #1690): an
        // `ollama_loopback` / `llamacpp_loopback` model carries a
        // `macprovider.gguf-file.v1` identity resolved from the local GGUF
        // file at serve time (an `mlxlm_loopback` model the CLI-computed
        // snapshot-manifest pair of its declared snapshot), not a catalog
        // artifact SHA. It is intentionally uncatalogued and non-earning, so it
        // neither requires nor runs the MLX catalog-artifact preflight. Returning
        // nil (no catalog trust) lets the daemon stay connected instead of
        // exiting `catalog_incompatible`. It never becomes buyer-serving because
        // the candidate keeps a null `catalog_model_key` and so can never reach
        // a settlement/`catalog_priced` state — the coordinator's BYOM paid-
        // routing gate (`byomDefaultPaidRoutingEligible` →
        // `ReasonBYOMNonSettlement`) excludes it. That money-path gate, not the
        // SPEC-032 hello-gate ceiling flag (which is set only when the gate is
        // ON), is what holds in the gate-off E2E posture (SPEC-047-R003/R005).
        if LoopbackServeSelection.select(resolved.model) != nil {
            return ModelArtifactPreflightOutcome(
                catalogTrust: try await runLoopbackPoolCatalogPreflight(
                    resolved,
                    joiningCoordinator: joiningCoordinator,
                    isolateLifecycle: isolateLifecycle,
                    staticInputs: staticInputs
                ),
                runtimeBinding: nil
            )
        }
        var artifactResolver = artifactResolver
        if let root = resolved.modelArtifactRoot, root.hasPrefix("/") {
            artifactResolver.durableRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        }
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
            return ModelArtifactPreflightOutcome(catalogTrust: nil, runtimeBinding: nil)
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
        let configuredPath = URL(fileURLWithPath: artifactPath).standardizedFileURL.path
        let loadPath: String
        let persistFrom: String?
        let actual: String
        let runtimeLoadSHA256: String
        let authorityPath: String
        let privateRuntime = usesBuild1PrivateRuntimeVariant(resolved)
        do {
            let resolvedLoad = try resolveVerifiedLoadPath(
                configuredPath: configuredPath,
                expectedSHA256: expected,
                resolved: resolved,
                artifactResolver: artifactResolver
            )
            persistFrom = resolvedLoad.persistFrom
            authorityPath = resolvedLoad.path
            let inspection = try ModelArtifactVerifier.inspectCanonicalArtifact(
                directory: URL(fileURLWithPath: resolvedLoad.path),
                scopedSubdirectory: privateRuntime ? Build1PrivatePrepareProfile.runtimeVariantDirectory : nil
            )
            actual = inspection.sha256
            guard actual == expected else {
                FileHandle.standardError.write(Data("model artifact hash mismatch for \(resolvedLoad.path)\n".utf8))
                throw ExitCode(2)
            }
            loadPath = try runtimeModelLoadPath(
                verifiedArtifactPath: resolvedLoad.path,
                config: resolved,
                artifactResolver: artifactResolver
            )
            runtimeLoadSHA256 = inspection.scopedSHA256 ?? actual
        } catch let exit as ExitCode {
            throw exit
        } catch {
            FileHandle.standardError.write(Data("model artifact verification failed for \(configuredPath): \(error)\n".utf8))
            throw ExitCode(2)
        }
        resolved.modelArtifactPath = loadPath
        // #1816: a native model served as a signed pool entry has no catalog
        // row by definition. Its artifact hash was verified above; the
        // coordinator matches that hash against the pool manifest and is the
        // only authority that admits it, so the catalog preflight is skipped
        // for that join alone. Donor mode keeps its catalog gate.
        if resolved.donorMode || (joiningCoordinator && !servesPoolModelEntry && !skipsCatalogPreflightForLabJoin(
            isolateLifecycle: isolateLifecycle,
            coordinatorURL: resolved.coordinatorURL
        )) {
            // Catalog admission verifies and canonicalizes the authority-bound
            // artifact root. The private Build 1 runtime loads only its 4-bit
            // member, whose scoped digest intentionally differs from the full
            // signed revision digest, so never feed that member path back into
            // full-artifact catalog verification. Keep the canonical authority
            // root in config and carry the scoped member only in the verified
            // runtime binding used by the model loader.
            let catalogArtifactSHA256 = privateRuntime
                ? runtimeLoadSHA256
                : actual
            let catalogTrust = try await runModelCatalogPreflight(
                &resolved,
                modelPath: authorityPath,
                actualArtifactSHA256: actual,
                catalogArtifactSHA256: catalogArtifactSHA256,
                requireRecommendable: !resolved.donorMode,
                staticInputs: staticInputs,
                artifactResolver: artifactResolver,
                persistConfigMigration: persistConfigMigration,
                persistFrom: persistFrom
            )
            let canonicalAuthorityPath = resolved.modelArtifactPath ?? authorityPath
            let canonicalLoadPath = try runtimeModelLoadPath(
                verifiedArtifactPath: canonicalAuthorityPath,
                config: resolved,
                artifactResolver: artifactResolver
            )
            let nativeMTPResolvedAdmission = await resolveNativeMTPArtifactAuthority(
                config: resolved,
                catalogTrust: catalogTrust,
                authorityPath: canonicalAuthorityPath,
                authoritySHA256: actual,
                staticInputs: staticInputs,
                artifactResolver: artifactResolver
            )
            return ModelArtifactPreflightOutcome(
                catalogTrust: catalogTrust,
                runtimeBinding: VerifiedModelRuntimeBinding(
                    authorityPath: canonicalAuthorityPath,
                    authoritySHA256: actual,
                    loadPath: canonicalLoadPath,
                    loadSHA256: runtimeLoadSHA256,
                    nativeMTPResolvedArtifactAuthority: nativeMTPResolvedAdmission?.authority,
                    nativeMTPAdmissionSidecarPath: nativeMTPResolvedAdmission?.sidecarPath,
                    nativeMTPAdmissionArtifactRoot: nativeMTPResolvedAdmission?.artifactRoot
                )
            )
        }
        return ModelArtifactPreflightOutcome(
            catalogTrust: nil,
            runtimeBinding: VerifiedModelRuntimeBinding(
                authorityPath: authorityPath,
                authoritySHA256: actual,
                loadPath: loadPath,
                loadSHA256: runtimeLoadSHA256,
                nativeMTPResolvedArtifactAuthority: nil
            )
        )
    }

    private static func resolveNativeMTPArtifactAuthority(
        config: AppConfig,
        catalogTrust: CatalogRuntimeTrust,
        authorityPath: String,
        authoritySHA256: String,
        staticInputs: AutotuneStaticInputs,
        artifactResolver: CachedModelArtifactResolver
    ) async -> NativeMTPResolvedAdmission? {
        guard config.nativeMTPMode == .auto,
              let modelKey = config.modelCatalogKey,
              !modelKey.isEmpty,
              !authoritySHA256.isEmpty
        else {
            return nil
        }
        let inputs = await staticInputs.loadRecommendationInputs(includeArtifactFeed: true)
        guard inputs.candidate.value.version == catalogTrust.releaseID,
              AutotuneStaticInputs.candidateCatalogSHA256(bytes: inputs.candidate.selectedBytes) == catalogTrust.digest,
              inputs.artifactFeed.warnings.blockingArtifactFeedWarnings.isEmpty,
              let qualified = inputs.artifactFeed.value,
              qualified.releaseID == catalogTrust.releaseID,
              qualified.feedSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              !qualified.signerKeyID.isEmpty
        else {
            return nil
        }
        let matches = qualified.artifactIdentities().filter {
            $0.catalogKey == modelKey
                && $0.isPrimary
                && $0.hashAlgorithm == NativeMTPResolvedArtifactAuthority.nativeMTPHashAlgorithm
                && $0.hash == authoritySHA256
                && $0.verificationStatus == "verified"
        }
        guard matches.count == 1, let identity = matches.first else {
            return nil
        }
        let targetURL = URL(fileURLWithPath: authorityPath, isDirectory: true).standardizedFileURL
        let bundleRoot = targetURL.deletingLastPathComponent()
        let bundledSidecar = bundleRoot.appendingPathComponent("native-mtp-admission.json")
        let localSidecarURL = FileManager.default.fileExists(atPath: bundledSidecar.path)
            ? bundledSidecar
            : targetURL.appendingPathComponent("native-mtp-admission.json")
        let sidecarPath: String?
        var artifactRoot: String?
        if FileManager.default.fileExists(atPath: localSidecarURL.path) {
            // An operator-placed set next to the bundle keeps the bundle lookup.
            sidecarPath = nil
        } else {
            // SPEC-023 §12.5 Stage A: the release's signed admission set,
            // fetched from the static-feed origin into a private directory.
            guard let fetched = try? await NativeMTPAdmissionFeed.fetchAndMaterialize(
                releaseID: catalogTrust.releaseID,
                signerKeyID: AutotuneStaticInputs.keyID,
                trustedPublicKeys: staticInputs.trustedPublicKeys
            ) else {
                return nil
            }
            // The fetched set projects the served target and the MTP drafter
            // by durable-store path; the drafter is fetched here if missing.
            guard let manifest = try? Data(contentsOf: fetched.deletingLastPathComponent()
                    .appendingPathComponent(NativeMTPAdmissionFeed.manifestFileName)),
                  let storeRoot = await NativeMTPStoreProjection.prepare(
                    manifest: manifest,
                    servedTargetURL: targetURL,
                    resolver: artifactResolver
                  )
            else {
                return nil
            }
            sidecarPath = fetched.path
            artifactRoot = storeRoot.path
        }
        guard let authority = try? qualified.nativeMTPResolvedArtifactAuthority(
            releaseID: catalogTrust.releaseID,
            modelKey: modelKey,
            artifactID: identity.artifactID,
            hash: identity.hash,
            preflightTargetURL: targetURL
        ) else {
            return nil
        }
        return NativeMTPResolvedAdmission(authority: authority, sidecarPath: sidecarPath, artifactRoot: artifactRoot)
    }

    /// The Build 1 private authority covers the complete upstream revision,
    /// which contains multiple quantization variants. mlx-swift-lm recursively
    /// discovers safetensors below its load directory, so loading the revision
    /// root mixes same-named tensors from 2/4/6/8-bit variants. Verify the full
    /// authority-bound snapshot first, then load only its fixed 4-bit member.
    static func runtimeModelLoadPath(
        verifiedArtifactPath: String,
        config: AppConfig,
        artifactResolver: CachedModelArtifactResolver
    ) throws -> String {
        guard usesBuild1PrivateRuntimeVariant(config) else {
            return verifiedArtifactPath
        }

        let runtimeDirectory = URL(fileURLWithPath: verifiedArtifactPath, isDirectory: true)
            .appendingPathComponent(Build1PrivatePrepareProfile.runtimeVariantDirectory, isDirectory: true)
            .standardizedFileURL
        _ = try artifactResolver.durableStore.validatedContainedDirectory(runtimeDirectory.path)
        for name in ["config.json", "model.safetensors.index.json"] {
            var info = stat()
            let path = runtimeDirectory.appendingPathComponent(name).path
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw AutotuneRecommendError.invalidArtifact(
                    "Build 1 private runtime variant is incomplete: \(name)"
                )
            }
        }
        return runtimeDirectory.path
    }

    private static func usesBuild1PrivateRuntimeVariant(_ config: AppConfig) -> Bool {
        config.modelArtifactSHA256 == Build1PrivatePrepareProfile.hash
            && config.modelCatalogKey == Build1PrivatePrepareProfile.modelKey
            && config.modelCatalogModelID == Build1PrivatePrepareProfile.modelID
            && config.modelCatalogRevision == Build1PrivatePrepareProfile.revision
            && config.modelCatalogVersion == Build1PrivatePrepareProfile.releaseID
    }

    /// SPEC-042-R013 / SPEC-047-R003(iv) pool route-time clause (#1690 M6): a
    /// loopback model the operator pins to a signed catalog row
    /// (`model_catalog_key` + `model_catalog_model_id`) is a Trusted Pool
    /// member candidate. The coordinator binds its GGUF identity only for a
    /// session admitted on a current or compatible catalog release, so the
    /// hello must carry the release envelope of that row. Without the pin the
    /// loopback path stays envelope-less and non-earning, as before. The row
    /// check is the same one the MLX preflight applies; the weights are proven
    /// by the GGUF file digest, never by the row's MLX `model_sha256`, so no
    /// served-model refresher is attached (`modelSHA256` is nil).
    static func runLoopbackPoolCatalogPreflight(
        _ resolved: AppConfig,
        joiningCoordinator: Bool,
        isolateLifecycle: Bool,
        staticInputs: AutotuneStaticInputs
    ) async throws -> CatalogRuntimeTrust? {
        guard joiningCoordinator, !resolved.donorMode,
              let key = LoopbackServeSelection.nonEmpty(resolved.modelCatalogKey),
              let modelID = LoopbackServeSelection.nonEmpty(resolved.modelCatalogModelID)
        else {
            return nil
        }
        // A lab join (isolated lifecycle, loopback coordinator) binds the
        // compiled-in release and never fetches the production static feeds.
        var inputs = staticInputs
        if relaxesJoinAdmissionForLab(isolateLifecycle: isolateLifecycle, coordinatorURL: resolved.coordinatorURL) {
            inputs.fetch = { _ in throw AutotuneRecommendError.invalidStaticJSON("lab join: static feed fetch disabled") }
        }
        let catalog = await inputs.loadCandidateCatalog()
        if !catalog.warnings.isDisjoint(with: [.candidateCatalogIntegrityFailure, .candidateCatalogUpdateRequired]) {
            let state = catalog.warnings.contains(.candidateCatalogIntegrityFailure)
                ? "catalog_integrity_failure"
                : "catalog_update_required"
            FileHandle.standardError.write(Data("\(state): refusing coordinator join with an untrusted or incompatible catalog release\n".utf8))
            throw ExitCode(2)
        }
        guard let row = catalog.value.rows[key],
              row.runtimeStatus == "recommendable",
              row.modelID == modelID,
              let rowIdentity = catalog.value.rowIdentity(for: key)
        else {
            FileHandle.standardError.write(Data("loopback model_catalog_key/model_catalog_model_id is not a recommendable row of the signed candidate catalog\n".utf8))
            throw ExitCode(2)
        }
        return CatalogRuntimeTrust(
            state: catalog.usedFallback ? "safe_offline_fallback" : "live_verified",
            releaseID: catalog.value.version,
            digest: AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalog.selectedBytes),
            signerKeyID: catalog.signerKeyID,
            source: catalog.usedFallback ? "baked" : "coordinator",
            policyVersion: catalog.value.policyVersion,
            rowIdentity: rowIdentity,
            modelSHA256: nil,
            siblingSnapshotSHA256: row.modelSHA256,
            siblingSnapshotRevision: row.modelRevision
        )
    }

    /// #1690 M9: where the catalog row's MLX artifact lives on this Mac, in
    /// the order native serving verifies it: the durable-store copy, then the
    /// Hugging Face snapshot macprovider's downloader writes (plain files).
    static func loopbackSiblingSnapshotDirectories(_ resolved: AppConfig, trust: CatalogRuntimeTrust?) -> [URL] {
        guard let modelID = LoopbackServeSelection.nonEmpty(resolved.modelCatalogModelID),
              let revision = trust?.siblingSnapshotRevision,
              let sha256 = trust?.siblingSnapshotSHA256
        else { return [] }
        let resolver = CachedModelArtifactResolver.forConfig(resolved)
        var directories: [URL] = []
        if let durable = try? resolver.durableStore.artifactURL(modelID: modelID, revision: revision, sha256: sha256) {
            directories.append(durable)
        }
        directories.append(resolver.snapshotURL(modelID: modelID, revision: revision))
        return directories
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func requireContainedDurablePathIfOwned(
        _ path: String,
        artifactResolver: CachedModelArtifactResolver
    ) throws {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = artifactResolver.durableRoot.standardizedFileURL.path
        guard standardized == root || standardized.hasPrefix(root + "/") else {
            return
        }
        do {
            _ = try artifactResolver.durableStore.validatedContainedDirectory(path)
        } catch {
            FileHandle.standardError.write(Data(
                "[error] Configured durable model artifact failed containment: \(error.localizedDescription)\n".utf8
            ))
            throw ExitCode(2)
        }
    }

    /// Where serve looks for a pinned artifact, in order: an existing
    /// configured directory, with no fallback when it fails to verify; else
    /// the durable-store copy of the pinned snapshot. `models verify-artifact`
    /// (SPEC-010-R008) resolves through this so it checks the bytes serve loads.
    enum PinnedArtifactLoadCandidate {
        case configured(String)
        case durable(String)
        case missingPin
        case invalidDurablePath(Error)
    }

    static func pinnedArtifactLoadCandidate(
        configuredPath: String,
        modelID: String?,
        revision: String?,
        expectedSHA256: String,
        artifactResolver: CachedModelArtifactResolver
    ) -> PinnedArtifactLoadCandidate {
        if isExistingDirectory(configuredPath) {
            return .configured(configuredPath)
        }
        guard let modelID, !modelID.isEmpty, let revision, !revision.isEmpty else {
            return .missingPin
        }
        do {
            return .durable(try artifactResolver.durableStore.artifactURL(
                modelID: modelID,
                revision: revision,
                sha256: expectedSHA256
            ).standardizedFileURL.path)
        } catch {
            return .invalidDurablePath(error)
        }
    }

    private static func resolveVerifiedLoadPath(
        configuredPath: String,
        expectedSHA256: String,
        resolved: AppConfig,
        artifactResolver: CachedModelArtifactResolver
    ) throws -> (path: String, persistFrom: String?) {
        let durablePath: String
        switch pinnedArtifactLoadCandidate(
            configuredPath: configuredPath,
            modelID: resolved.modelCatalogModelID,
            revision: resolved.modelCatalogRevision,
            expectedSHA256: expectedSHA256,
            artifactResolver: artifactResolver
        ) {
        case .configured:
            try requireContainedDurablePathIfOwned(configuredPath, artifactResolver: artifactResolver)
            let actual = try ModelArtifactVerifier.canonicalArtifactHash(
                directory: URL(fileURLWithPath: configuredPath)
            )
            guard actual == expectedSHA256 else {
                FileHandle.standardError.write(Data("model artifact hash mismatch for \(configuredPath)\n".utf8))
                throw ExitCode(2)
            }
            return (configuredPath, nil)
        case .missingPin:
            FileHandle.standardError.write(
                Data("model artifact verification failed for \(configuredPath): missing pinned snapshot\n".utf8)
            )
            throw ExitCode(2)
        case .invalidDurablePath(let error):
            FileHandle.standardError.write(Data("model durable artifact path is invalid: \(error)\n".utf8))
            throw ExitCode(2)
        case .durable(let path):
            durablePath = path
        }
        guard isExistingDirectory(durablePath) else {
            FileHandle.standardError.write(
                Data("model artifact verification failed for \(configuredPath): missing pinned snapshot\n".utf8)
            )
            throw ExitCode(2)
        }
        try requireContainedDurablePathIfOwned(durablePath, artifactResolver: artifactResolver)
        let actual = try ModelArtifactVerifier.canonicalArtifactHash(
            directory: URL(fileURLWithPath: durablePath)
        )
        guard actual == expectedSHA256 else {
            FileHandle.standardError.write(Data("model artifact hash mismatch for \(durablePath)\n".utf8))
            throw ExitCode(2)
        }
        if DurableModelArtifactStore.isHuggingFaceCachePath(configuredPath) {
            FileHandle.standardError.write(
                Data("\(DurableModelArtifactStore.cacheBackedWarning)\n".utf8)
            )
        }
        return (durablePath, configuredPath)
    }

    private static func runModelCatalogPreflight(
        _ resolved: inout AppConfig,
        modelPath: String,
        actualArtifactSHA256: String,
        catalogArtifactSHA256: String? = nil,
        requireRecommendable: Bool,
        staticInputs: AutotuneStaticInputs,
        artifactResolver: CachedModelArtifactResolver,
        persistConfigMigration: Bool,
        persistFrom: String?
    ) async throws -> CatalogRuntimeTrust {
        let actual = actualArtifactSHA256
        let catalogActual = catalogArtifactSHA256 ?? actualArtifactSHA256
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
            ? await staticInputs.loadRecommendationInputs(includeArtifactFeed: false)
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
        let durableURL: URL
        do {
            durableURL = try artifactResolver.durableStore.artifactURL(
                modelID: modelID,
                revision: revision,
                sha256: actual
            )
        } catch {
            FileHandle.standardError.write(Data("model durable artifact path is invalid: \(error)\n".utf8))
            throw ExitCode(2)
        }
        let durablePath = durableURL.standardizedFileURL.path
        var pendingPersistFrom = persistFrom
        if configuredSnapshot == durablePath {
            try requireContainedDurablePathIfOwned(configuredSnapshot, artifactResolver: artifactResolver)
            resolved.modelArtifactPath = durablePath
        } else if configuredSnapshot == expectedSnapshot {
            FileHandle.standardError.write(
                Data("\(DurableModelArtifactStore.cacheBackedWarning)\n".utf8)
            )
            do {
                let adopted = try artifactResolver.durableStore.adoptVerifiedStaging(
                    staging: URL(fileURLWithPath: configuredSnapshot),
                    modelID: modelID,
                    revision: revision,
                    sha256: actual
                )
                guard adopted.standardizedFileURL.path == durablePath else {
                    FileHandle.standardError.write(Data("durable artifact migration landed outside the expected store path\n".utf8))
                    throw ExitCode(2)
                }
                resolved.modelArtifactPath = durablePath
                pendingPersistFrom = configuredSnapshot
            } catch let exit as ExitCode {
                throw exit
            } catch {
                FileHandle.standardError.write(
                    Data("cache-backed model artifact could not be migrated to the durable store: \(error)\n".utf8)
                )
                throw ExitCode(2)
            }
        } else if artifactResolver.durableStore.contains(configuredSnapshot) {
            let durableHash: String
            do {
                durableHash = try ModelArtifactVerifier.canonicalArtifactHash(
                    directory: URL(fileURLWithPath: configuredSnapshot)
                )
            } catch {
                FileHandle.standardError.write(Data("model artifact verification failed for \(configuredSnapshot): \(error)\n".utf8))
                throw ExitCode(2)
            }
            guard durableHash == actual else {
                FileHandle.standardError.write(Data("model artifact hash mismatch for \(configuredSnapshot)\n".utf8))
                throw ExitCode(2)
            }
            if configuredSnapshot != durablePath {
                do {
                    let adopted = try artifactResolver.durableStore.adoptVerifiedStaging(
                        staging: URL(fileURLWithPath: configuredSnapshot),
                        modelID: modelID,
                        revision: revision,
                        sha256: actual
                    )
                    guard adopted.standardizedFileURL.path == durablePath else {
                        FileHandle.standardError.write(Data("durable artifact migration landed outside the expected store path\n".utf8))
                        throw ExitCode(2)
                    }
                } catch {
                    FileHandle.standardError.write(
                        Data("non-canonical durable artifact could not be moved to the catalog identity path: \(error)\n".utf8)
                    )
                    throw ExitCode(2)
                }
                pendingPersistFrom = configuredSnapshot
            }
            resolved.modelArtifactPath = durablePath
        } else if DurableModelArtifactStore.isHuggingFaceCachePath(configuredSnapshot) {
            FileHandle.standardError.write(
                Data(
                    "model_artifact_missing_from_cache: \(configuredSnapshot) is a Hugging Face cache path that is not the catalog-pinned snapshot; re-run autotune --recommend --apply\n"
                        .utf8
                )
            )
            throw ExitCode(2)
        } else {
            FileHandle.standardError.write(Data("model must be a durable provider artifact or the catalog-pinned Hugging Face snapshot path\n".utf8))
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
              catalogSHA256 == catalogActual
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
                    + "row still admitted — run malibu-cli autotune --recommend --apply to refresh config\n")
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
        if persistConfigMigration,
           let from = pendingPersistFrom,
           let to = resolved.modelArtifactPath,
           from != to
        {
            try persistMigratedArtifactPath(
                configPath: resolved.configPath,
                from: from,
                to: to
            )
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

    /// SPEC-023-R010 / AC-CAT-22 (#1705): the in-process counterpart of the
    /// serve-start catalog preflight. Re-runs the same signed live fetch and
    /// row admission for the model key this process already serves, and
    /// returns a hello envelope only when a live, signature-verified document
    /// still pins that key to the loaded model id, revision, and model_sha256.
    /// Baked bytes are a startup fallback only and never become a new envelope;
    /// a changed or absent row returns nil because new weights need a restart.
    static func refreshCatalogEnvelope(
        config: AppConfig,
        servedModelSHA256: String,
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs()
    ) async -> CoordinatorClient.CatalogEnvelope? {
        guard let key = config.modelCatalogKey, !key.isEmpty,
              let modelID = config.modelCatalogModelID, !modelID.isEmpty,
              let revision = config.modelCatalogRevision, !revision.isEmpty,
              !servedModelSHA256.isEmpty
        else {
            return nil
        }
        let requireRecommendable = !config.donorMode
        let catalog: AutotuneStaticSelection<CandidateCatalog>
        if requireRecommendable {
            let inputs = await staticInputs.loadRecommendationInputs(includeArtifactFeed: false)
            let rateCard = inputs.rateCard
            guard rateCard.warnings.isDisjoint(with: [.rateCardIntegrityFailure, .rateCardUpdateRequired]),
                  let match = rateCard.value.rowForRecommendation(modelKey: key),
                  config.model == rateCard.value.servedModelKey(modelKey: key, rateCardKey: match.key)
            else {
                return nil
            }
            catalog = inputs.candidate
        } else {
            catalog = await staticInputs.loadCandidateCatalog()
        }
        guard !catalog.usedFallback,
              catalog.warnings.isDisjoint(with: [.candidateCatalogIntegrityFailure, .candidateCatalogUpdateRequired]),
              let signerKeyID = catalog.signerKeyID,
              !catalog.value.policyVersion.isEmpty,
              let rowIdentity = catalog.value.rowIdentity(for: key),
              let row = catalog.value.rows[key],
              requireRecommendable
                ? row.runtimeStatus == "recommendable"
                : ["candidate", "listed", "recommendable"].contains(row.runtimeStatus),
              row.modelID == modelID,
              row.modelRevision == revision,
              let rowModelSHA256 = row.modelSHA256,
              rowModelSHA256 == servedModelSHA256
        else {
            return nil
        }
        return CoordinatorClient.CatalogEnvelope(
            releaseID: catalog.value.version,
            policyVersion: catalog.value.policyVersion,
            candidateSHA256: AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalog.selectedBytes),
            signerKeyID: signerKeyID,
            rowIdentity: rowIdentity,
            modelSHA256: rowModelSHA256
        )
    }

    static func persistMigratedArtifactPath(configPath: String, from oldPath: String, to newPath: String) throws {
        let expanded: String
        if configPath.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(configPath.dropFirst(2))).path
        } else {
            expanded = configPath
        }
        guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) else {
            return
        }
        try ProviderConfigMutationLock.withExclusiveLock(configPath: expanded) {
            try persistMigratedArtifactPathLocked(
                expanded: expanded,
                from: oldPath,
                to: newPath
            )
        }
    }

    private static func persistMigratedArtifactPathLocked(
        expanded: String,
        from oldPath: String,
        to newPath: String
    ) throws {
        guard FileManager.default.fileExists(atPath: expanded) else {
            return
        }
        var info = stat()
        guard lstat(expanded, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return
        }
        let original = try String(contentsOfFile: expanded, encoding: .utf8)
        let oldLiterals = Set([oldPath, yamlPathLiteral(oldPath)])
        let replacement = "model_artifact_path: \(yamlPathLiteral(newPath))"
        var replaced = false
        let updated = original.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard !replaced else { return String(line) }
            let raw = String(line)
            guard raw.first?.isWhitespace != true else { return raw }
            let candidate = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            for literal in oldLiterals where candidate == "model_artifact_path: \(literal)" {
                replaced = true
                return replacement
            }
            return raw
        }.joined(separator: "\n")
        guard replaced, updated != original else {
            return
        }
        let backup = expanded + ".pre-durable-artifact.bak"
        var bakInfo = stat()
        if lstat(backup, &bakInfo) == 0 {
            guard (bakInfo.st_mode & S_IFMT) == S_IFREG else {
                return
            }
            try FileManager.default.removeItem(atPath: backup)
        }
        let backupMode = mode_t((info.st_mode & 0o777) & ~0o077)
        try writeExclusiveRegularFile(
            path: backup,
            contents: original,
            mode: backupMode == 0 ? 0o600 : backupMode
        )
        try updated.write(toFile: expanded, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: info.st_mode & 0o777)],
            ofItemAtPath: expanded
        )
    }

    private static func writeExclusiveRegularFile(path: String, contents: String, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        _ = fchmod(fd, mode)
        let bytes = Array(contents.utf8)
        let written = bytes.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
        guard written == bytes.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func yamlPathLiteral(_ value: String) -> String {
        let plain = value.utf8.allSatisfy { byte in
            (0x61...0x7A).contains(byte)
                || (0x41...0x5A).contains(byte)
                || (0x30...0x39).contains(byte)
                || [0x2D, 0x5F, 0x2E, 0x2F].contains(byte)
        }
        guard !value.isEmpty, plain else {
            // Keep forward slashes literal (see ConfigApplier.yamlScalar): an
            // escaped "\/Users\/…" is valid JSON but breaks install.sh's YAML
            // read-back absolute-path check, which then fails closed.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let data = try? encoder.encode(value)
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        return value
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
        // short real temp root. `/tmp` is a symlink to `/private/tmp` and
        // protected-file credential custody rejects symlink ancestors, which
        // blocked isolated lab join from persisting a minted coordinator token.
        temporaryDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
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

    /// Isolated lab serve: skip PATH-repair re-exec and keep provider identity,
    /// but do not share launchd lifecycle/lease/control files with the incumbent.
    /// `--no-join` + protected-file is the local-HTTP form.
    /// `--isolate-lifecycle` + protected-file is the joined-coordinator form.
    static func isolatesNoJoinLabServe(
        noJoin: Bool,
        isolateLifecycle: Bool = false,
        credentialStore: ProviderCredentialStoreKind,
        autotuneCandidate: Bool
    ) -> Bool {
        (noJoin || isolateLifecycle) && credentialStore == .protectedFile && !autotuneCandidate
    }

    /// Catalog/credential/admission identity may relax only for an isolated
    /// join against a loopback coordinator. Production coordinator URLs keep
    /// those checks even with `--isolate-lifecycle`.
    static func relaxesJoinAdmissionForLab(
        isolateLifecycle: Bool,
        coordinatorURL: String?
    ) -> Bool {
        isolateLifecycle && isLoopbackCoordinatorURL(coordinatorURL)
    }

    /// The isolated lab join skips the catalog preflight because it cannot
    /// reach the production static feeds. A lab build whose static feeds are
    /// redirected to a loopback origin signed by a test key
    /// (`StaticFeedOrigin.labOverride`) has its own signed catalog, so it runs
    /// the real preflight and native-MTP admission fetch: the delivery-path
    /// rehearsal (SPEC-048 R014, #1770). Release builds have no override.
    static func skipsCatalogPreflightForLabJoin(
        isolateLifecycle: Bool,
        coordinatorURL: String?,
        labStaticFeedOverrideActive: Bool = StaticFeedOrigin.labOverride != nil
    ) -> Bool {
        relaxesJoinAdmissionForLab(isolateLifecycle: isolateLifecycle, coordinatorURL: coordinatorURL)
            && !labStaticFeedOverrideActive
    }

    /// The isolated lab join skips the catalog preflight (`relaxesJoinAdmissionForLab`),
    /// so it can never present the catalog envelope the buyer-serving
    /// readiness gate requires. Waive only that gate, only for that join.
    static func waivesLabLoopbackCatalogReadiness(
        isolateLifecycle: Bool,
        credentialStore: ProviderCredentialStoreKind,
        coordinatorURL: String?,
        hasCatalogTrust: Bool
    ) -> Bool {
        isolateLifecycle
            && credentialStore == .protectedFile
            && relaxesJoinAdmissionForLab(isolateLifecycle: isolateLifecycle, coordinatorURL: coordinatorURL)
            && !hasCatalogTrust
    }

    static func isLoopbackCoordinatorURL(_ raw: String?) -> Bool {
        guard let raw, let url = URL(string: raw), let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    @discardableResult
    static func validatePrivacyLabIdentityScopeIfRequested(
        config: AppConfig,
        isolateLifecycle: Bool,
        requested: Bool
    ) throws -> PrivacyLabIdentityScope? {
        try PrivacyLabIdentityScope.validatedIfRequested(
            config: config,
            isolateLifecycle: isolateLifecycle,
            requested: requested
        )
    }

    static func samePrivacyLabIdentityInputs(_ checked: AppConfig, _ serving: AppConfig) -> Bool {
        checked.credentialStore == serving.credentialStore
            && normalizedCoordinatorURL(checked.coordinatorURL) == normalizedCoordinatorURL(serving.coordinatorURL)
    }

    private static func normalizedCoordinatorURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// SPEC-049-R007/R024 ordering. Privacy mode is decided from non-secret
    /// inputs only (flag > `MACPROVIDER_PRIVACY_CLASS_BETA` > `privacy_class_beta`,
    /// and an explicit `relay_blind_enabled: false` opts out). In privacy mode
    /// the canonical re-exec decision and hardening run on the non-secret
    /// bootstrap before any provider credential is resolved. Forced mode keeps
    /// the hardening refusal. Automatic mode (unset, with `automatic` hooks)
    /// enters privacy mode only when the read-only eligibility check and then
    /// the hardening both pass, and otherwise serves ordinarily. Without hooks,
    /// unset means off. Otherwise the order is unchanged: full load, then the
    /// re-exec decision.
    static func resolveServeConfig(
        load: (_ resolveCredentials: Bool) throws -> AppConfig,
        loadAfterNonCredentialValidation: ((_ validate: (AppConfig) throws -> Void) throws -> AppConfig)? = nil,
        canonicalReexec: (AppConfig) throws -> Void,
        harden: (AppConfig) throws -> Void,
        automatic: PrivacyAutoEnrollmentHooks? = nil,
        sameLabIdentityInputs: ((AppConfig, AppConfig) -> Bool)? = nil,
        automaticPostHardenCheckpoint: ((AppConfig) throws -> Void)? = nil
    ) throws -> AppConfig {
        let bootstrap = try load(false)
        // A fallback after the automatic check may serve only ordinary mode.
        // A configuration that switched to forced privacy between the reads
        // was never checked or hardened as such, so it refuses.
        func ordinaryAfterAutomaticCheck(_ final: AppConfig) throws -> AppConfig {
            guard !final.privacyClassBeta else {
                throw PrivacyAutoEnrollmentError.configurationChanged
            }
            return final
        }
        func validateBeforeCredentialResolution(_ config: AppConfig) throws {
            try canonicalReexec(config)
            if config.privacyClassBeta {
                try harden(config)
            }
        }
        func ordinary() throws -> AppConfig {
            if let loadAfterNonCredentialValidation {
                return try loadAfterNonCredentialValidation(validateBeforeCredentialResolution)
            }
            let resolved = try load(true)
            try validateBeforeCredentialResolution(resolved)
            return resolved
        }
        func ordinaryAfterFailedAutomaticHardening() throws -> AppConfig {
            if let loadAfterNonCredentialValidation {
                return try loadAfterNonCredentialValidation { final in
                    guard !final.privacyClassBeta else {
                        throw PrivacyAutoEnrollmentError.configurationChanged
                    }
                }
            }
            return try ordinaryAfterAutomaticCheck(try load(true))
        }
        if automaticPostHardenCheckpoint != nil, PrivacyAutoEnrollment.mode(bootstrap) != .automatic {
            throw PrivacyLabConfigChangeCheckpointError.malformed
        }
        switch PrivacyAutoEnrollment.mode(bootstrap) {
        case .forced:
            let candidate = PrivacyAutoEnrollment.withStateDirectory(bootstrap)
            try canonicalReexec(candidate)
            try harden(candidate)
            let final = PrivacyAutoEnrollment.withStateDirectory(try load(true))
            // The checked snapshot must be the one that serves.
            guard PrivacyAutoEnrollment.sameEligibilityInputs(candidate, final),
                  sameLabIdentityInputs?(candidate, final) ?? true else {
                throw PrivacyAutoEnrollmentError.configurationChanged
            }
            return final
        case .off:
            return try ordinary()
        case .automatic:
            guard let automatic else { return try ordinary() }
            let candidate = PrivacyAutoEnrollment.enable(bootstrap)
            let ineligible = automatic.eligibility(candidate)
            guard ineligible.isEmpty else {
                automatic.log(PrivacyAutoEnrollment.ineligibleLine(ineligible))
                return try ordinary()
            }
            try canonicalReexec(candidate)
            let hardeningFailures = automatic.harden(candidate)
            guard hardeningFailures.isEmpty else {
                // Process-wide hardening already applied stays applied; the
                // provider serves ordinarily and never advertises privacy keys.
                automatic.log(PrivacyAutoEnrollment.hardeningFailedLine(hardeningFailures))
                return try ordinaryAfterFailedAutomaticHardening()
            }
            try automaticPostHardenCheckpoint?(candidate)
            let final = try load(true)
            // The checked snapshot must be the one that serves; a change
            // between the two reads falls back to ordinary serving.
            guard PrivacyAutoEnrollment.mode(final) == .automatic,
                  PrivacyAutoEnrollment.sameEligibilityInputs(candidate, PrivacyAutoEnrollment.enable(final)),
                  sameLabIdentityInputs?(candidate, final) ?? true else {
                automatic.log(PrivacyAutoEnrollment.hardeningFailedLine([PrivacyHardeningCode.configurationChanged]))
                return try ordinaryAfterAutomaticCheck(final)
            }
            return PrivacyAutoEnrollment.enable(final)
        }
    }

    func run() async throws {
        let cliOverrides = CLIOverrides(
            port: port,
            model: model,
            modelArtifactPath: modelArtifactPath,
            modelArtifactSHA256: modelArtifactSha256,
            draftModel: draftModel,
            draftModelArtifactSHA256: draftModelArtifactSha256,
            numDraftTokens: numDraftTokens,
            publishesSpecDecodeTelemetry: publishSpecDecodeTelemetry,
            nativeMTPMode: nativeMTP,
            coordinatorURL: coordinator,
            providerID: providerID,
            endpointURL: endpointURL,
            configPath: config,
            logLevel: logLevel,
            supportedModels: SupportedModels.parseCSV(supportedModels),
            publishesSupportedModels: publishSupportedModels,
            enableWarmSwap: enableWarmSwap,
            enableReceipts: enableReceipts,
            relayBlindEnabled: relayBlindEnabled,
            privacyClassBeta: privacyClassBeta,
            relayBlindStateDirectory: relayBlindStateDirectory,
            swapDrainTimeoutSeconds: swapDrainTimeoutSeconds,
            ctlSocketPath: ctlSocketPath,
            switchStatePath: switchStatePath,
            providerToken: providerToken,
            providerTokenFile: tokenFile,
            credentialStore: credentialStore,
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
            continuousBatchQueueWaitTimeoutMS: continuousBatchQueueWaitTimeoutMS,
            continuousBatchPrefillTokensPerIteration: continuousBatchPrefillTokensPerIteration,
            continuousBatchingCachedTurns: continuousBatchingCachedTurns,
            pagedKV: pagedKVCLIOverrides
        )
        let serveMarkerStore = AutoUpdateMarkerStore()
        let isolateLifecycleForPrivacy = isolateLifecycle
        let labIdentityScopeForPrivacy = labIdentityScope
        let labConfigChangeCheckpoint: PrivacyLabConfigChangeCheckpoint?
        if let checkpointFD = privacyLabConfigChangeCheckpointFD {
            guard checkpointFD >= 3, checkpointFD <= Int(Int32.max) else {
                throw ValidationError("--privacy-lab-config-change-checkpoint-fd must be an inherited descriptor >= 3")
            }
            let inheritedFD = Int32(checkpointFD)
            do {
                labConfigChangeCheckpoint = try PrivacyLabConfigChangeCheckpoint(fd: inheritedFD)
                Darwin.close(inheritedFD)
            } catch {
                Darwin.close(inheritedFD)
                throw error
            }
        } else {
            labConfigChangeCheckpoint = nil
        }
        var resolved = try Self.resolveServeConfig(
            load: { resolveCredentials in
                try ConfigLoader.load(cli: cliOverrides, resolveCredentials: resolveCredentials)
            },
            loadAfterNonCredentialValidation: { validate in
                try ConfigLoader.loadAfterNonCredentialValidation(
                    cli: cliOverrides,
                    validate: validate
                )
            },
            canonicalReexec: { loaded in
                // #616/#610: repair a stale PATH regular-file entrypoint to install
                // authority, then re-exec into that canonical binary when this process
                // was launched from a non-canonical path. PATH repair alone does not
                // replace the already-running stale inode; identity must freeze on the
                // binary that matches the signed set's provider_cli member.
                if !autotuneCandidate,
                   loaded.credentialStore != .protectedFile,
                   let canonical = try serveMarkerStore.ensurePathEntrypointMatchesInstallAuthority(),
                   let launched = Bundle.main.executableURL?.standardizedFileURL,
                   launched.path != canonical.standardizedFileURL.path {
                    try execCanonicalInstall(canonical)
                }
            },
            harden: { loaded in
                _ = try Self.validatePrivacyLabIdentityScopeIfRequested(
                    config: loaded,
                    isolateLifecycle: isolateLifecycleForPrivacy,
                    requested: labIdentityScopeForPrivacy
                )
                // SPEC-049-R007: after canonical re-exec, before credentials, model
                // load, HTTPServer, or CoordinatorClient. The live probe calls
                // ptrace(PT_DENY_ATTACH); tests inject a probe and never do.
                if case .failure(let reasons) = PrivacyRuntimeHardening.apply(
                    probe: SystemPrivacyPostureProbe(),
                    config: loaded
                ) {
                    let line = PrivacyRuntimeHardening.fatalLine(reasons: reasons)
                    FileHandle.standardError.write(Data(line.utf8))
                    try? FileHandle.standardError.synchronize()
                    throw ExitCode(78)
                }
            },
            // SPEC-049-R024: automatic mode only for a serving provider that
            // joins the coordinator; autotune candidates and --no-join stay off.
            automatic: autotuneCandidate || noJoin ? nil : PrivacyAutoEnrollment.liveHooks(
                labIdentityScope: { config in
                    try PrivacyLabIdentityScope.validatedIfRequested(
                        config: config,
                        isolateLifecycle: isolateLifecycleForPrivacy,
                        requested: labIdentityScopeForPrivacy
                    )
                }
            ),
            sameLabIdentityInputs: labIdentityScopeForPrivacy ? Self.samePrivacyLabIdentityInputs : nil,
            automaticPostHardenCheckpoint: labConfigChangeCheckpoint.map { checkpoint in
                { config in
                    guard labIdentityScopeForPrivacy,
                          isolateLifecycleForPrivacy else {
                        throw PrivacyLabConfigChangeCheckpointError.malformed
                    }
                    guard let scope = try Self.validatePrivacyLabIdentityScopeIfRequested(
                        config: config,
                        isolateLifecycle: isolateLifecycleForPrivacy,
                        requested: labIdentityScopeForPrivacy
                    ) else {
                        throw PrivacyLabConfigChangeCheckpointError.malformed
                    }
                    try checkpoint.signalReady(scope: scope)
                }
            }
        )

        let privacyLabIdentityScope = try Self.validatePrivacyLabIdentityScopeIfRequested(
            config: resolved,
            isolateLifecycle: isolateLifecycleForPrivacy,
            requested: labIdentityScopeForPrivacy
        )

        // v1.8.53 can leave its one-shot reload helper alive long enough to
        // restart the newly installed target repeatedly. The target fences that
        // helper before configuration/model work, but only while two durable
        // authorities agree that this exact executable is the intended
        // self-update child. Ordinary launches never touch reload jobs.
        let consumerUpdaterLifecycleAllowed = !AutoUpdater.defaultHeadlessOperatorManagedTopology(config: resolved)
        let startupReloadFenceAuthorized = autotuneCandidate
            ? false
            : consumerUpdaterLifecycleAllowed
                ? try Self.fenceAuthorizedSelfUpdateReloadJobsAtStartup()
                : false

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

        // Isolated lab serve (`--no-join` + protected-file credentials) must not
        // share the incumbent launchd lifecycle/lease/control paths, or it
        // displaces live 8080. Unlike `--autotune-candidate`, this path keeps
        // provider_id so the KV disk tier can namespace DEKs.
        if isolateLifecycle && resolved.credentialStore != .protectedFile {
            throw ValidationError("--isolate-lifecycle requires --credential-store protected_file")
        }
        let isolateNoJoinLab = Self.isolatesNoJoinLabServe(
            noJoin: noJoin,
            isolateLifecycle: isolateLifecycle,
            credentialStore: resolved.credentialStore,
            autotuneCandidate: autotuneCandidate
        )
        let candidateIsolationRoot = (autotuneCandidate || isolateNoJoinLab)
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
        } else if isolateNoJoinLab, let candidateIsolationRoot {
            resolved.ctlSocketPath = Self.candidateControlSocketPath(rootDirectory: candidateIsolationRoot)
            resolved.switchStatePath = Self.candidateSwitchStatePath(rootDirectory: candidateIsolationRoot)
        }

        // Candidate / isolated-lab lifecycle, lease, and singleton-lock files
        // all live under the fresh owner-only root. This keeps a probe from
        // fencing, replacing, or being mistaken for the installed provider.
        let lifecycleStateStore = Self.lifecycleStateStore(
            autotuneCandidate: autotuneCandidate || isolateNoJoinLab,
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
        let startupHandoffOperationID = consumerUpdaterLifecycleAllowed
            ? Self.startupHandoffOperationID(in: lifecycleLeaseStore)
            : nil
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
        do {
            _ = try lifecycleStateStore.transition(
                to: .startingProvider,
                reasonCode: startupReason,
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
        } catch let fence as ProviderLifecycleStateError {
            // F3 (#1363): a fresh launchd serve child that inherits an ABANDONED
            // updater-owned rollback/update state (a failed self-update with no
            // handoff lease) is fenced here forever, so launchd respawns in a
            // loop with no in-CLI escape. When the transaction is genuinely
            // abandoned — expired marker deadline, no live installer/updater
            // owner — recover it in place and retry the transition once so the
            // respawn loop self-heals. A legitimate in-flight self-update never
            // reaches this catch (its matching handoff operation id lets the
            // transition through above); WedgedUpdateRecovery additionally
            // refuses to touch a still-live or not-yet-expired transaction.
            guard case .operationFenced = fence,
                  !autotuneCandidate,
                  candidateIsolationRoot == nil,
                  consumerUpdaterLifecycleAllowed
            else { throw fence }
            let recovery = WedgedUpdateRecovery(
                markerStore: AutoUpdateMarkerStore(),
                lifecycleStore: lifecycleStateStore
            )
            guard case .recovered(_, let lifecycleUnfenced) = recovery.recover(),
                  lifecycleUnfenced
            else { throw fence }
            _ = try lifecycleStateStore.transition(
                to: .startingProvider,
                reasonCode: startupReason,
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
        }

        // AUDIT R1 SECURITY S2 fix (PR #334): drop MACPROVIDER_PROVIDER_TOKEN
        // from the process env immediately after we've resolved it. Under
        // Malibu.app the token arrives via env (see SPEC-025 §7 followup:
        // eventually via Keychain read here). Same-user malware inspecting
        // `ps -E <cli-pid>` would otherwise see a payout-bearing bearer token
        // for the lifetime of the process. Config resolution has already
        // captured it into `resolved.providerToken`; the env slot is unused
        // downstream.
        unsetenv("MACPROVIDER_PROVIDER_TOKEN")

        let credentialStore = ProviderCredentialStoreFactory.providerStore(for: resolved)
        let credentialSource = ProviderCredentialStoreFactory.credentialSource(for: resolved)
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
                reasonCode: "resolving_\(credentialSource.rawValue)_custody",
                writer: .serve,
                providerID: resolved.providerID,
                modelID: resolved.model,
                operationID: lifecycleOperationID
            )
            credentialStatus = try ProviderCredentialResolver.resolve(
                config: &resolved,
                store: credentialStore,
                authoritativeSource: credentialSource
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
            noJoin: noJoin,
            isolateLifecycle: isolateLifecycle
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
        // Keep disabled speculative configuration out of every production
        // preflight as well as runtime execution. Otherwise a stale draft can
        // downshift target-only capacity or prevent ordinary serving.
        let speculativeCacheWrapValidated = ModelRuntime.productionSpeculativeCacheWrapValidated
        Self.applySpeculativeSafetyGate(
            &resolved,
            cacheWrapValidated: speculativeCacheWrapValidated
        )
        let startupPreflight: Self.ServeStartupPreflightResult
        let startupProviderID = resolved.providerID
        let allowStartupHandoff = consumerUpdaterLifecycleAllowed
        var acquiredStartupLease: ProviderLifecycleLeaseRecord?
        do {
            startupPreflight = try await Self.runServeStartupPreflights(
                &resolved,
                joiningCoordinator: !noJoin,
                isolateLifecycle: isolateLifecycle,
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
                        allowStartupHandoff: allowStartupHandoff,
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

        let continuousBatchingPolicy = await Self.loadContinuousBatchingPolicy(
            catalogTrust: startupPreflight.catalogTrust
        )
        let policyEntries = continuousBatchingPolicy.selection.entries
        let currentPolicyKeys = Set([resolved.modelCatalogKey, resolved.model].compactMap { $0 })
        let currentPolicyEntries = policyEntries.filter {
            currentPolicyKeys.contains($0.modelKey)
        }
        let emergencyOffOverride = resolved.continuousBatchingExplicitlyConfigured
            && resolved.continuousBatching == .off
        if !emergencyOffOverride,
           !currentPolicyEntries.isEmpty,
           !resolved.pagedKVEnabledExplicitlyConfigured,
           resolved.pagedKV.errors.isEmpty {
            resolved.pagedKV.enabled = true
        }
        if !resolved.continuousBatchingAcceptedTuples.isEmpty, !noJoin {
            FileHandle.standardError.write(Data(
                "event=continuous_batching_manual_tuple action=ignored reason=signed_policy_required\n".utf8
            ))
        }
        let policyAcceptedTuples = policyEntries.map(\.tuple)
        let effectiveAcceptedTuples = policyAcceptedTuples
            + (noJoin ? resolved.continuousBatchingAcceptedTuples : [])
        FileHandle.standardError.write(Data(
            "event=continuous_batching_policy action=resolved status=\(continuousBatchingPolicy.status.rawValue) entries=\(policyEntries.count) emergency_off=\(emergencyOffOverride)\n".utf8
        ))

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
        // #1816: with no catalog id, a configured pool_model_id is the alias
        // (validated by the startup preflight; never both).
        let catalogModelIDAlias: String? = PoolModelServe.requestAlias(
            catalogModelID: resolved.modelCatalogModelID,
            poolModelID: resolved.poolModelID
        )
        var targetResolver = CachedModelArtifactResolver()
        if let root = resolved.modelArtifactRoot, root.hasPrefix("/") {
            targetResolver.durableRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        }
        // #1689 FR-20b: a recommendation-generated context is recomputed for
        // each verified switch target from the same verified config.json.
        let switchMemoryGB = ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil).ramGB
        var switchTargets: [(ids: [String], recomputed: Int, slots: Int)] = []
        let targetAuthorities = Self.localRuntimeTargetAuthorities(
            supportedModels: resolved.supportedModels,
            artifactResolver: targetResolver,
            onVerifiedTarget: { ids, row, artifact in
                guard resolved.maxContextSource == .recommendationApply else { return }
                let knobs = ModelSwitchContext.recomputedServeKnobs(
                    memoryGB: switchMemoryGB,
                    modelID: row.modelID,
                    catalogMinRAMGB: row.minRAMGB,
                    configJSONData: artifact.configJSONData,
                    configSHA256: artifact.configSHA256,
                    draftModel: ProviderCapacity.servedDraftModel(configured: resolved.draftModel),
                    // The slot count this serve runs (`maxBatch` below).
                    slots: ProviderCapacity.servedSlotCount(maxConcurrencyOverride: resolved.maxConcurrencyOverride),
                    modelWeightSizeBytes: artifact.sizeBytes > 0 ? UInt64(artifact.sizeBytes) : nil
                )
                switchTargets.append((ids, knobs.context, knobs.slots))
            }
        )
        // SPEC-023-R018 item 9: a generated context gives way when the slot
        // count this serve runs (config, environment, or --max-batch) would
        // not fit memory at it; an operator value is kept (status warns).
        let servedSlots = ProviderCapacity.servedSlotCount(maxConcurrencyOverride: resolved.maxConcurrencyOverride)
        let startupBound = ModelSwitchContext.startupBoundedContext(
            config: resolved,
            slots: servedSlots,
            memoryGB: switchMemoryGB,
            configJSONData: resolved.modelArtifactPath.flatMap {
                try? Data(contentsOf: URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("config.json"))
            },
            catalogMinRAMGB: (try? AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(
                Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
            )).flatMap { catalog in
                [resolved.modelCatalogKey, resolved.modelCatalogModelID, resolved.model]
                    .compactMap { $0 }
                    .lazy
                    .compactMap { ModelArtifactSignedRowResolver.lookup($0, in: catalog)?.1.minRAMGB }
                    .first
            },
            modelWeightSizeBytes: ProviderContextWorkflow.liveModelFacts(
                artifactPath: resolved.modelArtifactPath
            ).weightsBytes
        )
        let switchMaxContextByTarget = ModelSwitchContext.serveContextsByTarget(
            config: resolved,
            configuredModelIDs: [resolved.model, catalogModelIDAlias].compactMap { $0 },
            targets: switchTargets.map { ($0.ids, $0.recomputed) },
            configuredContext: startupBound?.context
        )
        let switchMaxBatchByTarget = ModelSwitchContext.serveSlotsByTarget(
            config: resolved,
            configuredModelIDs: [resolved.model, catalogModelIDAlias].compactMap { $0 },
            targets: switchTargets.map { ($0.ids, $0.slots) },
            configuredSlots: startupBound?.slots ?? servedSlots
        )
        let switchContextProvenanceModelIDs = ModelSwitchContext.provenanceModelIDs(
            config: resolved,
            configuredModelIDs: [resolved.model, catalogModelIDAlias].compactMap { $0 },
            targets: switchTargets.map { ($0.ids, $0.recomputed) }
        )
        if let startupBound, let configured = resolved.maxContextOverride {
            if startupBound.slots < servedSlots {
                // SPEC-023-R018 item 9: even the minimum context does not fit
                // the configured slots, so serve runs fewer rather than an
                // over-envelope pair.
                FileHandle.standardError.write(Data(
                    "max_context_override \(configured) was generated by a recommendation; even the \(AutotuneModelContextCap.minimumServeContext)-token minimum context does not fit \(servedSlots) slots in memory, so serving \(startupBound.context) tokens with \(startupBound.slots) slots\n".utf8
                ))
                resolved.maxConcurrencyOverride = startupBound.slots
            } else {
                FileHandle.standardError.write(Data(
                    "max_context_override \(configured) was generated by a recommendation; lowered to \(startupBound.context) tokens so \(servedSlots) slots fit in memory\n".utf8
                ))
            }
            resolved.maxContextOverride = startupBound.context
        }
        let authorizedSwitchModelIDs = Self.localRuntimeTargetModelIDs(
            supportedModels: resolved.supportedModels,
            authorities: targetAuthorities
        )
        _ = try lifecycleStateStore.transition(
            to: .loadingModel,
            reasonCode: "catalog_preflight_passed",
            writer: .serve,
            providerID: resolved.providerID,
            modelID: resolved.model,
            operationID: lifecycleOperationID
        )
        let modelRuntime: any ModelRuntimeServing
        // Non-nil only when a SPEC-046 loopback adapter serves (issue #1569);
        // threaded to the coordinator hello as `runtime_source`.
        let helloRuntimeSource: String?
        // Upstream mlx-swift-lm #424 can corrupt speculative rollback after a
        // model-specific rotating-cache wrap. Keep one source of truth for both
        // execution and advertised heartbeat capability until the tagged fix and
        // cache-wrap parity gate are green.
        do {
            if let loopbackServedRef = resolved.model, let loopback = LoopbackServeSelection.select(loopbackServedRef) {
                // SPEC-046-R002 / SPEC-010-R007(e) loopback serving (#1569,
                // #1690 M2): proxy inference to the validated loopback
                // OpenAI-compatible origin. ONE process, ONE model — no MLX
                // weights are loaded. Relay-blind is disabled on this path, and
                // signed receipts are disabled outside the authorized pool
                // path: a receipt is signed only for a request whose
                // coordinator-issued pool runtime authorization matches
                // (SPEC-015-R006, #1690 M5); global traffic stays non-earning.
                helloRuntimeSource = loopback.runtimeSource
                switch loopback {
                case .ollama:
                    modelRuntime = try OpenAICompatibleLoopbackRuntime(
                        servedModelRef: loopbackServedRef,
                        origin: OllamaLoopbackServeModel.resolveOrigin(configured: resolved.loopbackOrigin),
                        catalogModelIDAlias: catalogModelIDAlias,
                        siblingSnapshotSHA256: startupPreflight.catalogTrust?.siblingSnapshotSHA256,
                        siblingSnapshotDirectories: Self.loopbackSiblingSnapshotDirectories(resolved, trust: startupPreflight.catalogTrust)
                    )
                case .llamaCpp:
                    // The GGUF file llama.cpp serves is named by the operator
                    // (MACPROVIDER_LLAMACPP_MODEL_ROOT / _PATH, as for
                    // `models discover`), never by the runtime.
                    modelRuntime = try await OpenAICompatibleLoopbackRuntime.llamaCpp(
                        servedModelRef: loopbackServedRef,
                        origin: LlamaCppLoopbackServeModel.resolveOrigin(configured: resolved.loopbackOrigin),
                        selector: try BYOMLlamaCppArtifactSelector.resolve(cliRoot: nil, cliPath: nil),
                        catalogModelIDAlias: catalogModelIDAlias,
                        siblingSnapshotSHA256: startupPreflight.catalogTrust?.siblingSnapshotSHA256,
                        siblingSnapshotDirectories: Self.loopbackSiblingSnapshotDirectories(resolved, trust: startupPreflight.catalogTrust)
                    )
                case .mlxLM:
                    // SPEC-010-R009: the MLX snapshot mlx_lm.server serves is
                    // named by the operator (MACPROVIDER_MLXLM_MODEL_PATH) and
                    // hashed by the CLI, never reported by the runtime.
                    modelRuntime = try await OpenAICompatibleLoopbackRuntime.mlxLM(
                        servedModelRef: loopbackServedRef,
                        origin: MLXLMLoopbackServeModel.resolveOrigin(configured: resolved.loopbackOrigin),
                        snapshotDirectory: MLXLMLoopbackServeModel.snapshotDirectory(),
                        catalogModelIDAlias: catalogModelIDAlias
                    )
                case .lmStudio:
                    // SPEC-010-R007(i) / SPEC-046-R009 (#1690 M9): the GGUF is
                    // the one file the operator's LM Studio models root
                    // (MACPROVIDER_LMSTUDIO_MODELS_ROOT) resolves for the key,
                    // hashed by the CLI; LM Studio names no file.
                    modelRuntime = try await OpenAICompatibleLoopbackRuntime.lmStudio(
                        servedModelRef: loopbackServedRef,
                        origin: LMStudioLoopbackServeModel.resolveOrigin(configured: resolved.loopbackOrigin),
                        catalogModelIDAlias: catalogModelIDAlias,
                        siblingSnapshotSHA256: startupPreflight.catalogTrust?.siblingSnapshotSHA256,
                        siblingSnapshotDirectories: Self.loopbackSiblingSnapshotDirectories(resolved, trust: startupPreflight.catalogTrust)
                    )
                case .oMLX:
                    // SPEC-010-R009 (#1690 M9): the MLX snapshot oMLX serves
                    // is named by the operator (MACPROVIDER_OMLX_MODEL_PATH)
                    // and hashed by the CLI, never reported by the runtime.
                    modelRuntime = try await OpenAICompatibleLoopbackRuntime.oMLX(
                        servedModelRef: loopbackServedRef,
                        origin: OMLXLoopbackServeModel.resolveOrigin(configured: resolved.loopbackOrigin),
                        snapshotDirectory: OMLXLoopbackServeModel.snapshotDirectory(),
                        catalogModelIDAlias: catalogModelIDAlias
                    )
                }
            } else {
                helloRuntimeSource = nil
                if let applied = ModelRuntime.applyMLXCacheLimit(megabytes: resolved.mlxCacheLimitMB) {
                    FileHandle.standardError.write(Data("mlx_cache_limit_bytes=\(applied)\n".utf8))
                }
                modelRuntime = try await ModelRuntime(
                    modelID: resolved.model,
                    modelLoadPath: startupPreflight.runtimeBinding?.loadPath ?? resolved.modelArtifactPath,
                    draftModelID: resolved.draftModel,
                    draftModelLoadPath: verifiedDraftModelLoadPath,
                    numDraftTokens: resolved.numDraftTokens,
                    speculativeCacheWrapValidated: speculativeCacheWrapValidated,
                    maxContextTokensOverride: resolved.maxContextOverride,
                    kvBitsOverride: effectiveKVBits,
                    pagedKVConfig: resolved.pagedKV.sizedToCover(
                        contextTokens: ProviderCapacity(maxContextOverride: resolved.maxContextOverride, maxConcurrencyOverride: nil).maxContextTokens
                    ),
                    prefillStepSize: resolved.prefillStepSize,
                    maxBatch: ProviderCapacity.servedSlotCount(maxConcurrencyOverride: resolved.maxConcurrencyOverride),
                    continuousBatchingMode: resolved.continuousBatching,
                    continuousBatchQueueLimit: resolved.continuousBatchQueueLimit,
                    continuousBatchQueueWaitTimeoutMS: resolved.continuousBatchQueueWaitTimeoutMS,
                    continuousBatchPrefillTokensPerIteration: resolved.continuousBatchPrefillTokensPerIteration,
                    continuousBatchingCachedTurns: resolved.continuousBatchingCachedTurns,
                    continuousBatchingAcceptanceCoverage: ContinuousBatchingAcceptanceCoverage(
                        acceptedTuples: effectiveAcceptedTuples
                    ),
                    continuousBatchingPolicyLoadResult: continuousBatchingPolicy,
                    continuousBatchingEmergencyOffOverride: emergencyOffOverride,
                    continuousBatchingModeExplicitlyConfigured: resolved.continuousBatchingExplicitlyConfigured,
                    nativeMTPMode: resolved.nativeMTPMode,
                    nativeMTPAdmissionSidecarPath: startupPreflight.runtimeBinding?.nativeMTPAdmissionSidecarPath,
                    nativeMTPAdmissionArtifactRoot: startupPreflight.runtimeBinding?.nativeMTPAdmissionArtifactRoot,
                    nativeMTPResolvedArtifactAuthority: startupPreflight.runtimeBinding?.nativeMTPResolvedArtifactAuthority,
                    warmSwapEnabled: resolved.enableWarmSwap,
                    swapDrainTimeoutSeconds: resolved.swapDrainTimeoutSeconds,
                    catalogModelIDAlias: catalogModelIDAlias,
                    verifiedModelArtifactSHA256: resolved.modelArtifactSHA256,
                    verifiedModelLoadSHA256: startupPreflight.runtimeBinding?.loadSHA256,
                    // MEDIUM-5 (FR-KVP4): thread the catalog REVISION separately from the
                    // artifact SHA so the cold-tier envelope carries both as distinct identity
                    // fields; nil ⇒ cold tier treats identity as unavailable (no promote/persist).
                    verifiedModelCatalogRevision: resolved.modelCatalogRevision,
                    targetAuthorities: targetAuthorities,
                    authorizedSwitchModelIDs: authorizedSwitchModelIDs,
                    switchMaxContextByTarget: switchMaxContextByTarget,
                    switchMaxBatchByTarget: switchMaxBatchByTarget,
                    switchContextProvenanceModelIDs: switchContextProvenanceModelIDs
                )
            }
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
        // standalone `malibu-cli kv-cache` invocation can acquire the free
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
        // SPEC-037 encrypted KV survival is an MLX-runtime data path; the SPEC-046
        // loopback serving runtime holds no local KV cache, so the tier is only
        // activated when an MLX `ModelRuntime` is serving.
        if let mlxRuntime = modelRuntime as? ModelRuntime,
           resolved.kvDiskCache.effectiveEnabled,
           let kvProviderID = resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !kvProviderID.isEmpty {
            let kvTTL = Int(ConversationCache.Config.fromEnvironment().ttlSeconds)
            let tier = KVDiskTier(config: resolved.kvDiskCache, namespaceID: kvProviderID, eligibilityTTLSeconds: kvTTL)
            switch await tier.activateForServeDetailed() {
            case .activated:
                await mlxRuntime.attachKVDiskTier(tier)
                kvDiskTier = tier
            case .dormantLock, .dormantKeychain:
                // FR-KVP7 (M-13): the namespace lock is held by another writer, OR
                // (Item 6 / FR-KVP6) the Keychain is unavailable pre-unlock — keep the
                // tier and retry with bounded backoff in the background, running full
                // recovery and attaching once the condition clears.
                kvDiskTier = tier
                Task { [mlxRuntime] in
                    await tier.retryActivationUntilAcquired { await mlxRuntime.attachKVDiskTier(tier) }
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
            maxConcurrencyOverride: ProviderCapacity.servedSlotCount(maxConcurrencyOverride: resolved.maxConcurrencyOverride),
            maxContextSource: resolved.maxContextSource
        )
        // A loopback runtime probes through its upstream chat-completions leg
        // (SPEC-001 FR-20, #1690): a 0 estimate falls under the coordinator's
        // routing throughput floor, so an unprobed loopback provider never routes.
        var loopbackProbeSucceeded = false
        let throughputEstimate = await Self.startupThroughputEstimate(
            autotuneCandidate: autotuneCandidate,
            measure: {
                if let mlxRuntime = modelRuntime as? ModelRuntime {
                    return await mlxRuntime.measureStartupThroughput(
                        maxTokens: ModelRuntime.startupThroughputProbeMaxTokens
                    )
                }
                if let loopbackRuntime = modelRuntime as? OpenAICompatibleLoopbackRuntime {
                    let outcome = await loopbackRuntime.measureStartupThroughput(
                        maxTokens: ModelRuntime.startupThroughputProbeMaxTokens
                    )
                    print(outcome.logLine(runtimeSource: loopbackRuntime.runtimeSource))
                    loopbackProbeSucceeded = outcome.tps > 0
                    return outcome.tps
                }
                return 0
            }
        )
        // #1689: operator-visible provenance for the estimate above. `nil`
        // means no probe ran (autotune candidate) or a loopback probe failed.
        var startupThroughputProbe: StartupThroughputProbe?
        if !autotuneCandidate, let mlxRuntime = modelRuntime as? ModelRuntime {
            startupThroughputProbe = StartupThroughputProbe(
                maxTokens: ModelRuntime.startupThroughputProbeMaxTokens,
                modelID: await mlxRuntime.loadedModelID ?? resolved.model
            )
        } else if !autotuneCandidate, loopbackProbeSucceeded, let loopbackRuntime = modelRuntime as? OpenAICompatibleLoopbackRuntime {
            startupThroughputProbe = StartupThroughputProbe(
                maxTokens: ModelRuntime.startupThroughputProbeMaxTokens,
                modelID: loopbackRuntime.servedModelRef
            )
        }
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
            capacity: capacityDefaults.withThroughputEstimate(throughputEstimate, probe: startupThroughputProbe),
            modelHash: await modelRuntime.loadedModelHash,
            modelHashAlgorithm: await modelRuntime.loadedModelHashAlgorithm,
            weightsManifestSHA256: await modelRuntime.loadedWeightsManifestSHA256,
            thermalGate: thermalGate,
            specDecodeDraftModelID: speculativeCacheWrapValidated ? resolved.draftModel : nil,
            specDecodeNumDraftTokens: speculativeCacheWrapValidated ? resolved.numDraftTokens : nil,
            providerID: resolved.providerID
        )
        if operatorPausedInitially {
            await providerStatus.setState(.unavailable, reason: "operator_pause_restored")
        }
        await modelRuntime.setProviderStatus(providerStatus)
        let receiptKeyStore = ProviderCredentialStoreFactory.receiptKeyStore(for: resolved)
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
                try Self.validateProtectedFileAdmissionIdentityForServe(
                    config: resolved,
                    providerID: providerID,
                    recoveryMarker: recoveryMarker,
                    isolateLifecycle: isolateLifecycle
                )
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
                source: providerAdmissionRecovery
                    ? "\(credentialSource.rawValue)_pending"
                    : (admissionIdentityWasPersisted ? credentialSource.rawValue : "local_recovery_candidate"),
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
        let labScopedPrivacySESigner: (any SEBlobSigner)?
        let labScopedSELivenessSigner: (any SELivenessSigning)?
        let labScopedAttestationGenerator: Tier2AttestationTokenGenerating?
        if let privacyLabIdentityScope {
            #if arch(arm64)
            do {
                let identity = try SecureEnclaveIdentity.loadOrCreate(
                    label: privacyLabIdentityScope.secureEnclaveLabel,
                    quiet: true,
                    fileBackedURL: privacyLabIdentityScope.secureEnclaveFileURL
                )
                labScopedPrivacySESigner = resolved.privacyClassBeta ? identity : nil
                labScopedSELivenessSigner = identity
                labScopedAttestationGenerator = SecureEnclaveAttestationGenerator(signer: identity)
            } catch {
                if resolved.privacyClassBeta {
                    FileHandle.standardError.write(Data("FATAL privacy_class_se_identity_failed\n".utf8))
                    throw ExitCode(78)
                } else {
                    labScopedPrivacySESigner = nil
                    labScopedSELivenessSigner = nil
                    labScopedAttestationGenerator = nil
                    FileHandle.standardError.write(Data("WARN privacy_lab_scoped_identity_unavailable ordinary_mode_omits_se_identity\n".utf8))
                }
            }
            #else
            if resolved.privacyClassBeta {
                FileHandle.standardError.write(Data("FATAL privacy_class_se_identity_failed\n".utf8))
                throw ExitCode(78)
            } else {
                labScopedPrivacySESigner = nil
                labScopedSELivenessSigner = nil
                labScopedAttestationGenerator = nil
            }
            #endif
        } else {
            labScopedPrivacySESigner = nil
            labScopedSELivenessSigner = nil
            labScopedAttestationGenerator = nil
        }
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
                runtimeSource: helloRuntimeSource,
                attestationGenerator: {
                    if privacyLabIdentityScope != nil {
                        return labScopedAttestationGenerator
                    }
                    #if arch(arm64)
                    return SecureEnclaveAttestationGenerator.loadIfAvailable()
                        ?? ManagedDeviceAttestationGenerator(artifactPath: resolved.tier2MDAArtifactPath)
                    #else
                    return ManagedDeviceAttestationGenerator(artifactPath: resolved.tier2MDAArtifactPath)
                    #endif
                }(),
                seLivenessSignerOverride: labScopedSELivenessSigner,
                privacySESignerOverride: labScopedPrivacySESigner,
                providerReceiptPublicKey: providerReceiptPublicKey,
                providerAdmissionPublicKey: providerAdmissionPublicKey,
                providerAdmissionNextPublicKey: providerAdmissionNextPublicKey,
                providerAdmissionRecovery: providerAdmissionRecovery,
                commitAdmissionIdentityPublicKey: commitAdmissionIdentityPublicKey,
                receiptBuilder: receiptRuntime.builder,
                labLoopbackCatalogReadinessWaived: Self.waivesLabLoopbackCatalogReadiness(
                    isolateLifecycle: isolateLifecycle,
                    credentialStore: resolved.credentialStore,
                    coordinatorURL: resolved.coordinatorURL,
                    hasCatalogTrust: startupPreflight.catalogTrust != nil
                ),
                catalogReleaseID: startupPreflight.catalogTrust?.releaseID,
                catalogPolicyVersion: startupPreflight.catalogTrust?.policyVersion,
                catalogCandidateSHA256: startupPreflight.catalogTrust?.digest,
                catalogSignerKeyID: startupPreflight.catalogTrust?.signerKeyID,
                catalogRowIdentity: startupPreflight.catalogTrust?.rowIdentity,
                catalogModelSHA256: startupPreflight.catalogTrust?.modelSHA256,
                catalogEnvelopeRefresher: startupPreflight.catalogTrust?.modelSHA256.map { servedModelSHA256 in
                    let refreshConfig = resolved
                    return {
                        await Self.refreshCatalogEnvelope(
                            config: refreshConfig,
                            servedModelSHA256: servedModelSHA256
                        )
                    }
                },
                receiptIdentitySigningKeyCandidates: admissionIdentitySigningKeyCandidates,
                persistReceiptIdentitySigningKey: persistAdmissionIdentitySigningKey,
                providerCredentialStore: credentialStore,
                providerCredentialSource: credentialSource,
                credentialStatusRuntime: credentialStatusRuntime,
                admissionIdentityStatusRuntime: admissionIdentityStatusRuntime,
                privacyLabIdentityScope: privacyLabIdentityScope,
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
           let receiptSigningKeyStore = receiptRuntime.signingKeyStore,
           let coordinatorClient {
            receiptRotator = {
                try await RotateKeyCommand.rotateActiveProvider(
                    providerID: providerID,
                    keyStore: receiptSigningKeyStore,
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
	        let providerWalletStatusClient = try? ProviderWalletStatusClient(coordinatorURL: resolved.coordinatorURL)
	        let providerRewardAuditClient = try? ProviderRewardAuditClient(coordinatorURL: resolved.coordinatorURL)
	        if let mlxRuntime = modelRuntime as? ModelRuntime {
	        controlSocket = ControlSocketServer(
            socketPath: socketURL,
            modelRuntime: mlxRuntime,
            supportedModels: resolved.supportedModels,
            receiptRotator: receiptRotator,
            receiptRotationProviderID: resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
            providerStatus: providerStatus,
            providerEarningsClient: providerEarningsClient,
	            referralCoordinatorService: referralCoordinatorService,
	            malibuAccrualClient: malibuAccrualClient,
	            providerWalletStatusClient: providerWalletStatusClient,
	            providerRewardAuditClient: providerRewardAuditClient,
	            providerToken: resolved.providerToken,
            pauseProvider: pauseProvider,
            resumeProvider: resumeProvider,
            watchdogCleanup: coordinatorClient == nil ? nil : watchdogCleanup,
            kvDiskTier: kvDiskTier
        )
        } else {
            // SPEC-046 loopback serving runtime (#1569) exposes no MLX warm-swap,
            // model-adoption, or hot-conversation-purge control surface.
            controlSocket = nil
        }
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

    static let providerLaunchdServiceIdentity = "live.malibu.provider"

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
        allowStartupHandoff: Bool = true,
        allowAdoptedHandoffRecovery: Bool = false
    ) throws -> ProviderLifecycleLeaseRecord {
        guard allowStartupHandoff else {
            return try store.acquire(
                kind: .startup,
                operationID: operationID,
                duration: duration
            )
        }
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
        noJoin: Bool,
        isolateLifecycle: Bool = false
    ) throws {
        guard !noJoin, !config.donorMode else { return }
        guard !relaxesJoinAdmissionForLab(
            isolateLifecycle: isolateLifecycle,
            coordinatorURL: config.coordinatorURL
        ) else { return }
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
        let runtimeBinding: VerifiedModelRuntimeBinding?
    }

    static func runServeStartupPreflights(
        _ resolved: inout AppConfig,
        joiningCoordinator: Bool,
        isolateLifecycle: Bool = false,
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
            let modelPreflight: ModelArtifactPreflightOutcome
            do {
                modelPreflight = try await Self.runModelArtifactPreflightOutcome(
                    &resolved,
                    joiningCoordinator: joiningCoordinator,
                    isolateLifecycle: isolateLifecycle,
                    staticInputs: staticInputs,
                    artifactResolver: artifactResolver,
                    persistConfigMigration: true
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
                catalogTrust: modelPreflight.catalogTrust,
                runtimeBinding: modelPreflight.runtimeBinding
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
    ) throws -> (builder: ReceiptBuilder?, publicKeyBase64: String?, signingKeyStore: ReceiptKeyStoring?) {
        guard config.enableReceipts,
              let providerID = config.providerID,
              !providerID.isEmpty else {
            return (nil, nil, nil)
        }
        let cachingStore = CachedReceiptKeyStore(keyStore)
        let privateKey: Curve25519.Signing.PrivateKey
        if config.credentialStore == .protectedFile {
            guard let existing = try cachingStore.loadCurrent(providerId: providerID) else {
                throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerID)
            }
            privateKey = existing
        } else {
            privateKey = try cachingStore.loadOrGenerate(providerId: providerID)
        }
        // The builder caches the signing key for the process lifetime, so a
        // receipt-key rotation MUST swap through this same caching store
        // (signingKeyStore). Swapping the underlying store alone leaves the
        // builder signing with the retired key (#1690 E2E-F9).
        return (
            ReceiptBuilder(keyStore: cachingStore),
            Data(privateKey.publicKey.rawRepresentation).base64EncodedString(),
            cachingStore
        )
    }

    static func validateProtectedFileAdmissionIdentityForServe(
        config: AppConfig,
        providerID: String,
        recoveryMarker: Data?,
        isolateLifecycle: Bool = false
    ) throws {
        guard !relaxesJoinAdmissionForLab(
            isolateLifecycle: isolateLifecycle,
            coordinatorURL: config.coordinatorURL
        ) else { return }
        guard config.credentialStore == .protectedFile, recoveryMarker == nil else { return }
        throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerID)
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
            advanced: advanced,
            coordinatorURL: resolved.coordinatorURL,
            sustainedBenchmarks: advanced ? Self.sustainedBenchmarks() : [],
            contextWarnings: advanced ? Self.contextWarnings(status: status, configPath: resolved.configPath) : []
        ))
    }

    /// Best effort, from the config file alone (the launchd service does not
    /// inherit this shell) and the served model's local `config.json`.
    static func contextWarnings(status: [String: Any], configPath: String) -> [String] {
        let fileConfig = try? ConfigLoader.load(cli: CLIOverrides(configPath: configPath), environment: [:])
        let artifactPath = ProviderContextWorkflow.servedModelArtifactPath(modelID: status["model"] as? String, config: fileConfig)
        return ProviderContextWorkflow.statusContextWarnings(
            status: status,
            config: fileConfig,
            physicalMemoryGB: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil).ramGB,
            facts: ProviderContextWorkflow.liveModelFacts(artifactPath: artifactPath)
        )
    }

    /// Best effort: a missing, unsafe, or undecodable recommendation state
    /// yields no benchmarks and never fails `status`.
    static func sustainedBenchmarks(stateURL: URL = RecommendationStateStore.defaultURL) -> [BenchmarkPayload] {
        (try? RecommendationStateStore.read(from: stateURL))?.hardwareEvidence?.benchmarks ?? []
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
        var resolved = try ConfigLoader.load(
            cli: CLIOverrides(model: model, configPath: config)
        )
        let preflight = try await ServeCommand.runModelArtifactPreflightOutcome(
            &resolved,
            joiningCoordinator: false
        )
        let runtime = try await ModelRuntime(
            modelID: resolved.model,
            modelLoadPath: preflight.runtimeBinding?.loadPath ?? Self.modelLoadPath(for: resolved),
            maxContextTokensOverride: resolved.maxContextOverride,
            verifiedModelArtifactSHA256: resolved.modelArtifactSHA256,
            verifiedModelLoadSHA256: preflight.runtimeBinding?.loadSHA256
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
        let hasAcceptanceOptions = acceptanceDirectory != nil || acceptanceTag != nil || acceptanceCommit != nil
            || acceptanceRunID != nil || acceptanceControlCommit != nil || acceptanceRunAttempt != nil
        let resolvedConfig: AppConfig?
        do {
            resolvedConfig = try ConfigLoader.load(cli: CLIOverrides())
        } catch {
            guard check, !hasAcceptanceOptions else {
                throw ValidationError(
                    "cannot determine install profile for mutating update; fix macprovider config or use the signed headless installer acceptance bundle"
                )
            }
            resolvedConfig = nil
        }
        try Self.validateHeadlessUpdateMode(
            config: resolvedConfig,
            checkOnly: check,
            hasAcceptanceOptions: hasAcceptanceOptions,
            home: FileManager.default.homeDirectoryForCurrentUser
        )

        // #616/#610: converge PATH, then hand off to the canonical install binary
        // when this process was launched from a divergent PATH copy so update
        // runs with sibling compatibility-set.json and matching provider_cli.
        let updateMarkerStore = AutoUpdateMarkerStore()
        if resolvedConfig?.credentialStore != .protectedFile,
           let canonical = try updateMarkerStore.ensurePathEntrypointMatchesInstallAuthority(),
           let launched = Bundle.main.executableURL?.standardizedFileURL,
           launched.path != canonical.standardizedFileURL.path {
            try execCanonicalInstall(canonical)
        }
        let updater = SelfUpdate(
            currentVersion: CoordinatorClient.binaryVersion,
            releasesAPIURL: releasesAPIURL,
            coordinatorURL: resolvedConfig?.coordinatorURL,
            providerID: resolvedConfig?.providerID
        )
        if hasAcceptanceOptions {
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
            Run: malibu-cli autotune --recommend

            """.utf8))
        }
    }

    static func validateHeadlessUpdateMode(
        config: AppConfig?,
        checkOnly: Bool,
        hasAcceptanceOptions: Bool,
        home: URL,
        manifestLoader: (() throws -> UninstallCommand.ManifestLoadResult)? = nil,
        validateSystemArtifactsAbsent: (([String], @escaping ([String]) throws -> Int32) throws -> Void)? = nil,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        runLaunchctl: (([String]) throws -> Int32)? = nil
    ) throws {
        if checkOnly, !hasAcceptanceOptions { return }
        let rejectMessage = "headless_fleet does not support mutating malibu-cli update yet; use the signed headless installer acceptance bundle"
        let loadManifest = manifestLoader ?? {
            try UninstallCommand.loadManifest(home: home)
        }
        do {
            switch try loadManifest() {
            case .loaded(let manifest):
                if manifest.installProfile == "headless_fleet" || manifest.launchdDomain == "system" {
                    throw ValidationError(rejectMessage)
                }
                if config?.credentialStore == .protectedFile {
                    guard AutoUpdater.manifestDeclaresConsumerGUIForCurrentUser(manifest) else {
                        throw ValidationError(rejectMessage)
                    }
                }
            case .missing:
                if config?.credentialStore == .protectedFile {
                    throw ValidationError(rejectMessage)
                }
            }
            let validator = validateSystemArtifactsAbsent ?? { systemPlists, run in
                try UninstallCommand.validateNoHeadlessSystemArtifactsPresent(
                    systemPlists: systemPlists,
                    fileExists: fileExists,
                    run: run
                )
            }
            try validator(UninstallCommand.managedSystemLaunchDaemonPlists, runLaunchctl ?? Self.launchctlStatus)
        } catch let error as ValidationError {
            throw error
        } catch UninstallCommand.UninstallError.unsupportedHeadlessInstallProfile {
            throw ValidationError(rejectMessage)
        } catch UninstallCommand.UninstallError.headlessProfileIndeterminateWithoutManifest {
            throw ValidationError(
                "cannot determine install profile for mutating update because system launchd state is indeterminate; fix or remove the headless system LaunchDaemon first"
            )
        } catch UninstallCommand.UninstallError.invalidInstallManifest {
            throw ValidationError(
                "cannot determine install profile for mutating update; fix macprovider install manifest or use the signed headless installer acceptance bundle"
            )
        } catch {
            throw error
        }
    }

    private static func launchctlStatus(arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Replaces this process with the canonical install binary and the same argv
/// after PATH entrypoint repair (#616). Used by serve/update when launched from
/// a stale `~/.local/bin` regular-file copy.
/// #616 hand-off guard: a newer running binary never silently re-execs into an
/// older canonical install, which would reject newer flags with a misleading
/// usage error or serve with older code. The hand-off fails closed: it runs only
/// when a strict `X.Y.Z` canonical version proves the canonical install is the
/// same as or newer than this binary. A missing, invalid, or timed-out version
/// is refused with its own reason.
enum CanonicalReexecDecision: Equatable {
    case reexec
    case refuse(canonicalVersion: String)
    case refuseUnknownVersion

    static func decide(canonicalVersion: String?, runningVersion: String) -> CanonicalReexecDecision {
        guard let canonicalVersion,
              let canonical = try? SelfUpdate.validateReleaseTag(canonicalVersion),
              let running = try? SelfUpdate.validateReleaseTag(runningVersion) else {
            return .refuseUnknownVersion
        }
        if SelfUpdate.compareSemver(canonical, running) == .orderedAscending {
            return .refuse(canonicalVersion: canonical)
        }
        return .reexec
    }

    static func fatalLine(path: String, canonicalVersion: String, runningVersion: String) -> String {
        "FATAL canonical_install_older path=\(path) canonical=\(canonicalVersion) running=\(runningVersion): "
            + "update or reinstall the canonical provider, or run the canonical binary\n"
    }

    static func unknownVersionFatalLine(path: String, runningVersion: String) -> String {
        "FATAL canonical_install_version_unknown path=\(path) running=\(runningVersion): "
            + "the canonical provider's version could not be read; update or reinstall the canonical provider, "
            + "or run the canonical binary\n"
    }
}

/// The canonical binary's version: the signed sibling compatibility set's
/// `provider_cli` member when present, else `<canonical> --version` bounded to
/// five seconds. Nil when neither yields a strict `X.Y.Z`.
private func canonicalInstallVersion(_ canonical: URL) -> String? {
    if let payload = CompatibilitySetManifest.payloadDirectory(for: canonical),
       let manifest = try? CompatibilitySetManifest.loadValidated(from: payload) {
        return manifest.providerCLIVersion
    }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = canonical
    process.arguments = ["--version"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return nil }
    guard exited.wait(timeout: .now() + 5) == .success else {
        process.terminate()
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return try? SelfUpdate.validateReleaseTag(output)
}

private func execCanonicalInstall(_ canonical: URL) throws -> Never {
    let fatal: String
    switch CanonicalReexecDecision.decide(
        canonicalVersion: canonicalInstallVersion(canonical),
        runningVersion: CoordinatorClient.binaryVersion
    ) {
    case .reexec:
        fatal = ""
    case .refuse(let canonicalVersion):
        fatal = CanonicalReexecDecision.fatalLine(
            path: canonical.path,
            canonicalVersion: canonicalVersion,
            runningVersion: CoordinatorClient.binaryVersion
        )
    case .refuseUnknownVersion:
        fatal = CanonicalReexecDecision.unknownVersionFatalLine(
            path: canonical.path,
            runningVersion: CoordinatorClient.binaryVersion
        )
    }
    if !fatal.isEmpty {
        FileHandle.standardError.write(Data(fatal.utf8))
        try? FileHandle.standardError.synchronize()
        // EX_CONFIG, as for the SPEC-049-R007 hardening refusal.
        throw ExitCode(78)
    }
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

/// Ensures only the first SIGTERM/SIGINT drives shutdown. A second signal during
/// the bounded drain must NOT re-evaluate the (already consumed, consume-once)
/// stop-intent marker, which would reclassify a legitimate local stop as
/// unsolicited and change the exit code.
private final class TerminationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    func beginIfFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if started { return false }
        started = true
        return true
    }
}

private func installTerminationHandlers(
    coordinatorClient: CoordinatorClient?,
    controlSocket: ControlSocketServer?,
    idlePrewarmer: IdlePrewarmer?,
    kvDiskTier: KVDiskTier?
) -> [DispatchSourceSignal] {
    let latch = TerminationLatch()
    return [SIGTERM, SIGINT].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            Task {
                // Only the first signal decides and consumes the marker; a second
                // signal during drain is ignored so it cannot reclassify the stop.
                guard latch.beginIfFirst() else { return }
                // SPEC-001 FR-12 / SPEC-020 R-4.14: decide the exit code BEFORE
                // draining. `drainAndExit` calls Darwin.exit itself for the normal
                // coordinator-joined provider, so the decision and the exit code
                // must be computed up front and threaded through it — otherwise the
                // gate is unreachable on the common path. Exit 0 only under a
                // validated local stop intent (uninstall/operator-disable/local
                // stop, which records a PID+boot+process-start-bound marker). An
                // unsolicited SIGTERM/SIGINT — a stray kill or a macOS
                // memory-pressure/jetsam SIGTERM while the launchd job is still
                // loaded — exits nonzero so launchd KeepAlive{SuccessfulExit:false}
                // relaunches the provider instead of leaving the node down
                // (removing the watchdog exit-restart is safe only because of this).
                // A coordinator drain drops registration only and never reaches here.
                let exitCode: Int32 = StopIntentMarker.consumeIfValid(currentPID: getpid())
                    ? 0
                    : (128 + signalNumber)
                await idlePrewarmer?.stop()
                await controlSocket?.stop()
                await coordinatorClient?.drainAndExit(
                    reason: "\(signalName(signalNumber)) received",
                    exitCode: exitCode
                )
                // M-A: drain queued cold writes (bounded by shutdownDrainSeconds) and
                // release the namespace lock BEFORE exit, on the signal path too.
                // (Reached only when there is no coordinator client, e.g. --no-join.)
                await kvDiskTier?.shutdown()
                Darwin.exit(exitCode)
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
    print("malibu-cli config")
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
    print("  continuous_batch_queue_wait_timeout_ms: \(config.continuousBatchQueueWaitTimeoutMS.map(String.init) ?? "<unset, 30000>")")
    print("  continuous_batch_prefill_tokens_per_iteration: \(config.continuousBatchPrefillTokensPerIteration.map(String.init) ?? "<unset, 2048>")")
    print("  continuous_batching_cached_turns: \(config.continuousBatchingCachedTurns)")
    print("  enable_receipts: \(config.enableReceipts)")
    print("  relay_blind_enabled: \(config.relayBlindEnabled)")
    print("  privacy_class_beta: \(config.privacyClassBeta)")
    print("  idle_prewarm.enabled: \(config.idlePrewarmEnabled)")
    print("  idle_prewarm.idle_threshold_seconds: \(config.idlePrewarmIdleThresholdSeconds)")
    print("  idle_prewarm.tick_seconds: \(config.idlePrewarmTickSeconds)")
    print("  idle_prewarm.max_tokens: \(config.idlePrewarmMaxTokens)")
    print("  idle_prewarm.prompt: \(config.idlePrewarmPrompt)")
    print("  idle_prewarm.run_on_battery: \(config.idlePrewarmRunOnBattery)")
    print("  stream_interval: \(config.streamInterval)")
    print("  prefill_step_size: \(config.prefillStepSize)")
}
