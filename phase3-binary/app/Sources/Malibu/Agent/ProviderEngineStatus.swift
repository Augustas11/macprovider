import Foundation

/// Provider runtime details from the CLI's `/v1/status`.
/// Only the fields the Provider screen shows are kept; diagnostic counters,
/// policy digests and signer ids stay in exported diagnostics.
struct ProviderEngineStatus: Equatable, Sendable {
    struct Restart: Equatable, Sendable {
        let at: Date
        let reason: String
        let version: String?
    }

    let continuousBatchingMode: String?
    let continuousBatchingActive: Bool?
    let continuousBatchingUnsupportedReason: String?
    let slotsTotal: Int?
    let slotsFree: Int?
    let waitingRequests: Int?
    let nativeMTPSupported: Bool?
    let nativeMTPMode: String?
    let nativeMTPMeanAcceptedLength: Double?
    let kvDiskEnabled: Bool?
    let kvDiskActivated: Bool?
    let kvDiskUnsupportedReason: String?
    let kvDiskBytesUsed: Int?
    let kvDiskMaxBytes: Int?
    /// nil means an older CLI does not expose the list; [] means supported
    /// with no recorded restart.
    let recentRestarts: [Restart]?

    /// `ContinuousBatchingMode` and `NativeMTPStatusMode` in the CLI.
    static let continuousBatchingModes: Set<String> = ["off", "canary", "on"]
    static let nativeMTPModes: Set<String> = ["off", "eligible", "active", "degraded_depth_zero"]

    static func decode(status object: [String: Any]) -> ProviderEngineStatus? {
        let cb = object["continuous_batching"] as? [String: Any]
        let mtp = object["native_mtp"] as? [String: Any]
        let kv = object["kv_disk_tier"] as? [String: Any]
        let restartObjects = object["recent_restarts"] as? [[String: Any]]
        guard cb != nil || mtp != nil || kv != nil || restartObjects != nil else { return nil }
        let scheduler = cb?["scheduler"] as? [String: Any]
        func int(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let int = number.intValue
            return int >= 0 ? int : nil
        }
        func bool(_ value: Any?) -> Bool? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        /// Only a value from the CLI's closed enum is kept; anything else is
        /// treated as not reported.
        func token(_ value: Any?, _ allowed: Set<String>) -> String? {
            guard let string = value as? String, allowed.contains(string) else { return nil }
            return string
        }
        func presentToken(_ value: Any?) -> String? {
            guard let string = value as? String, !string.isEmpty, string.count <= 64,
                  string.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) })
            else { return nil }
            return string
        }
        let meanAccepted = (mtp?["mean_accepted_length"] as? NSNumber)
            .flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue }
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        let recentRestarts = restartObjects.map { objects in objects.prefix(10).compactMap { restart -> Restart? in
            guard let atString = restart["at"] as? String,
                  let at = formatter.date(from: atString) ?? fallbackFormatter.date(from: atString),
                  let reason = presentToken(restart["reason"]) else { return nil }
            let version = (restart["version"] as? String).flatMap {
                !$0.isEmpty && $0.count <= 64 ? $0 : nil
            }
            return Restart(at: at, reason: reason, version: version)
        }}
        return ProviderEngineStatus(
            continuousBatchingMode: token(cb?["mode"], Self.continuousBatchingModes),
            continuousBatchingActive: bool(cb?["active"]),
            continuousBatchingUnsupportedReason: presentToken(cb?["unsupported_reason"]),
            slotsTotal: int(scheduler?["slots_total"]),
            slotsFree: int(scheduler?["slots_free"]),
            waitingRequests: int(scheduler?["waiting_count"]),
            nativeMTPSupported: bool(mtp?["supported"]),
            nativeMTPMode: token(mtp?["mode"], Self.nativeMTPModes),
            nativeMTPMeanAcceptedLength: meanAccepted,
            kvDiskEnabled: bool(kv?["enabled"]),
            kvDiskActivated: bool(kv?["activated"]),
            kvDiskUnsupportedReason: presentToken(kv?["unsupported_reason"]),
            kvDiskBytesUsed: int(kv?["bytes_used"]),
            kvDiskMaxBytes: int(kv?["max_bytes"]),
            recentRestarts: recentRestarts
        )
    }
}
