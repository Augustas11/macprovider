import Foundation

/// Provider-facing MALIBU accrual read model from GET /v1/provider/malibu-accrual (SPEC-MALIBU-EMISSION-LEDGER §5).
struct MalibuAccrualSummary: Decodable, Equatable {
    let accruedMALIBU: Double
    let withdrawableMALIBU: Double
    let heldMALIBU: Double
    let trustTier: AgentSnapshot.TrustTier
    let trustCriteriaMet: Int?
    let trustCriteriaRequired: Int?
    let walletBound: Bool?

    enum CodingKeys: String, CodingKey {
        case accruedMALIBU = "accrued_malibu"
        case withdrawableMALIBU = "withdrawable_malibu"
        case heldMALIBU = "held_malibu"
        case trustTier = "trust_tier"
        case trustCriteriaMet = "trust_criteria_met"
        case trustCriteriaRequired = "trust_criteria_required"
        case walletBound = "wallet_bound"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accruedMALIBU = try Self.decodeDecimal(c, key: .accruedMALIBU)
        withdrawableMALIBU = try Self.decodeDecimal(c, key: .withdrawableMALIBU)
        heldMALIBU = try Self.decodeDecimal(c, key: .heldMALIBU)
        trustTier = try c.decodeIfPresent(AgentSnapshot.TrustTier.self, forKey: .trustTier) ?? .provisional
        trustCriteriaMet = try c.decodeIfPresent(Int.self, forKey: .trustCriteriaMet)
        trustCriteriaRequired = try c.decodeIfPresent(Int.self, forKey: .trustCriteriaRequired)
        walletBound = try c.decodeIfPresent(Bool.self, forKey: .walletBound)
    }

    private static func decodeDecimal(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Double {
        guard c.contains(key) else { return 0 }
        if let value = try? c.decode(Double.self, forKey: key) {
            return value
        }
        if let text = try? c.decode(String.self, forKey: key) {
            return Double(text) ?? 0
        }
        return 0
    }
}

enum MalibuAccrualClientError: Error {
    case httpStatus(Int)
}

struct MalibuAccrualClient {
    let coordinatorBaseURL: URL
    private let session: URLSession?

    init(
        coordinatorBaseURL: URL = URL(string: "https://coordinator.streamvc.live")!,
        session: URLSession? = nil
    ) {
        self.coordinatorBaseURL = coordinatorBaseURL
        self.session = session
    }

    func fetch(bearerToken: String) async throws -> MalibuAccrualSummary {
        let url = coordinatorBaseURL.appendingPathComponent("v1/provider/malibu-accrual")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        if let session {
            (data, response) = try await session.data(for: request)
        } else {
            let guarded = ProviderBearerURLSession.make()
            defer { guarded.finishTasksAndInvalidate() }
            (data, response) = try await guarded.data(for: request)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MalibuAccrualClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(MalibuAccrualSummary.self, from: data)
    }
}
