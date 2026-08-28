import CryptoKit
import Foundation

enum LosslessnessProbeProtocol {
    static let version = "losslessness_probe_v1"
    static let requestType = "losslessness_probe_v1.request"
    static let resultType = "losslessness_probe_v1.result"
    static let encryptedRequestType = "losslessness_probe_v1.encrypted_request"
    static let encryptedResultType = "losslessness_probe_v1.encrypted_result"
    static let requestPlaintextType = "losslessness_probe_v1.request_plaintext"
    static let resultPlaintextType = "losslessness_probe_v1.result_plaintext"
    static let supportSelection = "support_selection_v1"
    static let normalizationBasis = "full_distribution"
    static let samplerStage = "post_processors_post_sampling_profile_next_emitted_token"

    static let allowedProviderInconclusiveReasons: Set<String> = [
        "inconclusive:model_swap",
        "inconclusive:unsupported_sampler",
        "inconclusive:draft_unavailable",
        "inconclusive:position_mismatch",
        "inconclusive:missing_distribution",
        "inconclusive:timeout",
    ]

    struct Envelope {
        let type: String
        let probeID: String
        let probeRequestDigest: String
        let probeResultDigest: String?
        let payload: [String: Any]
    }

    struct ProviderInconclusive {
        let probeID: String
        let probeNonce: String
        let probeRequestDigest: String
        let reasonCode: String
        let identityUnavailableReason: String?
    }

    struct RequestPayload {
        let probeID: String
        let probeNonce: String
    }

    static func digest(payload: [String: Any]) throws -> String {
        let value = try jcsValue(from: payload)
        let canonical = try RFC8785JCS.canonicalStringRawStrings(value)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func decodeEnvelope(_ raw: [String: Any], expectedType: String) throws -> Envelope {
        guard raw["type"] as? String == expectedType,
              let probeID = raw["probe_id"] as? String, !probeID.isEmpty,
              let probeRequestDigest = raw["probe_request_digest"] as? String,
              let payload = raw["payload"] as? [String: Any]
        else {
            throw LosslessnessProbeError.invalidEnvelope
        }
        let probeResultDigest = raw["probe_result_digest"] as? String
        let computed = try digest(payload: payload)
        if expectedType == requestType, computed != probeRequestDigest {
            throw LosslessnessProbeError.digestMismatch
        }
        if expectedType == resultType, computed != probeResultDigest {
            throw LosslessnessProbeError.digestMismatch
        }
        guard payload["probe_id"] as? String == probeID else {
            throw LosslessnessProbeError.invalidEnvelope
        }
        if expectedType == resultType, payload["probe_request_digest"] as? String != probeRequestDigest {
            throw LosslessnessProbeError.invalidEnvelope
        }
        return Envelope(
            type: expectedType,
            probeID: probeID,
            probeRequestDigest: probeRequestDigest,
            probeResultDigest: probeResultDigest,
            payload: payload
        )
    }

    static func decodeProviderInconclusive(_ payload: [String: Any]) throws -> ProviderInconclusive {
        guard payload["result_kind"] as? String == "provider_inconclusive",
              let probeID = payload["probe_id"] as? String, !probeID.isEmpty,
              let probeNonce = payload["probe_nonce"] as? String, !probeNonce.isEmpty,
              let requestDigest = payload["probe_request_digest"] as? String,
              let reason = payload["provider_reason_code"] as? String
        else {
            throw LosslessnessProbeError.invalidPayload
        }
        guard allowedProviderInconclusiveReasons.contains(reason) else {
            throw LosslessnessProbeError.unsupportedProviderReason(reason)
        }
        guard payload.keys.contains("target_model_hash"),
              payload.keys.contains("target_generation"),
              payload.keys.contains("draft_artifact_binding"),
              payload.keys.contains("draft_generation") else {
            throw LosslessnessProbeError.invalidPayload
        }
        let identityKnown = payload["target_model_hash"] as? String != nil &&
            intValue(payload["target_generation"]).map { $0 > 0 } == true &&
            payload["draft_artifact_binding"] as? [String: Any] != nil &&
            intValue(payload["draft_generation"]).map { $0 > 0 } == true
        let identityUnavailable = payload["target_model_hash"] is NSNull &&
            payload["target_generation"] is NSNull &&
            payload["draft_artifact_binding"] is NSNull &&
            payload["draft_generation"] is NSNull &&
            (payload["identity_unavailable_reason"] as? String)?.isEmpty == false
        if !identityKnown && !identityUnavailable {
            throw LosslessnessProbeError.invalidPayload
        }
        return ProviderInconclusive(
            probeID: probeID,
            probeNonce: probeNonce,
            probeRequestDigest: requestDigest,
            reasonCode: reason,
            identityUnavailableReason: payload["identity_unavailable_reason"] as? String
        )
    }

    static func decodeRequestPayload(_ payload: [String: Any]) throws -> RequestPayload {
        guard payload["probe_version"] as? String == version,
              let probeID = payload["probe_id"] as? String, !probeID.isEmpty,
              let nonce = payload["probe_nonce"] as? String, !nonce.isEmpty,
              let expiresAt = payload["expires_at"] as? String, ISO8601DateFormatter().date(from: expiresAt) != nil,
              let modelID = payload["model_id"] as? String, !modelID.isEmpty,
              let targetHash = payload["target_model_hash"] as? String, !targetHash.isEmpty,
              let targetGeneration = intValue(payload["target_generation"]), targetGeneration > 0,
              let draftModelID = payload["draft_model_id"] as? String, !draftModelID.isEmpty,
              let draftBinding = payload["draft_artifact_binding"] as? [String: Any],
              let draftBindingModelID = draftBinding["draft_model_id"] as? String, !draftBindingModelID.isEmpty,
              let draftSHA = draftBinding["draft_artifact_sha256"] as? String, !draftSHA.isEmpty,
              let bindingTokenizer = draftBinding["tokenizer_identity"] as? String, !bindingTokenizer.isEmpty,
              let compatibility = draftBinding["compatibility_check_digest"] as? String, !compatibility.isEmpty,
              let draftGeneration = intValue(payload["draft_generation"]), draftGeneration > 0,
              let tokenizer = payload["tokenizer_identity"] as? String, !tokenizer.isEmpty,
              let samplingProfile = payload["sampling_profile"] as? [String: Any],
              numberPresent(samplingProfile["temperature"]),
              numberPresent(samplingProfile["top_p"]),
              let corpusVersion = payload["corpus_version"] as? String, !corpusVersion.isEmpty,
              let thresholdVersion = payload["threshold_version"] as? String, !thresholdVersion.isEmpty,
              let prompts = payload["prompts"] as? [[String: Any]], !prompts.isEmpty, prompts.count <= 4,
              let positions = payload["measurement_positions"] as? [Any], !positions.isEmpty, positions.count <= 8,
              let requestedK = intValue(payload["requested_k"]), requestedK == 64 || requestedK == 256,
              payload["support_selection"] as? String == supportSelection,
              let maxPrompts = intValue(payload["max_prompts"]), maxPrompts > 0, maxPrompts <= 4, prompts.count <= maxPrompts,
              let maxPositions = intValue(payload["max_stochastic_positions"]), maxPositions > 0, maxPositions <= 8, positions.count <= maxPositions,
              intValue(payload["timeout_ms"]) == 60_000 else {
            throw LosslessnessProbeError.invalidPayload
        }
        for prompt in prompts {
            guard prompt["prompt_id"] as? String != nil,
                  prompt["prompt"] as? String != nil,
                  prompt["coordinator_owned"] as? Bool == true,
                  prompt["buyer_origin"] as? Bool == false else {
                throw LosslessnessProbeError.invalidPayload
            }
        }
        for position in positions {
            guard let number = intValue(position), number >= 0 else {
                throw LosslessnessProbeError.invalidPayload
            }
        }
        return RequestPayload(probeID: probeID, probeNonce: nonce)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if isJSONBool(value) {
            return nil
        }
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, double.rounded(.towardZero) == double else {
                return nil
            }
            return number.intValue
        }
        return nil
    }

    private static func numberPresent(_ value: Any?) -> Bool {
        if isJSONBool(value) {
            return false
        }
        if value is NSNumber {
            return true
        }
        return value is Double || value is Int
    }

    private static func isJSONBool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() || String(cString: number.objCType) == "c"
        }
        return value is Bool
    }

    static func validateMeasurementPosition(_ position: [String: Any]) throws {
        guard position["support_selection"] as? String == supportSelection,
              position["normalization_basis"] as? String == normalizationBasis,
              position["sampler_stage"] as? String == samplerStage
        else {
            throw LosslessnessProbeError.malformedDistribution
        }
    }

    static func jcsValue(from input: Any) throws -> RFC8785JCS.Value {
        if let object = input as? [String: Any] {
            var members: [String: RFC8785JCS.Value] = [:]
            for (key, value) in object {
                members[key] = try jcsValue(from: value)
            }
            return .object(members)
        }
        if let array = input as? [Any] {
            return .array(try array.map { try jcsValue(from: $0) })
        }
        if let string = input as? String {
            return .string(string)
        }
        if input is NSNull {
            return .null
        }
        if let number = input as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let type = String(cString: number.objCType)
            if type == "d" || type == "f" {
                return .double(number.doubleValue)
            }
            guard let int = Int(exactly: number.int64Value) else {
                throw LosslessnessProbeError.invalidPayload
            }
            return .int(int)
        }
        throw LosslessnessProbeError.invalidPayload
    }
}

enum LosslessnessProbeError: Error, Equatable {
    case digestMismatch
    case invalidEnvelope
    case invalidPayload
    case malformedDistribution
    case unsupportedProviderReason(String)
    case samplerHookUnavailable
}

enum LosslessnessProbeRuntime {
    static let samplerStage = LosslessnessProbeProtocol.samplerStage

    static func providerInconclusiveForUnavailableSampler(probeID: String, probeNonce: String, requestDigest: String) -> [String: Any] {
        [
            "probe_id": probeID,
            "probe_nonce": probeNonce,
            "probe_request_digest": requestDigest,
            "result_kind": "provider_inconclusive",
            "provider_reason_code": "inconclusive:unsupported_sampler",
            "target_model_hash": NSNull(),
            "target_generation": NSNull(),
            "draft_artifact_binding": NSNull(),
            "draft_generation": NSNull(),
            "identity_unavailable_reason": "full-distribution MLX sampler hook is not available in the current runtime",
        ]
    }
}
