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
    case metricsResponse(earningsUsdc: Double, malibuAccrued: Double, gpuC: Double?, latencyP50Ms: Int?, uptimeSec: Int)

    case pauseRequest
    case pauseAck(accepted: Bool)
    case resumeRequest
    case resumeAck(accepted: Bool)

    case shutdownRequest(graceSeconds: Int)
    case shutdownAck
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
        case let .metricsResponse(earnings, malibu, gpu, latency, uptime):
            var obj: [String: Any] = [
                "type": "metrics_response",
                "earnings_usdc": earnings,
                "malibu_accrued": malibu,
                "uptime_sec": uptime
            ]
            if let gpu { obj["gpu_c"] = gpu }
            if let latency { obj["latency_p50_ms"] = latency }
            return obj
        case .pauseRequest: return ["type": "pause_request"]
        case let .pauseAck(accepted): return ["type": "pause_ack", "accepted": accepted]
        case .resumeRequest: return ["type": "resume_request"]
        case let .resumeAck(accepted): return ["type": "resume_ack", "accepted": accepted]
        case let .shutdownRequest(grace): return ["type": "shutdown_request", "grace_seconds": grace]
        case .shutdownAck: return ["type": "shutdown_ack"]
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
                earningsUsdc: dict["earnings_usdc"] as? Double ?? 0,
                malibuAccrued: dict["malibu_accrued"] as? Double ?? 0,
                gpuC: dict["gpu_c"] as? Double,
                latencyP50Ms: dict["latency_p50_ms"] as? Int,
                uptimeSec: dict["uptime_sec"] as? Int ?? 0
            )
        case "pause_ack": return .pauseAck(accepted: dict["accepted"] as? Bool ?? false)
        case "resume_ack": return .resumeAck(accepted: dict["accepted"] as? Bool ?? false)
        case "shutdown_ack": return .shutdownAck
        default: throw DecodeError.unknownType(type)
        }
    }
}
