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
    let stableReason: String?
    // Provisional-tier autoupdate is enabled by DEFAULT (accept = true). When
    // true, a bearer-validated provisional session becomes autoupdate-eligible;
    // set `auto_update_accept_provisional: false` in provider config to opt out
    // and stay notify-only. See SPEC-020 v0.1.5 trust table.
    let acceptProvisional: Bool

    init(
        v2Accepted: Bool,
        tier: String?,
        encryptedLegValid: Bool,
        attestationRequired: Bool,
        attestationSatisfied: Bool,
        tokenConfigured: Bool,
        tokenValidated: Bool,
        bearerlessDuplicate: Bool,
        connected: Bool,
        stableReason: String? = nil,
        acceptProvisional: Bool = true
    ) {
        self.v2Accepted = v2Accepted
        self.tier = tier
        self.encryptedLegValid = encryptedLegValid
        self.attestationRequired = attestationRequired
        self.attestationSatisfied = attestationSatisfied
        self.tokenConfigured = tokenConfigured
        self.tokenValidated = tokenValidated
        self.bearerlessDuplicate = bearerlessDuplicate
        self.connected = connected
        self.stableReason = stableReason
        self.acceptProvisional = acceptProvisional
    }

    var verdict: AutoUpdateTrustVerdict {
        guard connected else { return .coordinatorDisconnected }
        guard v2Accepted else { return .legacyHelloAck }
        if bearerlessDuplicate { return .bearerlessDuplicate }
        // Tier gate: pinned always passes. Provisional passes when
        // acceptProvisional is true (the default; config opts out via
        // `auto_update_accept_provisional: false`). Passing this gate is
        // necessary but not sufficient — the encrypted-leg, attestation, and
        // token-validation guards below still apply. A provisional session
        // reaches `.eligible` whether or not it holds a validated token: the
        // token guard (`!tokenConfigured || tokenValidated`) only blocks a
        // session with a configured-but-invalid token, and passes trivially
        // when no token is configured at all (SPEC-020 v0.1.5 trust table;
        // see "Eligible does not always mean bearer-validated").
        if tier != "pinned" {
            guard tier == "provisional" && acceptProvisional else { return .provisional }
        }
        guard encryptedLegValid else { return .encryptedLegFailed }
        guard !attestationRequired || attestationSatisfied else { return .attestationFailed }
        guard !tokenConfigured || tokenValidated else { return .tokenRejected }
        return .eligible
    }

    var isEligible: Bool {
        verdict == .eligible
    }

    var lossReason: String {
        stableReason ?? verdict.rawValue
    }

    static func fromCoordinatorPayload(
        _ payload: [String: Any],
        isV2: Bool,
        session: Tier2ProviderSession?,
        providerToken: String?,
        assignedProviderTokenAdopted: Bool,
        acceptProvisional: Bool = true
    ) -> AutoUpdateTrustState {
        let tier = payload["tier"] as? String
        let attestationStatus = (((payload["tier2_session"] as? [String: Any])?["attestation"] as? [String: Any])?["status"] as? String)
        let tokenConfigured = providerToken?.isEmpty == false || (payload["assigned_provider_token"] as? String)?.isEmpty == false
        // Runbook item 23 / SPEC-020 v0.1.7: prefer the coordinator's EXPLICIT
        // admission verdict (`auth_state`) over the client-side heuristic. The
        // coordinator propagates one of bearer_validated / self_minted /
        // bearerless_duplicate on the accept ack (mint_failed / rejects close the
        // connection and never ride an ack — the switch handles it defensively),
        // so a bearerless_duplicate race-loser is client-enforceable rather than
        // inferred. A legacy coordinator omits `auth_state` (empty) — fall back
        // to the pre-existing inference so behavior is unchanged against old
        // coordinators. The client uses this only to hold a MORE restrictive
        // floor (bearerless_duplicate → notify-only); it never relaxes the
        // verdict based on a coordinator claim.
        // Distinguish the key being ABSENT (legacy coordinator → heuristic
        // fallback, behavior unchanged) from the key being PRESENT-but-malformed
        // (empty, non-string null/number/object, or an unrecognized string). The
        // coordinator uses omitempty, so a legitimately "no verdict" ack omits the
        // key entirely; any present value that is not a recognized non-empty
        // string is anomalous and MUST fail closed to the notify-only floor rather
        // than fall through to the heuristic (which could reach .eligible).
        let bearerlessDuplicate: Bool
        if let rawAuthState = payload["auth_state"] {
            if let authState = rawAuthState as? String, !authState.isEmpty {
                switch authState {
                case "bearer_validated", "self_minted":
                    // The closed wire domain of ack auth_state (SPEC-001 §6.5.1):
                    // known non-duplicate verdicts — the verdict pipeline still
                    // applies its own tier/token/attestation guards. (Reserved
                    // states like self_minted_verified are NOT in the emitted
                    // domain; if one ever appears it takes the fail-closed default
                    // below until a coordinated SPEC-001/003/020 bump defines it.)
                    bearerlessDuplicate = false
                case "bearerless_duplicate", "mint_failed":
                    // Race-loser holds the notify-only floor. mint_failed does not
                    // normally ride an ack (the coordinator closes the connection),
                    // but if ever seen it is treated as notify-only, defensively.
                    bearerlessDuplicate = true
                default:
                    // Unrecognized string (enum evolution) — FAIL CLOSED.
                    bearerlessDuplicate = true
                }
            } else {
                // Present but empty / non-string (NSNull, number, bool, object):
                // malformed — FAIL CLOSED to the notify-only floor.
                bearerlessDuplicate = true
            }
        } else {
            // Key absent → legacy coordinator; use the pre-existing inference.
            bearerlessDuplicate = tokenConfigured && providerToken == nil && !assignedProviderTokenAdopted
        }
        return AutoUpdateTrustState(
            v2Accepted: isV2,
            tier: tier,
            encryptedLegValid: isV2 && session != nil,
            attestationRequired: attestationStatus != nil,
            attestationSatisfied: attestationStatus == nil || attestationStatus == "attested" || attestationStatus == "not_required",
            tokenConfigured: tokenConfigured,
            tokenValidated: !tokenConfigured || providerToken?.isEmpty == false || assignedProviderTokenAdopted,
            bearerlessDuplicate: bearerlessDuplicate,
            connected: true,
            acceptProvisional: acceptProvisional
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

    /// Effective accept-provisional default is TRUE: `!= false` maps both unset
    /// (nil) and true to true, so provisional providers receive coordinator-
    /// driven autoupdate unless explicitly opted out via
    /// `auto_update_accept_provisional: false`. See SPEC-020 v0.1.5 trust table.
    static func acceptProvisional(_ config: AppConfig) -> Bool {
        config.autoUpdateAcceptProvisional != false
    }
}
