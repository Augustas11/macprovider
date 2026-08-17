import Foundation

/// Coordinator-owned MALIBU reward eligibility reason model.
public struct MalibuRewardEligibility: Codable, Equatable, Sendable {
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
