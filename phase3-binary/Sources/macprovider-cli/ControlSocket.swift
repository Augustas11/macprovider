import Darwin
import Foundation
import MacProviderCore

public enum SwitchAckReason: String, Sendable, Equatable {
    case loadingInProgress = "loading_in_progress"
    case cooldown
    case notInSupportedModels = "not_in_supported_models"
    case other
}

public enum SwitchProgressState: String, Sendable, Equatable {
    case loading
    case draining
    case loaded
    case failed
}

public enum ReceiptKeyRotationResultStatus: String, Sendable, Equatable {
    case accepted
    case rejected
    case committedUnconfirmed = "committed_unconfirmed"
}

struct ProviderControlCommandResult: Equatable, Sendable {
    let accepted: Bool
    let reason: String?

    static let accepted = ProviderControlCommandResult(accepted: true, reason: nil)

    static func rejected(_ reason: String) -> ProviderControlCommandResult {
        ProviderControlCommandResult(accepted: false, reason: reason)
    }
}

public enum ControlSocketFrame: Equatable, Sendable {
    case switchRequest(targetModelID: String, requestedAtMs: Int64)
    case statusRequest
    case rotateReceiptKeyRequest(providerID: String)
    case rotateReceiptKeyResult(status: ReceiptKeyRotationResultStatus, error: String?)
    case switchAck(accepted: Bool, reason: SwitchAckReason?, currentTarget: String?, secondsRemaining: Int?)
    case switchProgress(state: SwitchProgressState, elapsedMs: Int, reason: String?)
    case statusResponse(currentModelID: String, runtimeState: SwapState)

    // SPEC-025 §5.2 — additive frames used by Malibu.app's read-only control client.
    case metricsRequest
    case metricsResponse(ControlMetricsSnapshot)
    case pauseRequest
    case pauseAck(accepted: Bool, reason: String?)
    case resumeRequest
    case resumeAck(accepted: Bool, reason: String?)
    case shutdownRequest(graceSeconds: Int)
    case shutdownAck
    case referralStatusRequest
    case referralStatusResponse(ReferralStatusSnapshot)
    case referralChallengeRequest
    case referralChallengeResponse(expiresAt: String)
    case referralChallengeReopenRequest
    case referralChallengeReopenAck(expiresAt: String)
    case referralVerifyRequest(postURL: String)
    case referralChallengeCancelRequest
    case referralChallengeCancelAck(status: ReferralStatusSnapshot?)
    case referralError(
        operation: ReferralControlOperation,
        code: ReferralControlErrorCode,
        retryAfterSeconds: Int?
    )

    // SPEC-037 stage 5 (FR-KVP8/KVP12) — in-process KV survival disk-tier control,
    // executed by the serve process that holds the namespace flock. `mode` is one
    // of "single" | "all" | "all_forget"; the raw key travels only over the
    // owner-only local socket, never argv.
    case kvCachePurgeRequest(mode: String, key: String?)
    case kvCachePurgeResponse(status: String, entriesRemoved: Int, bytesFreed: Int, detail: String?)
    case kvCacheStatusRequest
    case kvCacheStatusResponse(payloadJSON: String)
}

public enum ControlSocketCodec {
    public static func encode(_ frame: ControlSocketFrame) throws -> Data {
        let object: [String: Any]
        switch frame {
        case let .switchRequest(targetModelID, requestedAtMs):
            object = [
                "type": "switch_request",
                "target_model_id": targetModelID,
                "requested_at_ms": requestedAtMs,
            ]
        case .statusRequest:
            object = ["type": "status_request"]
        case let .rotateReceiptKeyRequest(providerID):
            object = [
                "type": "rotate_receipt_key_request",
                "provider_id": providerID,
            ]
        case let .rotateReceiptKeyResult(status, error):
            var frame: [String: Any] = [
                "type": "rotate_receipt_key_result",
                "status": status.rawValue,
                "accepted": status == .accepted,
            ]
            if status != .accepted, let error {
                frame["error"] = error
            }
            object = frame
        case let .switchAck(accepted, reason, currentTarget, secondsRemaining):
            var frame: [String: Any] = [
                "type": "switch_ack",
                "accepted": accepted,
            ]
            if !accepted, let reason {
                frame["reason"] = reason.rawValue
                if reason == .loadingInProgress, let currentTarget {
                    frame["current_target"] = currentTarget
                }
                if reason == .cooldown, let secondsRemaining {
                    frame["seconds_remaining"] = secondsRemaining
                }
            }
            object = frame
        case let .switchProgress(state, elapsedMs, reason):
            var frame: [String: Any] = [
                "type": "switch_progress",
                "state": state.rawValue,
                "elapsed_ms": elapsedMs,
            ]
            if state == .failed, let reason {
                frame["reason"] = reason
            }
            object = frame
        case let .statusResponse(currentModelID, runtimeState):
            object = [
                "type": "status_response",
                "current_model_id": currentModelID,
                "runtime_state": runtimeState.rawValue,
            ]
        case .metricsRequest:
            object = ["type": "metrics_request"]
        case let .metricsResponse(metrics):
            var frame: [String: Any] = [
                "type": "metrics_response",
                "uptime_sec": metrics.uptimeSec,
            ]
            if let earningsUsdc = metrics.earningsUsdc { frame["earnings_usdc"] = earningsUsdc }
            if let malibuAccrued = metrics.malibuAccrued { frame["malibu_accrued"] = malibuAccrued }
            if let providerEarnings = metrics.providerEarnings {
                frame["provider_earnings"] = try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(providerEarnings)
                )
            }
            if let gpuC = metrics.gpuC { frame["gpu_c"] = gpuC }
            if let latencyP50Ms = metrics.latencyP50Ms { frame["latency_p50_ms"] = latencyP50Ms }
            if let requestsServedToday = metrics.requestsServedToday { frame["requests_served_today"] = requestsServedToday }
            if let requestsServedAllTime = metrics.requestsServedAllTime { frame["requests_served_all_time"] = requestsServedAllTime }
            if let requestsPerMinute = metrics.requestsPerMinute { frame["requests_per_minute"] = requestsPerMinute }
            if let inputTokensToday = metrics.inputTokensToday { frame["input_tokens_today"] = inputTokensToday }
            if let outputTokensToday = metrics.outputTokensToday { frame["output_tokens_today"] = outputTokensToday }
            if let inputTokensAllTime = metrics.inputTokensAllTime { frame["input_tokens_all_time"] = inputTokensAllTime }
            if let outputTokensAllTime = metrics.outputTokensAllTime { frame["output_tokens_all_time"] = outputTokensAllTime }
            if let queueDepth = metrics.queueDepth { frame["queue_depth"] = queueDepth }
            object = frame
        case .pauseRequest:
            object = ["type": "pause_request"]
        case let .pauseAck(accepted, reason):
            var frame: [String: Any] = ["type": "pause_ack", "accepted": accepted]
            if let reason { frame["reason"] = reason }
            object = frame
        case .resumeRequest:
            object = ["type": "resume_request"]
        case let .resumeAck(accepted, reason):
            var frame: [String: Any] = ["type": "resume_ack", "accepted": accepted]
            if let reason { frame["reason"] = reason }
            object = frame
        case let .shutdownRequest(graceSeconds):
            object = ["type": "shutdown_request", "grace_seconds": graceSeconds]
        case .shutdownAck:
            object = ["type": "shutdown_ack"]
        case .referralStatusRequest:
            object = ["type": "referral_status_request"]
        case let .referralStatusResponse(status):
            object = try Self.object(
                encoding: status,
                adding: ["type": "referral_status_response"]
            )
        case .referralChallengeRequest:
            object = ["type": "referral_challenge_request"]
        case let .referralChallengeResponse(expiresAt):
            object = [
                "type": "referral_challenge_response",
                "expires_at": expiresAt,
            ]
        case .referralChallengeReopenRequest:
            object = ["type": "referral_challenge_reopen_request"]
        case let .referralChallengeReopenAck(expiresAt):
            object = ["type": "referral_challenge_reopen_ack", "expires_at": expiresAt]
        case let .referralVerifyRequest(postURL):
            object = [
                "type": "referral_verify_request",
                "post_url": postURL,
            ]
        case .referralChallengeCancelRequest:
            object = ["type": "referral_challenge_cancel_request"]
        case let .referralChallengeCancelAck(status):
            var frame: [String: Any] = ["type": "referral_challenge_cancel_ack"]
            if let status {
                frame["status"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status))
            }
            object = frame
        case let .referralError(operation, code, retryAfterSeconds):
            var frame: [String: Any] = [
                "type": "referral_error",
                "operation": operation.rawValue,
                "code": code.rawValue,
            ]
            if let retryAfterSeconds { frame["retry_after_seconds"] = retryAfterSeconds }
            object = frame
        case let .kvCachePurgeRequest(mode, key):
            var frame: [String: Any] = ["type": "kv_cache_purge_request", "mode": mode]
            if let key { frame["key"] = key }
            object = frame
        case let .kvCachePurgeResponse(status, entriesRemoved, bytesFreed, detail):
            var frame: [String: Any] = [
                "type": "kv_cache_purge_response", "status": status,
                "entries_removed": entriesRemoved, "bytes_freed": bytesFreed,
            ]
            if let detail { frame["detail"] = detail }
            object = frame
        case .kvCacheStatusRequest:
            object = ["type": "kv_cache_status_request"]
        case let .kvCacheStatusResponse(payloadJSON):
            object = ["type": "kv_cache_status_response", "payload_json": payloadJSON]
        }

        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) throws -> ControlSocketFrame {
        let trimmed = line.last == 0x0A ? line.dropLast() : line[...]
        let raw = try JSONSerialization.jsonObject(with: Data(trimmed))
        guard let object = raw as? [String: Any] else {
            throw ControlSocketError.missingType
        }
        guard let type = object["type"] as? String else {
            throw ControlSocketError.missingType
        }

        switch type {
        case "switch_request":
            return .switchRequest(
                targetModelID: try stringField("target_model_id", in: object),
                requestedAtMs: try int64Field("requested_at_ms", in: object)
            )
        case "status_request":
            return .statusRequest
        case "rotate_receipt_key_request":
            return .rotateReceiptKeyRequest(providerID: try stringField("provider_id", in: object))
        case "rotate_receipt_key_result":
            let status: ReceiptKeyRotationResultStatus
            if let statusRaw = object["status"] as? String {
                guard let decoded = ReceiptKeyRotationResultStatus(rawValue: statusRaw) else {
                    throw ControlSocketError.invalidEnumValue(field: "status", value: statusRaw)
                }
                status = decoded
            } else {
                status = try boolField("accepted", in: object) ? .accepted : .rejected
            }
            let error = status == .accepted ? nil : try stringField("error", in: object)
            return .rotateReceiptKeyResult(status: status, error: error)
        case "switch_ack":
            let accepted = try boolField("accepted", in: object)
            if accepted {
                return .switchAck(accepted: true, reason: nil, currentTarget: nil, secondsRemaining: nil)
            }
            let reasonRaw = try stringField("reason", in: object)
            guard let reason = SwitchAckReason(rawValue: reasonRaw) else {
                throw ControlSocketError.invalidEnumValue(field: "reason", value: reasonRaw)
            }
            let currentTarget = reason == .loadingInProgress ? try stringField("current_target", in: object) : nil
            let secondsRemaining = reason == .cooldown ? try intField("seconds_remaining", in: object) : nil
            return .switchAck(
                accepted: false,
                reason: reason,
                currentTarget: currentTarget,
                secondsRemaining: secondsRemaining
            )
        case "switch_progress":
            let stateRaw = try stringField("state", in: object)
            guard let state = SwitchProgressState(rawValue: stateRaw) else {
                throw ControlSocketError.invalidEnumValue(field: "state", value: stateRaw)
            }
            let reason = state == .failed ? try stringField("reason", in: object) : nil
            return .switchProgress(state: state, elapsedMs: try intField("elapsed_ms", in: object), reason: reason)
        case "status_response":
            let stateRaw = try stringField("runtime_state", in: object)
            guard let state = SwapState(rawValue: stateRaw), state != .failed else {
                throw ControlSocketError.invalidEnumValue(field: "runtime_state", value: stateRaw)
            }
            return .statusResponse(
                currentModelID: try stringField("current_model_id", in: object),
                runtimeState: state
            )
        case "metrics_request":
            return .metricsRequest
        case "metrics_response":
            return .metricsResponse(ControlMetricsSnapshot(
                earningsUsdc: optionalDoubleField("earnings_usdc", in: object),
                malibuAccrued: optionalDoubleField("malibu_accrued", in: object),
                providerEarnings: try decodeProviderEarnings(in: object),
                gpuC: optionalDoubleField("gpu_c", in: object),
                latencyP50Ms: optionalIntField("latency_p50_ms", in: object),
                uptimeSec: try intField("uptime_sec", in: object),
                requestsServedToday: optionalIntField("requests_served_today", in: object),
                requestsServedAllTime: optionalIntField("requests_served_all_time", in: object),
                requestsPerMinute: optionalDoubleField("requests_per_minute", in: object),
                inputTokensToday: optionalInt64Field("input_tokens_today", in: object),
                outputTokensToday: optionalInt64Field("output_tokens_today", in: object),
                inputTokensAllTime: optionalInt64Field("input_tokens_all_time", in: object),
                outputTokensAllTime: optionalInt64Field("output_tokens_all_time", in: object),
                queueDepth: optionalIntField("queue_depth", in: object)
            ))
        case "pause_request":
            return .pauseRequest
        case "pause_ack":
            return .pauseAck(
                accepted: try boolField("accepted", in: object),
                reason: object["reason"] as? String
            )
        case "resume_request":
            return .resumeRequest
        case "resume_ack":
            return .resumeAck(
                accepted: try boolField("accepted", in: object),
                reason: object["reason"] as? String
            )
        case "shutdown_request":
            return .shutdownRequest(graceSeconds: try intField("grace_seconds", in: object))
        case "shutdown_ack":
            return .shutdownAck
        case "referral_status_request":
            return .referralStatusRequest
        case "referral_status_response":
            return .referralStatusResponse(try decode(ReferralStatusSnapshot.self, from: object, removing: "type"))
        case "referral_challenge_request":
            return .referralChallengeRequest
        case "referral_challenge_response":
            return .referralChallengeResponse(expiresAt: try stringField("expires_at", in: object))
        case "referral_challenge_reopen_request":
            return .referralChallengeReopenRequest
        case "referral_challenge_reopen_ack":
            return .referralChallengeReopenAck(expiresAt: try stringField("expires_at", in: object))
        case "referral_verify_request":
            return .referralVerifyRequest(postURL: try stringField("post_url", in: object))
        case "referral_challenge_cancel_request":
            return .referralChallengeCancelRequest
        case "referral_challenge_cancel_ack":
            let status: ReferralStatusSnapshot? = if let raw = object["status"] {
                try decode(ReferralStatusSnapshot.self, from: raw)
            } else {
                nil
            }
            return .referralChallengeCancelAck(status: status)
        case "referral_error":
            let operationRaw = try stringField("operation", in: object)
            guard let operation = ReferralControlOperation(rawValue: operationRaw) else {
                throw ControlSocketError.invalidEnumValue(field: "operation", value: operationRaw)
            }
            let codeRaw = try stringField("code", in: object)
            guard let code = ReferralControlErrorCode(rawValue: codeRaw) else {
                throw ControlSocketError.invalidEnumValue(field: "code", value: codeRaw)
            }
            let retryAfter = optionalIntField("retry_after_seconds", in: object)
            if let retryAfter, !(0...86_400).contains(retryAfter) {
                throw ControlSocketError.invalidEnumValue(
                    field: "retry_after_seconds",
                    value: String(retryAfter)
                )
            }
            return .referralError(
                operation: operation,
                code: code,
                retryAfterSeconds: retryAfter
            )
        case "kv_cache_purge_request":
            return .kvCachePurgeRequest(mode: try stringField("mode", in: object), key: object["key"] as? String)
        case "kv_cache_purge_response":
            return .kvCachePurgeResponse(
                status: try stringField("status", in: object),
                entriesRemoved: try intField("entries_removed", in: object),
                bytesFreed: try intField("bytes_freed", in: object),
                detail: object["detail"] as? String)
        case "kv_cache_status_request":
            return .kvCacheStatusRequest
        case "kv_cache_status_response":
            return .kvCacheStatusResponse(payloadJSON: try stringField("payload_json", in: object))
        default:
            throw ControlSocketError.unknownType(type)
        }
    }

    private static func object<T: Encodable>(encoding value: T, adding fields: [String: Any]) throws -> [String: Any] {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            throw ControlSocketError.missingType
        }
        for (key, value) in fields { object[key] = value }
        return object
    }

    private static func decode<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: raw))
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from object: [String: Any],
        removing key: String
    ) throws -> T {
        var value = object
        value.removeValue(forKey: key)
        return try decode(type, from: value)
    }

    private static func doubleField(_ field: String, in object: [String: Any]) throws -> Double {
        if let value = object[field] as? Double { return value }
        if let value = object[field] as? NSNumber { return value.doubleValue }
        throw ControlSocketError.missingRequiredField(field)
    }

    private static func optionalDoubleField(_ field: String, in object: [String: Any]) -> Double? {
        if let value = object[field] as? Double { return value }
        if let value = object[field] as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func decodeProviderEarnings(in object: [String: Any]) throws -> ProviderEarningsSummary? {
        guard let raw = object["provider_earnings"] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(ProviderEarningsSummary.self, from: data)
    }

    private static func optionalIntField(_ field: String, in object: [String: Any]) -> Int? {
        if let value = object[field] as? Int { return value }
        if let value = object[field] as? NSNumber { return value.intValue }
        return nil
    }

    private static func optionalInt64Field(_ field: String, in object: [String: Any]) -> Int64? {
        if let value = object[field] as? Int64 { return value }
        if let value = object[field] as? Int { return Int64(value) }
        if let value = object[field] as? NSNumber { return value.int64Value }
        return nil
    }

    private static func stringField(_ field: String, in object: [String: Any]) throws -> String {
        guard let value = object[field] as? String else {
            throw ControlSocketError.missingRequiredField(field)
        }
        return value
    }

    private static func boolField(_ field: String, in object: [String: Any]) throws -> Bool {
        guard let value = object[field] as? Bool else {
            throw ControlSocketError.missingRequiredField(field)
        }
        return value
    }

    private static func intField(_ field: String, in object: [String: Any]) throws -> Int {
        if let value = object[field] as? Int {
            return value
        }
        if let value = object[field] as? NSNumber {
            return value.intValue
        }
        throw ControlSocketError.missingRequiredField(field)
    }

    private static func int64Field(_ field: String, in object: [String: Any]) throws -> Int64 {
        if let value = object[field] as? Int64 {
            return value
        }
        if let value = object[field] as? Int {
            return Int64(value)
        }
        if let value = object[field] as? NSNumber {
            return value.int64Value
        }
        throw ControlSocketError.missingRequiredField(field)
    }
}

public enum ControlSocketError: Error, Equatable {
    case missingType
    case unknownType(String)
    case missingRequiredField(String)
    case invalidEnumValue(field: String, value: String)
}

public enum ControlSocketPaths {
    public static func resolve(ctlSocketPath: String?) -> URL {
        if let ctlSocketPath, !ctlSocketPath.isEmpty {
            return URL(fileURLWithPath: (ctlSocketPath as NSString).expandingTildeInPath)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-cli")
            .appendingPathComponent("ctl.sock")
    }

    public static func defaultSwitchStatePath(_ switchStatePath: String?) -> URL {
        if let switchStatePath, !switchStatePath.isEmpty {
            return URL(fileURLWithPath: (switchStatePath as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider-cli/last-switch.ts")
    }
}

struct ControlSocketFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let mode: mode_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        owner = info.st_uid
        mode = info.st_mode
    }
}

enum ControlSocketStaleSocketOutcome: Equatable {
    /// No live listener was found at the path; the orphaned inode was
    /// safely quarantined and unlinked (or was already gone). Safe to bind.
    case reclaimed
    /// A live peer accepted a connection attempt on the path. Must stay
    /// fail-closed; some other serve process currently owns this socket.
    case live
    /// The path could not be verified as our own control socket (wrong
    /// owner/type/mode, unsafe parent directory, or an ambiguous connect
    /// failure). Never reclaimed; caller must stay fail-closed.
    case unverified
}

/// Reclaims a control socket path left behind by a serve process that died
/// without running its watchdog exit cleanup (e.g. SIGKILL, launchd
/// KeepAlive restart racing a crash). Applies the same identity-verification
/// and atomic quarantine-then-unlink discipline as
/// `ControlSocketWatchdogCleanup` so an unknown or live path is never
/// touched — this only clears sockets we can prove are both ours and dead.
enum ControlSocketStaleSocketReclaimer {
    static func reclaimIfOrphaned(socketPath: URL) -> ControlSocketStaleSocketOutcome {
        let parentPath = socketPath.deletingLastPathComponent().path
        let socketName = socketPath.lastPathComponent

        let parentFD = Darwin.open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else {
            log("could not open control socket directory", error: errno)
            return .unverified
        }
        defer { Darwin.close(parentFD) }

        var parentInfo = stat()
        guard Darwin.fstat(parentFD, &parentInfo) == 0,
              parentInfo.st_uid == geteuid(),
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              (parentInfo.st_mode & 0o777) == 0o700
        else {
            log("refused unverified control socket directory")
            return .unverified
        }

        var socketInfo = stat()
        guard Darwin.fstatat(parentFD, socketName, &socketInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            let error = errno
            if error == ENOENT { return .reclaimed }
            log("could not inspect control socket", error: error)
            return .unverified
        }
        guard socketInfo.st_uid == geteuid(),
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              (socketInfo.st_mode & 0o777) == 0o600
        else {
            log("refused unverified control socket")
            return .unverified
        }

        switch probeLiveness(socketPath: socketPath.path) {
        case .live:
            return .live
        case .unknown:
            return .unverified
        case .orphaned:
            break
        }

        let expectedIdentity = ControlSocketFileIdentity(socketInfo)
        return quarantineAndUnlink(
            parentFD: parentFD,
            socketName: socketName,
            expectedIdentity: expectedIdentity
        ) ? .reclaimed : .unverified
    }

    /// Test-only seam exercising the exact quarantine-then-unlink step used
    /// by `reclaimIfOrphaned`, so tests can assert the race-safety guarantee
    /// (a mismatched identity — i.e. someone else's live replacement won the
    /// race — is preserved untouched) without depending on real thread
    /// timing.
    static func quarantineAndUnlinkForTest(
        parentFD: Int32,
        socketName: String,
        expectedIdentity: ControlSocketFileIdentity
    ) -> Bool {
        quarantineAndUnlink(parentFD: parentFD, socketName: socketName, expectedIdentity: expectedIdentity)
    }

    private enum LivenessProbe {
        case live
        case orphaned
        case unknown
    }

    private static func probeLiveness(socketPath: String) -> LivenessProbe {
        guard let address = try? unixAddress(path: socketPath) else { return .unknown }
        var raw = address.sockaddr
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unknown }
        defer { Darwin.close(fd) }
        let result = withUnsafePointer(to: &raw) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, address.length)
            }
        }
        if result == 0 { return .live }
        switch errno {
        case ECONNREFUSED, ENOTSOCK, EPROTOTYPE, ENOENT:
            return .orphaned
        default:
            return .unknown
        }
    }

    private static func quarantineAndUnlink(
        parentFD: Int32,
        socketName: String,
        expectedIdentity: ControlSocketFileIdentity
    ) -> Bool {
        let quarantineName = ".\(socketName).stale-reclaim-\(getpid())-\(UUID().uuidString.lowercased())"
        guard Darwin.renameatx_np(
            parentFD, socketName,
            parentFD, quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            let error = errno
            if error == ENOENT { return true }
            log("could not quarantine control socket", error: error)
            return false
        }

        var quarantinedInfo = stat()
        guard Darwin.fstatat(parentFD, quarantineName, &quarantinedInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            let error = errno
            if Darwin.renameatx_np(
                parentFD, quarantineName,
                parentFD, socketName,
                UInt32(RENAME_EXCL)
            ) != 0 {
                log("preserved mismatched control socket as \(quarantineName)", error: errno)
            } else {
                log("could not inspect quarantined control socket", error: error)
            }
            return false
        }
        guard ControlSocketFileIdentity(quarantinedInfo) == expectedIdentity else {
            if Darwin.renameatx_np(
                parentFD, quarantineName,
                parentFD, socketName,
                UInt32(RENAME_EXCL)
            ) != 0 {
                log("preserved mismatched control socket as \(quarantineName)", error: errno)
            } else {
                log("refused replacement control socket cleanup")
            }
            return false
        }

        guard Darwin.unlinkat(parentFD, quarantineName, 0) == 0 else {
            let error = errno
            if error == ENOENT { return true }
            log("could not remove quarantined control socket", error: error)
            return false
        }
        return true
    }

    private static func log(_ message: String, error: Int32? = nil) {
        let detail = error.map { ": \(String(cString: strerror($0)))" } ?? ""
        FileHandle.standardError.write(Data("control socket stale reclaim \(message)\(detail)\n".utf8))
    }
}

// Fatal watchdog exits cannot await actor/defer cleanup. This object is armed
// only after the server has bound and listened, and records that exact socket
// identity through a pinned 0700 parent-directory descriptor. Exit cleanup
// atomically quarantines the pathname before verifying and unlinking it, so a
// same-user replacement cannot win an lstat-to-unlink race. Ordinary startup
// remains fail-closed and never reclaims unknown paths.
final class ControlSocketWatchdogCleanup: @unchecked Sendable {
    private let socketPath: URL
    private let socketName: String
    private let lock = NSLock()
    private var parentFD: Int32?
    private var expectedIdentity: ControlSocketFileIdentity?

    init(socketPath: URL) {
        self.socketPath = socketPath
        self.socketName = socketPath.lastPathComponent
    }

    deinit {
        disarm()
    }

    @discardableResult
    func arm() -> Bool {
        let parentPath = socketPath.deletingLastPathComponent().path
        let fd = Darwin.open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            log("could not open control socket directory", error: errno)
            return false
        }

        var parentInfo = stat()
        guard Darwin.fstat(fd, &parentInfo) == 0 else {
            let error = errno
            Darwin.close(fd)
            log("could not inspect control socket directory", error: error)
            return false
        }
        guard parentInfo.st_uid == geteuid(),
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              (parentInfo.st_mode & 0o777) == 0o700
        else {
            Darwin.close(fd)
            log("refused unverified control socket directory")
            return false
        }

        var socketInfo = stat()
        guard Darwin.fstatat(fd, socketName, &socketInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            let error = errno
            Darwin.close(fd)
            log("could not inspect control socket", error: error)
            return false
        }
        guard socketInfo.st_uid == geteuid(),
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              (socketInfo.st_mode & 0o777) == 0o600
        else {
            Darwin.close(fd)
            log("refused unverified control socket")
            return false
        }

        lock.lock()
        let oldFD = parentFD
        parentFD = fd
        expectedIdentity = ControlSocketFileIdentity(socketInfo)
        lock.unlock()
        if let oldFD { Darwin.close(oldFD) }
        return true
    }

    func disarm() {
        lock.lock()
        let fd = parentFD
        parentFD = nil
        expectedIdentity = nil
        lock.unlock()
        if let fd { Darwin.close(fd) }
    }

    @discardableResult
    func prepareForWatchdogExit() -> Bool {
        lock.lock()
        let fd = parentFD
        let expected = expectedIdentity
        parentFD = nil
        expectedIdentity = nil
        lock.unlock()

        guard let fd, let expected else {
            log("refused unarmed control socket cleanup")
            return false
        }
        defer { Darwin.close(fd) }

        let quarantineName = ".\(socketName).watchdog-\(getpid())-\(UUID().uuidString.lowercased())"
        guard Darwin.renameatx_np(
            fd, socketName,
            fd, quarantineName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            let error = errno
            if error == ENOENT { return true }
            log("could not quarantine control socket", error: error)
            return false
        }

        var quarantinedInfo = stat()
        guard Darwin.fstatat(fd, quarantineName, &quarantinedInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            let error = errno
            if Darwin.renameatx_np(
                fd, quarantineName,
                fd, socketName,
                UInt32(RENAME_EXCL)
            ) != 0 {
                log("preserved mismatched control socket as \(quarantineName)", error: errno)
            } else {
                log("could not inspect quarantined control socket", error: error)
            }
            return false
        }
        guard ControlSocketFileIdentity(quarantinedInfo) == expected else {
            if Darwin.renameatx_np(
                fd, quarantineName,
                fd, socketName,
                UInt32(RENAME_EXCL)
            ) != 0 {
                log("preserved mismatched control socket as \(quarantineName)", error: errno)
            } else {
                log("refused replacement control socket cleanup")
            }
            return false
        }

        guard Darwin.unlinkat(fd, quarantineName, 0) == 0 else {
            let error = errno
            if error == ENOENT { return true }
            log("could not remove quarantined control socket", error: error)
            return false
        }
        return true
    }

    private func log(_ message: String, error: Int32? = nil) {
        let detail = error.map { ": \(String(cString: strerror($0)))" } ?? ""
        FileHandle.standardError.write(Data("watchdog cleanup \(message)\(detail)\n".utf8))
    }
}

public enum ControlSocketConnectError: Error, Equatable {
    case socketAbsent(path: String)
    case connectionRefused(path: String)
    case handshakeTimeout(path: String)
    case other(underlying: String)
}

public enum ControlSocketServerError: Error, CustomStringConvertible, Equatable {
    case staleSocket(path: String)
    case bindFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)
    case socketFailed(errno: Int32)
    case watchdogCleanupFailed(path: String)

    public var description: String {
        switch self {
        case let .staleSocket(path):
            return "control socket \(path) already exists; remove the stale file and restart serve"
        case let .bindFailed(path, errno):
            return "control socket \(path) bind failed: \(String(cString: strerror(errno)))"
        case let .listenFailed(errno):
            return "control socket listen failed: \(String(cString: strerror(errno)))"
        case let .socketFailed(errno):
            return "control socket creation failed: \(String(cString: strerror(errno)))"
        case let .watchdogCleanupFailed(path):
            return "control socket \(path) could not arm restart cleanup"
        }
    }
}

public enum ControlSocketConnectionError: Error, Equatable {
    case closed
    case timedOut
    case frameTooLarge(size: Int)
}

actor ControlSocketServer {
    private let socketPath: URL
    private let modelRuntime: ModelRuntime
    private let supportedModels: [String]?
    private let receiptRotator: (@Sendable () async throws -> Void)?
    private let receiptRotationProviderID: String?
    private let idleTimeoutSeconds: TimeInterval
    private let providerStatus: ProviderStatus?
    private let providerEarningsClient: ProviderEarningsClient?
    private let referralCoordinatorService: ReferralCoordinatorService?
    private let malibuAccrualClient: MalibuAccrualClient?
    private let providerToken: String?
    private let pauseProvider: (@Sendable () async -> ProviderControlCommandResult)?
    private let resumeProvider: (@Sendable () async -> ProviderControlCommandResult)?
    private let watchdogCleanup: ControlSocketWatchdogCleanup?
    /// SPEC-037 stage 5 — the serve-owned, lock-holding disk tier. When present,
    /// kv-cache purge/status frames are executed in-process (no lock
    /// re-acquisition); nil ⇒ the tier is disabled and the standalone CLI path
    /// acquires the free lock instead.
    private let kvDiskTier: KVDiskTier?
    private let tracker = ControlSocketSwitchTracker()
    private var listenerFD: Int32?
    private var acceptTask: Task<Void, Never>?
    private var clientTasks: [UUID: Task<Void, Never>] = [:]
    private var clientFDs: [Int32] = []

    init(
        socketPath: URL,
        modelRuntime: ModelRuntime,
        supportedModels: [String]? = nil,
        receiptRotator: (@Sendable () async throws -> Void)? = nil,
        receiptRotationProviderID: String? = nil,
        idleTimeoutSeconds: TimeInterval = 30.0,
        providerStatus: ProviderStatus? = nil,
        providerEarningsClient: ProviderEarningsClient? = nil,
        referralCoordinatorService: ReferralCoordinatorService? = nil,
        malibuAccrualClient: MalibuAccrualClient? = nil,
        providerToken: String? = nil,
        pauseProvider: (@Sendable () async -> ProviderControlCommandResult)? = nil,
        resumeProvider: (@Sendable () async -> ProviderControlCommandResult)? = nil,
        watchdogCleanup: ControlSocketWatchdogCleanup? = nil,
        kvDiskTier: KVDiskTier? = nil
    ) {
        self.socketPath = socketPath
        self.modelRuntime = modelRuntime
        self.supportedModels = supportedModels
        self.receiptRotator = receiptRotator
        self.receiptRotationProviderID = receiptRotationProviderID
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.providerStatus = providerStatus
        self.providerEarningsClient = providerEarningsClient
        self.referralCoordinatorService = referralCoordinatorService
        self.malibuAccrualClient = malibuAccrualClient
        self.providerToken = providerToken
        self.pauseProvider = pauseProvider
        self.resumeProvider = resumeProvider
        self.watchdogCleanup = watchdogCleanup
        self.kvDiskTier = kvDiskTier
    }

    func start() async throws {
        let parent = socketPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        chmod(parent.path, S_IRWXU)

        if FileManager.default.fileExists(atPath: socketPath.path) {
            // launchd KeepAlive restarts a serve process whose predecessor
            // may have died (SIGKILL, OOM, power loss) before its watchdog
            // exit cleanup ran, leaving an orphaned control socket file with
            // no listener. Reclaim only when we can prove the path is both
            // ours and dead; otherwise stay fail-closed exactly as before.
            let outcome = ControlSocketStaleSocketReclaimer.reclaimIfOrphaned(socketPath: socketPath)
            if outcome != .reclaimed {
                let error = ControlSocketServerError.staleSocket(path: socketPath.path)
                FileHandle.standardError.write(Data(("\(error.description)\n").utf8))
                throw error
            }
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketServerError.socketFailed(errno: errno)
        }

        do {
            try bindUnixSocket(fd: fd, path: socketPath.path)
        } catch let error as ControlSocketServerError {
            close(fd)
            if case let .bindFailed(_, err) = error, err == EADDRINUSE {
                let stale = ControlSocketServerError.staleSocket(path: socketPath.path)
                FileHandle.standardError.write(Data(("\(stale.description)\n").utf8))
                throw stale
            }
            throw error
        }

        chmod(socketPath.path, S_IRUSR | S_IWUSR)
        guard Darwin.listen(fd, 128) == 0 else {
            let err = errno
            close(fd)
            try? FileManager.default.removeItem(at: socketPath)
            throw ControlSocketServerError.listenFailed(errno: err)
        }

        guard watchdogCleanup?.arm() ?? true else {
            close(fd)
            throw ControlSocketServerError.watchdogCleanupFailed(path: socketPath.path)
        }

        listenerFD = fd
        let runtime = modelRuntime
        let tracker = tracker
        let supportedModels = supportedModels
        let receiptRotator = receiptRotator
        let receiptRotationProviderID = receiptRotationProviderID
        let idleTimeoutSeconds = idleTimeoutSeconds
        let providerStatus = providerStatus
        let providerEarningsClient = providerEarningsClient
        let referralCoordinatorService = referralCoordinatorService
        let malibuAccrualClient = malibuAccrualClient
        let providerToken = providerToken
        let pauseProvider = pauseProvider
        let resumeProvider = resumeProvider
        acceptTask = Task.detached(priority: .userInitiated) {
            await Self.acceptLoop(
                listenerFD: fd,
                modelRuntime: runtime,
                tracker: tracker,
                supportedModels: supportedModels,
                receiptRotator: receiptRotator,
                receiptRotationProviderID: receiptRotationProviderID,
                idleTimeoutSeconds: idleTimeoutSeconds,
                providerStatus: providerStatus,
                providerEarningsClient: providerEarningsClient,
                referralCoordinatorService: referralCoordinatorService,
                malibuAccrualClient: malibuAccrualClient,
                providerToken: providerToken,
                pauseProvider: pauseProvider,
                resumeProvider: resumeProvider,
                kvDiskTier: self.kvDiskTier,
                server: self
            )
        }
    }

    func stop() async {
        watchdogCleanup?.disarm()
        acceptTask?.cancel()
        acceptTask = nil
        for task in clientTasks.values {
            task.cancel()
        }
        clientTasks.removeAll()
        for fd in clientFDs {
            close(fd)
        }
        clientFDs.removeAll()
        if let listenerFD {
            close(listenerFD)
            self.listenerFD = nil
        }
        try? FileManager.default.removeItem(at: socketPath)
        await tracker.clear()
    }

    func clientTasksCountForTest() -> Int {
        clientTasks.count
    }

    private func appendClientTask(id: UUID, task: Task<Void, Never>) {
        clientTasks[id] = task
    }

    private func removeClientTask(_ id: UUID) {
        clientTasks.removeValue(forKey: id)
    }

    private func appendClientFD(_ fd: Int32) {
        clientFDs.append(fd)
    }

    private func removeClientFD(_ fd: Int32) {
        clientFDs.removeAll { $0 == fd }
    }

    private nonisolated static func acceptLoop(
        listenerFD: Int32,
        modelRuntime: ModelRuntime,
        tracker: ControlSocketSwitchTracker,
        supportedModels: [String]?,
        receiptRotator: (@Sendable () async throws -> Void)?,
        receiptRotationProviderID: String?,
        idleTimeoutSeconds: TimeInterval,
        providerStatus: ProviderStatus?,
        providerEarningsClient: ProviderEarningsClient?,
        referralCoordinatorService: ReferralCoordinatorService?,
        malibuAccrualClient: MalibuAccrualClient?,
        providerToken: String?,
        pauseProvider: (@Sendable () async -> ProviderControlCommandResult)?,
        resumeProvider: (@Sendable () async -> ProviderControlCommandResult)?,
        kvDiskTier: KVDiskTier?,
        server: ControlSocketServer
    ) async {
        while !Task.isCancelled {
            let clientFD = Darwin.accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            if !Self.peerHasSameEUID(fd: clientFD) {
                close(clientFD)
                continue
            }
            await server.appendClientFD(clientFD)
            let taskID = UUID()
            let task = Task.detached(priority: .userInitiated) { [server] in
                defer {
                    Task { await server.removeClientTask(taskID) }
                }
                await handleClient(
                    fd: clientFD,
                    modelRuntime: modelRuntime,
                    tracker: tracker,
                    supportedModels: supportedModels,
                    receiptRotator: receiptRotator,
                    receiptRotationProviderID: receiptRotationProviderID,
                    idleTimeoutSeconds: idleTimeoutSeconds,
                    providerStatus: providerStatus,
                    providerEarningsClient: providerEarningsClient,
                    referralCoordinatorService: referralCoordinatorService,
                    malibuAccrualClient: malibuAccrualClient,
                    providerToken: providerToken,
                    pauseProvider: pauseProvider,
                    resumeProvider: resumeProvider,
                    kvDiskTier: kvDiskTier
                )
                await server.removeClientFD(clientFD)
            }
            await server.appendClientTask(id: taskID, task: task)
        }
    }

    private nonisolated static func handleClient(
        fd: Int32,
        modelRuntime: ModelRuntime,
        tracker: ControlSocketSwitchTracker,
        supportedModels: [String]?,
        receiptRotator: (@Sendable () async throws -> Void)?,
        receiptRotationProviderID: String?,
        idleTimeoutSeconds: TimeInterval,
        providerStatus: ProviderStatus? = nil,
        providerEarningsClient: ProviderEarningsClient? = nil,
        referralCoordinatorService: ReferralCoordinatorService? = nil,
        malibuAccrualClient: MalibuAccrualClient? = nil,
        providerToken: String? = nil,
        pauseProvider: (@Sendable () async -> ProviderControlCommandResult)? = nil,
        resumeProvider: (@Sendable () async -> ProviderControlCommandResult)? = nil,
        kvDiskTier: KVDiskTier? = nil
    ) async {
        let connection = ControlSocketConnection(fd: fd)

        while !Task.isCancelled {
            do {
                let frame = try await connection.receive(timeout: idleTimeoutSeconds)
                switch frame {
                case .statusRequest:
                    let snapshot = await modelRuntime.currentSnapshot()
                    let state = snapshot.state == .failed ? SwapState.ready : snapshot.state
                    try await connection.send(.statusResponse(currentModelID: snapshot.modelID ?? "", runtimeState: state))
                case let .rotateReceiptKeyRequest(providerID):
                    await handleReceiptKeyRotationRequest(
                        providerID: providerID,
                        connection: connection,
                        receiptRotator: receiptRotator,
                        receiptRotationProviderID: receiptRotationProviderID
                    )
                    await connection.close()
                    return
                case let .switchRequest(targetModelID, requestedAtMs):
                    await handleSwitchRequest(
                        targetModelID: targetModelID,
                        requestedAtMs: requestedAtMs,
                        connection: connection,
                        modelRuntime: modelRuntime,
                        tracker: tracker,
                        supportedModels: supportedModels
                    )
                    await connection.close()
                    return
                case .metricsRequest:
                    let snapshot = await ControlMetricsBuilder.build(
                        providerStatus: providerStatus,
                        providerEarningsClient: providerEarningsClient,
                        malibuAccrualClient: malibuAccrualClient,
                        providerToken: providerToken
                    )
                    try? await connection.send(.metricsResponse(snapshot))
                case .pauseRequest:
                    let result = await pauseProvider?()
                        ?? .rejected("lifecycle_control_unavailable")
                    try? await connection.send(.pauseAck(accepted: result.accepted, reason: result.reason))
                case .resumeRequest:
                    let result = await resumeProvider?()
                        ?? .rejected("lifecycle_control_unavailable")
                    try? await connection.send(.resumeAck(accepted: result.accepted, reason: result.reason))
                case let .shutdownRequest(graceSeconds):
                    // This frame is retained for the temporary App-spawned
                    // bootstrap child during launchd handoff. Ack immediately;
                    // the spawning wrapper owns bounded process termination.
                    // Ordinary Malibu quit never sends this to the standalone
                    // launchd provider under the Issue 585 Option-2 contract.
                    try? await connection.send(.shutdownAck)
                    _ = graceSeconds
                case .referralStatusRequest:
                    await handleReferralRequest(
                        operation: .status,
                        service: referralCoordinatorService,
                        connection: connection
                    ) { service in
                        .referralStatusResponse(try await service.status())
                    }
                case .referralChallengeRequest:
                    await handleReferralRequest(
                        operation: .challenge,
                        service: referralCoordinatorService,
                        connection: connection
                    ) { service in
                        let pending = try await service.challenge()
                        return .referralChallengeResponse(expiresAt: pending.expiresAt)
                    }
                case .referralChallengeReopenRequest:
                    await handleReferralRequest(
                        operation: .challenge,
                        service: referralCoordinatorService,
                        connection: connection
                    ) { service in
                        let pending = try await service.reopenChallenge()
                        return .referralChallengeReopenAck(expiresAt: pending.expiresAt)
                    }
                case let .referralVerifyRequest(postURL):
                    await handleReferralRequest(
                        operation: .verify,
                        service: referralCoordinatorService,
                        connection: connection
                    ) { service in
                        .referralStatusResponse(try await service.verify(postURL: postURL))
                    }
                case .referralChallengeCancelRequest:
                    await handleReferralRequest(
                        operation: .cancel,
                        service: referralCoordinatorService,
                        connection: connection
                    ) { service in
                        .referralChallengeCancelAck(status: try await service.cancel())
                    }
                case let .kvCachePurgeRequest(mode, key):
                    await handleKVCachePurge(mode: mode, key: key, tier: kvDiskTier, modelRuntime: modelRuntime, connection: connection)
                    await connection.close()
                    return
                case .kvCacheStatusRequest:
                    await handleKVCacheStatus(tier: kvDiskTier, modelRuntime: modelRuntime, connection: connection)
                    await connection.close()
                    return
                default:
                    FileHandle.standardError.write(Data("control socket received unexpected frame type; closing connection\n".utf8))
                    await connection.close()
                    return
                }
            } catch let error as ControlSocketError {
                FileHandle.standardError.write(Data("control socket decode error: \(error); closing connection\n".utf8))
                await connection.close()
                return
            } catch ControlSocketConnectionError.closed {
                await connection.close()
                return
            } catch ControlSocketConnectError.other(let underlying) where Task.isCancelled && underlying == "Bad file descriptor" {
                await connection.close()
                return
            } catch {
                FileHandle.standardError.write(Data("control socket error: \(error); closing connection\n".utf8))
                await connection.close()
                return
            }
        }
        await connection.close()
    }

    /// SPEC-037 stage 5 (FR-KVP8) — execute a kv-cache purge in the lock-holding
    /// serve process. When the disk tier is DISABLED here (`tier == nil`), the serve
    /// process still owns its RAM `ConversationCache`, so purge must remain functional
    /// (FR-KVP8): clear the matching hot-tier residency — so we never keep serving a
    /// purged prefix from RAM until TTL — and report what was removed. The disk
    /// component is absent in this process (a standalone CLI handles disk purge when
    /// no serve holds the namespace lock); this path never reports a hot purge it did
    /// not perform.
    private nonisolated static func handleKVCachePurge(
        mode: String, key: String?, tier: KVDiskTier?, modelRuntime: ModelRuntime, connection: ControlSocketConnection
    ) async {
        guard let tier else {
            let entriesRemoved: Int
            switch mode {
            case "all", "all_forget":
                // Report the hot residency actually cleared.
                let before = await modelRuntime.hotConversationStats().entries
                await modelRuntime.purgeAllHotConversations()
                entriesRemoved = before
            default:
                let hadHot = await modelRuntime.purgeHotConversation(conversationKey: key ?? "")
                entriesRemoved = hadHot ? 1 : 0
            }
            try? await connection.send(.kvCachePurgeResponse(
                status: "purge_ok", entriesRemoved: entriesRemoved, bytesFreed: 0, detail: "disk_tier_disabled"))
            return
        }
        // Enabled: the tier's purge path already clears the wired hot-tier residency
        // (setHotPurgeHooks) in addition to disk — unchanged behavior.
        let result: KVPurgeResult
        switch mode {
        case "all": result = await tier.purgeAll()
        case "all_forget": result = await tier.purgeAllAndForget()
        default: result = await tier.purge(rawKey: key ?? "")
        }
        switch result {
        case let .ok(entriesRemoved, bytesFreed):
            try? await connection.send(.kvCachePurgeResponse(
                status: "purge_ok", entriesRemoved: entriesRemoved, bytesFreed: bytesFreed, detail: nil))
        case let .failed(detail):
            try? await connection.send(.kvCachePurgeResponse(
                status: "purge_failed", entriesRemoved: 0, bytesFreed: 0, detail: detail.rawValue))
        }
    }

    /// SPEC-037 stage 5 (FR-KVP12) — report the inspection surface from the
    /// lock-holding serve process (JSON payload identical to the CLI shape). When the
    /// disk tier is DISABLED here (`tier == nil`), still report the serve-owned RAM
    /// (hot) residency with `enabled=false` so status remains functional while
    /// disabled (FR-KVP8).
    private nonisolated static func handleKVCacheStatus(
        tier: KVDiskTier?, modelRuntime: ModelRuntime, connection: ControlSocketConnection
    ) async {
        guard let tier else {
            let stats = await modelRuntime.hotConversationStats()
            let object: [String: Any] = [
                "status": "ok",
                "enabled": false,
                "hot_entries": stats.entries,
                "hot_tokens": stats.tokens,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            try? await connection.send(.kvCacheStatusResponse(payloadJSON: String(decoding: data, as: UTF8.self)))
            return
        }
        guard let inspection = await tier.status() else {
            try? await connection.send(.kvCacheStatusResponse(payloadJSON: "{\"status\":\"unavailable\"}"))
            return
        }
        let object: [String: Any] = [
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
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        try? await connection.send(.kvCacheStatusResponse(payloadJSON: String(decoding: data, as: UTF8.self)))
    }

    private nonisolated static func handleReferralRequest(
        operation: ReferralControlOperation,
        service: ReferralCoordinatorService?,
        connection: ControlSocketConnection,
        action: @Sendable (ReferralCoordinatorService) async throws -> ControlSocketFrame
    ) async {
        guard let service else {
            try? await connection.send(.referralError(
                operation: operation,
                code: .featureUnavailable,
                retryAfterSeconds: nil
            ))
            return
        }
        do {
            try await connection.send(try await action(service))
        } catch let error as ReferralCoordinatorClientError {
            let code: ReferralControlErrorCode
            let retryAfter: Int?
            switch error {
            case .invalidCoordinatorURL:
                code = .featureUnavailable
                retryAfter = nil
            case let .control(errorCode, retryAfterSeconds, _):
                code = errorCode
                retryAfter = retryAfterSeconds
            }
            try? await connection.send(.referralError(
                operation: operation,
                code: code,
                retryAfterSeconds: retryAfter
            ))
        } catch {
            try? await connection.send(.referralError(
                operation: operation,
                code: .temporarilyUnavailable,
                retryAfterSeconds: nil
            ))
        }
    }


    private nonisolated static func handleReceiptKeyRotationRequest(
        providerID: String,
        connection: ControlSocketConnection,
        receiptRotator: (@Sendable () async throws -> Void)?,
        receiptRotationProviderID: String?
    ) async {
        guard let receiptRotator else {
            try? await connection.send(.rotateReceiptKeyResult(status: .rejected, error: "receipt rotation is not enabled in this serve process"))
            return
        }
        if let receiptRotationProviderID, receiptRotationProviderID != providerID {
            try? await connection.send(.rotateReceiptKeyResult(status: .rejected, error: "receipt rotation provider_id mismatch"))
            return
        }
        do {
            try await receiptRotator()
            try await connection.send(.rotateReceiptKeyResult(status: .accepted, error: nil))
        } catch let error as CoordinatorReceiptRotationCommittedRecoveryFailed {
            try? await connection.send(.rotateReceiptKeyResult(status: .committedUnconfirmed, error: String(describing: error)))
        } catch {
            try? await connection.send(.rotateReceiptKeyResult(status: .rejected, error: String(describing: error)))
        }
    }

    private nonisolated static func handleSwitchRequest(
        targetModelID: String,
        requestedAtMs: Int64,
        connection: ControlSocketConnection,
        modelRuntime: ModelRuntime,
        tracker: ControlSocketSwitchTracker,
        supportedModels: [String]?
    ) async {
        do {
            do {
                _ = try SupportedModels.validate(model: targetModelID, supportedModels: supportedModels)
            } catch SupportedModelsValidationError.modelNotInCatalog {
                try? await connection.send(.switchAck(
                    accepted: false,
                    reason: .notInSupportedModels,
                    currentTarget: nil,
                    secondsRemaining: nil
                ))
                await connection.close()
                return
            } catch {
                try? await connection.send(.switchAck(accepted: false, reason: .other, currentTarget: nil, secondsRemaining: nil))
                await connection.close()
                return
            }

            let stream = await modelRuntime.swapSignals()
            _ = try await modelRuntime.beginSwap(targetModelID: targetModelID)
            await tracker.start(targetModelID)
            try await connection.send(.switchAck(accepted: true, reason: nil, currentTarget: nil, secondsRemaining: nil))
            try await connection.send(.switchProgress(state: .loading, elapsedMs: elapsedMs(since: requestedAtMs), reason: nil))

            var iterator = stream.makeAsyncIterator()
            while let signal = await iterator.next() {
                guard signal.targetModelID == targetModelID else {
                    continue
                }
                switch signal.outcome {
                case .loadFinished:
                    try await connection.send(.switchProgress(state: .draining, elapsedMs: elapsedMs(since: requestedAtMs), reason: nil))
                    continue
                case .completed:
                    try await connection.send(.switchProgress(state: .loaded, elapsedMs: elapsedMs(since: requestedAtMs), reason: nil))
                case let .failed(reason):
                    try await connection.send(.switchProgress(state: .failed, elapsedMs: elapsedMs(since: requestedAtMs), reason: reason))
                }
                await tracker.clear()
                return
            }
        } catch RuntimeStateMachineError.notReady {
            let currentTarget = await tracker.currentTarget() ?? targetModelID
            try? await connection.send(.switchAck(
                accepted: false,
                reason: .loadingInProgress,
                currentTarget: currentTarget,
                secondsRemaining: nil
            ))
        } catch is WarmSwapDisabledError {
            try? await connection.send(.switchAck(accepted: false, reason: .other, currentTarget: nil, secondsRemaining: nil))
        } catch {
            try? await connection.send(.switchAck(accepted: false, reason: .other, currentTarget: nil, secondsRemaining: nil))
        }
    }

    private nonisolated static func elapsedMs(since requestedAtMs: Int64) -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return max(0, Int(now - requestedAtMs))
    }

    private nonisolated static func peerHasSameEUID(fd: Int32) -> Bool {
        var euid = uid_t(0)
        var egid = gid_t(0)
        guard getpeereid(fd, &euid, &egid) == 0 else {
            return false
        }
        return euid == geteuid()
    }
}

private actor ControlSocketSwitchTracker {
    private var targetModelID: String?

    func start(_ targetModelID: String) {
        self.targetModelID = targetModelID
    }

    func currentTarget() -> String? {
        targetModelID
    }

    func clear() {
        targetModelID = nil
    }
}

public enum ControlSocketClient {
    public static func connect(socketPath: URL, timeout _: TimeInterval = 2.0) async throws -> ControlSocketConnection {
        let path = socketPath.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ControlSocketConnectError.socketAbsent(path: path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketConnectError.other(underlying: String(cString: strerror(errno)))
        }

        do {
            try connectUnixSocket(fd: fd, path: path)
            return ControlSocketConnection(fd: fd)
        } catch {
            let err = errno
            close(fd)
            if err == ECONNREFUSED || err == ENOTSOCK || err == EPROTOTYPE {
                throw ControlSocketConnectError.connectionRefused(path: path)
            }
            throw ControlSocketConnectError.other(underlying: String(cString: strerror(err)))
        }
    }
}

public actor ControlSocketConnection {
    public static let maxFrameBytes = 64 * 1024

    private var fd: Int32?
    private var receiveBuffer = Data()

    init(fd: Int32) {
        self.fd = fd
    }

    public func send(_ frame: ControlSocketFrame) async throws {
        let data = try ControlSocketCodec.encode(frame)
        try writeAll(data)
    }

    public func receive(timeout: TimeInterval? = nil) async throws -> ControlSocketFrame {
        while true {
            if let newline = receiveBuffer.firstIndex(of: 0x0A) {
                let frameSize = receiveBuffer.distance(from: receiveBuffer.startIndex, to: newline) + 1
                if frameSize > Self.maxFrameBytes {
                    throw ControlSocketConnectionError.frameTooLarge(size: frameSize)
                }
                let line = receiveBuffer.prefix(through: newline)
                receiveBuffer.removeSubrange(...newline)
                return try ControlSocketCodec.decode(Data(line))
            }

            guard let fd else {
                throw ControlSocketConnectionError.closed
            }
            if let timeout, !waitForReadable(fd: fd, timeout: timeout) {
                throw ControlSocketConnectionError.timedOut
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 {
                throw ControlSocketConnectionError.closed
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw ControlSocketConnectError.other(underlying: String(cString: strerror(errno)))
            }
            receiveBuffer.append(contentsOf: bytes.prefix(count))
            if let newline = receiveBuffer.firstIndex(of: 0x0A) {
                let frameSize = receiveBuffer.distance(from: receiveBuffer.startIndex, to: newline) + 1
                if frameSize > Self.maxFrameBytes {
                    throw ControlSocketConnectionError.frameTooLarge(size: frameSize)
                }
            } else if receiveBuffer.count > Self.maxFrameBytes {
                throw ControlSocketConnectionError.frameTooLarge(size: receiveBuffer.count)
            }
        }
    }

    public func close() async {
        if let fd {
            Darwin.close(fd)
            self.fd = nil
        }
    }

    private func writeAll(_ data: Data) throws {
        guard let fd else {
            throw ControlSocketConnectionError.closed
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.write(fd, base.advanced(by: sent), rawBuffer.count - sent)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ControlSocketConnectError.other(underlying: String(cString: strerror(errno)))
                }
                sent += count
            }
        }
    }

    private func waitForReadable(fd: Int32, timeout: TimeInterval) -> Bool {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMs = Int32((timeout * 1000).rounded())
        let result = Darwin.poll(&pollFD, 1, timeoutMs)
        return result > 0
    }
}

private func bindUnixSocket(fd: Int32, path: String) throws {
    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address.sockaddr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, address.length)
        }
    }
    guard result == 0 else {
        throw ControlSocketServerError.bindFailed(path: path, errno: errno)
    }
}

private func connectUnixSocket(fd: Int32, path: String) throws {
    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address.sockaddr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, address.length)
        }
    }
    guard result == 0 else {
        throw ControlSocketConnectError.other(underlying: String(cString: strerror(errno)))
    }
}

private func unixAddress(path: String) throws -> (sockaddr: sockaddr_un, length: socklen_t) {
    let pathBytes = Array(path.utf8)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else {
        throw ControlSocketConnectError.other(underlying: "socket path too long")
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + pathBytes.count + 1)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        for (index, byte) in pathBytes.enumerated() {
            bytes[index] = byte
        }
        bytes[pathBytes.count] = 0
    }
    return (address, socklen_t(address.sun_len))
}
