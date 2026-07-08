import Foundation

/// Provider-facing MALIBU accrual read model from GET /v1/provider/malibu-accrual.
struct MalibuAccrualSummary: Decodable, Equatable, Sendable {
    let accruedMALIBU: Double
    let withdrawableMALIBU: Double
    let heldMALIBU: Double
    let trustTier: String
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
        trustTier = try c.decodeIfPresent(String.self, forKey: .trustTier) ?? "provisional"
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
            let ephemeral = URLSession(configuration: .ephemeral)
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
