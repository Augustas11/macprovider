import Foundation
import MacProviderCore

/// SPEC-037 FR-KVP11 — the synthetic-key persistence gate. The disk tier
/// persists (and, once wired, promotes) a conversation ONLY when BOTH hold:
///   1. the canonical key bytes begin with the reserved `conv:kvs-synth:`
///      sub-namespace prefix, and
///   2. the request arrived over the direct-HTTP operator path.
/// Coordinator-derived buyer keys carry a base64url HMAC suffix that cannot
/// contain `:`, so they can never match the sub-namespace; and relay / Tier-2
/// traffic never persists regardless of key shape (defense in depth against a
/// buyer crafting the prefix on a non-gateway path). The gate never infers
/// provenance from key shape alone — both inputs are required.
enum KVDiskCacheGate {
    static let syntheticPrefix = "conv:kvs-synth:"

    static func persists(conversationKey: String?, provenance: KVIngestProvenance) -> Bool {
        guard provenance == .directHTTP else { return false }
        guard let key = conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return key.hasPrefix(syntheticPrefix) && key.utf8.count > syntheticPrefix.utf8.count
    }
}

/// SPEC-037 — provider-runtime coordinator around the stage-1/2
/// `KVDiskCacheStore`. Owns the resolved `KVDiskCacheConfig`, the store's
/// lifecycle (activation with dormant-retry semantics, shutdown drain), the
/// enable-time notice + free-space headroom check, and the operator-facing
/// purge/status control plane. The heavier RAM<->disk data path
/// (snapshot-at-commit capture and lazy promotion into the live model) is wired
/// into `ModelRuntime`/`ConversationCache` in stage 5 alongside its AC-1/AC-8
/// fixtures; this coordinator exposes the control-plane primitives those need.
final class KVDiskTier: @unchecked Sendable {
    let store: KVDiskCacheStore
    let config: KVDiskCacheConfig
    let namespaceID: String
    let eligibilityTTLSeconds: Int

    /// Graceful-shutdown drain of queued cold writes (HIGH-5), wired at cold-tier
    /// attach time. Bounded by `shutdownDrainSeconds`. Lock-guarded.
    static let shutdownDrainSeconds = 5
    private let drainLock = NSLock()
    private var drainHook: (@Sendable (Int) async -> Void)?
    func setDrainHook(_ hook: (@Sendable (Int) async -> Void)?) {
        drainLock.lock(); drainHook = hook; drainLock.unlock()
    }

    init(
        config: KVDiskCacheConfig,
        namespaceID: String,
        eligibilityTTLSeconds: Int = 900,
        keychain: any KVKeychain = KVSecItemKeychain(),
        sink: any KVEventSink = KVStderrEventSink()
    ) {
        self.config = config
        self.namespaceID = namespaceID
        self.eligibilityTTLSeconds = eligibilityTTLSeconds
        var storeConfig = KVDiskCacheStoreConfig(
            root: URL(fileURLWithPath: config.directory, isDirectory: true),
            namespaceID: namespaceID,
            maxBytes: config.maxBytes,
            maxEntries: config.maxEntries,
            maxEntryBytes: config.maxEntryBytes,
            retentionSeconds: config.retentionMinutes * 60,
            stagingMaxBytes: config.stagingMaxBytes,
            writeStagingMaxBytes: config.writeStagingMaxBytes,
            minFreeBytes: config.minFreeBytes,
            promotionMaxSeconds: config.promotionMaxSeconds,
            eligibilityTTLSeconds: eligibilityTTLSeconds)
        // M-12: run a background retention sweep every 5 minutes while active.
        storeConfig.retentionSweepSeconds = 300
        self.store = KVDiskCacheStore(config: storeConfig, keychain: keychain, sink: sink)
    }

    /// Build a coordinator from resolved app config. Returns nil when the tier
    /// is not enabled AND there is no provider identity to namespace a store
    /// with — i.e. nothing to activate. Purge/status callers that need a store
    /// even while disabled pass an explicit namespaceID via `init`.
    static func make(config: KVDiskCacheConfig, providerID: String?, eligibilityTTLSeconds: Int = 900) -> KVDiskTier? {
        guard let providerID, !providerID.isEmpty else { return nil }
        return KVDiskTier(config: config, namespaceID: providerID, eligibilityTTLSeconds: eligibilityTTLSeconds)
    }

    // MARK: - Lifecycle (FR-KVP7)

    /// Activate the store on serve start when the tier is enabled. Fail-closed:
    /// a config error, missing purge primitive, or lock unavailability leaves
    /// the tier dormant (never fails the serve loop). Returns true on activation.
    @discardableResult
    func activateForServe() async -> Bool {
        guard config.effectiveEnabled else {
            for error in config.errors { log("event=kv_disk_cache action=config_error detail=\"\(error)\"") }
            return false
        }
        logEnableNotice()
        do {
            let activated = try await store.activate()
            if !activated {
                log("event=kv_disk_cache action=dormant reason=lock_unavailable")
            }
            return activated
        } catch {
            log("event=kv_disk_cache action=dormant reason=quarantined")
            return false
        }
    }

    /// Ensure the store is active for a control-plane op (purge/status), even
    /// while `enabled=false`. Acquires the free lock standalone (FR-KVP7).
    @discardableResult
    func activateForControlPlane() async -> Bool {
        (try? await store.activate()) ?? false
    }

    /// Graceful shutdown drain (FR-KVP3 / HIGH-5): flush queued cold writes (bounded
    /// by `shutdownDrainSeconds`) BEFORE releasing the namespace lock.
    func shutdown() async {
        drainLock.lock(); let hook = drainHook; drainLock.unlock()
        if let hook { await hook(Self.shutdownDrainSeconds) }
        await store.deactivate()
    }

    // MARK: - Control plane (FR-KVP8/KVP12) — functional while enabled=false

    func purge(rawKey: String) async -> KVPurgeResult {
        guard await activateForControlPlane() else { return .failed(.ioError) }
        return (try? await store.purge(rawKey: rawKey)) ?? .failed(.ioError)
    }

    func purgeAll() async -> KVPurgeResult {
        guard await activateForControlPlane() else { return .failed(.ioError) }
        return (try? await store.purgeAll()) ?? .failed(.ioError)
    }

    func purgeAllAndForget() async -> KVPurgeResult {
        guard await activateForControlPlane() else { return .failed(.ioError) }
        return (try? await store.purgeAllAndForget()) ?? .failed(.ioError)
    }

    func status() async -> KVInspection? {
        guard await activateForControlPlane() else { return nil }
        return await store.inspect()
    }

    // MARK: - Enable-time notice + headroom (FR-KVP11 / FR-KVP7)

    func logEnableNotice() {
        let freeBytes = KVDiskTier.freeSpaceBytes(atPath: config.directory)
        let headroom: String
        if let freeBytes {
            headroom = freeBytes >= config.minFreeBytes
                ? "ok(free=\(freeBytes) floor=\(config.minFreeBytes))"
                : "LOW(free=\(freeBytes) floor=\(config.minFreeBytes))"
        } else {
            headroom = "unknown"
        }
        log("event=kv_disk_cache action=enabled"
            + " directory=\(config.directory)"
            + " max_bytes=\(config.maxBytes) max_entries=\(config.maxEntries) max_entry_bytes=\(config.maxEntryBytes)"
            + " reuse_eligibility_ttl_seconds=\(eligibilityTTLSeconds)"
            + " retention_minutes=\(config.retentionMinutes)(cleanup_only)"
            + " synthetic_gate=conv:kvs-synth:+direct_http"
            + " purge_command=\"macprovider-cli kv-cache purge\""
            + " free_space=\(headroom)")
        if let freeBytes, freeBytes < config.minFreeBytes {
            log("event=kv_disk_cache action=warn reason=insufficient_free_space free=\(freeBytes) floor=\(config.minFreeBytes)")
        }
    }

    static func freeSpaceBytes(atPath path: String) -> Int? {
        var stat = statvfs()
        // Walk up to the nearest existing ancestor (the dir may not exist yet).
        var probe = path
        let fm = FileManager.default
        while !probe.isEmpty, probe != "/", !fm.fileExists(atPath: probe) {
            probe = (probe as NSString).deletingLastPathComponent
        }
        guard statvfs(probe.isEmpty ? "/" : probe, &stat) == 0 else { return nil }
        let free = UInt64(stat.f_bavail) * UInt64(stat.f_frsize)
        return free > UInt64(Int.max) ? Int.max : Int(free)
    }

    private nonisolated func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
