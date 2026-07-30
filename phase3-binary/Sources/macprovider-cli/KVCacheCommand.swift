import ArgumentParser
import Foundation
import MacProviderCore

/// SPEC-037 FR-KVP8/FR-KVP12 — operator control plane for the KV survival disk
/// tier. Canonical spellings:
///   macprovider-cli kv-cache purge --key <k> | --key-stdin | --all [--forget]
///   macprovider-cli kv-cache status
///
/// These work while the tier is `enabled=false` (a disabled tier still has
/// purgeable residue). Execution honors the FR-KVP7 flock model: a standalone
/// invocation with no serve process running acquires the free namespace lock
/// itself. (The in-serve-process control-socket route, used when a serve
/// process already holds the lock, lands with the serve-lifecycle wiring in
/// stage 5; a standalone invocation while serve holds the lock reports
/// `purge_failed` on lock timeout, fail-closed.)
///
/// Output is counts/bytes only — never raw conversation keys or index values.
struct KVCacheCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kv-cache",
        abstract: "Inspect and purge the encrypted KV survival disk tier (SPEC-037).",
        shouldDisplay: false,
        subcommands: [KVCachePurgeCommand.self, KVCacheStatusCommand.self]
    )
}

enum KVCacheCommandError: Error, CustomStringConvertible, Equatable {
    case missingProviderID
    case invalidSelection(String)
    case emptyKey

    var description: String {
        switch self {
        case .missingProviderID:
            return "kv-cache requires provider_id in config, env (MACPROVIDER_PROVIDER_ID), or --provider-id"
        case let .invalidSelection(message):
            return message
        case .emptyKey:
            return "no conversation key provided on stdin"
        }
    }
}

/// Shared resolution: build a standalone coordinator from config.
enum KVCacheCommandSupport {
    static func makeTier(configPath: String?, providerIDOverride: String?) throws -> KVDiskTier {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(providerID: providerIDOverride, configPath: configPath))
        guard let providerID = resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            throw KVCacheCommandError.missingProviderID
        }
        let ttl = Int(ConversationCache.Config.fromEnvironment().ttlSeconds)
        return KVDiskTier(config: resolved.kvDiskCache, namespaceID: providerID, eligibilityTTLSeconds: ttl)
    }

    /// Resolve the control-socket path from config (nil when unresolvable).
    static func socketPath(configPath: String?, providerIDOverride: String?) -> URL? {
        guard let resolved = try? ConfigLoader.load(
            cli: CLIOverrides(providerID: providerIDOverride, configPath: configPath)) else { return nil }
        return ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
    }

    /// FR-KVP7 execution model: while a serve process holds the namespace flock,
    /// purge/status are executed by that process via the control socket (no lock
    /// re-acquisition). Returns the response frame, or nil to fall back to the
    /// standalone lock path (socket absent/refused, or the serve tier is inactive).
    static func trySocket(
        _ request: ControlSocketFrame, configPath: String?, providerIDOverride: String?
    ) async -> ControlSocketFrame? {
        guard let path = socketPath(configPath: configPath, providerIDOverride: providerIDOverride) else { return nil }
        let connection: ControlSocketConnection
        do {
            connection = try await ControlSocketClient.connect(socketPath: path)
        } catch {
            return nil   // socket absent/refused ⇒ no serve process holds the lock
        }
        defer { Task { await connection.close() } }
        do {
            try await connection.send(request)
            return try await connection.receive(timeout: 180)
        } catch {
            return nil
        }
    }

    static func emit(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func emitRaw(_ json: String) {
        FileHandle.standardOutput.write(Data(json.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct KVCachePurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Purge one conversation key, or the whole namespace (--all)."
    )

    @Option(help: "YAML config path. Defaults to MACPROVIDER_CONFIG or ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(name: .customLong("provider-id"), help: "Stable provider identifier. Overrides config provider_id.")
    var providerID: String?

    @Option(help: "Raw conversation key to purge (canonicalized + HMAC-indexed in-process). Prefer --key-stdin to keep keys out of argv.")
    var key: String?

    @Flag(name: .customLong("key-stdin"), help: "Read the raw conversation key from stdin (preferred; no argv exposure).")
    var keyStdin: Bool = false

    @Flag(help: "Purge the entire namespace via key-epoch rotation.")
    var all: Bool = false

    @Flag(help: "With --all: also delete the namespace directory and all Keychain items (uninstall).")
    var forget: Bool = false

    func run() async throws {
        // Exactly one target selector.
        let selectors = [key != nil, keyStdin, all].filter { $0 }.count
        guard selectors == 1 else {
            throw KVCacheCommandError.invalidSelection(
                "specify exactly one of --key, --key-stdin, or --all")
        }
        if forget && !all {
            throw KVCacheCommandError.invalidSelection("--forget is only valid with --all")
        }

        // Resolve mode + raw key once (stdin may only be read once).
        let mode: String
        var rawKey = ""
        if all {
            mode = forget ? "all_forget" : "all"
        } else {
            mode = "single"
            if keyStdin {
                let stdinData = FileHandle.standardInput.readDataToEndOfFile()
                let raw = String(decoding: stdinData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { throw KVCacheCommandError.emptyKey }
                rawKey = raw
            } else {
                rawKey = key ?? ""
            }
        }

        // FR-KVP7: try the in-process control-socket route first (a running serve
        // process holds the flock); fall back to the standalone lock path.
        let socketRequest = ControlSocketFrame.kvCachePurgeRequest(mode: mode, key: mode == "single" ? rawKey : nil)
        if case let .kvCachePurgeResponse(status, entriesRemoved, bytesFreed, detail)? =
            await KVCacheCommandSupport.trySocket(socketRequest, configPath: config, providerIDOverride: providerID),
           status != "unavailable" {
            if status == "purge_ok" {
                KVCacheCommandSupport.emit([
                    "status": "purge_ok", "mode": mode, "route": "control_socket",
                    "entries_removed": entriesRemoved, "bytes_freed": bytesFreed,
                ])
            } else {
                KVCacheCommandSupport.emit([
                    "status": "purge_failed", "mode": mode, "route": "control_socket",
                    "detail": detail ?? "unknown",
                ])
                throw ExitCode(1)
            }
            return
        }

        let tier = try KVCacheCommandSupport.makeTier(configPath: config, providerIDOverride: providerID)
        let result: KVPurgeResult
        switch mode {
        case "all_forget": result = await tier.purgeAllAndForget()
        case "all": result = await tier.purgeAll()
        default: result = await tier.purge(rawKey: rawKey)
        }
        await tier.shutdown()

        switch result {
        case let .ok(entriesRemoved, bytesFreed):
            KVCacheCommandSupport.emit([
                "status": "purge_ok",
                "mode": mode,
                "entries_removed": entriesRemoved,
                "bytes_freed": bytesFreed,
            ])
        case let .failed(detail):
            KVCacheCommandSupport.emit([
                "status": "purge_failed",
                "mode": mode,
                "detail": detail.rawValue,
            ])
            throw ExitCode(1)
        }
    }
}

struct KVCacheStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report namespace usage, caps, headroom, epoch, and per-reason counters."
    )

    @Option(help: "YAML config path. Defaults to MACPROVIDER_CONFIG or ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(name: .customLong("provider-id"), help: "Stable provider identifier. Overrides config provider_id.")
    var providerID: String?

    func run() async throws {
        // FR-KVP7: prefer the in-process control-socket route.
        if case let .kvCacheStatusResponse(payloadJSON)? = await KVCacheCommandSupport.trySocket(
            .kvCacheStatusRequest, configPath: config, providerIDOverride: providerID),
           !payloadJSON.contains("\"unavailable\"") {
            KVCacheCommandSupport.emitRaw(payloadJSON)
            return
        }

        let tier = try KVCacheCommandSupport.makeTier(configPath: config, providerIDOverride: providerID)
        let inspection = await tier.status()
        await tier.shutdown()
        guard let inspection else {
            KVCacheCommandSupport.emit(["status": "unavailable", "detail": "namespace lock unavailable or quarantined"])
            throw ExitCode(1)
        }
        KVCacheCommandSupport.emit([
            "status": "ok",
            "enabled": tier.config.effectiveEnabled,
            "retention_minutes": tier.config.retentionMinutes,
            "namespace_id": inspection.namespaceID,
            "bytes_used": inspection.bytesUsed,
            "control_bytes_used": inspection.controlBytesUsed,
            "usage_journal_bytes": inspection.usageJournalBytes,
            "total_bytes_used": inspection.totalBytesUsed,
            "max_bytes": inspection.maxBytes,
            "entry_count": inspection.entryCount,
            "max_entries": inspection.maxEntries,
            "free_space_headroom": inspection.freeSpaceHeadroom,
            "key_epoch": inspection.keyEpoch,
            "tombstone_count": inspection.tombstoneCount,
            "keychain_item_count": inspection.keychainItemCount,
            "reuse_eligibility_ttl_seconds": inspection.eligibilityTTLSeconds,
            "purge_high_watermark_entries": inspection.purgeHighWatermarkEntries,
            "counters": inspection.counters,
        ])
    }
}
