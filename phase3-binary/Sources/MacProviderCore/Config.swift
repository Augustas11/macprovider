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

public struct AppConfig: Equatable, Sendable {
    public var port: Int
    public var model: String?
    public var modelArtifactPath: String?
    public var modelArtifactSHA256: String?
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
    // Operator opt-in: when true, provisional-tier providers apply
    // coordinator-recommended auto-updates. Default nil (== false) preserves
    // the pinned-only trust posture. Landed to unblock the trust-orphan
    // pattern where self-service (curl|bash) providers, which are always
    // provisional at admission, would otherwise never receive fixes without
    // manual operator SSH intervention. Flipping this to true is an explicit
    // operator statement of trust in the connected coordinator's version
    // recommendation surface.
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
    // SPEC-001: provider authentication token (closes XSEC-1 from
    // audits/2026-06-10/REPO_AUDIT.md). When set, the binary sends
    // "Authorization: Bearer <token>" on the WS connect and the
    // coordinator validates against its store when
    // auth.require_provider_tokens=true. Triple-exposed per house
    // convention: yaml key `provider_token`, env
    // MACPROVIDER_PROVIDER_TOKEN, CLI --provider-token. Operator should
    // chmod 0600 the config file containing this value; the binary
    // never logs the token (URL is redacted, headers are not logged).
    public var providerToken: String?

    // SPEC-025 §12 conflict #2 — set to "malibu-app" when the CLI is spawned as a
    // managed child of Malibu.app. The AutoUpdater checks this and no-ops so the
    // App track's Sparkle update path owns whole-bundle updates end-to-end. Other
    // values are reserved (e.g. future MDM wrappers can set their own tag).
    public var managedBy: String?

    public static let defaultConfigPath = "~/.config/macprovider/config.yaml"

    public static func defaults(configPath: String = defaultConfigPath) -> AppConfig {
        AppConfig(
            port: 8080,
            model: nil,
            modelArtifactPath: nil,
            modelArtifactSHA256: nil,
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
            providerToken: nil,
            managedBy: nil
        )
    }
}

public struct CLIOverrides: Equatable, Sendable {
    public var port: Int?
    public var model: String?
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
    // SPEC-025 §12 conflict #2 — see AppConfig.managedBy.
    public var managedBy: String?
    // SPEC-013 autoresearch serving knobs. nil ⇒ defer to env / YAML /
    // built-in default (the latter mirrors prior single-slot behavior).
    public var kvBits: Int?
    public var maxContext: Int?
    public var maxBatch: Int?

    public init(
        port: Int? = nil,
        model: String? = nil,
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
        managedBy: String? = nil,
        kvBits: Int? = nil,
        maxContext: Int? = nil,
        maxBatch: Int? = nil
    ) {
        self.port = port
        self.model = model
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
        self.managedBy = managedBy
        self.kvBits = kvBits
        self.maxContext = maxContext
        self.maxBatch = maxBatch
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
        do {
            raw = try Yams.load(yaml: text)
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
        try assign(&config.providerToken, from: dict, key: "provider_token", expected: "string")
        try assign(&config.managedBy, from: dict, key: "managed_by", expected: "string")
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
        try assign(&config.providerToken, from: environment, env: "MACPROVIDER_PROVIDER_TOKEN", expected: "string")
        try assign(&config.managedBy, from: environment, env: "MACPROVIDER_MANAGED_BY", expected: "string")
        return config
    }

    private static func applyCLI(_ base: AppConfig, cli: CLIOverrides) throws -> AppConfig {
        var config = base
        if let port = cli.port {
            config.port = port
        }
        if let model = cli.model {
            config.model = model
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
            config.providerToken = providerToken
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
        return config
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
}
