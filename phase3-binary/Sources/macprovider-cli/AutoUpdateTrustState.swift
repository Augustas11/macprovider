import Foundation
import MacProviderCore

enum AutoUpdateTrustVerdict: String, Sendable {
    case eligible
    case legacyHelloAck = "legacy_hello_ack"
    case unauthenticated
    case authRejected = "auth_rejected"
    case provisional
    case bearerlessDuplicate = "bearerless_duplicate"
    case encryptedLegFailed = "encrypted_leg_failed"
    case attestationFailed = "attestation_failed"
    case tokenRejected = "token_rejected"
    case coordinatorDisconnected = "coordinator_disconnected"
}

struct AutoUpdateTrustState: Sendable {
    let v2Accepted: Bool
    let tier: String?
    let encryptedLegValid: Bool
    let attestationRequired: Bool
    let attestationSatisfied: Bool
    let tokenConfigured: Bool
    let tokenValidated: Bool
    let bearerlessDuplicate: Bool
    let connected: Bool

    var verdict: AutoUpdateTrustVerdict {
        guard connected else { return .coordinatorDisconnected }
        guard v2Accepted else { return .legacyHelloAck }
        if bearerlessDuplicate { return .bearerlessDuplicate }
        guard tier == "pinned" else { return .provisional }
        guard encryptedLegValid else { return .encryptedLegFailed }
        guard !attestationRequired || attestationSatisfied else { return .attestationFailed }
        guard !tokenConfigured || tokenValidated else { return .tokenRejected }
        return .eligible
    }

    var isEligible: Bool {
        verdict == .eligible
    }

    static func fromCoordinatorPayload(
        _ payload: [String: Any],
        isV2: Bool,
        session: Tier2ProviderSession?,
        providerToken: String?,
        assignedProviderTokenAdopted: Bool
    ) -> AutoUpdateTrustState {
        let tier = payload["tier"] as? String
        let attestationStatus = (((payload["tier2_session"] as? [String: Any])?["attestation"] as? [String: Any])?["status"] as? String)
        let tokenConfigured = providerToken?.isEmpty == false || (payload["assigned_provider_token"] as? String)?.isEmpty == false
        return AutoUpdateTrustState(
            v2Accepted: isV2,
            tier: tier,
            encryptedLegValid: isV2 && session != nil,
            attestationRequired: attestationStatus != nil,
            attestationSatisfied: attestationStatus == nil || attestationStatus == "attested" || attestationStatus == "not_required",
            tokenConfigured: tokenConfigured,
            tokenValidated: !tokenConfigured || providerToken?.isEmpty == false || assignedProviderTokenAdopted,
            bearerlessDuplicate: tokenConfigured && providerToken == nil && !assignedProviderTokenAdopted,
            connected: true
        )
    }
}

struct AutoUpdateRecommendation: Sendable, Equatable {
    let raw: String
    let normalized: String
    let oversizedSHA256: String?

    static func validate(_ raw: String) throws -> AutoUpdateRecommendation {
        let rawBytes = raw.utf8.count
        if rawBytes > 32 {
            throw AutoUpdateValidationError.versionTooLong(AutoUpdateEvent.sha256Hex(raw))
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              normalized.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
        else {
            throw AutoUpdateValidationError.invalid
        }
        if parts.contains(where: { $0.utf8.count > 8 }) {
            throw AutoUpdateValidationError.componentTooLong
        }
        return AutoUpdateRecommendation(raw: raw, normalized: normalized, oversizedSHA256: nil)
    }
}

enum AutoUpdateValidationError: Error, Equatable {
    case invalid
    case versionTooLong(String)
    case componentTooLong
}

enum AutoUpdateConfig {
    static func enabled(_ config: AppConfig) -> Bool {
        if config.autoUpdateEnabled == false { return false }
        if config.autoupdateEnabled == false { return false }
        return true
    }
}
