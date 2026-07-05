import Foundation

// Wire-format mirror of ControlSocketFrame in Sources/macprovider-cli/ControlSocket.swift.
// Duplicated for P0. Extract to a shared `MacProviderControl` library target so the
// CLI and the app share one source of truth (SPEC-025 §12 conflict #9 — followup).

enum ControlFrame: Sendable, Equatable {
    case statusRequest
    case statusResponse(currentModelID: String, runtimeState: String)

    case switchRequest(targetModelID: String, requestedAtMs: Int64)
    case switchAck(accepted: Bool, reason: String?, currentTarget: String?, secondsRemaining: Int?)
    case switchProgress(state: String, elapsedMs: Int, reason: String?)

    case metricsRequest                                     // added by SPEC-025 §5.2
    case metricsResponse(
        earningsUsdc: Double?,
        malibuAccrued: Double?,
        gpuC: Double?,
        gpuUtilizationPct: Double?,
        latencyP50Ms: Int?,
        latencyP99Ms: Int?,
        queueDepth: Int?,
        requestsServedToday: Int?,
        requestsServedAllTime: Int?,
        requestsPerMinute: Double?,
        inputTokensToday: Int64?,
        outputTokensToday: Int64?,
        inputTokensAllTime: Int64?,
        outputTokensAllTime: Int64?,
        uptimeSec: Int?
    )

    case pauseRequest
    case pauseAck(accepted: Bool, reason: String?)
    case resumeRequest
    case resumeAck(accepted: Bool, reason: String?)

    case shutdownRequest(graceSeconds: Int)
    case shutdownAck

    case identitySignatureRequest(
        authAttemptID: String,
        providerID: String,
        // String NOT Int: must byte-match the CLI's `binary_version` field
        // in the initial auth_request so coordinator + Malibu canonical
        // tuples agree on JSON type (SPEC-026 §7).
        binaryVersion: String,
        providerECDHPublicKey: String,
        transcriptSHA256: String
    )
    case identitySignatureResponse(
        accepted: Bool,
        identitySignature: String?,
        transcriptSHA256: String?,
        reason: String?
    )
}

enum ControlCodec {
    static func encode(_ frame: ControlFrame) throws -> Data {
        let object = payload(for: frame)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) throws -> ControlFrame {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let dict = raw as? [String: Any], let type = dict["type"] as? String else {
            throw DecodeError.malformed
        }
        return try frame(from: type, dict: dict)
    }

    enum DecodeError: Error { case malformed, unknownType(String) }

    private static func payload(for frame: ControlFrame) -> [String: Any] {
        switch frame {
        case .statusRequest:
            return ["type": "status_request"]
        case let .statusResponse(currentModelID, runtimeState):
            return ["type": "status_response", "current_model_id": currentModelID, "runtime_state": runtimeState]
        case let .switchRequest(target, ms):
            return ["type": "switch_request", "target_model_id": target, "requested_at_ms": ms]
        case let .switchAck(accepted, reason, currentTarget, seconds):
            var obj: [String: Any] = ["type": "switch_ack", "accepted": accepted]
            if let reason { obj["reason"] = reason }
            if let currentTarget { obj["current_target"] = currentTarget }
            if let seconds { obj["seconds_remaining"] = seconds }
            return obj
        case let .switchProgress(state, ms, reason):
            var obj: [String: Any] = ["type": "switch_progress", "state": state, "elapsed_ms": ms]
            if let reason { obj["reason"] = reason }
            return obj
        case .metricsRequest:
            return ["type": "metrics_request"]
        case let .metricsResponse(
            earnings,
            malibu,
            gpu,
            gpuUtilization,
            latencyP50,
            latencyP99,
            queueDepth,
            requestsToday,
            requestsAllTime,
            requestsPerMinute,
            inputTokensToday,
            outputTokensToday,
            inputTokensAllTime,
            outputTokensAllTime,
            uptime
        ):
            var obj: [String: Any] = ["type": "metrics_response"]
            if let earnings { obj["earnings_usdc"] = earnings }
            if let malibu { obj["malibu_accrued"] = malibu }
            if let gpu { obj["gpu_c"] = gpu }
            if let gpuUtilization { obj["gpu_utilization_pct"] = gpuUtilization }
            if let latencyP50 { obj["latency_p50_ms"] = latencyP50 }
            if let latencyP99 { obj["latency_p99_ms"] = latencyP99 }
            if let queueDepth { obj["queue_depth"] = queueDepth }
            if let requestsToday { obj["requests_served_today"] = requestsToday }
            if let requestsAllTime { obj["requests_served_all_time"] = requestsAllTime }
            if let requestsPerMinute { obj["requests_per_minute"] = requestsPerMinute }
            if let inputTokensToday { obj["input_tokens_today"] = inputTokensToday }
            if let outputTokensToday { obj["output_tokens_today"] = outputTokensToday }
            if let inputTokensAllTime { obj["input_tokens_all_time"] = inputTokensAllTime }
            if let outputTokensAllTime { obj["output_tokens_all_time"] = outputTokensAllTime }
            if let uptime { obj["uptime_sec"] = uptime }
            return obj
        case .pauseRequest: return ["type": "pause_request"]
        case let .pauseAck(accepted, reason):
            var obj: [String: Any] = ["type": "pause_ack", "accepted": accepted]
            if let reason { obj["reason"] = reason }
            return obj
        case .resumeRequest: return ["type": "resume_request"]
        case let .resumeAck(accepted, reason):
            var obj: [String: Any] = ["type": "resume_ack", "accepted": accepted]
            if let reason { obj["reason"] = reason }
            return obj
        case let .shutdownRequest(grace): return ["type": "shutdown_request", "grace_seconds": grace]
        case .shutdownAck: return ["type": "shutdown_ack"]
        case let .identitySignatureRequest(authAttemptID, providerID, binaryVersion, ecdhKey, transcriptSHA256):
            return [
                "type": "identity_signature_request",
                "auth_attempt_id": authAttemptID,
                "provider_id": providerID,
                "binary_version": binaryVersion,
                "provider_ecdh_public_key": ecdhKey,
                "transcript_sha256": transcriptSHA256
            ]
        case let .identitySignatureResponse(accepted, signature, transcriptSHA256, reason):
            var obj: [String: Any] = [
                "type": "identity_signature_response",
                "accepted": accepted
            ]
            if let signature { obj["identity_signature"] = signature }
            if let transcriptSHA256 { obj["identity_signature_transcript_sha256"] = transcriptSHA256 }
            if let reason { obj["reason"] = reason }
            return obj
        }
    }

    private static func frame(from type: String, dict: [String: Any]) throws -> ControlFrame {
        switch type {
        case "status_request": return .statusRequest
        case "status_response":
            return .statusResponse(
                currentModelID: dict["current_model_id"] as? String ?? "",
                runtimeState: dict["runtime_state"] as? String ?? ""
            )
        case "switch_ack":
            return .switchAck(
                accepted: dict["accepted"] as? Bool ?? false,
                reason: dict["reason"] as? String,
                currentTarget: dict["current_target"] as? String,
                secondsRemaining: dict["seconds_remaining"] as? Int
            )
        case "switch_progress":
            return .switchProgress(
                state: dict["state"] as? String ?? "",
                elapsedMs: dict["elapsed_ms"] as? Int ?? 0,
                reason: dict["reason"] as? String
            )
        case "metrics_response":
            return .metricsResponse(
                earningsUsdc: doubleValue(dict["earnings_usdc"]),
                malibuAccrued: doubleValue(dict["malibu_accrued"]),
                gpuC: doubleValue(dict["gpu_c"]),
                gpuUtilizationPct: doubleValue(dict["gpu_utilization_pct"]),
                latencyP50Ms: intValue(dict["latency_p50_ms"]),
                latencyP99Ms: intValue(dict["latency_p99_ms"]),
                queueDepth: intValue(dict["queue_depth"]),
                requestsServedToday: intValue(dict["requests_served_today"]),
                requestsServedAllTime: intValue(dict["requests_served_all_time"]),
                requestsPerMinute: doubleValue(dict["requests_per_minute"]),
                inputTokensToday: int64Value(dict["input_tokens_today"]),
                outputTokensToday: int64Value(dict["output_tokens_today"]),
                inputTokensAllTime: int64Value(dict["input_tokens_all_time"]),
                outputTokensAllTime: int64Value(dict["output_tokens_all_time"]),
                uptimeSec: intValue(dict["uptime_sec"])
            )
        case "pause_ack":
            return .pauseAck(
                accepted: dict["accepted"] as? Bool ?? false,
                reason: dict["reason"] as? String
            )
        case "resume_ack":
            return .resumeAck(
                accepted: dict["accepted"] as? Bool ?? false,
                reason: dict["reason"] as? String
            )
        case "shutdown_ack": return .shutdownAck
        case "identity_signature_request":
            return .identitySignatureRequest(
                authAttemptID: dict["auth_attempt_id"] as? String ?? "",
                providerID: dict["provider_id"] as? String ?? "",
                binaryVersion: dict["binary_version"] as? String ?? "",
                providerECDHPublicKey: dict["provider_ecdh_public_key"] as? String ?? "",
                transcriptSHA256: dict["transcript_sha256"] as? String ?? ""
            )
        case "identity_signature_response":
            return .identitySignatureResponse(
                accepted: dict["accepted"] as? Bool ?? false,
                identitySignature: dict["identity_signature"] as? String,
                transcriptSHA256: dict["identity_signature_transcript_sha256"] as? String,
                reason: dict["reason"] as? String
            )
        default: throw DecodeError.unknownType(type)
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }
}
