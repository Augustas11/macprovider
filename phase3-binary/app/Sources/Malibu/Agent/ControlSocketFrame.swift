import Foundation

enum ReferralWireDate {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

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
        providerEarnings: ProviderEarnings?,
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

    case referralStatusRequest
    case referralStatusResponse(ReferralStatusProjection)
    case referralChallengeRequest
    case referralChallengeResponse(expiresAt: String)
    case referralChallengeReopenRequest
    case referralChallengeReopenAck(expiresAt: String)
    case referralVerifyRequest(postURL: String)
    case referralChallengeCancelRequest
    case referralChallengeCancelAck(status: ReferralStatusProjection?)
    case referralError(operation: ReferralControlOperation, code: ReferralControlErrorCode, retryAfterSeconds: Int?)
}

enum ReferralControlOperation: String, Sendable, Equatable {
    case status, challenge, verify, cancel
}

enum ReferralControlErrorCode: String, Sendable, Equatable {
    case authenticationRequired = "authentication_required"
    case featureUnavailable = "feature_unavailable"
    case rateLimited = "rate_limited"
    case temporarilyUnavailable = "temporarily_unavailable"
    case invalidResponse = "invalid_response"
    case invalidPostURL = "invalid_post_url"
    case firstServingRequired = "first_serving_required"
    case challengeUnavailable = "challenge_unavailable"
    case challengeInvalid = "challenge_invalid"
    case postNotVerified = "post_not_verified"
    case referralLocked = "referral_locked"
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
            providerEarnings,
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
            if let providerEarnings,
               let encoded = try? JSONEncoder().encode(providerEarnings),
               let nested = try? JSONSerialization.jsonObject(with: encoded) {
                obj["provider_earnings"] = nested
            }
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
        case .referralStatusRequest: return ["type": "referral_status_request"]
        case let .referralStatusResponse(status):
            var payload = referralStatusPayload(status)
            payload["type"] = "referral_status_response"
            return payload
        case .referralChallengeRequest: return ["type": "referral_challenge_request"]
        case let .referralChallengeResponse(expiresAt):
            return ["type": "referral_challenge_response", "expires_at": expiresAt]
        case .referralChallengeReopenRequest:
            return ["type": "referral_challenge_reopen_request"]
        case let .referralChallengeReopenAck(expiresAt):
            return ["type": "referral_challenge_reopen_ack", "expires_at": expiresAt]
        case let .referralVerifyRequest(postURL):
            return ["type": "referral_verify_request", "post_url": postURL]
        case .referralChallengeCancelRequest:
            return ["type": "referral_challenge_cancel_request"]
        case let .referralChallengeCancelAck(status):
            var payload: [String: Any] = ["type": "referral_challenge_cancel_ack"]
            if let status { payload["status"] = referralStatusPayload(status) }
            return payload
        case let .referralError(operation, code, retryAfterSeconds):
            var payload: [String: Any] = [
                "type": "referral_error",
                "operation": operation.rawValue,
                "code": code.rawValue,
            ]
            if let retryAfterSeconds { payload["retry_after_seconds"] = retryAfterSeconds }
            return payload
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
                providerEarnings: try providerEarningsValue(dict["provider_earnings"]),
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
        case "referral_status_request": return .referralStatusRequest
        case "referral_status_response":
            return .referralStatusResponse(try referralStatusValue(dict))
        case "referral_challenge_request": return .referralChallengeRequest
        case "referral_challenge_response":
            guard let expiresAt = dict["expires_at"] as? String else { throw DecodeError.malformed }
            return .referralChallengeResponse(expiresAt: expiresAt)
        case "referral_challenge_reopen_request": return .referralChallengeReopenRequest
        case "referral_challenge_reopen_ack":
            guard let expiresAt = dict["expires_at"] as? String else { throw DecodeError.malformed }
            return .referralChallengeReopenAck(expiresAt: expiresAt)
        case "referral_verify_request":
            guard let postURL = dict["post_url"] as? String else { throw DecodeError.malformed }
            return .referralVerifyRequest(postURL: postURL)
        case "referral_challenge_cancel_request": return .referralChallengeCancelRequest
        case "referral_challenge_cancel_ack":
            if let status = dict["status"] as? [String: Any] {
                return .referralChallengeCancelAck(status: try referralStatusValue(status))
            }
            return .referralChallengeCancelAck(status: nil)
        case "referral_error":
            guard let operationRaw = dict["operation"] as? String,
                  let operation = ReferralControlOperation(rawValue: operationRaw),
                  let codeRaw = dict["code"] as? String,
                  let code = ReferralControlErrorCode(rawValue: codeRaw) else { throw DecodeError.malformed }
            return .referralError(
                operation: operation,
                code: code,
                retryAfterSeconds: intValue(dict["retry_after_seconds"])
            )
        default: throw DecodeError.unknownType(type)
        }
    }

    private static func referralStatusPayload(_ status: ReferralStatusProjection) -> [String: Any] {
        var payload: [String: Any] = [
            "campaign": status.campaign,
            "join_base_url": status.joinBaseURL.absoluteString,
            "social_state": status.socialState,
            "base_capacity": status.baseCapacity,
            "configured_bonus_capacity": status.configuredBonusCapacity,
            "bonus_capacity": status.bonusCapacity,
            "redemptions": status.redemptions,
            "remaining": status.remaining,
            "first_serving_seen": status.firstServingSeen,
            "join_links_enabled": status.joinLinksEnabled,
            "social_bonus_enabled": status.socialBonusEnabled,
            "observed_at": ISO8601DateFormatter().string(from: status.observedAt),
        ]
        if let remaining = status.socialBonusGrantsRemaining {
            payload["social_bonus_grants_remaining"] = remaining
        }
        if let inviteCode = status.inviteCode { payload["invite_code"] = inviteCode }
        if let inviteURL = status.inviteURL { payload["invite_url"] = inviteURL.absoluteString }
        if let challenge = status.pendingChallenge {
            payload["pending_challenge"] = [
                "expires_at": ISO8601DateFormatter().string(from: challenge.expiresAt),
            ]
        }
        return payload
    }

    private static func referralStatusValue(_ dict: [String: Any]) throws -> ReferralStatusProjection {
        guard let campaign = dict["campaign"] as? String,
              let joinBaseWire = dict["join_base_url"] as? String,
              let joinBaseURL = URL(string: joinBaseWire),
              let socialState = dict["social_state"] as? String,
              let baseCapacity = intValue(dict["base_capacity"]),
              let configuredBonusCapacity = intValue(dict["configured_bonus_capacity"]),
              let bonusCapacity = intValue(dict["bonus_capacity"]),
              let redemptions = intValue(dict["redemptions"]),
              let remaining = intValue(dict["remaining"]),
              let firstServingSeen = dict["first_serving_seen"] as? Bool,
              let joinLinksEnabled = dict["join_links_enabled"] as? Bool,
              let socialBonusEnabled = dict["social_bonus_enabled"] as? Bool,
              let observedWire = dict["observed_at"] as? String,
              let observedAt = ReferralWireDate.parse(observedWire) else {
            throw DecodeError.malformed
        }
        let inviteCode = dict["invite_code"] as? String
        let inviteURL: URL?
        if let raw = dict["invite_url"] as? String {
            guard let parsed = URL(string: raw) else { throw DecodeError.malformed }
            inviteURL = parsed
        } else {
            inviteURL = nil
        }
        let socialBonusGrantsRemaining = intValue(dict["social_bonus_grants_remaining"])
        let pending: ReferralPendingChallengeProjection?
        if let raw = dict["pending_challenge"] as? [String: Any] {
            guard let expiresWire = raw["expires_at"] as? String,
                  let expiresAt = ReferralWireDate.parse(expiresWire) else {
                throw DecodeError.malformed
            }
            pending = ReferralPendingChallengeProjection(expiresAt: expiresAt)
        } else {
            pending = nil
        }
        guard let status = ReferralStatusProjection(
            campaign: campaign,
            joinBaseURL: joinBaseURL,
            socialState: socialState,
            baseCapacity: baseCapacity,
            configuredBonusCapacity: configuredBonusCapacity,
            bonusCapacity: bonusCapacity,
            redemptions: redemptions,
            remaining: remaining,
            firstServingSeen: firstServingSeen,
            joinLinksEnabled: joinLinksEnabled,
            socialBonusEnabled: socialBonusEnabled,
            socialBonusGrantsRemaining: socialBonusGrantsRemaining,
            inviteCode: inviteCode,
            inviteURL: inviteURL,
            observedAt: observedAt,
            pendingChallenge: pending
        ) else {
            throw DecodeError.malformed
        }
        return status
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

    private static func providerEarningsValue(_ value: Any?) throws -> ProviderEarnings? {
        guard let value else { return nil }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(ProviderEarnings.self, from: data)
    }
}
