import Foundation

public enum PagedKVFallbackPolicy: String, Sendable, Equatable, Codable {
    case permissive
    case strict
}

/// SPEC-039 FR-PKV7 closed reason-code enum. Do not add cases without a SPEC-039
/// revision; tests assert this set stays exhaustive.
public enum PagedKVFallbackReason: String, CaseIterable, Sendable, Equatable, Codable {
    case cacheClass = "paged_fallback_cache_class"
    case allocator = "paged_fallback_allocator"
    case kernel = "paged_fallback_kernel"
    case metallib = "paged_fallback_metallib"
    case parity = "paged_fallback_parity"
    case identity = "paged_fallback_identity"
    case quantized = "paged_fallback_quantized"
    case preflightReject = "paged_preflight_reject"
}

public struct PagedKVConfig: Equatable, Sendable {
    public var enabled: Bool
    public var blockSizeTokens: Int
    public var maxPhysicalBlocks: Int
    public var fallbackPolicy: PagedKVFallbackPolicy
    /// Non-empty means the resolver forced paged mode off. Serve logs these and
    /// continues on the stock contiguous path.
    public var errors: [String]

    public init(
        enabled: Bool = false,
        blockSizeTokens: Int = PagedKVConfig.defaultBlockSizeTokens,
        maxPhysicalBlocks: Int = PagedKVConfig.defaultMaxPhysicalBlocks,
        fallbackPolicy: PagedKVFallbackPolicy = .permissive,
        errors: [String] = []
    ) {
        self.enabled = enabled
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.fallbackPolicy = fallbackPolicy
        self.errors = errors
    }

    public static func defaults() -> PagedKVConfig { PagedKVConfig() }

    public var effectiveEnabled: Bool { enabled && errors.isEmpty }
    public var maxResidentTokens: Int {
        let (value, overflow) = blockSizeTokens.multipliedReportingOverflow(by: maxPhysicalBlocks)
        return overflow ? Int.max : value
    }

    public static let defaultBlockSizeTokens = 16
    public static let defaultMaxPhysicalBlocks = 1024
    public static let maximumBlockSizeTokens = 4096
    public static let maximumPhysicalBlocks = 1_048_576
}

public struct PagedKVCLIOverrides: Equatable, Sendable {
    public var enabled: Bool?
    public var blockSizeTokens: Int?
    public var maxPhysicalBlocks: Int?
    public var fallbackPolicy: String?

    public init(
        enabled: Bool? = nil,
        blockSizeTokens: Int? = nil,
        maxPhysicalBlocks: Int? = nil,
        fallbackPolicy: String? = nil
    ) {
        self.enabled = enabled
        self.blockSizeTokens = blockSizeTokens
        self.maxPhysicalBlocks = maxPhysicalBlocks
        self.fallbackPolicy = fallbackPolicy
    }
}

public enum PagedKVConfigResolver {
    public static func resolve(
        yaml: [String: Any]?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cli: PagedKVCLIOverrides = PagedKVCLIOverrides()
    ) -> PagedKVConfig {
        var config = PagedKVConfig.defaults()
        var errors: [String] = []

        func fail(_ key: String, _ raw: String, _ expected: String) {
            errors.append("invalid \(key)=<redacted,len=\(raw.count)>; expected \(expected); paged_kv disabled")
        }

        func boundedPositive(_ value: Int, maximum: Int) -> Bool {
            value > 0 && value <= maximum
        }

        func rawString(_ yamlKey: String, _ envKey: String) -> (raw: String, value: String?)? {
            if let value = environment[envKey] {
                return (value, value)
            }
            return yamlScalarString(yaml, yamlKey)
        }

        func rawBool(_ yamlKey: String, _ envKey: String) -> (raw: String, value: Bool?)? {
            if let resolved = rawString(yamlKey, envKey) {
                guard let value = resolved.value else { return (resolved.raw, nil) }
                return (value, parseBool(value))
            }
            return nil
        }

        func rawInt(_ yamlKey: String, _ envKey: String) -> (raw: String, value: Int?)? {
            if let value = environment[envKey] {
                return (value, Int(value.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if let resolved = yamlScalarString(yaml, yamlKey) {
                guard let value = resolved.value else { return (resolved.raw, nil) }
                return (resolved.raw, Int(value.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return nil
        }

        if let enabled = cli.enabled {
            config.enabled = enabled
        } else if let resolved = rawBool("enabled", "MACPROVIDER_PAGED_KV_ENABLED") {
            if let value = resolved.value { config.enabled = value }
            else { fail("enabled", resolved.raw, "boolean") }
        }

        if let blockSize = cli.blockSizeTokens {
            if boundedPositive(blockSize, maximum: PagedKVConfig.maximumBlockSizeTokens) { config.blockSizeTokens = blockSize }
            else { fail("block_size_tokens", String(blockSize), "1...\(PagedKVConfig.maximumBlockSizeTokens)") }
        } else if let resolved = rawInt("block_size_tokens", "MACPROVIDER_PAGED_KV_BLOCK_SIZE_TOKENS") {
            if let value = resolved.value, boundedPositive(value, maximum: PagedKVConfig.maximumBlockSizeTokens) { config.blockSizeTokens = value }
            else { fail("block_size_tokens", resolved.raw, "1...\(PagedKVConfig.maximumBlockSizeTokens)") }
        }

        if let blocks = cli.maxPhysicalBlocks {
            if boundedPositive(blocks, maximum: PagedKVConfig.maximumPhysicalBlocks) { config.maxPhysicalBlocks = blocks }
            else { fail("max_physical_blocks", String(blocks), "1...\(PagedKVConfig.maximumPhysicalBlocks)") }
        } else if let resolved = rawInt("max_physical_blocks", "MACPROVIDER_PAGED_KV_MAX_PHYSICAL_BLOCKS") {
            if let value = resolved.value, boundedPositive(value, maximum: PagedKVConfig.maximumPhysicalBlocks) { config.maxPhysicalBlocks = value }
            else { fail("max_physical_blocks", resolved.raw, "1...\(PagedKVConfig.maximumPhysicalBlocks)") }
        }

        if let policy = cli.fallbackPolicy {
            let normalized = policy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let value = PagedKVFallbackPolicy(rawValue: normalized) {
                config.fallbackPolicy = value
            } else {
                fail("fallback_policy", policy, "permissive or strict")
            }
        } else if let resolved = rawString("fallback_policy", "MACPROVIDER_PAGED_KV_FALLBACK_POLICY") {
            if let policy = resolved.value,
               let value = PagedKVFallbackPolicy(rawValue: policy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                config.fallbackPolicy = value
            } else {
                fail("fallback_policy", resolved.raw, "permissive or strict")
            }
        }

        if !errors.isEmpty {
            config.enabled = false
            config.errors = errors
        }
        return config
    }

    private static func yamlScalarString(_ yaml: [String: Any]?, _ key: String) -> (raw: String, value: String?)? {
        guard let value = yaml?[key], !(value is NSNull) else { return nil }
        if let string = value as? String { return (string, string) }
        if let bool = value as? Bool { return (String(describing: value), bool ? "true" : "false") }
        if let int = value as? Int { return (String(describing: value), String(int)) }
        return (String(describing: value), nil)
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
