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

public struct AppConfig: Equatable, Sendable {
    public var port: Int
    public var model: String?
    public var modelArtifactPath: String?
    public var modelArtifactSHA256: String?
    public var draftModel: String?
    public var draftModelArtifactSHA256: String?
    public var numDraftTokens: Int
    public var publishesSpecDecodeTelemetry: Bool
    public var modelCatalogKey: String?
    public var modelCatalogModelID: String?
    public var modelCatalogRevision: String?
    public var modelCatalogSHA256: String?
    public var modelCatalogVersion: String?
    public var modelCatalogHash: String?
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
    public var maxConcurrencyOverride: Int?
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
    public var continuousBatchQueueLimit: Int?

    // SPEC-037 FR-KVP11: encrypted KV survival disk tier. Default-off; resolved
    // fail-closed (invalid value ⇒ tier disabled + `errors` populated, never a
    // process abort). See `KVDiskCacheConfig`.
    public var kvDiskCache: KVDiskCacheConfig

    // SPEC-039 FR-PKV14: provider-local paged KV residency engine. Default-off;
    // resolved fail-closed (invalid value ⇒ paged mode disabled + `errors`
    // populated, never a partial enable).
    public var pagedKV: PagedKVConfig

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
            modelCatalogKey: nil,
            modelCatalogModelID: nil,
            modelCatalogRevision: nil,
            modelCatalogSHA256: nil,
            modelCatalogVersion: nil,
            modelCatalogHash: nil,
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
            managedBy: nil,
            streamInterval: 1,
            prefillStepSize: 512,
            continuousBatching: .off,
            continuousBatchQueueLimit: nil,
            kvDiskCache: .defaults(),
            pagedKV: .defaults()
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
    public var coordinatorURL: String?
    public var providerID: String?
    public var endpointURL: String?
    public var configPath: String?
    public var logLevel: String?
    public var supportedModels: [String]?
    public var publishesSupportedModels: Bool?
    public var enableWarmSwap: Bool?
    public var enableReceipts: Bool?
    public var swapDrainTimeoutSeconds: Int?
    public var ctlSocketPath: String?
    public var switchStatePath: String?
    public var providerToken: String?
    public var providerTokenFile: String?
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
        coordinatorURL: String? = nil,
        providerID: String? = nil,
        endpointURL: String? = nil,
        configPath: String? = nil,
        logLevel: String? = nil,
        supportedModels: [String]? = nil,
        publishesSupportedModels: Bool? = nil,
        enableWarmSwap: Bool? = nil,
        enableReceipts: Bool? = nil,
        swapDrainTimeoutSeconds: Int? = nil,
        ctlSocketPath: String? = nil,
        switchStatePath: String? = nil,
        providerToken: String? = nil,
        providerTokenFile: String? = nil,
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
        self.coordinatorURL = coordinatorURL
        self.providerID = providerID
        self.endpointURL = endpointURL
        self.configPath = configPath
        self.logLevel = logLevel
        self.supportedModels = supportedModels
        self.publishesSupportedModels = publishesSupportedModels
        self.enableWarmSwap = enableWarmSwap
        self.enableReceipts = enableReceipts
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.ctlSocketPath = ctlSocketPath
        self.switchStatePath = switchStatePath
        self.providerToken = providerToken
        self.providerTokenFile = providerTokenFile
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
    public static func load(
        cli: CLIOverrides,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: expandTilde($0)) },
        readFile: (String) throws -> String = { try String(contentsOfFile: expandTilde($0), encoding: .utf8) }
    ) throws -> AppConfig {
        let configPath = cli.configPath
            ?? environment["MACPROVIDER_CONFIG"]
            ?? AppConfig.defaultConfigPath
        let explicitConfigPath = cli.configPath != nil || environment["MACPROVIDER_CONFIG"] != nil

        var config = AppConfig.defaults(configPath: configPath)
        if fileExists(configPath) {
            config = try applyYAMLConfig(config, path: configPath, readFile: readFile)
        } else if explicitConfigPath {
            throw ConfigError.unreadableConfig(path: configPath, underlying: "file does not exist")
        }

        config = try applyEnvironment(config, environment: environment)
        config = try applyCLI(config, cli: cli)
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
        // A malformed `paged_kv:` block (scalar/list where a map is required) is a config
        // shape error that must NEVER be silently dropped: always surface the warning and
        // fail closed by disabling paged mode, regardless of any env/CLI override presence.
        // (Env/CLI precedence still governs the well-formed-map case via the resolver above.)
        if pagedYAMLShapeError {
            config.pagedKV.enabled = false
            config.pagedKV.errors.append("invalid paged_kv=<redacted>; expected map; paged_kv disabled")
        }

        return config
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
        readFile: (String) throws -> String
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
        try assign(&config.modelCatalogKey, from: dict, key: "model_catalog_key", expected: "string")
        try assign(&config.modelCatalogModelID, from: dict, key: "model_catalog_model_id", expected: "string")
        try assign(&config.modelCatalogRevision, from: dict, key: "model_catalog_revision", expected: "string")
        try assign(&config.modelCatalogSHA256, from: dict, key: "model_catalog_sha256", expected: "string")
        try assign(&config.modelCatalogVersion, from: dict, key: "model_catalog_version", expected: "string")
        try assign(&config.modelCatalogHash, from: dict, key: "model_catalog_hash", expected: "string")
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
        try assign(&config.maxConcurrencyOverride, from: dict, key: "max_concurrency_override", expected: "integer")
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
        try assign(&config.providerToken, from: dict, key: "provider_token", expected: "string")
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
        }
        try assign(&config.continuousBatchQueueLimit, from: dict, key: "continuous_batch_queue_limit", expected: "integer >= 1")
        return config
    }

    private static func applyEnvironment(
        _ base: AppConfig,
        environment: [String: String]
    ) throws -> AppConfig {
        var config = base
        try assign(&config.port, from: environment, env: "MACPROVIDER_PORT", expected: "integer")
        try assign(&config.model, from: environment, env: "MACPROVIDER_MODEL", expected: "string")
        try assign(&config.modelArtifactSHA256, from: environment, env: "MACPROVIDER_MODEL_ARTIFACT_SHA256", expected: "string")
        try assign(&config.draftModel, from: environment, env: "MACPROVIDER_DRAFT_MODEL", expected: "string")
        try assign(&config.draftModelArtifactSHA256, from: environment, env: "MACPROVIDER_DRAFT_MODEL_ARTIFACT_SHA256", expected: "string")
        try assign(&config.numDraftTokens, from: environment, env: "MACPROVIDER_NUM_DRAFT_TOKENS", expected: "integer")
        try assign(&config.publishesSpecDecodeTelemetry, from: environment, env: "MACPROVIDER_PUBLISHES_SPEC_DECODE_TELEMETRY", expected: "boolean")
        try assign(&config.coordinatorURL, from: environment, env: "MACPROVIDER_COORDINATOR_URL", expected: "string")
        try assign(&config.providerID, from: environment, env: "MACPROVIDER_PROVIDER_ID", expected: "string")
        try assign(&config.endpointURL, from: environment, env: "MACPROVIDER_ENDPOINT_URL", expected: "string")
        try assign(&config.wsTunneledMode, from: environment, env: "MACPROVIDER_WS_TUNNELED_MODE", expected: "boolean")
        try assign(&config.autoUpdateEnabled, from: environment, env: "MACPROVIDER_AUTO_UPDATE_ENABLED", expected: "boolean")
        try assign(&config.autoupdateEnabled, from: environment, env: "MACPROVIDER_AUTOUPDATE", expected: "boolean")
        try assign(&config.autoUpdateAcceptProvisional, from: environment, env: "MACPROVIDER_AUTO_UPDATE_ACCEPT_PROVISIONAL", expected: "boolean")
        try assign(&config.logLevel, from: environment, env: "MACPROVIDER_LOG_LEVEL", expected: "valid log level")
        try assign(&config.logFormat, from: environment, env: "MACPROVIDER_LOG_FORMAT", expected: "json or text")
        try assign(&config.logFile, from: environment, env: "MACPROVIDER_LOG_FILE", expected: "string")
        try assign(&config.maxContextOverride, from: environment, env: "MACPROVIDER_MAX_CONTEXT_OVERRIDE", expected: "integer")
        try assign(&config.maxConcurrencyOverride, from: environment, env: "MACPROVIDER_MAX_CONCURRENCY_OVERRIDE", expected: "integer")
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
        try assign(&config.providerToken, from: environment, env: "MACPROVIDER_PROVIDER_TOKEN", expected: "string")
        try assign(&config.managedBy, from: environment, env: "MACPROVIDER_MANAGED_BY", expected: "string")
        try assign(&config.streamInterval, from: environment, env: "MACPROVIDER_STREAM_INTERVAL", expected: "integer >= 1")
        try assign(&config.prefillStepSize, from: environment, env: "MACPROVIDER_PREFILL_STEP_SIZE", expected: "integer >= 1")
        try assign(&config.continuousBatching, from: environment, env: "MACPROVIDER_CONTINUOUS_BATCHING", expected: "off, canary, or on")
        try assign(&config.continuousBatchQueueLimit, from: environment, env: "MACPROVIDER_CONTINUOUS_BATCH_QUEUE_LIMIT", expected: "integer >= 1")
        return config
    }

    private static func applyCLI(_ base: AppConfig, cli: CLIOverrides) throws -> AppConfig {
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
        if let providerTokenFile = cli.providerTokenFile {
            config.providerToken = try readProviderTokenFile(providerTokenFile)
        }
        if let managedBy = cli.managedBy {
            config.managedBy = managedBy
        }
        if let kvBits = cli.kvBits {
            config.kvBitsOverride = kvBits
        }
        if let maxContext = cli.maxContext {
            config.maxContextOverride = maxContext
        }
        if let maxBatch = cli.maxBatch {
            config.maxConcurrencyOverride = maxBatch
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
        }
        if let continuousBatchQueueLimit = cli.continuousBatchQueueLimit {
            config.continuousBatchQueueLimit = continuousBatchQueueLimit
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
