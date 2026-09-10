import Foundation

/// Read-only, provider-authenticated access to the coordinator reward audit.
/// This is deliberately separate from the wallet status projection: a history
/// page can fail or be rate-limited without changing eligibility or balances.
struct ProviderRewardAuditClient: Sendable {
    let auditURL: URL
    private let session: URLSession?

    init(coordinatorURL: String?, session: URLSession? = nil) throws {
        guard let url = Self.auditURL(from: coordinatorURL) else {
            throw ProviderRewardAuditClientError.invalidCoordinatorURL
        }
        auditURL = url
        self.session = session
    }

    init(auditURL: URL, session: URLSession? = nil) {
        self.auditURL = auditURL
        self.session = session
    }

    static func auditURL(from coordinatorURL: String?) -> URL? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL) else {
            return nil
        }
        switch components.scheme {
        case "wss": components.scheme = "https"
        case "https": break
        default: return nil
        }
        components.path = "/v1/provider/malibu-reward-audit"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func fetch(
        bearerToken: String,
        beforeID: String? = nil,
        limit: Int = 10
    ) async throws -> ProviderWalletAuditPageSummary {
        guard (1...100).contains(limit) else {
            throw ProviderRewardAuditClientError.invalidPageRequest
        }
        let beforeID = beforeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let beforeID, !Self.isValidCursor(beforeID) {
            throw ProviderRewardAuditClientError.invalidPageRequest
        }
        guard var components = URLComponents(url: auditURL, resolvingAgainstBaseURL: false) else {
            throw ProviderRewardAuditClientError.invalidCoordinatorURL
        }
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let beforeID { items.append(URLQueryItem(name: "before_id", value: beforeID)) }
        components.queryItems = items
        guard let url = components.url else {
            throw ProviderRewardAuditClientError.invalidCoordinatorURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
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
        } catch {
            try Task.checkCancellation()
            throw ProviderRewardAuditClientError.unavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderRewardAuditClientError.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderRewardAuditClientError.httpStatus(
                http.statusCode,
                retryAfterSeconds: retryAfterSeconds(http)
            )
        }
        let page: ProviderWalletAuditPageSummary
        do {
            page = try JSONDecoder().decode(ProviderWalletAuditPageSummary.self, from: data)
        } catch {
            throw ProviderRewardAuditClientError.invalidResponse
        }
        if let cursor = page.nextBeforeID, !Self.isValidCursor(cursor) {
            throw ProviderRewardAuditClientError.invalidResponse
        }
        return page
    }

    private static func isValidCursor(_ value: String) -> Bool {
        guard value.hasPrefix("mra_"),
              let id = Int64(value.dropFirst(4)) else { return false }
        return id > 0 && value == "mra_\(id)"
    }

    private func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(raw), (0...86_400).contains(seconds) else { return nil }
        return seconds
    }
}

enum ProviderRewardAuditClientError: Error, Equatable {
    case invalidCoordinatorURL
    case invalidPageRequest
    case invalidResponse
    case httpStatus(Int, retryAfterSeconds: Int?)
    case unavailable
}
