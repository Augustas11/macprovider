import Foundation

/// Coordinator-owned MALIBU reward eligibility reason model.
public struct MalibuRewardEligibility: Codable, Equatable, Sendable {
    public static let schemaV1 = "malibu_reward_eligibility.v1"

    public let schemaVersion: String
    public let earningState: String
    public let withdrawalState: String
    public let primaryReason: String
    public let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case earningState = "earning_state"
        case withdrawalState = "withdrawal_state"
        case primaryReason = "primary_reason"
        case reasons
    }

    public init(
        schemaVersion: String = schemaV1,
        earningState: String,
        withdrawalState: String,
        primaryReason: String,
        reasons: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.earningState = earningState
        self.withdrawalState = withdrawalState
        self.primaryReason = primaryReason
        self.reasons = reasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawSchema = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? ""
        guard rawSchema == Self.schemaV1 else {
            self = .unavailable(schemaVersion: rawSchema, driftField: "schema_version")
            return
        }
        let rawEarningState = try c.decodeIfPresent(String.self, forKey: .earningState) ?? ""
        let rawWithdrawalState = try c.decodeIfPresent(String.self, forKey: .withdrawalState) ?? ""
        let rawPrimaryReason = try c.decodeIfPresent(String.self, forKey: .primaryReason) ?? ""
        let rawReasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        if !Self.allowedEarningStates.contains(rawEarningState) {
            self = .unavailable(schemaVersion: rawSchema, driftField: "earning_state")
            return
        }
        if !Self.allowedWithdrawalStates.contains(rawWithdrawalState) {
            self = .unavailable(schemaVersion: rawSchema, driftField: "withdrawal_state")
            return
        }
        if !Self.allowedReasons.contains(rawPrimaryReason) {
            self = .unavailable(schemaVersion: rawSchema, driftField: "primary_reason")
            return
        }
        if rawReasons.contains(where: { !Self.allowedReasons.contains($0) }) {
            self = .unavailable(schemaVersion: rawSchema, driftField: "reasons")
            return
        }
        self.init(
            schemaVersion: rawSchema,
            earningState: rawEarningState,
            withdrawalState: rawWithdrawalState,
            primaryReason: rawPrimaryReason,
            reasons: rawReasons
        )
    }

    private static func unavailable(schemaVersion: String, driftField: String) -> MalibuRewardEligibility {
        logSchemaDrift(schemaVersion: schemaVersion, field: driftField)
        return MalibuRewardEligibility(
            schemaVersion: schemaVersion.isEmpty ? schemaV1 : schemaVersion,
            earningState: "unavailable",
            withdrawalState: "unavailable",
            primaryReason: "telemetry_unavailable",
            reasons: ["telemetry_unavailable"]
        )
    }

    private static func logSchemaDrift(schemaVersion: String, field: String) {
        let schema = schemaVersion.isEmpty ? "missing" : schemaVersion
        let line = "event=malibu_reward_eligibility_schema_drift schema_version=\(schema) field=\(field)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static let allowedEarningStates: Set<String> = [
        "earning", "eligible_idle", "held", "capped", "ineligible", "unavailable"
    ]
    private static let allowedWithdrawalStates: Set<String> = [
        "withdrawable", "held", "capped", "ineligible", "unavailable"
    ]
    private static let allowedReasons: Set<String> = [
        "earning_verified_work",
        "eligible_idle_no_work",
        "held_provisional_trust_tier",
        "held_wallet_daily_cap",
        "held_demotion_cooldown",
        "withdrawable_balance_available",
        "withdrawable_no_balance",
        "missing_wallet_binding",
        "insufficient_verified_receipts",
        "app_attestation_missing",
        "hardware_evidence_unavailable",
        "hardware_evidence_missing_or_expired",
        "compute_integrity_unavailable",
        "compute_integrity_pending",
        "compute_integrity_blocked",
        "provider_token_untrusted",
        "local_on_battery",
        "local_thermal_pressure",
        "model_not_ready",
        "telemetry_unavailable",
    ]
}

/// Provider-facing MALIBU accrual read model from GET /v1/provider/malibu-accrual.
struct MalibuAccrualSummary: Decodable, Equatable, Sendable {
    let accruedMALIBU: Double
    let withdrawableMALIBU: Double
    let heldMALIBU: Double
    let trustTier: String
    let trustCriteriaMet: Int?
    let trustCriteriaRequired: Int?
    let walletBound: Bool?
    let dailyCapMALIBU: Double?
    let walletDailyCapMALIBU: Double?
    let withdrawalHoldReasons: [String]
    let rewardEligibility: MalibuRewardEligibility?

    enum CodingKeys: String, CodingKey {
        case accruedMALIBU = "accrued_malibu"
        case withdrawableMALIBU = "withdrawable_malibu"
        case heldMALIBU = "held_malibu"
        case trustTier = "trust_tier"
        case trustCriteriaMet = "trust_criteria_met"
        case trustCriteriaRequired = "trust_criteria_required"
        case walletBound = "wallet_bound"
        case dailyCapMALIBU = "daily_cap_malibu"
        case walletDailyCapMALIBU = "wallet_daily_cap_malibu"
        case withdrawalHoldReasons = "withdrawal_hold_reasons"
        case rewardEligibility = "reward_eligibility"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accruedMALIBU = try Self.decodeRequiredDecimal(c, key: .accruedMALIBU)
        withdrawableMALIBU = try Self.decodeRequiredDecimal(c, key: .withdrawableMALIBU)
        heldMALIBU = try Self.decodeRequiredDecimal(c, key: .heldMALIBU)
        let rawTrustTier = try c.decode(String.self, forKey: .trustTier).lowercased()
        guard rawTrustTier == "provisional" || rawTrustTier == "trusted" else {
            throw DecodingError.dataCorruptedError(
                forKey: .trustTier,
                in: c,
                debugDescription: "Invalid MALIBU trust tier"
            )
        }
        trustTier = rawTrustTier
        trustCriteriaMet = try c.decodeIfPresent(Int.self, forKey: .trustCriteriaMet)
        trustCriteriaRequired = try c.decodeIfPresent(Int.self, forKey: .trustCriteriaRequired)
        walletBound = try c.decodeIfPresent(Bool.self, forKey: .walletBound)
        dailyCapMALIBU = try Self.decodeOptionalDecimal(c, key: .dailyCapMALIBU)
        walletDailyCapMALIBU = try Self.decodeOptionalDecimal(c, key: .walletDailyCapMALIBU)
        withdrawalHoldReasons = try c.decodeIfPresent([String].self, forKey: .withdrawalHoldReasons) ?? []
        rewardEligibility = try c.decodeIfPresent(MalibuRewardEligibility.self, forKey: .rewardEligibility)
    }

    private static func decodeRequiredDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Double {
        guard c.contains(key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: c.codingPath,
                    debugDescription: "Missing required MALIBU amount"
                )
            )
        }
        if let value = try? c.decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let text = try? c.decode(String.self, forKey: key),
           let value = Double(text),
           value.isFinite {
            return value
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: c,
            debugDescription: "Invalid MALIBU amount"
        )
    }

    private static func decodeOptionalDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Double? {
        guard c.contains(key) else { return nil }
        if let value = try? c.decode(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let text = try? c.decode(String.self, forKey: key),
           let value = Double(text),
           value.isFinite {
            return value
        }
        return nil
    }
}

enum MalibuAccrualClientError: Error, Equatable {
    case invalidCoordinatorURL
    case httpStatus(Int)
    case unavailable
}

struct MalibuAccrualClient: Sendable {
    let accrualURL: URL
    private let session: URLSession?

    init(coordinatorURL: String?, session: URLSession? = nil) throws {
        guard let url = Self.accrualURL(from: coordinatorURL) else {
            throw MalibuAccrualClientError.invalidCoordinatorURL
        }
        self.accrualURL = url
        self.session = session
    }

    init(accrualURL: URL, session: URLSession? = nil) {
        self.accrualURL = accrualURL
        self.session = session
    }

    static func accrualURL(from coordinatorURL: String?) -> URL? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL) else {
            return nil
        }
        switch components.scheme {
        case "wss":
            components.scheme = "https"
        case "https":
            break
        default:
            return nil
        }
        components.path = "/v1/provider/malibu-accrual"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func fetch(bearerToken: String) async throws -> MalibuAccrualSummary {
        var request = URLRequest(url: accrualURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        if let session {
            (data, response) = try await session.data(for: request)
        } else {
            let ephemeral = URLSession(
                configuration: .ephemeral,
                delegate: NoRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
            defer { ephemeral.finishTasksAndInvalidate() }
            (data, response) = try await ephemeral.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MalibuAccrualClientError.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MalibuAccrualClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(MalibuAccrualSummary.self, from: data)
    }
}
