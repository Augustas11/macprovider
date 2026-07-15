import Foundation

/// Provider-facing read model returned by GET /providers/{provider_id}/earnings.
/// The CLI owns the provider bearer and exposes this non-secret projection to
/// same-user local clients over the 0600 control socket.
public struct ProviderEarningsSummary: Codable, Equatable, Sendable {
    public let walletBound: Bool
    public let trustTier: String
    public let unpaidLedgerBacklogUSDC: Double
    public let unpaidLedgerBacklogMALIBU: Double
    public let usdcToday: Double?
    public let usdcWeek: Double?
    public let usdcPending: Double?
    public let usdcLifetime: Double?
    public let malibuToday: Double?
    public let malibuAllTime: Double?
    public let trustCriteriaMet: Int?
    public let trustCriteriaRequired: Int?

    enum CodingKeys: String, CodingKey {
        case walletBound = "wallet_bound"
        case trustTier = "trust_tier"
        case unpaidLedgerBacklogUSDC = "unpaid_ledger_backlog_usdc"
        case unpaidLedgerBacklogMALIBU = "unpaid_ledger_backlog_malibu"
        case usdcToday = "usdc_today"
        case usdcWeek = "usdc_week"
        case usdcPending = "usdc_pending"
        case usdcLifetime = "usdc_lifetime"
        case malibuToday = "malibu_today"
        case malibuAllTime = "malibu_all_time"
        case trustCriteriaMet = "trust_criteria_met"
        case trustCriteriaRequired = "trust_criteria_required"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walletBound = try container.decodeIfPresent(Bool.self, forKey: .walletBound) ?? false
        trustTier = try container.decodeIfPresent(String.self, forKey: .trustTier) ?? "provisional"
        unpaidLedgerBacklogUSDC = try container.decodeIfPresent(
            Double.self,
            forKey: .unpaidLedgerBacklogUSDC
        ) ?? 0
        unpaidLedgerBacklogMALIBU = try container.decodeIfPresent(
            Double.self,
            forKey: .unpaidLedgerBacklogMALIBU
        ) ?? 0
        usdcToday = try container.decodeIfPresent(Double.self, forKey: .usdcToday)
        usdcWeek = try container.decodeIfPresent(Double.self, forKey: .usdcWeek)
        usdcPending = try container.decodeIfPresent(Double.self, forKey: .usdcPending)
        usdcLifetime = try container.decodeIfPresent(Double.self, forKey: .usdcLifetime)
        malibuToday = try container.decodeIfPresent(Double.self, forKey: .malibuToday)
        malibuAllTime = try container.decodeIfPresent(Double.self, forKey: .malibuAllTime)
        trustCriteriaMet = try container.decodeIfPresent(Int.self, forKey: .trustCriteriaMet)
        trustCriteriaRequired = try container.decodeIfPresent(Int.self, forKey: .trustCriteriaRequired)
    }

    public init(
        walletBound: Bool,
        trustTier: String,
        unpaidLedgerBacklogUSDC: Double,
        unpaidLedgerBacklogMALIBU: Double,
        usdcToday: Double?,
        usdcWeek: Double?,
        usdcPending: Double?,
        usdcLifetime: Double?,
        malibuToday: Double?,
        malibuAllTime: Double?,
        trustCriteriaMet: Int?,
        trustCriteriaRequired: Int?
    ) {
        self.walletBound = walletBound
        self.trustTier = trustTier
        self.unpaidLedgerBacklogUSDC = unpaidLedgerBacklogUSDC
        self.unpaidLedgerBacklogMALIBU = unpaidLedgerBacklogMALIBU
        self.usdcToday = usdcToday
        self.usdcWeek = usdcWeek
        self.usdcPending = usdcPending
        self.usdcLifetime = usdcLifetime
        self.malibuToday = malibuToday
        self.malibuAllTime = malibuAllTime
        self.trustCriteriaMet = trustCriteriaMet
        self.trustCriteriaRequired = trustCriteriaRequired
    }

    func merging(accrual: MalibuAccrualSummary) -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: accrual.walletBound ?? walletBound,
            trustTier: accrual.trustTier,
            unpaidLedgerBacklogUSDC: unpaidLedgerBacklogUSDC,
            unpaidLedgerBacklogMALIBU: unpaidLedgerBacklogMALIBU,
            usdcToday: usdcToday,
            usdcWeek: usdcWeek,
            usdcPending: usdcPending,
            usdcLifetime: usdcLifetime,
            malibuToday: malibuToday,
            malibuAllTime: accrual.accruedMALIBU,
            trustCriteriaMet: accrual.trustCriteriaMet ?? trustCriteriaMet,
            trustCriteriaRequired: accrual.trustCriteriaRequired ?? trustCriteriaRequired
        )
    }

    static func from(accrual: MalibuAccrualSummary) -> ProviderEarningsSummary {
        ProviderEarningsSummary(
            walletBound: accrual.walletBound ?? false,
            trustTier: accrual.trustTier,
            unpaidLedgerBacklogUSDC: 0,
            unpaidLedgerBacklogMALIBU: 0,
            usdcToday: nil,
            usdcWeek: nil,
            usdcPending: nil,
            usdcLifetime: nil,
            malibuToday: nil,
            malibuAllTime: accrual.accruedMALIBU,
            trustCriteriaMet: accrual.trustCriteriaMet,
            trustCriteriaRequired: accrual.trustCriteriaRequired
        )
    }
}

enum ProviderEarningsClientError: Error, Equatable {
    case invalidCoordinatorURL
    case httpStatus(Int)
    case unavailable
}

struct ProviderEarningsClient: Sendable {
    let earningsURL: URL
    private let session: URLSession?

    init(coordinatorURL: String?, providerID: String, session: URLSession? = nil) throws {
        guard let url = Self.earningsURL(from: coordinatorURL, providerID: providerID) else {
            throw ProviderEarningsClientError.invalidCoordinatorURL
        }
        self.earningsURL = url
        self.session = session
    }

    init(earningsURL: URL, session: URLSession? = nil) {
        self.earningsURL = earningsURL
        self.session = session
    }

    static func earningsURL(from coordinatorURL: String?, providerID: String) -> URL? {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty,
              let coordinatorURL,
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
        let pathSegmentAllowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        guard let escapedProviderID = trimmedProviderID.addingPercentEncoding(
            withAllowedCharacters: pathSegmentAllowed
        ) else {
            return nil
        }
        components.percentEncodedPath = "/providers/\(escapedProviderID)/earnings"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func fetch(bearerToken: String) async throws -> ProviderEarningsSummary {
        var request = URLRequest(url: earningsURL)
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
            throw ProviderEarningsClientError.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderEarningsClientError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(ProviderEarningsSummary.self, from: data)
    }
}
