import Foundation

/// SPEC-037 FR-KVP11 — resolved configuration for the encrypted KV survival
/// disk tier. Follows the `idle_prewarm` triple-source shape (YAML file →
/// environment → CLI overrides), but with a **fail-closed** resolution policy:
/// an invalid value never aborts the serve process (unlike the throwing
/// `idle_prewarm` validators) — it disables the tier and records an error the
/// caller logs. `allow_buyer_keys: true` is rejected in v0.1.
public struct KVDiskCacheConfig: Equatable, Sendable {
    public var enabled: Bool
    public var allowBuyerKeys: Bool
    public var directory: String
    public var maxBytes: Int
    public var maxEntries: Int
    public var maxEntryBytes: Int
    public var retentionMinutes: Int
    /// Read/promotion staging ceiling (FR-KVP9): hard max 256 MiB.
    public var stagingMaxBytes: Int
    /// Write/snapshot staging ceiling (FR-KVP3): hard max 1 GiB.
    public var writeStagingMaxBytes: Int
    public var minFreeBytes: Int
    public var promotionMaxSeconds: Int
    public var shutdownDrainSeconds: Int
    /// Non-empty ⇒ resolution failed and the tier is forced off (FR-KVP11).
    public var errors: [String]

    public init(
        enabled: Bool = false,
        allowBuyerKeys: Bool = false,
        directory: String = KVDiskCacheConfig.defaultDirectory,
        maxBytes: Int = KVDiskCacheConfig.defaultMaxBytes,
        maxEntries: Int = KVDiskCacheConfig.defaultMaxEntries,
        maxEntryBytes: Int = KVDiskCacheConfig.defaultMaxEntryBytes,
        retentionMinutes: Int = KVDiskCacheConfig.defaultRetentionMinutes,
        stagingMaxBytes: Int = KVDiskCacheConfig.defaultStagingMaxBytes,
        writeStagingMaxBytes: Int = KVDiskCacheConfig.defaultWriteStagingMaxBytes,
        minFreeBytes: Int = KVDiskCacheConfig.defaultMinFreeBytes,
        promotionMaxSeconds: Int = KVDiskCacheConfig.defaultPromotionMaxSeconds,
        shutdownDrainSeconds: Int = KVDiskCacheConfig.defaultShutdownDrainSeconds,
        errors: [String] = []
    ) {
        self.enabled = enabled
        self.allowBuyerKeys = allowBuyerKeys
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.retentionMinutes = retentionMinutes
        self.stagingMaxBytes = stagingMaxBytes
        self.writeStagingMaxBytes = writeStagingMaxBytes
        self.minFreeBytes = minFreeBytes
        self.promotionMaxSeconds = promotionMaxSeconds
        self.shutdownDrainSeconds = shutdownDrainSeconds
        self.errors = errors
    }

    public static func defaults() -> KVDiskCacheConfig { KVDiskCacheConfig() }

    /// The tier may activate only when the operator enabled it AND no config
    /// error was recorded (fail-closed, FR-KVP11).
    public var effectiveEnabled: Bool { enabled && errors.isEmpty }

    // Defaults / hard bounds (FR-KVP11 table).
    public static let defaultDirectory = "~/Library/Caches/macprovider/kv-cache"
    public static let defaultMaxBytes = 16 * 1024 * 1024 * 1024          // 16 GiB
    public static let defaultMaxEntries = 64
    public static let defaultMaxEntryBytes = 2 * 1024 * 1024 * 1024      // 2 GiB
    public static let defaultRetentionMinutes = 60
    public static let defaultStagingMaxBytes = 256 * 1024 * 1024        // 256 MiB
    public static let defaultWriteStagingMaxBytes = 256 * 1024 * 1024   // 256 MiB
    public static let defaultMinFreeBytes = 8 * 1024 * 1024 * 1024      // 8 GiB
    public static let defaultPromotionMaxSeconds = 5
    public static let defaultShutdownDrainSeconds = 5

    static let hardStagingMaxBytes = 256 * 1024 * 1024                  // ≤ 256 MiB
    static let hardWriteStagingMaxBytes = 1024 * 1024 * 1024           // ≤ 1 GiB
    static let minMinFreeBytes = 1024 * 1024 * 1024                    // ≥ 1 GiB
}

/// Typed CLI overrides for the tier (mirrors the FR-KVP11 CLI-flag column).
/// `nil` fields defer to environment / YAML / default.
public struct KVDiskCacheCLIOverrides: Equatable, Sendable {
    public var enabled: Bool?
    public var allowBuyerKeys: Bool?
    public var directory: String?
    public var maxBytes: Int?
    public var maxEntries: Int?
    public var maxEntryBytes: Int?
    public var retentionMinutes: Int?
    public var stagingMaxBytes: Int?
    public var writeStagingMaxBytes: Int?
    public var minFreeBytes: Int?
    public var promotionMaxSeconds: Int?
    public var shutdownDrainSeconds: Int?

    public init(
        enabled: Bool? = nil,
        allowBuyerKeys: Bool? = nil,
        directory: String? = nil,
        maxBytes: Int? = nil,
        maxEntries: Int? = nil,
        maxEntryBytes: Int? = nil,
        retentionMinutes: Int? = nil,
        stagingMaxBytes: Int? = nil,
        writeStagingMaxBytes: Int? = nil,
        minFreeBytes: Int? = nil,
        promotionMaxSeconds: Int? = nil,
        shutdownDrainSeconds: Int? = nil
    ) {
        self.enabled = enabled
        self.allowBuyerKeys = allowBuyerKeys
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.retentionMinutes = retentionMinutes
        self.stagingMaxBytes = stagingMaxBytes
        self.writeStagingMaxBytes = writeStagingMaxBytes
        self.minFreeBytes = minFreeBytes
        self.promotionMaxSeconds = promotionMaxSeconds
        self.shutdownDrainSeconds = shutdownDrainSeconds
    }
}

/// Fail-closed resolver for the `kv_disk_cache:` group (FR-KVP11). Precedence
/// is YAML file → environment → CLI overrides (later wins). Any type error,
/// bound violation, or `allow_buyer_keys: true` records an error and forces the
/// tier off; the resolver never throws.
public enum KVDiskCacheConfigResolver {
    /// - Parameters:
    ///   - yaml: the parsed `kv_disk_cache:` nested dictionary, or nil.
    ///   - environment: process environment (env-var column).
    ///   - cli: typed CLI overrides.
    ///   - homeDirectory: home used for leading-`~` expansion (injectable for tests).
    public static func resolve(
        yaml: [String: Any]?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cli: KVDiskCacheCLIOverrides = KVDiskCacheCLIOverrides(),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> KVDiskCacheConfig {
        var config = KVDiskCacheConfig.defaults()
        var errors: [String] = []

        func fail(_ key: String, _ raw: String, _ expected: String) {
            errors.append("invalid \(key)=\(raw); expected \(expected); kv_disk_cache tier disabled")
        }

        // A per-key value may come from three string/typed sources; resolve in
        // precedence order and validate whichever is highest-priority present.
        func rawBool(_ yamlKey: String, _ envKey: String) -> (raw: String, ok: Bool?)? {
            if let v = environment[envKey] ?? yamlString(yaml, yamlKey) {
                return (v, parseBool(v))
            }
            return nil
        }
        func rawInt(_ yamlKey: String, _ envKey: String) -> (raw: String, value: Int?)? {
            if let s = environment[envKey] {
                return (s, Int(s.trimmingCharacters(in: .whitespaces)))
            }
            if let any = yaml?[yamlKey] {
                if let i = intFromAny(any) { return (String(describing: any), i) }
                return (String(describing: any), nil)
            }
            return nil
        }

        // enabled
        if let cli = cli.enabled {
            config.enabled = cli
        } else if let r = rawBool("enabled", "MACPROVIDER_KV_DISK_CACHE_ENABLED") {
            if let b = r.ok { config.enabled = b } else { fail("enabled", r.raw, "boolean") }
        }

        // allow_buyer_keys — v0.1: true is REJECTED.
        var allowBuyerRequested = false
        if let cli = cli.allowBuyerKeys {
            allowBuyerRequested = cli
        } else if let r = rawBool("allow_buyer_keys", "MACPROVIDER_KV_DISK_CACHE_ALLOW_BUYER_KEYS") {
            if let b = r.ok { allowBuyerRequested = b } else { fail("allow_buyer_keys", r.raw, "boolean") }
        }
        config.allowBuyerKeys = allowBuyerRequested
        if allowBuyerRequested {
            errors.append(
                "allow_buyer_keys=true is rejected in SPEC-037 v0.1; kv_disk_cache tier disabled. "
                + "Preconditions: machine-verifiable coordinator purge propagation (SPEC-024 FR-CI10a) "
                + "and a published buyer-purge disclosure must land first.")
        }

        // directory (leading ~ expanded, then MUST be absolute)
        var rawDir: String?
        if let cli = cli.directory { rawDir = cli }
        else if let s = environment["MACPROVIDER_KV_DISK_CACHE_DIR"] { rawDir = s }
        else if let s = yamlString(yaml, "directory") { rawDir = s }
        if let rawDir {
            let expanded = expandTilde(rawDir, home: homeDirectory)
            if expanded.hasPrefix("/") { config.directory = expanded }
            else { fail("directory", rawDir, "absolute path (leading ~ allowed)") }
        } else {
            config.directory = expandTilde(config.directory, home: homeDirectory)
        }

        // Positive-integer knobs.
        resolvePositive(&config.maxBytes, cli.maxBytes,
                        rawInt("max_bytes", "MACPROVIDER_KV_DISK_CACHE_MAX_BYTES"), "max_bytes", ">0", fail)
        resolvePositive(&config.maxEntries, cli.maxEntries,
                        rawInt("max_entries", "MACPROVIDER_KV_DISK_CACHE_MAX_ENTRIES"), "max_entries", ">0", fail)
        resolvePositive(&config.maxEntryBytes, cli.maxEntryBytes,
                        rawInt("max_entry_bytes", "MACPROVIDER_KV_DISK_CACHE_MAX_ENTRY_BYTES"), "max_entry_bytes", ">0", fail)
        resolvePositive(&config.retentionMinutes, cli.retentionMinutes,
                        rawInt("retention_minutes", "MACPROVIDER_KV_DISK_CACHE_RETENTION_MINUTES"), "retention_minutes", ">0", fail)
        resolvePositive(&config.promotionMaxSeconds, cli.promotionMaxSeconds,
                        rawInt("promotion_max_seconds", "MACPROVIDER_KV_DISK_CACHE_PROMOTION_MAX_S"), "promotion_max_seconds", ">0", fail)

        // staging_max_bytes: >0 and ≤ 256 MiB hard.
        resolveBounded(&config.stagingMaxBytes, cli.stagingMaxBytes,
                       rawInt("staging_max_bytes", "MACPROVIDER_KV_DISK_CACHE_STAGING_MAX_BYTES"),
                       "staging_max_bytes", min: 1, max: KVDiskCacheConfig.hardStagingMaxBytes,
                       expected: ">0 and ≤ 256 MiB", fail)
        // write_staging_max_bytes: >0 and ≤ 1 GiB hard.
        resolveBounded(&config.writeStagingMaxBytes, cli.writeStagingMaxBytes,
                       rawInt("write_staging_max_bytes", "MACPROVIDER_KV_DISK_CACHE_WRITE_STAGING_MAX_BYTES"),
                       "write_staging_max_bytes", min: 1, max: KVDiskCacheConfig.hardWriteStagingMaxBytes,
                       expected: ">0 and ≤ 1 GiB", fail)
        // min_free_bytes: ≥ 1 GiB.
        resolveBounded(&config.minFreeBytes, cli.minFreeBytes,
                       rawInt("min_free_bytes", "MACPROVIDER_KV_DISK_CACHE_MIN_FREE_BYTES"),
                       "min_free_bytes", min: KVDiskCacheConfig.minMinFreeBytes, max: Int.max,
                       expected: "≥ 1 GiB", fail)
        // shutdown_drain_seconds: ≥ 0.
        resolveBounded(&config.shutdownDrainSeconds, cli.shutdownDrainSeconds,
                       rawInt("shutdown_drain_seconds", "MACPROVIDER_KV_DISK_CACHE_SHUTDOWN_DRAIN_S"),
                       "shutdown_drain_seconds", min: 0, max: Int.max, expected: "≥ 0", fail)

        config.errors = errors
        return config
    }

    // MARK: - Helpers

    private static func resolvePositive(
        _ target: inout Int, _ cli: Int?, _ source: (raw: String, value: Int?)?,
        _ key: String, _ expected: String, _ fail: (String, String, String) -> Void
    ) {
        if let cli {
            if cli > 0 { target = cli } else { fail(key, String(cli), expected) }
        } else if let source {
            if let v = source.value, v > 0 { target = v } else { fail(key, source.raw, expected) }
        }
    }

    private static func resolveBounded(
        _ target: inout Int, _ cli: Int?, _ source: (raw: String, value: Int?)?,
        _ key: String, min: Int, max: Int, expected: String, _ fail: (String, String, String) -> Void
    ) {
        if let cli {
            if cli >= min && cli <= max { target = cli } else { fail(key, String(cli), expected) }
        } else if let source {
            if let v = source.value, v >= min, v <= max { target = v } else { fail(key, source.raw, expected) }
        }
    }

    private static func yamlString(_ yaml: [String: Any]?, _ key: String) -> String? {
        guard let any = yaml?[key] else { return nil }
        if let s = any as? String { return s }
        if let b = any as? Bool { return b ? "true" : "false" }
        if let i = any as? Int { return String(i) }
        return String(describing: any)
    }

    private static func intFromAny(_ any: Any) -> Int? {
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        if let d = any as? Double, d == d.rounded() { return Int(d) }
        return nil
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + "/" + String(path.dropFirst(2)) }
        return path
    }
}
