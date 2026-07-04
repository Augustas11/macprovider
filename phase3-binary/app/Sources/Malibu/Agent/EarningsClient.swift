import Foundation

struct ProviderEarnings: Decodable, Equatable {
    let walletBound: Bool
    let trustTier: AgentSnapshot.TrustTier
    let unpaidLedgerBacklogUSDC: Double
    let unpaidLedgerBacklogMALIBU: Double

    enum CodingKeys: String, CodingKey {
        case walletBound = "wallet_bound"
        case trustTier = "trust_tier"
        case unpaidLedgerBacklogUSDC = "unpaid_ledger_backlog_usdc"
        case unpaidLedgerBacklogMALIBU = "unpaid_ledger_backlog_malibu"
    }
}

struct EarningsClient {
    let coordinatorBaseURL: URL
    let session: URLSession

    init(
        coordinatorBaseURL: URL = URL(string: "https://coordinator.streamvc.live")!,
        session: URLSession = .shared
    ) {
        self.coordinatorBaseURL = coordinatorBaseURL
        self.session = session
    }

    func fetch(providerID: String, bearerToken: String) async throws -> ProviderEarnings {
        let escapedProviderID = providerID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerID
        let url = coordinatorBaseURL
            .appendingPathComponent("providers")
            .appendingPathComponent(escapedProviderID)
            .appendingPathComponent("earnings")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EarningsClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(ProviderEarnings.self, from: data)
    }
}

enum EarningsClientError: Error {
    case httpStatus(Int)
}

enum UnclaimedBadgePolicy {
    static let thresholds: [Double] = [1, 10, 100]

    static func visibleThreshold(totalBacklog: Double, dismissedThreshold: Double?) -> Double? {
        thresholds.first { threshold in
            totalBacklog >= threshold && threshold > (dismissedThreshold ?? 0)
        }
    }

    static func nextDismissedThreshold(totalBacklog: Double) -> Double? {
        thresholds.last { totalBacklog >= $0 }
    }
}
