import Foundation
import Yams

public enum LogFormat: String, Sendable {
    case json
    case text
}

public enum LogLevel: String, Sendable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical
}

public enum ContinuousBatchingMode: String, Sendable {
    case off
    case canary
    case on
}

public enum NativeMTPMode: String, Sendable {
    case off
    case auto
}

/// SPEC-038 FR-CB10: one operator-declared tuple that real-hardware acceptance
/// (AC-14 / AC-23) actually qualified for continuous batching. Declared in the
/// `continuous_batching_accepted_tuples` config key; an absent key covers
/// nothing.
///
/// This lives in `MacProviderCore` next to `ContinuousBatchingMode` and
/// `PagedKVDType` because configuration parsing owns it; the CLI's
/// `ContinuousBatchingAcceptanceCoverage` matches requested tuples against it.
public struct ContinuousBatchingAcceptedTuple: Sendable, Equatable {
    public let modelID: String
    public let modelSHA256: String
    public let tokenizerSHA256: String?
    public let chatTemplateSHA256: String?
    public let cacheClass: String
    public let kvDType: PagedKVDType
    public let requiresMoE: Bool
    public let hardwareClass: String
    /// The runtime revision the acceptance evidence was measured on. A new
    /// build with a different Metal library or paged-KV kernel is a different
    /// runtime: it must be re-measured (including the SPEC-039 FR-PKV13
    /// overhead ceiling) and re-accepted, not inherit this entry.
    public let metallibSHA256: String
    public let kernelIdentifier: String
    /// SPEC-038 AC-26: the operator recorded the packaged gateway/relay proof
    /// for positive-cached turns on exactly this tuple and runtime revision.
    /// Only then may `continuous_batching_cached_turns` batch such turns here.
    /// Optional in config; absent means false.
    public let cachedTurnsAccepted: Bool

    public init(
        modelID: String,
        modelSHA256: String,
        tokenizerSHA256: String? = nil,
        chatTemplateSHA256: String? = nil,
        cacheClass: String,
        kvDType: PagedKVDType,
        requiresMoE: Bool,
        hardwareClass: String,
        metallibSHA256: String,
        kernelIdentifier: String,
        cachedTurnsAccepted: Bool = false
    ) {
        self.modelID = modelID
        self.modelSHA256 = modelSHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.chatTemplateSHA256 = chatTemplateSHA256
        self.cacheClass = cacheClass
        self.kvDType = kvDType
        self.requiresMoE = requiresMoE
        self.hardwareClass = hardwareClass
        self.metallibSHA256 = metallibSHA256
        self.kernelIdentifier = kernelIdentifier
        self.cachedTurnsAccepted = cachedTurnsAccepted
    }
}

/// Where the effective serve context cap came from (#1689, SPEC-001 FR-17
/// `capacity.max_context_source`). Recorded where the value is resolved;
/// `nil` on `AppConfig` means nothing overrode the RAM-tier default.
public enum MaxContextSource: String, Sendable {
    case operatorConfig = "operator_config"
    case environment
    case cliFlag = "cli_flag"
    case ramTierDefault = "ram_tier_default"
    case draftClamp = "draft_clamp"
    case recommendationAdoption = "recommendation_adoption"
    /// Config `max_context_override` written by `autotune --recommend --apply`
    /// (or a recommendation adoption), per its `max_context_override_provenance`.
    case recommendationApply = "recommendation_apply"
}

/// Which recommendation generated `max_context_override` (#1689, SPEC-001
/// FR-20b). It lives in config.yaml itself, as the one-line mapping
/// `max_context_override_provenance: {…}`, so the config lock, atomic write,
/// `.bak-` backups, rollback, and the adoption journal carry it together with
/// the value. Older CLIs ignore the unknown key.
///
/// The binding is field-scoped: the config value is generated iff the record
/// says `source: recommendation_apply`, names a model, and records exactly
/// the current `max_context_override`. Edits to other keys do not change
/// ownership. `provider context set` removes the record in the same write, and
/// a hand edit to a different value no longer matches it. Accepted trade-off:
/// a hand edit to exactly the generated number stays generated, so a later
/// model switch recomputes it. An absent, malformed, or mismatched record
/// leaves the value operator-owned; it never fails the config load.
public struct MaxContextProvenance: Equatable, Sendable {
    public static let configKey = "max_context_override_provenance"

    public var source: String
    public var value: Int
    /// The model the value was generated for; required.
    public var model: String
    public var benchmarkID: String?
    public var generatedAt: String?

    public init(source: String, value: Int, model: String, benchmarkID: String?, generatedAt: String?) {
        self.source = source
        self.value = value
        self.model = model
        self.benchmarkID = benchmarkID
        self.generatedAt = generatedAt
    }

    /// Tolerant: anything other than a mapping with a string `source`, an
    /// integer `value`, and a string `model` is no record.
    public static func parse(_ raw: Any?) -> MaxContextProvenance? {
        guard let map = raw as? [String: Any],
              let source = map["source"] as? String,
              let value = map["value"] as? Int,
              let model = map["model"] as? String
        else { return nil }
        return MaxContextProvenance(
            source: source,
            value: value,
            model: model,
            benchmarkID: map["benchmark_id"] as? String,
            generatedAt: map["generated_at"] as? String
        )
    }

    /// True when this record marks `value` as generated.
    public func generatedMaxContext(_ value: Int?) -> Bool {
        guard let value else { return false }
        return source == MaxContextSource.recommendationApply.rawValue
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && self.value == value
    }

    /// The single-line YAML flow mapping written after the key. Strings are
    /// always double-quoted so YAML never reads a model id or timestamp as
    /// another type.
    public var yamlFlowValue: String {
        var fields = ["source: \(Self.quoted(source))", "value: \(value)", "model: \(Self.quoted(model))"]
        if let benchmarkID { fields.append("benchmark_id: \(Self.quoted(benchmarkID))") }
        if let generatedAt { fields.append("generated_at: \(Self.quoted(generatedAt))") }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    private static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

/// Who owns `max_concurrency_override` (SPEC-023-R009, SPEC-038-R011). An
/// `owner` value is pinned: serve runs it as written. An `autotune` value,
/// and any config without the `max_concurrency_source` key (every install
/// and `autotune --recommend --apply` before this key existed), is a
/// recommendation serve recomputes at each start from the signed
/// continuous-batching policy, so a new policy entry raises existing
/// providers without another apply. Environment and `--max-batch` values are
/// owner values.
public enum MaxConcurrencySource: String, Sendable {
    case owner
    case autotune
}

public enum ProviderCredentialStoreKind: String, Sendable {
    case keychain
    case protectedFile = "protected_file"
}

public struct AppConfig: Equatable, Sendable {
    /// Config key for a served depth above `legacyMaxConcurrencyOverrideLimit`
    /// (#1906). CLIs before the 32-row bound reject `max_concurrency_override`
    /// above 8 at startup, so writers keep that key at or below 8 and carry a
    /// higher depth here. Older CLIs ignore the unknown key and serve the
    /// rollback-safe value; this CLI serves this key when it is present.
    public static let maxConcurrencyDepthOverrideKey = "max_concurrency_depth_override"
    /// The `max_concurrency_override` bound every pre-#1906 CLI enforces.
    public static let legacyMaxConcurrencyOverrideLimit = 8
    public static let maxConcurrencySourceKey = "max_concurrency_source"

    public var port: Int
    public var model: String?
    public var modelArtifactPath: String?
    public var modelArtifactSHA256: String?
    public var draftModel: String?
    public var draftModelArtifactSHA256: String?
    public var numDraftTokens: Int
    public var publishesSpecDecodeTelemetry: Bool
    public var nativeMTPMode: NativeMTPMode
    public var modelCatalogKey: String?
    public var modelCatalogModelID: String?
    public var modelCatalogRevision: String?
    public var modelCatalogSHA256: String?
    public var modelCatalogVersion: String?
    public var modelCatalogHash: String?
    public var modelArtifactRoot: String?
    public var coordinatorURL: String?
    public var providerID: String?
    public var endpointURL: String?
    public var wsTunneledMode: Bool?
    public var autoUpdateEnabled: Bool?
    public var autoupdateEnabled: Bool?
    // Operator opt-OUT knob for provisional-tier autoupdate. The effective
    // default is accept = TRUE: when this is nil (unset) or true, a
    // bearer-validated provisional provider is autoupdate-eligible — see
    // `AutoUpdateConfig.acceptProvisional`, which reads `!= false`, so unset
    // resolves to true. Set `auto_update_accept_provisional: false` to opt a
    // provider out and keep it notify-only. Accept-by-default is deliberate:
    // self-service (curl|bash) providers are always admitted at
    // `tier: provisional`, so the whole fleet is provisional and a pinned-only
    // posture would leave every provider unable to receive signed fixes without
    // manual operator SSH. Binary replacement stays independently crypto-gated
    // (SPEC-020 threat model T-3), so a coordinator can at most accelerate a
    // legitimately signed newer release. Matches SPEC-020 v0.1.5 trust table.
    public var autoUpdateAcceptProvisional: Bool?
    public var configPath: String
    public var logLevel: LogLevel
    public var logFormat: LogFormat
    public var logFile: String?
    public var maxContextOverride: Int?
    public var maxContextSource: MaxContextSource? = nil
    /// Set only when it marks `maxContextOverride` generated (source
    /// `recommendationApply`).
    public var maxContextProvenance: MaxContextProvenance? = nil
    public var maxConcurrencyOverride: Int?
    /// `nil` means autotune-derived (see `MaxConcurrencySource`).
    public var maxConcurrencySource: MaxConcurrencySource? = nil
    // SPEC-013 (autoresearch serving knobs): KV-cache quantization bits
    // forwarded to mlx-swift `GenerateParameters.kvBits`. nil ⇒ no
    // quantization (mlx-swift default). Triple-exposed: yaml key
    // `kv_bits`, env `MACPROVIDER_KV_BITS`, CLI `--kv-bits`. Validated
    // to be 4 or 8 (the values mlx-swift accepts) at serve preflight.
    public var kvBitsOverride: Int?
    public var drainTimeoutSeconds: Int
    public var warmupEnabled: Bool
    public var losslessnessProbeEnabled: Bool
    public var maxRequestBodyBytes: Int
    public var tier2MDAArtifactPath: String?
    public var supportedModels: [String]?
    public var publishesSupportedModels: Bool
    public var enableWarmSwap: Bool
    public var enableReceipts: Bool
    public var relayBlindEnabled: Bool
    /// SPEC-049-R001. Default off. YAML `privacy_class_beta`, env
    /// `MACPROVIDER_PRIVACY_CLASS_BETA`, CLI `--privacy-class-beta`.
    /// On while relay-blind is off fails configuration validation.
    public var privacyClassBeta: Bool
    public var relayBlindStateDirectory: String?
    /// SPEC-049-R024 explicit intent, independent of the resolved booleans
    /// above. Nil means the operator did not say: `privacyClassRequested`
    /// nil selects automatic mode at serve, and `relayBlindRequested` false
    /// is an explicit opt-out of automatic privacy mode.
    public var privacyClassRequested: Bool? = nil
    public var relayBlindRequested: Bool? = nil
    public var swapDrainTimeoutSeconds: Int
    public var ctlSocketPath: String?
    public var switchStatePath: String?
    public var donorMode: Bool
    public var idlePrewarmEnabled: Bool
    public var idlePrewarmIdleThresholdSeconds: Double
    public var idlePrewarmTickSeconds: Double
    public var idlePrewarmMaxTokens: Int
    public var idlePrewarmPrompt: String
    public var idlePrewarmRunOnBattery: Bool
    // SPEC-001: provider authentication token (closes XSEC-1 from
    // audits/2026-06-10/REPO_AUDIT.md). When set, the binary sends
    // "Authorization: Bearer <token>" on the WS connect and the
    // coordinator validates against its store when
    // auth.require_provider_tokens=true. Triple-exposed per house
    // convention: yaml key `provider_token`, env
    // MACPROVIDER_PROVIDER_TOKEN or CLI --token-file. Operator should
    // chmod 0600 the config file containing this value; the binary
    // never logs the token (URL is redacted, headers are not logged).
    public var providerToken: String?
    public var credentialStore: ProviderCredentialStoreKind

    // Optional origin metadata retained for diagnostics and control-socket
    // compatibility. It never transfers lifecycle, credential, identity, or
    // update authority away from the launchd-managed CLI.
    public var managedBy: String?

    // T3-01 token/chunk batching: number of content-token deltas to accumulate
    // before emitting one SSE frame. 1 = current behaviour (one frame per token).
    // Production experiment at 4 (upstream default). Triple-exposed: yaml key
    // `stream_interval`, env `MACPROVIDER_STREAM_INTERVAL`, CLI `--stream-interval`.
    public var streamInterval: Int

    // T3-02 adaptive prefill: mlx-swift chunked prefill window (GenerateParameters.prefillStepSize).
    // Default 512 matches mlx-swift-lm. Larger values reduce TTFT on long cold prefills.
    // Triple-exposed: yaml key `prefill_step_size`, env `MACPROVIDER_PREFILL_STEP_SIZE`,
    // CLI `--prefill-step-size`.
    public var prefillStepSize: Int
    public var continuousBatching: ContinuousBatchingMode
    /// True only when YAML, environment, or CLI explicitly selected a mode.
    /// An explicit `off` is the local emergency override; an implicit default
    /// may be promoted by a verified signed capability policy.
    public var continuousBatchingExplicitlyConfigured: Bool
    public var continuousBatchQueueLimit: Int?
    // SPEC-038 AC-25: bounded continuous-batching admission wait, in
    // milliseconds. Unset ⇒ the scheduler's 30s default. A request still
    // queued when it expires is rejected pre-admission, non-settling.
    public var continuousBatchQueueWaitTimeoutMS: Int?
    // SPEC-038: operator-tunable continuous-batch prefill per-iteration token
    // budget. Caps how many prompt tokens are prefilled per scheduler iteration
    // across concurrent admissions; larger values improve large-prompt TTFT and
    // de-serialize concurrent large prefills. Unset ⇒ the scheduler's
    // `defaultPrefillTokensPerIteration`. Triple-exposed: yaml key
    // `continuous_batch_prefill_tokens_per_iteration`, env
    // `MACPROVIDER_CONTINUOUS_BATCH_PREFILL_TOKENS_PER_ITERATION`, CLI
    // `--continuous-batch-prefill-tokens-per-iteration`.
    public var continuousBatchPrefillTokensPerIteration: Int?
    // SPEC-038 AC-26: let positive-cached follow-up turns that carry a usable
    // retained paged-KV handoff (plus a recurrent checkpoint on hybrid models)
    // batch instead of serial-routing. Default off; inert while
    // `continuous_batching` is off. Triple-exposed: yaml key
    // `continuous_batching_cached_turns`, env
    // `MACPROVIDER_CONTINUOUS_BATCHING_CACHED_TURNS`, CLI
    // `--[no-]continuous-batching-cached-turns`.
    public var continuousBatchingCachedTurns: Bool
    // MLX buffer-cache ceiling in MiB. MLX defaults it to its memory limit, so
    // freed GPU buffers accumulate for the life of the process (Studio live
    // provider 2026-09-24: 50 GB fresh -> ~130 GB under traffic -> kernel
    // memory kill). Unset keeps MLX's default; 0 disables the cache.
    public var mlxCacheLimitMB: Int?

    // SPEC-038 FR-CB10: per-tuple acceptance coverage. Descriptor membership
    // alone is not support; a tuple may only batch when the operator has
    // declared the real-hardware acceptance evidence for that exact tuple here.
    // Default empty ⇒ fail-closed on every Mac that takes the binary.
    public var continuousBatchingAcceptedTuples: [ContinuousBatchingAcceptedTuple]

    // SPEC-037 FR-KVP11: encrypted KV survival disk tier. Default-off; resolved
    // fail-closed (invalid value ⇒ tier disabled + `errors` populated, never a
    // process abort). See `KVDiskCacheConfig`.
    public var kvDiskCache: KVDiskCacheConfig

    // SPEC-039 FR-PKV14: provider-local paged KV residency engine. Default-off;
    // resolved fail-closed (invalid value ⇒ paged mode disabled + `errors`
    // populated, never a partial enable).
    public var pagedKV: PagedKVConfig
    /// True only when the operator explicitly set `paged_kv.enabled` through
    /// YAML, environment, or CLI. This preserves an explicit local disable
    /// while allowing verified capability policy to enable the engine.
    public var pagedKVEnabledExplicitlyConfigured: Bool

    // SPEC-046-R002 loopback serving (#1690 M2): origin of the loopback
    // runtime a `--model ollama:<tag>` / `llamacpp:<stem>` serve proxies to.
    // yaml key `loopback_origin`, env `MACPROVIDER_LOOPBACK_ORIGIN`. nil keeps
    // the per-runtime default (and `MACPROVIDER_OLLAMA_ORIGIN`, which still
    // wins for Ollama). Loopback-validated when the runtime is constructed.
    public var loopbackOrigin: String? = nil

    // #1816 SPEC-042-R015: the `pool/<pool_id>/<slug>` id a Trusted Pool
    // creator signed for the model this provider serves, accepted as a
    // request alias on that pool's routes. yaml key `pool_model_id`, env
    // `MACPROVIDER_POOL_MODEL_ID`. Never a catalog identity: it is not
    // advertised as the hello model id, and the coordinator binds the pool
    // entry only by the served artifact hash.
    public var poolModelID: String? = nil

    public static let defaultConfigPath = "~/.config/macprovider/config.yaml"

    public static func defaults(configPath: String = defaultConfigPath) -> AppConfig {
        AppConfig(
            port: 8080,
            model: nil,
            modelArtifactPath: nil,
            modelArtifactSHA256: nil,
            draftModel: nil,
            draftModelArtifactSHA256: nil,
            numDraftTokens: 3,
            publishesSpecDecodeTelemetry: false,
            nativeMTPMode: .off,
            modelCatalogKey: nil,
            modelCatalogModelID: nil,
            modelCatalogRevision: nil,
            modelCatalogSHA256: nil,
            modelCatalogVersion: nil,
            modelCatalogHash: nil,
            modelArtifactRoot: nil,
            coordinatorURL: nil,
            providerID: nil,
            endpointURL: nil,
            wsTunneledMode: nil,
            autoUpdateEnabled: nil,
            autoupdateEnabled: nil,
            autoUpdateAcceptProvisional: nil,
            configPath: configPath,
            logLevel: .info,
            logFormat: .json,
            logFile: nil,
            maxContextOverride: nil,
            maxConcurrencyOverride: nil,
            kvBitsOverride: nil,
            drainTimeoutSeconds: 30,
            warmupEnabled: true,
            losslessnessProbeEnabled: false,
            maxRequestBodyBytes: 10 * 1024 * 1024,
            tier2MDAArtifactPath: nil,
            supportedModels: nil,
            publishesSupportedModels: false,
            enableWarmSwap: false,
            enableReceipts: false,
            relayBlindEnabled: false,
            privacyClassBeta: false,
            relayBlindStateDirectory: nil,
            swapDrainTimeoutSeconds: 30,
            ctlSocketPath: nil,
            switchStatePath: nil,
            donorMode: false,
            idlePrewarmEnabled: true,
            idlePrewarmIdleThresholdSeconds: 30,
            idlePrewarmTickSeconds: 5,
            idlePrewarmMaxTokens: 1,
            idlePrewarmPrompt: "warm",
            idlePrewarmRunOnBattery: false,
            providerToken: nil,
            credentialStore: .keychain,
            managedBy: nil,
            streamInterval: 1,
            prefillStepSize: 512,
            continuousBatching: .off,
            continuousBatchingExplicitlyConfigured: false,
            continuousBatchQueueLimit: nil,
            continuousBatchQueueWaitTimeoutMS: nil,
            continuousBatchPrefillTokensPerIteration: nil,
            continuousBatchingCachedTurns: false,
            mlxCacheLimitMB: nil,
            continuousBatchingAcceptedTuples: [],
            kvDiskCache: .defaults(),
            pagedKV: .defaults(),
            pagedKVEnabledExplicitlyConfigured: false
        )
    }
}

public struct CLIOverrides: Equatable, Sendable {
    public var port: Int?
    public var model: String?
    public var modelArtifactPath: String?
    public var modelArtifactSHA256: String?
    public var draftModel: String?
    public var draftModelArtifactSHA256: String?
    public var numDraftTokens: Int?
    public var publishesSpecDecodeTelemetry: Bool?
    public var nativeMTPMode: String?
    public var coordinatorURL: String?
    public var providerID: String?
    public var endpointURL: String?
    public var configPath: String?
    public var logLevel: String?
    public var supportedModels: [String]?
    public var publishesSupportedModels: Bool?
    public var enableWarmSwap: Bool?
    public var enableReceipts: Bool?
    public var relayBlindEnabled: Bool?
    public var privacyClassBeta: Bool?
    public var relayBlindStateDirectory: String?
    public var swapDrainTimeoutSeconds: Int?
    public var ctlSocketPath: String?
    public var switchStatePath: String?
    public var providerToken: String?
    public var providerTokenFile: String?
    public var credentialStore: String?
    // See AppConfig.managedBy; this is origin metadata, not an authority flag.
    public var managedBy: String?
    // SPEC-013 autoresearch serving knobs. nil ⇒ defer to env / YAML /
    // built-in default (the latter mirrors prior single-slot behavior).
    public var kvBits: Int?
    public var maxContext: Int?
    public var maxBatch: Int?
    public var idlePrewarmEnabled: Bool?
    public var idlePrewarmIdleThresholdSeconds: Double?
    public var idlePrewarmTickSeconds: Double?
    public var idlePrewarmMaxTokens: Int?
    public var idlePrewarmPrompt: String?
    public var idlePrewarmRunOnBattery: Bool?
    public var streamInterval: Int?
    public var prefillStepSize: Int?
    public var continuousBatching: String?
    public var continuousBatchQueueLimit: Int?
    public var continuousBatchQueueWaitTimeoutMS: Int?
    public var continuousBatchPrefillTokensPerIteration: Int?
    public var continuousBatchingCachedTurns: Bool?
    // SPEC-037 FR-KVP11: KV disk-tier CLI flags (`--kv-disk-cache-*`).
    public var kvDiskCache: KVDiskCacheCLIOverrides
    // SPEC-039 FR-PKV14: paged KV CLI flags (`--paged-kv-*`).
    public var pagedKV: PagedKVCLIOverrides

    public init(
        port: Int? = nil,
        model: String? = nil,
        modelArtifactPath: String? = nil,
        modelArtifactSHA256: String? = nil,
        draftModel: String? = nil,
        draftModelArtifactSHA256: String? = nil,
        numDraftTokens: Int? = nil,
        publishesSpecDecodeTelemetry: Bool? = nil,
        nativeMTPMode: String? = nil,
        coordinatorURL: String? = nil,
        providerID: String? = nil,
        endpointURL: String? = nil,
        configPath: String? = nil,
        logLevel: String? = nil,
        supportedModels: [String]? = nil,
        publishesSupportedModels: Bool? = nil,
        enableWarmSwap: Bool? = nil,
        enableReceipts: Bool? = nil,
        relayBlindEnabled: Bool? = nil,
        privacyClassBeta: Bool? = nil,
        relayBlindStateDirectory: String? = nil,
        swapDrainTimeoutSeconds: Int? = nil,
        ctlSocketPath: String? = nil,
        switchStatePath: String? = nil,
        providerToken: String? = nil,
        providerTokenFile: String? = nil,
        credentialStore: String? = nil,
        managedBy: String? = nil,
        kvBits: Int? = nil,
        maxContext: Int? = nil,
        maxBatch: Int? = nil,
        idlePrewarmEnabled: Bool? = nil,
        idlePrewarmIdleThresholdSeconds: Double? = nil,
        idlePrewarmTickSeconds: Double? = nil,
        idlePrewarmMaxTokens: Int? = nil,
        idlePrewarmPrompt: String? = nil,
        idlePrewarmRunOnBattery: Bool? = nil,
        streamInterval: Int? = nil,
        prefillStepSize: Int? = nil,
        kvDiskCache: KVDiskCacheCLIOverrides = KVDiskCacheCLIOverrides(),
        continuousBatching: String? = nil,
        continuousBatchQueueLimit: Int? = nil,
        continuousBatchQueueWaitTimeoutMS: Int? = nil,
        continuousBatchPrefillTokensPerIteration: Int? = nil,
        continuousBatchingCachedTurns: Bool? = nil,
        pagedKV: PagedKVCLIOverrides = PagedKVCLIOverrides()
    ) {
        self.port = port
        self.model = model
        self.modelArtifactPath = modelArtifactPath
        self.modelArtifactSHA256 = modelArtifactSHA256
        self.draftModel = draftModel
        self.draftModelArtifactSHA256 = draftModelArtifactSHA256
        self.numDraftTokens = numDraftTokens
        self.publishesSpecDecodeTelemetry = publishesSpecDecodeTelemetry
        self.nativeMTPMode = nativeMTPMode
        self.coordinatorURL = coordinatorURL
        self.providerID = providerID
        self.endpointURL = endpointURL
        self.configPath = configPath
        self.logLevel = logLevel
        self.supportedModels = supportedModels
        self.publishesSupportedModels = publishesSupportedModels
        self.enableWarmSwap = enableWarmSwap
        self.enableReceipts = enableReceipts
        self.relayBlindEnabled = relayBlindEnabled
        self.privacyClassBeta = privacyClassBeta
        self.relayBlindStateDirectory = relayBlindStateDirectory
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.ctlSocketPath = ctlSocketPath
        self.switchStatePath = switchStatePath
        self.providerToken = providerToken
        self.providerTokenFile = providerTokenFile
        self.credentialStore = credentialStore
        self.managedBy = managedBy
        self.kvBits = kvBits
        self.maxContext = maxContext
        self.maxBatch = maxBatch
        self.idlePrewarmEnabled = idlePrewarmEnabled
        self.idlePrewarmIdleThresholdSeconds = idlePrewarmIdleThresholdSeconds
        self.idlePrewarmTickSeconds = idlePrewarmTickSeconds
        self.idlePrewarmMaxTokens = idlePrewarmMaxTokens
        self.idlePrewarmPrompt = idlePrewarmPrompt
        self.idlePrewarmRunOnBattery = idlePrewarmRunOnBattery
        self.streamInterval = streamInterval
        self.prefillStepSize = prefillStepSize
        self.continuousBatching = continuousBatching
        self.continuousBatchQueueLimit = continuousBatchQueueLimit
        self.continuousBatchQueueWaitTimeoutMS = continuousBatchQueueWaitTimeoutMS
        self.continuousBatchPrefillTokensPerIteration = continuousBatchPrefillTokensPerIteration
        self.continuousBatchingCachedTurns = continuousBatchingCachedTurns
        self.kvDiskCache = kvDiskCache
        self.pagedKV = pagedKV
    }
}

public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case unreadableConfig(path: String, underlying: String)
    case invalidYAML(path: String, underlying: String)
    case invalidValue(key: String, value: String, expected: String)

    public var description: String {
        switch self {
        case let .unreadableConfig(path, underlying):
            return "Unable to read config at \(path): \(underlying)"
        case let .invalidYAML(path, underlying):
            return "Invalid YAML in config at \(path): \(underlying)"
        case let .invalidValue(key, value, expected):
            return "Invalid \(key)=\(value); expected \(expected)"
        }
    }
}

public enum ConfigLoader {
    /// `resolveCredentials: false` is the SPEC-049-R007 non-secret bootstrap:
    /// it resolves every other key with the same precedence but never assigns
    /// `providerToken` from YAML `provider_token`, `MACPROVIDER_PROVIDER_TOKEN`,
    /// or `--token-file`, and never opens the token file.
    public static func load(
        cli: CLIOverrides,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: expandTilde($0)) },
        readFile: (String) throws -> String = { try String(contentsOfFile: expandTilde($0), encoding: .utf8) },
        resolveCredentials: Bool = true
    ) throws -> AppConfig {
        let configPath = cli.configPath
            ?? environment["MACPROVIDER_CONFIG"]
            ?? AppConfig.defaultConfigPath
        let explicitConfigPath = cli.configPath != nil || environment["MACPROVIDER_CONFIG"] != nil

        var config = AppConfig.defaults(configPath: configPath)
        if fileExists(configPath) {
            config = try applyYAMLConfig(config, path: configPath, readFile: readFile, resolveCredentials: resolveCredentials)
        } else if explicitConfigPath {
            throw ConfigError.unreadableConfig(path: configPath, underlying: "file does not exist")
        }

        config = try applyEnvironment(config, environment: environment, resolveCredentials: resolveCredentials)
        config = try applyCLI(config, cli: cli, resolveCredentials: resolveCredentials)
        config.configPath = configPath
        try validateIdlePrewarm(config)

        // SPEC-037 FR-KVP11: resolve the kv_disk_cache group fail-closed (never
        // throws; invalid ⇒ tier disabled + errors logged by the caller).
        var kvYAML: [String: Any]?
        if fileExists(configPath), let text = try? readFile(configPath),
           let root = try? Yams.load(yaml: text) as? [String: Any] {
            kvYAML = root["kv_disk_cache"] as? [String: Any]
        }
        config.kvDiskCache = KVDiskCacheConfigResolver.resolve(
            yaml: kvYAML, environment: environment, cli: cli.kvDiskCache)
        var pagedYAML: [String: Any]?
        var pagedYAMLShapeError = false
        if fileExists(configPath), let text = try? readFile(configPath),
           let root = try? Yams.load(yaml: text) as? [String: Any] {
            if let rawPaged = root["paged_kv"], !(rawPaged is NSNull) {
                if let map = rawPaged as? [String: Any] {
                    pagedYAML = map
                } else {
                    pagedYAMLShapeError = true
                }
            }
        }
        config.pagedKV = PagedKVConfigResolver.resolve(
            yaml: pagedYAML, environment: environment, cli: cli.pagedKV)
        config.pagedKVEnabledExplicitlyConfigured = pagedYAML?["enabled"] != nil
            || environment["MACPROVIDER_PAGED_KV_ENABLED"] != nil
            || cli.pagedKV.enabled != nil
        // A malformed `paged_kv:` block (scalar/list where a map is required) is a config
        // shape error that must NEVER be silently dropped: always surface the warning and
        // fail closed by disabling paged mode, regardless of any env/CLI override presence.
        // (Env/CLI precedence still governs the well-formed-map case via the resolver above.)
        if pagedYAMLShapeError {
            config.pagedKV.enabled = false
            config.pagedKV.errors.append("invalid paged_kv=<redacted>; expected map; paged_kv disabled")
        }
        // SPEC-049-R024: forcing the privacy class on turns relay-blind on
        // unless relay-blind is explicitly disabled.
        if config.privacyClassBeta && config.relayBlindRequested == nil {
            config.relayBlindEnabled = true
        }
        try validatePrivacyClass(config)
        return config
    }

    /// SPEC-049-R007 credential boundary. Capture the operator YAML once,
    /// validate the non-credential configuration produced from that captured
    /// snapshot, and only then resolve credentials from the same captured
    /// YAML/environment/CLI inputs. This prevents a mutable config file from
    /// switching privacy mode on between a pre-credential guard and token
    /// assignment or `--token-file` open.
    public static func loadAfterNonCredentialValidation(
        cli: CLIOverrides,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: expandTilde($0)) },
        readFile: (String) throws -> String = { try String(contentsOfFile: expandTilde($0), encoding: .utf8) },
        validate: (AppConfig) throws -> Void
    ) throws -> AppConfig {
        let configPath = cli.configPath
            ?? environment["MACPROVIDER_CONFIG"]
            ?? AppConfig.defaultConfigPath
        let exists = fileExists(configPath)
        let capturedText: String?
        if exists {
            do {
                capturedText = try readFile(configPath)
            } catch {
                throw ConfigError.unreadableConfig(path: configPath, underlying: String(describing: error))
            }
        } else {
            capturedText = nil
        }
        let snapshotExists: (String) -> Bool = { path in
            path == configPath ? exists : fileExists(path)
        }
        let snapshotRead: (String) throws -> String = { path in
            if path == configPath, let capturedText {
                return capturedText
            }
            return try readFile(path)
        }
        let checked = try load(
            cli: cli,
            environment: environment,
            fileExists: snapshotExists,
            readFile: snapshotRead,
            resolveCredentials: false
        )
        try validate(checked)
        return try load(
            cli: cli,
            environment: environment,
            fileExists: snapshotExists,
            readFile: snapshotRead,
            resolveCredentials: true
        )
    }

    /// SPEC-049-R001. Privacy class forced on with relay-blind explicitly off
    /// is a configuration error. The hardening probe refuses the same
    /// combination again before any network, with a bounded reason code.
    private static func validatePrivacyClass(_ config: AppConfig) throws {
        if config.privacyClassBeta && !config.relayBlindEnabled {
            throw ConfigError.invalidValue(
                key: "privacy_class_beta",
                value: "true",
                expected: "relay_blind_enabled true"
            )
        }
    }

    public static func expandTilde(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private static func applyYAMLConfig(
        _ base: AppConfig,
        path: String,
        readFile: (String) throws -> String,
        resolveCredentials: Bool
    ) throws -> AppConfig {
        let text: String
        do {
            text = try readFile(path)
        } catch {
            throw ConfigError.unreadableConfig(path: path, underlying: String(describing: error))
        }

        let raw: Any?
        let rawNode: Node?
        do {
            raw = try Yams.load(yaml: text)
            rawNode = try Yams.compose(yaml: text)
        } catch {
            throw ConfigError.invalidYAML(path: path, underlying: String(describing: error))
        }

        guard let dict = raw as? [String: Any] else {
            return base
        }

        var config = base
        try assign(&config.port, from: dict, key: "port", expected: "integer")
        try assign(&config.model, from: dict, key: "model", expected: "string")
        try assign(&config.modelArtifactPath, from: dict, key: "model_artifact_path", expected: "string")
        try assign(&config.modelArtifactSHA256, from: dict, key: "model_artifact_sha256", expected: "string")
        try assign(&config.draftModel, from: dict, key: "draft_model", expected: "string")
        try assign(&config.draftModelArtifactSHA256, from: dict, key: "draft_model_artifact_sha256", expected: "string")
        try assign(&config.numDraftTokens, from: dict, key: "num_draft_tokens", expected: "integer")
        try assign(&config.publishesSpecDecodeTelemetry, from: dict, key: "publishes_spec_decode_telemetry", expected: "boolean")
        if dict["native_mtp_mode"] != nil {
            guard let rawMode = rawNode?["native_mtp_mode"]?.scalar?.string,
                  let mode = NativeMTPMode(rawValue: rawMode.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: "native_mtp_mode",
                    value: String(describing: dict["native_mtp_mode"]),
                    expected: "off or auto"
                )
            }
            config.nativeMTPMode = mode
        }
        try assign(&config.modelCatalogKey, from: dict, key: "model_catalog_key", expected: "string")
        try assign(&config.modelCatalogModelID, from: dict, key: "model_catalog_model_id", expected: "string")
        try assign(&config.modelCatalogRevision, from: dict, key: "model_catalog_revision", expected: "string")
        try assign(&config.modelCatalogSHA256, from: dict, key: "model_catalog_sha256", expected: "string")
        try assign(&config.modelCatalogVersion, from: dict, key: "model_catalog_version", expected: "string")
        try assign(&config.modelCatalogHash, from: dict, key: "model_catalog_hash", expected: "string")
        try assign(&config.modelArtifactRoot, from: dict, key: "model_artifact_root", expected: "string")
        try assign(&config.loopbackOrigin, from: dict, key: "loopback_origin", expected: "string")
        try assign(&config.poolModelID, from: dict, key: "pool_model_id", expected: "string")
        try assign(&config.coordinatorURL, from: dict, key: "coordinator_url", expected: "string")
        try assign(&config.providerID, from: dict, key: "provider_id", expected: "string")
        try assign(&config.endpointURL, from: dict, key: "endpoint_url", expected: "string")
        try assign(&config.wsTunneledMode, from: dict, key: "ws_tunneled_mode", expected: "boolean")
        try assign(&config.autoUpdateEnabled, from: dict, key: "auto_update_enabled", expected: "boolean")
        try assign(&config.autoUpdateAcceptProvisional, from: dict, key: "auto_update_accept_provisional", expected: "boolean")
        if let nested = dict["autoupdate"] as? [String: Any] {
            try assign(&config.autoupdateEnabled, from: nested, key: "enabled", expected: "boolean")
            try assign(&config.autoUpdateAcceptProvisional, from: nested, key: "accept_provisional", expected: "boolean")
        }
        try assign(&config.logFormat, from: dict, key: "log_format", expected: "json or text")
        try assign(&config.logFile, from: dict, key: "log_file", expected: "string")
        try assign(&config.maxContextOverride, from: dict, key: "max_context_override", expected: "integer")
        if let value = dict["max_context_override"], !(value is NSNull) {
            let provenance = MaxContextProvenance.parse(dict[MaxContextProvenance.configKey])
            if provenance?.generatedMaxContext(config.maxContextOverride) == true {
                config.maxContextSource = .recommendationApply
                config.maxContextProvenance = provenance
            } else {
                config.maxContextSource = .operatorConfig
            }
        }
        try assign(&config.maxConcurrencyOverride, from: dict, key: "max_concurrency_override", expected: "integer")
        var maxConcurrencyDepthOverride: Int?
        try assign(&maxConcurrencyDepthOverride, from: dict, key: AppConfig.maxConcurrencyDepthOverrideKey, expected: "integer")
        // The depth key only extends a legacy value the new applier wrote (8,
        // or absent). Any other legacy value means an older CLI or the operator
        // changed it after the depth was recorded, so the legacy value wins.
        if let maxConcurrencyDepthOverride,
           config.maxConcurrencyOverride == nil
            || config.maxConcurrencyOverride == AppConfig.legacyMaxConcurrencyOverrideLimit {
            config.maxConcurrencyOverride = maxConcurrencyDepthOverride
        }
        var maxConcurrencySourceRaw: String?
        try assign(&maxConcurrencySourceRaw, from: dict, key: AppConfig.maxConcurrencySourceKey, expected: "owner or autotune")
        if let maxConcurrencySourceRaw {
            guard let source = MaxConcurrencySource(rawValue: maxConcurrencySourceRaw.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: AppConfig.maxConcurrencySourceKey,
                    value: maxConcurrencySourceRaw,
                    expected: "owner or autotune"
                )
            }
            config.maxConcurrencySource = source
        }
        try assign(&config.kvBitsOverride, from: dict, key: "kv_bits", expected: "integer (4 or 8)")
        try assign(&config.drainTimeoutSeconds, from: dict, key: "drain_timeout_s", expected: "integer")
        try assign(&config.warmupEnabled, from: dict, key: "warmup_enabled", expected: "boolean")
        try assign(&config.losslessnessProbeEnabled, from: dict, key: "losslessness_probe_enabled", expected: "boolean")
        try assign(&config.maxRequestBodyBytes, from: dict, key: "max_request_body_bytes", expected: "integer")
        try assign(&config.tier2MDAArtifactPath, from: dict, key: "tier2_mda_artifact_path", expected: "string")
        try assign(&config.supportedModels, from: dict, key: "supported_models", expected: "array of strings or comma-separated string")
        try assign(&config.publishesSupportedModels, from: dict, key: "publishes_supported_models", expected: "boolean")
        try assign(&config.enableWarmSwap, from: dict, key: "enable_warm_swap", expected: "boolean")
        try assign(&config.enableReceipts, from: dict, key: "enable_receipts", expected: "boolean")
        try assign(&config.relayBlindEnabled, from: dict, key: "relay_blind_enabled", expected: "boolean")
        try assign(&config.privacyClassBeta, from: dict, key: "privacy_class_beta", expected: "boolean")
        try assign(&config.relayBlindRequested, from: dict, key: "relay_blind_enabled", expected: "boolean")
        try assign(&config.privacyClassRequested, from: dict, key: "privacy_class_beta", expected: "boolean")
        try assign(&config.relayBlindStateDirectory, from: dict, key: "relay_blind_state_directory", expected: "absolute string")
        try assign(&config.swapDrainTimeoutSeconds, from: dict, key: "swap_drain_timeout_s", expected: "integer")
        try assign(&config.ctlSocketPath, from: dict, key: "ctl_socket_path", expected: "string")
        try assign(&config.switchStatePath, from: dict, key: "switch_state_path", expected: "string")
        try assign(&config.donorMode, from: dict, key: "donor_mode", expected: "boolean")
        if let nested = dict["idle_prewarm"] as? [String: Any] {
            try assign(&config.idlePrewarmEnabled, from: nested, key: "enabled", expected: "boolean")
            try assign(&config.idlePrewarmIdleThresholdSeconds, from: nested, key: "idle_threshold_seconds", expected: "number")
            try assign(&config.idlePrewarmTickSeconds, from: nested, key: "tick_seconds", expected: "number")
            try assign(&config.idlePrewarmMaxTokens, from: nested, key: "max_tokens", expected: "integer")
            try assign(&config.idlePrewarmPrompt, from: nested, key: "prompt", expected: "string")
            try assign(&config.idlePrewarmRunOnBattery, from: nested, key: "run_on_battery", expected: "boolean")
        }
        if resolveCredentials {
            try assign(&config.providerToken, from: dict, key: "provider_token", expected: "string")
        }
        if dict["credential_store"] != nil {
            guard let raw = rawNode?["credential_store"]?.scalar?.string,
                  let kind = ProviderCredentialStoreKind(rawValue: raw.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: "credential_store",
                    value: String(describing: dict["credential_store"]),
                    expected: "keychain or protected_file"
                )
            }
            config.credentialStore = kind
        }
        try assign(&config.managedBy, from: dict, key: "managed_by", expected: "string")
        try assign(&config.streamInterval, from: dict, key: "stream_interval", expected: "integer >= 1")
        try assign(&config.prefillStepSize, from: dict, key: "prefill_step_size", expected: "integer >= 1")
        if dict["continuous_batching"] != nil {
            guard let rawMode = rawNode?["continuous_batching"]?.scalar?.string,
                  let mode = ContinuousBatchingMode(rawValue: rawMode.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: "continuous_batching",
                    value: String(describing: dict["continuous_batching"]),
                    expected: "off, canary, or on"
                )
            }
            config.continuousBatching = mode
            config.continuousBatchingExplicitlyConfigured = true
        }
        try assign(&config.continuousBatchQueueLimit, from: dict, key: "continuous_batch_queue_limit", expected: "integer >= 1")
        try assign(
            &config.continuousBatchQueueWaitTimeoutMS,
            from: dict,
            key: "continuous_batch_queue_wait_timeout_ms",
            expected: "integer >= 1"
        )
        try assign(
            &config.continuousBatchPrefillTokensPerIteration,
            from: dict,
            key: "continuous_batch_prefill_tokens_per_iteration",
            expected: "integer >= 1"
        )
        try assign(
            &config.continuousBatchingCachedTurns,
            from: dict,
            key: "continuous_batching_cached_turns",
            expected: "boolean"
        )
        try assign(&config.mlxCacheLimitMB, from: dict, key: "mlx_cache_limit_mb", expected: "integer >= 0")
        if let rawTuples = dict["continuous_batching_accepted_tuples"] {
            config.continuousBatchingAcceptedTuples = try parseContinuousBatchingAcceptedTuples(rawTuples)
        }
        return config
    }

    /// SPEC-038 FR-CB10. A malformed entry is a hard configuration error, never
    /// a silent skip: a dropped entry would either disable batching the
    /// operator qualified, or — worse, if the shape were ever relaxed — admit a
    /// tuple no acceptance run covered.
    private static func parseContinuousBatchingAcceptedTuples(
        _ raw: Any
    ) throws -> [ContinuousBatchingAcceptedTuple] {
        let key = "continuous_batching_accepted_tuples"
        guard let entries = raw as? [Any] else {
            throw ConfigError.invalidValue(
                key: key,
                value: String(describing: raw),
                expected: "sequence of accepted-tuple maps"
            )
        }
        return try entries.enumerated().map { index, entry in
            let entryKey = "\(key)[\(index)]"
            guard let fields = entry as? [String: Any] else {
                throw ConfigError.invalidValue(
                    key: entryKey,
                    value: String(describing: entry),
                    expected: "map with model_id, model_sha256, optional tokenizer_sha256/chat_template_sha256, cache_class, kv_dtype, requires_moe, hardware_class, metallib_sha256, kernel_identifier, optional cached_turns_accepted"
                )
            }
            // Coverage matching in `ContinuousBatchingAcceptanceCoverage.covers(_:)`
            // is exact. A value that survives parsing but can never match is a
            // silent false negative: the operator believes the tuple is
            // qualified and the provider serial-routes instead. Reject the
            // shapes that cannot match here, at load, where the error names the
            // offending key.
            func requiredString(_ field: String) throws -> String {
                guard let value = fields[field] as? String,
                      !value.isEmpty,
                      value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw ConfigError.invalidValue(
                        key: "\(entryKey).\(field)",
                        value: String(describing: fields[field]),
                        expected: "non-empty string without leading or trailing whitespace"
                    )
                }
                return value
            }

            // Runtime-measured model identity is canonical lowercase 64-hex, so
            // an uppercase or truncated operator declaration never matches.
            func requiredSHA256(_ field: String) throws -> String {
                let value = try requiredString(field)
                // ASCII bytes only. `Character.isHexDigit` is true for
                // Unicode hex-likes such as fullwidth `ａ` and `１`, which are
                // not uppercase either — a 64-character fullwidth digest would
                // pass a Character-level test and then never equal the ASCII
                // lowercase runtime hash.
                let isCanonical = value.utf8.count == 64
                    && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                guard isCanonical else {
                    throw ConfigError.invalidValue(
                        key: "\(entryKey).\(field)",
                        value: value,
                        expected: "64-character lowercase hexadecimal SHA-256"
                    )
                }
                return value
            }
            func optionalSHA256(_ field: String) throws -> String? {
                guard fields[field] != nil else { return nil }
                return try requiredSHA256(field)
            }
            let rawDType = try requiredString("kv_dtype")
            guard let kvDType = PagedKVDType(rawValue: rawDType.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: "\(entryKey).kv_dtype",
                    value: rawDType,
                    expected: "fp16 or bf16"
                )
            }
            guard let requiresMoE = fields["requires_moe"] as? Bool else {
                throw ConfigError.invalidValue(
                    key: "\(entryKey).requires_moe",
                    value: String(describing: fields["requires_moe"]),
                    expected: "boolean"
                )
            }
            // Optional, but a present value must be a real boolean: a quoted
            // "true" or a typo must not silently grant (or drop) the grant.
            var cachedTurnsAccepted = false
            if let rawCachedTurns = fields["cached_turns_accepted"] {
                guard let value = rawCachedTurns as? Bool else {
                    throw ConfigError.invalidValue(
                        key: "\(entryKey).cached_turns_accepted",
                        value: String(describing: rawCachedTurns),
                        expected: "boolean"
                    )
                }
                cachedTurnsAccepted = value
            }
            return ContinuousBatchingAcceptedTuple(
                modelID: try requiredString("model_id"),
                modelSHA256: try requiredSHA256("model_sha256"),
                tokenizerSHA256: try optionalSHA256("tokenizer_sha256"),
                chatTemplateSHA256: try optionalSHA256("chat_template_sha256"),
                cacheClass: try requiredString("cache_class"),
                kvDType: kvDType,
                requiresMoE: requiresMoE,
                hardwareClass: try requiredString("hardware_class"),
                metallibSHA256: try requiredSHA256("metallib_sha256"),
                kernelIdentifier: try requiredString("kernel_identifier"),
                cachedTurnsAccepted: cachedTurnsAccepted
            )
        }
    }

    private static func applyEnvironment(
        _ base: AppConfig,
        environment: [String: String],
        resolveCredentials: Bool
    ) throws -> AppConfig {
        var config = base
        try assign(&config.port, from: environment, env: "MACPROVIDER_PORT", expected: "integer")
        try assign(&config.model, from: environment, env: "MACPROVIDER_MODEL", expected: "string")
        try assign(&config.modelArtifactSHA256, from: environment, env: "MACPROVIDER_MODEL_ARTIFACT_SHA256", expected: "string")
        try assign(&config.draftModel, from: environment, env: "MACPROVIDER_DRAFT_MODEL", expected: "string")
        try assign(&config.draftModelArtifactSHA256, from: environment, env: "MACPROVIDER_DRAFT_MODEL_ARTIFACT_SHA256", expected: "string")
        try assign(&config.numDraftTokens, from: environment, env: "MACPROVIDER_NUM_DRAFT_TOKENS", expected: "integer")
        try assign(&config.publishesSpecDecodeTelemetry, from: environment, env: "MACPROVIDER_PUBLISHES_SPEC_DECODE_TELEMETRY", expected: "boolean")
        try assign(&config.nativeMTPMode, from: environment, env: "MACPROVIDER_NATIVE_MTP_MODE", expected: "off or auto")
        try assign(&config.coordinatorURL, from: environment, env: "MACPROVIDER_COORDINATOR_URL", expected: "string")
        try assign(&config.providerID, from: environment, env: "MACPROVIDER_PROVIDER_ID", expected: "string")
        try assign(&config.endpointURL, from: environment, env: "MACPROVIDER_ENDPOINT_URL", expected: "string")
        try assign(&config.wsTunneledMode, from: environment, env: "MACPROVIDER_WS_TUNNELED_MODE", expected: "boolean")
        try assign(&config.autoUpdateEnabled, from: environment, env: "MACPROVIDER_AUTO_UPDATE_ENABLED", expected: "boolean")
        try assign(&config.autoupdateEnabled, from: environment, env: "MACPROVIDER_AUTOUPDATE", expected: "boolean")
        try assign(&config.autoUpdateAcceptProvisional, from: environment, env: "MACPROVIDER_AUTO_UPDATE_ACCEPT_PROVISIONAL", expected: "boolean")
        try assign(&config.modelArtifactRoot, from: environment, env: "MACPROVIDER_MODEL_ARTIFACT_ROOT", expected: "string")
        try assign(&config.loopbackOrigin, from: environment, env: "MACPROVIDER_LOOPBACK_ORIGIN", expected: "string")
        try assign(&config.poolModelID, from: environment, env: "MACPROVIDER_POOL_MODEL_ID", expected: "string")
        try assign(&config.logLevel, from: environment, env: "MACPROVIDER_LOG_LEVEL", expected: "valid log level")
        try assign(&config.logFormat, from: environment, env: "MACPROVIDER_LOG_FORMAT", expected: "json or text")
        try assign(&config.logFile, from: environment, env: "MACPROVIDER_LOG_FILE", expected: "string")
        try assign(&config.maxContextOverride, from: environment, env: "MACPROVIDER_MAX_CONTEXT_OVERRIDE", expected: "integer")
        if environment["MACPROVIDER_MAX_CONTEXT_OVERRIDE"] != nil {
            config.maxContextSource = .environment
            config.maxContextProvenance = nil
        }
        try assign(&config.maxConcurrencyOverride, from: environment, env: "MACPROVIDER_MAX_CONCURRENCY_OVERRIDE", expected: "integer")
        if environment["MACPROVIDER_MAX_CONCURRENCY_OVERRIDE"] != nil {
            config.maxConcurrencySource = .owner
        }
        try assign(&config.kvBitsOverride, from: environment, env: "MACPROVIDER_KV_BITS", expected: "integer (4 or 8)")
        try assign(&config.drainTimeoutSeconds, from: environment, env: "MACPROVIDER_DRAIN_TIMEOUT_S", expected: "integer")
        try assign(&config.warmupEnabled, from: environment, env: "MACPROVIDER_WARMUP_ENABLED", expected: "boolean")
        try assign(&config.losslessnessProbeEnabled, from: environment, env: "MACPROVIDER_LOSSLESSNESS_PROBE_ENABLED", expected: "boolean")
        try assign(&config.maxRequestBodyBytes, from: environment, env: "MACPROVIDER_MAX_REQUEST_BODY_BYTES", expected: "integer")
        try assign(&config.tier2MDAArtifactPath, from: environment, env: "MACPROVIDER_TIER2_MDA_ARTIFACT_PATH", expected: "string")
        config.supportedModels = SupportedModels.parseCSV(environment["MACPROVIDER_SUPPORTED_MODELS"]) ?? config.supportedModels
        try assign(&config.publishesSupportedModels, from: environment, env: "MACPROVIDER_PUBLISHES_SUPPORTED_MODELS", expected: "boolean")
        try assign(&config.enableWarmSwap, from: environment, env: "MACPROVIDER_ENABLE_WARM_SWAP", expected: "boolean")
        try assign(&config.enableReceipts, from: environment, env: "MACPROVIDER_ENABLE_RECEIPTS", expected: "boolean")
        try assign(&config.relayBlindEnabled, from: environment, env: "MACPROVIDER_RELAY_BLIND_ENABLED", expected: "boolean")
        try assign(&config.privacyClassBeta, from: environment, env: "MACPROVIDER_PRIVACY_CLASS_BETA", expected: "boolean")
        try assign(&config.relayBlindRequested, from: environment, env: "MACPROVIDER_RELAY_BLIND_ENABLED", expected: "boolean")
        try assign(&config.privacyClassRequested, from: environment, env: "MACPROVIDER_PRIVACY_CLASS_BETA", expected: "boolean")
        try assign(&config.relayBlindStateDirectory, from: environment, env: "MACPROVIDER_RELAY_BLIND_STATE_DIRECTORY", expected: "absolute string")
        try assign(&config.swapDrainTimeoutSeconds, from: environment, env: "MACPROVIDER_SWAP_DRAIN_TIMEOUT_S", expected: "integer")
        try assign(&config.ctlSocketPath, from: environment, env: "MACPROVIDER_CTL_SOCKET_PATH", expected: "string")
        try assign(&config.switchStatePath, from: environment, env: "MACPROVIDER_SWITCH_STATE_PATH", expected: "string")
        try assign(&config.donorMode, from: environment, env: "MACPROVIDER_DONOR_MODE", expected: "boolean")
        try assign(&config.idlePrewarmEnabled, from: environment, env: "MACPROVIDER_IDLE_PREWARM_ENABLED", expected: "boolean")
        try assign(&config.idlePrewarmIdleThresholdSeconds, from: environment, env: "MACPROVIDER_IDLE_PREWARM_IDLE_THRESHOLD_S", expected: "number")
        try assign(&config.idlePrewarmTickSeconds, from: environment, env: "MACPROVIDER_IDLE_PREWARM_TICK_S", expected: "number")
        try assign(&config.idlePrewarmMaxTokens, from: environment, env: "MACPROVIDER_IDLE_PREWARM_MAX_TOKENS", expected: "integer")
        try assign(&config.idlePrewarmPrompt, from: environment, env: "MACPROVIDER_IDLE_PREWARM_PROMPT", expected: "string")
        try assign(&config.idlePrewarmRunOnBattery, from: environment, env: "MACPROVIDER_IDLE_PREWARM_ON_BATTERY", expected: "boolean")
        if resolveCredentials {
            try assign(&config.providerToken, from: environment, env: "MACPROVIDER_PROVIDER_TOKEN", expected: "string")
        }
        if let raw = environment["MACPROVIDER_CREDENTIAL_STORE"] {
            guard let kind = ProviderCredentialStoreKind(rawValue: raw.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: "MACPROVIDER_CREDENTIAL_STORE",
                    value: raw,
                    expected: "keychain or protected_file"
                )
            }
            config.credentialStore = kind
        }
        try assign(&config.managedBy, from: environment, env: "MACPROVIDER_MANAGED_BY", expected: "string")
        try assign(&config.streamInterval, from: environment, env: "MACPROVIDER_STREAM_INTERVAL", expected: "integer >= 1")
        try assign(&config.prefillStepSize, from: environment, env: "MACPROVIDER_PREFILL_STEP_SIZE", expected: "integer >= 1")
        try assign(&config.continuousBatching, from: environment, env: "MACPROVIDER_CONTINUOUS_BATCHING", expected: "off, canary, or on")
        if environment["MACPROVIDER_CONTINUOUS_BATCHING"] != nil {
            config.continuousBatchingExplicitlyConfigured = true
        }
        try assign(&config.continuousBatchQueueLimit, from: environment, env: "MACPROVIDER_CONTINUOUS_BATCH_QUEUE_LIMIT", expected: "integer >= 1")
        try assign(
            &config.continuousBatchQueueWaitTimeoutMS,
            from: environment,
            env: "MACPROVIDER_CONTINUOUS_BATCH_QUEUE_WAIT_TIMEOUT_MS",
            expected: "integer >= 1"
        )
        try assign(
            &config.continuousBatchPrefillTokensPerIteration,
            from: environment,
            env: "MACPROVIDER_CONTINUOUS_BATCH_PREFILL_TOKENS_PER_ITERATION",
            expected: "integer >= 1"
        )
        try assign(
            &config.continuousBatchingCachedTurns,
            from: environment,
            env: "MACPROVIDER_CONTINUOUS_BATCHING_CACHED_TURNS",
            expected: "boolean"
        )
        try assign(&config.mlxCacheLimitMB, from: environment, env: "MACPROVIDER_MLX_CACHE_LIMIT_MB", expected: "integer >= 0")
        return config
    }

    private static func applyCLI(_ base: AppConfig, cli: CLIOverrides, resolveCredentials: Bool) throws -> AppConfig {
        var config = base
        if let port = cli.port {
            config.port = port
        }
        if let model = cli.model {
            // #745: `--model` must control what is loaded, not only the identity
            // string. Config `model_artifact_path` otherwise silently wins in
            // ModelRuntime (`modelLoadPath ?? modelID`), so autotune candidate
            // probes record the incumbent under the candidate's name.
            //
            // When CLI model disagrees with the configured artifact binding,
            // clear the artifact path + SHA so load falls through to
            // `modelLoadPath ?? modelID` with the CLI model. Fresh installs
            // (no artifact path) are unchanged.
            let previousModel = config.model
            let previousArtifact = config.modelArtifactPath
            config.model = model
            // #1816: a pool_model_id names the configured model's pool entry;
            // a different CLI model must not inherit it.
            if let previousModel, previousModel != model {
                config.poolModelID = nil
            }
            if let previousArtifact {
                let modelPath = Self.standardizedPathIfFilesystem(model)
                let artifactPath = Self.standardizedPathIfFilesystem(previousArtifact)
                let sameFilesystemPath =
                    modelPath != nil && artifactPath != nil && modelPath == artifactPath
                let identityUnchanged = previousModel == model
                if sameFilesystemPath {
                    // Explicit path matches configured artifact — keep SHA binding.
                } else if identityUnchanged, modelPath == nil {
                    // Same model id, non-path CLI — keep configured artifact.
                } else {
                    // Mismatch: prefer CLI model (load path) over silent incumbent.
                    // Clear artifact binding and catalog identity so we do not
                    // serve/load under the incumbent's catalog alias (#745).
                    config.modelArtifactPath = nil
                    config.modelArtifactSHA256 = nil
                    config.modelCatalogKey = nil
                    config.modelCatalogModelID = nil
                    config.modelCatalogRevision = nil
                    config.modelCatalogSHA256 = nil
                    config.modelCatalogVersion = nil
                    config.modelCatalogHash = nil
                }
            }
        }
        if let draftModel = cli.draftModel {
            config.draftModel = draftModel
        }
        if let modelArtifactSHA256 = cli.modelArtifactSHA256 {
            config.modelArtifactSHA256 = modelArtifactSHA256
        }
        if let modelArtifactPath = cli.modelArtifactPath {
            config.modelArtifactPath = modelArtifactPath
        }
        if let draftModelArtifactSHA256 = cli.draftModelArtifactSHA256 {
            config.draftModelArtifactSHA256 = draftModelArtifactSHA256
        }
        if let numDraftTokens = cli.numDraftTokens {
            config.numDraftTokens = numDraftTokens
        }
        if let publishesSpecDecodeTelemetry = cli.publishesSpecDecodeTelemetry {
            config.publishesSpecDecodeTelemetry = publishesSpecDecodeTelemetry
        }
        if let nativeMTPMode = cli.nativeMTPMode {
            guard let mode = NativeMTPMode(rawValue: nativeMTPMode.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: "--native-mtp",
                    value: nativeMTPMode,
                    expected: "off or auto"
                )
            }
            config.nativeMTPMode = mode
        }
        if let coordinatorURL = cli.coordinatorURL {
            config.coordinatorURL = coordinatorURL
        }
        if let providerID = cli.providerID {
            config.providerID = providerID
        }
        if let endpointURL = cli.endpointURL {
            config.endpointURL = endpointURL
        }
        if let logLevel = cli.logLevel {
            guard let value = LogLevel(rawValue: logLevel.lowercased()) else {
                throw ConfigError.invalidValue(key: "--log-level", value: logLevel, expected: "valid log level")
            }
            config.logLevel = value
        }
        if let supportedModels = cli.supportedModels {
            config.supportedModels = supportedModels
        }
        if let publishesSupportedModels = cli.publishesSupportedModels {
            config.publishesSupportedModels = publishesSupportedModels
        }
        if let enableWarmSwap = cli.enableWarmSwap {
            config.enableWarmSwap = enableWarmSwap
        }
        if let enableReceipts = cli.enableReceipts {
            config.enableReceipts = enableReceipts
        }
        if let relayBlindEnabled = cli.relayBlindEnabled {
            config.relayBlindEnabled = relayBlindEnabled
            config.relayBlindRequested = relayBlindEnabled
        }
        if let privacyClassBeta = cli.privacyClassBeta {
            config.privacyClassBeta = privacyClassBeta
            config.privacyClassRequested = privacyClassBeta
        }
        if let relayBlindStateDirectory = cli.relayBlindStateDirectory {
            config.relayBlindStateDirectory = relayBlindStateDirectory
        }
        if let swapDrainTimeoutSeconds = cli.swapDrainTimeoutSeconds {
            config.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        }
        if let ctlSocketPath = cli.ctlSocketPath {
            config.ctlSocketPath = ctlSocketPath
        }
        if let switchStatePath = cli.switchStatePath {
            config.switchStatePath = switchStatePath
        }
        if let providerToken = cli.providerToken {
            throw ConfigError.invalidValue(
                key: "--provider-token",
                value: providerToken.isEmpty ? "<empty>" : "<redacted>",
                expected: "use MACPROVIDER_PROVIDER_TOKEN, provider_token in a 0600 config file, or --token-file"
            )
        }
        if resolveCredentials, let providerTokenFile = cli.providerTokenFile {
            config.providerToken = try readProviderTokenFile(providerTokenFile)
        }
        if let raw = cli.credentialStore {
            guard let kind = ProviderCredentialStoreKind(rawValue: raw.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: "--credential-store",
                    value: raw,
                    expected: "keychain or protected_file"
                )
            }
            config.credentialStore = kind
        }
        if let managedBy = cli.managedBy {
            config.managedBy = managedBy
        }
        if let kvBits = cli.kvBits {
            config.kvBitsOverride = kvBits
        }
        if let maxContext = cli.maxContext {
            config.maxContextOverride = maxContext
            config.maxContextSource = .cliFlag
            config.maxContextProvenance = nil
        }
        if let maxBatch = cli.maxBatch {
            config.maxConcurrencyOverride = maxBatch
            config.maxConcurrencySource = .owner
        }
        if let idlePrewarmEnabled = cli.idlePrewarmEnabled {
            config.idlePrewarmEnabled = idlePrewarmEnabled
        }
        if let idlePrewarmIdleThresholdSeconds = cli.idlePrewarmIdleThresholdSeconds {
            config.idlePrewarmIdleThresholdSeconds = idlePrewarmIdleThresholdSeconds
        }
        if let idlePrewarmTickSeconds = cli.idlePrewarmTickSeconds {
            config.idlePrewarmTickSeconds = idlePrewarmTickSeconds
        }
        if let idlePrewarmMaxTokens = cli.idlePrewarmMaxTokens {
            config.idlePrewarmMaxTokens = idlePrewarmMaxTokens
        }
        if let idlePrewarmPrompt = cli.idlePrewarmPrompt {
            config.idlePrewarmPrompt = idlePrewarmPrompt
        }
        if let idlePrewarmRunOnBattery = cli.idlePrewarmRunOnBattery {
            config.idlePrewarmRunOnBattery = idlePrewarmRunOnBattery
        }
        if let streamInterval = cli.streamInterval {
            config.streamInterval = streamInterval
        }
        if let prefillStepSize = cli.prefillStepSize {
            config.prefillStepSize = prefillStepSize
        }
        if let continuousBatching = cli.continuousBatching {
            guard let mode = ContinuousBatchingMode(rawValue: continuousBatching.lowercased()) else {
                throw ConfigError.invalidValue(
                    key: "--continuous-batching",
                    value: continuousBatching,
                    expected: "off, canary, or on"
                )
            }
            config.continuousBatching = mode
            config.continuousBatchingExplicitlyConfigured = true
        }
        if let continuousBatchQueueLimit = cli.continuousBatchQueueLimit {
            config.continuousBatchQueueLimit = continuousBatchQueueLimit
        }
        if let continuousBatchQueueWaitTimeoutMS = cli.continuousBatchQueueWaitTimeoutMS {
            config.continuousBatchQueueWaitTimeoutMS = continuousBatchQueueWaitTimeoutMS
        }
        if let continuousBatchPrefillTokensPerIteration = cli.continuousBatchPrefillTokensPerIteration {
            config.continuousBatchPrefillTokensPerIteration = continuousBatchPrefillTokensPerIteration
        }
        if let continuousBatchingCachedTurns = cli.continuousBatchingCachedTurns {
            config.continuousBatchingCachedTurns = continuousBatchingCachedTurns
        }
        return config
    }

    /// Returns a standardized absolute path when `value` names a filesystem
    /// location (absolute, `~/…`, or `./…` / `../…`). HuggingFace model IDs
    /// (`org/name`) return nil so they are not treated as artifact paths.
    public static func standardizedPathIfFilesystem(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded: String
        if trimmed == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if trimmed.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(trimmed.dropFirst(2))).path
        } else {
            expanded = trimmed
        }
        let looksLikePath =
            expanded.hasPrefix("/")
            || expanded.hasPrefix("./")
            || expanded.hasPrefix("../")
            || expanded == "."
            || expanded == ".."
        guard looksLikePath else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func readProviderTokenFile(_ path: String) throws -> String {
        let expanded = expandTilde(path)
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: expanded)
        } catch {
            throw ConfigError.unreadableConfig(path: expanded, underlying: String(describing: error))
        }
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard mode & 0o077 == 0 else {
            throw ConfigError.invalidValue(key: "--token-file", value: expanded, expected: "file mode 0600 or stricter")
        }
        let contents: String
        do {
            contents = try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw ConfigError.unreadableConfig(path: expanded, underlying: String(describing: error))
        }
        let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ConfigError.invalidValue(key: "--token-file", value: expanded, expected: "non-empty token")
        }
        return token
    }

    private static func assign(_ field: inout Int, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        if let int = value as? Int {
            field = int
            return
        }
        if let string = value as? String, let int = Int(string) {
            field = int
            return
        }
        throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
    }

    private static func assign(_ field: inout Int?, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        if let int = value as? Int {
            field = int
            return
        }
        if let string = value as? String, let int = Int(string) {
            field = int
            return
        }
        throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
    }

    private static func assign(_ field: inout String?, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        guard let string = value as? String else {
            throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
        }
        field = string
    }

    private static func assign(_ field: inout String, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        guard let string = value as? String else {
            throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
        }
        field = string
    }

    private static func assign(_ field: inout Double, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        if let double = value as? Double {
            field = double
            return
        }
        if let int = value as? Int {
            field = Double(int)
            return
        }
        if let string = value as? String, let double = Double(string) {
            field = double
            return
        }
        throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
    }

    private static func assign(_ field: inout [String]?, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        if let strings = value as? [String] {
            field = strings
            return
        }
        if let string = value as? String {
            field = SupportedModels.parseCSV(string)
            return
        }
        throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
    }

    private static func assign(_ field: inout Bool, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        if let bool = value as? Bool {
            field = bool
            return
        }
        if let string = value as? String, let bool = parseBool(string) {
            field = bool
            return
        }
        throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
    }

    private static func assign(_ field: inout Bool?, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        if let bool = value as? Bool {
            field = bool
            return
        }
        if let string = value as? String, let bool = parseBool(string) {
            field = bool
            return
        }
        throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
    }

    private static func assign(_ field: inout LogFormat, from dict: [String: Any], key: String, expected: String) throws {
        guard let value = dict[key], !(value is NSNull) else { return }
        guard let string = value as? String, let format = LogFormat(rawValue: string.lowercased()) else {
            throw ConfigError.invalidValue(key: key, value: String(describing: value), expected: expected)
        }
        field = format
    }

    private static func assign(_ field: inout Int, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let int = Int(value) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = int
    }

    private static func assign(_ field: inout Int?, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let int = Int(value) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = int
    }

    private static func assign(_ field: inout String?, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        field = value
    }

    private static func assign(_ field: inout String, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        field = value
    }

    private static func assign(_ field: inout Double, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let double = Double(value) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = double
    }

    private static func assign(_ field: inout Bool, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let bool = parseBool(value) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = bool
    }

    private static func assign(_ field: inout Bool?, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let bool = parseBool(value) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = bool
    }

    private static func assign(_ field: inout LogLevel, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let level = LogLevel(rawValue: value.lowercased()) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = level
    }

    private static func assign(_ field: inout LogFormat, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let format = LogFormat(rawValue: value.lowercased()) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = format
    }

    private static func assign(_ field: inout ContinuousBatchingMode, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let mode = ContinuousBatchingMode(rawValue: value.lowercased()) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = mode
    }

    private static func assign(_ field: inout NativeMTPMode, from env: [String: String], env key: String, expected: String) throws {
        guard let value = env[key] else { return }
        guard let mode = NativeMTPMode(rawValue: value.lowercased()) else {
            throw ConfigError.invalidValue(key: key, value: value, expected: expected)
        }
        field = mode
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func validateIdlePrewarm(_ config: AppConfig) throws {
        try validateRange(
            key: "idle_prewarm.idle_threshold_seconds",
            value: config.idlePrewarmIdleThresholdSeconds,
            range: 5...3600
        )
        try validateRange(
            key: "idle_prewarm.tick_seconds",
            value: config.idlePrewarmTickSeconds,
            range: 1...60
        )
        try validateRange(
            key: "idle_prewarm.max_tokens",
            value: Double(config.idlePrewarmMaxTokens),
            range: 1...8
        )
        let promptBytes = config.idlePrewarmPrompt.utf8.count
        guard (1...64).contains(promptBytes) else {
            throw ConfigError.invalidValue(
                key: "idle_prewarm.prompt",
                value: "\(promptBytes) bytes",
                expected: "1...64 UTF-8 bytes"
            )
        }
    }

    private static func validateRange(key: String, value: Double, range: ClosedRange<Double>) throws {
        guard range.contains(value) else {
            throw ConfigError.invalidValue(
                key: key,
                value: String(value),
                expected: "\(range.lowerBound)...\(range.upperBound)"
            )
        }
    }
}
