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
    public var coordinatorURL: String?
    public var providerID: String?
    public var endpointURL: String?
    public var wsTunneledMode: Bool?
    public var autoUpdateEnabled: Bool?
    public var configPath: String
    public var logLevel: LogLevel
    public var logFormat: LogFormat
    public var logFile: String?
    public var maxContextOverride: Int?
    public var maxConcurrencyOverride: Int?
    public var drainTimeoutSeconds: Int
    public var warmupEnabled: Bool
    public var maxRequestBodyBytes: Int
    public var tier2MDAArtifactPath: String?
    public var supportedModels: [String]?
    public var publishesSupportedModels: Bool
    public var enableWarmSwap: Bool
    public var swapDrainTimeoutSeconds: Int
    public var ctlSocketPath: String?
    public var switchStatePath: String?

    public static let defaultConfigPath = "~/.config/macprovider/config.yaml"

    public static func defaults(configPath: String = defaultConfigPath) -> AppConfig {
        AppConfig(
            port: 8080,
            model: nil,
            coordinatorURL: nil,
            providerID: nil,
            endpointURL: nil,
            wsTunneledMode: nil,
            autoUpdateEnabled: nil,
            configPath: configPath,
            logLevel: .info,
            logFormat: .json,
            logFile: nil,
            maxContextOverride: nil,
            maxConcurrencyOverride: nil,
            drainTimeoutSeconds: 30,
            warmupEnabled: true,
            maxRequestBodyBytes: 10 * 1024 * 1024,
            tier2MDAArtifactPath: nil,
            supportedModels: nil,
            publishesSupportedModels: false,
            enableWarmSwap: false,
            swapDrainTimeoutSeconds: 30,
            ctlSocketPath: nil,
            switchStatePath: nil
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
    public var swapDrainTimeoutSeconds: Int?
    public var ctlSocketPath: String?
    public var switchStatePath: String?

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
        swapDrainTimeoutSeconds: Int? = nil,
        ctlSocketPath: String? = nil,
        switchStatePath: String? = nil
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
        self.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        self.ctlSocketPath = ctlSocketPath
        self.switchStatePath = switchStatePath
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
        try assign(&config.coordinatorURL, from: dict, key: "coordinator_url", expected: "string")
        try assign(&config.providerID, from: dict, key: "provider_id", expected: "string")
        try assign(&config.endpointURL, from: dict, key: "endpoint_url", expected: "string")
        try assign(&config.wsTunneledMode, from: dict, key: "ws_tunneled_mode", expected: "boolean")
        try assign(&config.autoUpdateEnabled, from: dict, key: "auto_update_enabled", expected: "boolean")
        try assign(&config.logFormat, from: dict, key: "log_format", expected: "json or text")
        try assign(&config.logFile, from: dict, key: "log_file", expected: "string")
        try assign(&config.maxContextOverride, from: dict, key: "max_context_override", expected: "integer")
        try assign(&config.maxConcurrencyOverride, from: dict, key: "max_concurrency_override", expected: "integer")
        try assign(&config.drainTimeoutSeconds, from: dict, key: "drain_timeout_s", expected: "integer")
        try assign(&config.warmupEnabled, from: dict, key: "warmup_enabled", expected: "boolean")
        try assign(&config.maxRequestBodyBytes, from: dict, key: "max_request_body_bytes", expected: "integer")
        try assign(&config.tier2MDAArtifactPath, from: dict, key: "tier2_mda_artifact_path", expected: "string")
        try assign(&config.supportedModels, from: dict, key: "supported_models", expected: "array of strings or comma-separated string")
        try assign(&config.publishesSupportedModels, from: dict, key: "publishes_supported_models", expected: "boolean")
        try assign(&config.enableWarmSwap, from: dict, key: "enable_warm_swap", expected: "boolean")
        try assign(&config.swapDrainTimeoutSeconds, from: dict, key: "swap_drain_timeout_s", expected: "integer")
        try assign(&config.ctlSocketPath, from: dict, key: "ctl_socket_path", expected: "string")
        try assign(&config.switchStatePath, from: dict, key: "switch_state_path", expected: "string")
        return config
    }

    private static func applyEnvironment(
        _ base: AppConfig,
        environment: [String: String]
    ) throws -> AppConfig {
        var config = base
        try assign(&config.port, from: environment, env: "MACPROVIDER_PORT", expected: "integer")
        try assign(&config.model, from: environment, env: "MACPROVIDER_MODEL", expected: "string")
        try assign(&config.coordinatorURL, from: environment, env: "MACPROVIDER_COORDINATOR_URL", expected: "string")
        try assign(&config.providerID, from: environment, env: "MACPROVIDER_PROVIDER_ID", expected: "string")
        try assign(&config.endpointURL, from: environment, env: "MACPROVIDER_ENDPOINT_URL", expected: "string")
        try assign(&config.wsTunneledMode, from: environment, env: "MACPROVIDER_WS_TUNNELED_MODE", expected: "boolean")
        try assign(&config.autoUpdateEnabled, from: environment, env: "MACPROVIDER_AUTO_UPDATE_ENABLED", expected: "boolean")
        try assign(&config.logLevel, from: environment, env: "MACPROVIDER_LOG_LEVEL", expected: "valid log level")
        try assign(&config.logFormat, from: environment, env: "MACPROVIDER_LOG_FORMAT", expected: "json or text")
        try assign(&config.logFile, from: environment, env: "MACPROVIDER_LOG_FILE", expected: "string")
        try assign(&config.maxContextOverride, from: environment, env: "MACPROVIDER_MAX_CONTEXT_OVERRIDE", expected: "integer")
        try assign(&config.maxConcurrencyOverride, from: environment, env: "MACPROVIDER_MAX_CONCURRENCY_OVERRIDE", expected: "integer")
        try assign(&config.drainTimeoutSeconds, from: environment, env: "MACPROVIDER_DRAIN_TIMEOUT_S", expected: "integer")
        try assign(&config.warmupEnabled, from: environment, env: "MACPROVIDER_WARMUP_ENABLED", expected: "boolean")
        try assign(&config.maxRequestBodyBytes, from: environment, env: "MACPROVIDER_MAX_REQUEST_BODY_BYTES", expected: "integer")
        try assign(&config.tier2MDAArtifactPath, from: environment, env: "MACPROVIDER_TIER2_MDA_ARTIFACT_PATH", expected: "string")
        config.supportedModels = SupportedModels.parseCSV(environment["MACPROVIDER_SUPPORTED_MODELS"]) ?? config.supportedModels
        try assign(&config.publishesSupportedModels, from: environment, env: "MACPROVIDER_PUBLISHES_SUPPORTED_MODELS", expected: "boolean")
        try assign(&config.enableWarmSwap, from: environment, env: "MACPROVIDER_ENABLE_WARM_SWAP", expected: "boolean")
        try assign(&config.swapDrainTimeoutSeconds, from: environment, env: "MACPROVIDER_SWAP_DRAIN_TIMEOUT_S", expected: "integer")
        try assign(&config.ctlSocketPath, from: environment, env: "MACPROVIDER_CTL_SOCKET_PATH", expected: "string")
        try assign(&config.switchStatePath, from: environment, env: "MACPROVIDER_SWITCH_STATE_PATH", expected: "string")
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
        if let swapDrainTimeoutSeconds = cli.swapDrainTimeoutSeconds {
            config.swapDrainTimeoutSeconds = swapDrainTimeoutSeconds
        }
        if let ctlSocketPath = cli.ctlSocketPath {
            config.ctlSocketPath = ctlSocketPath
        }
        if let switchStatePath = cli.switchStatePath {
            config.switchStatePath = switchStatePath
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
