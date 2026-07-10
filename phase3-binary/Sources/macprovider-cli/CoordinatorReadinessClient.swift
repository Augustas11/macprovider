import Foundation

/// Reads the coordinator's buyer-routing verdict. A provider WebSocket session
/// proves transport, while this endpoint applies the coordinator's full pool,
/// catalog, capacity, and routing eligibility checks.
enum CoordinatorReadinessClient {
    static func readinessURL(coordinatorURL: String?, providerID: String?) -> URL? {
        guard let coordinatorURL,
              let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty,
              var components = URLComponents(string: coordinatorURL),
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased()
        else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "wss", "https":
            components.scheme = "https"
        case "ws" where host == "localhost" || host == "127.0.0.1" || host == "::1",
             "http" where host == "localhost" || host == "127.0.0.1" || host == "::1":
            components.scheme = "http"
        default:
            return nil
        }
        components.path = "/v1/pool/check"
        components.queryItems = [
            URLQueryItem(name: "provider_id", value: providerID),
            URLQueryItem(name: "details", value: "readiness"),
        ]
        components.fragment = nil
        return components.url
    }

    static func fetch(
        coordinatorURL: String?,
        providerID: String?,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> Bool? {
        guard let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = readinessURL(coordinatorURL: coordinatorURL, providerID: providerID)
        else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for attempt in 0 ..< 2 {
            do {
                let (data, response) = try await session.data(for: request)
                if attempt == 0,
                   let http = response as? HTTPURLResponse,
                   http.url == url,
                   http.statusCode == 429 {
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds(
                        providerID: providerID,
                        retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                    ))
                    continue
                }
                return verdict(data: data, response: response, requestURL: url, providerID: providerID)
            } catch {
                return nil
            }
        }
        return nil
    }

    static func retryDelayNanoseconds(providerID: String, retryAfterHeader: String?) -> UInt64 {
        let retryAfter = min(max(Double(retryAfterHeader ?? "") ?? 1, 0.1), 2)
        // Stable provider-scoped jitter prevents synchronized providers behind
        // one NAT from retrying on the same boundary.
        let hash = providerID.utf8.reduce(UInt64(1469598103934665603)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        let jitter = Double(50 + (hash % 251)) / 1_000
        return UInt64((retryAfter + jitter) * 1_000_000_000)
    }

    static func verdict(
        data: Data,
        response: URLResponse,
        requestURL: URL,
        providerID: String
    ) -> Bool? {
        guard let http = response as? HTTPURLResponse,
              // URLSession follows redirects by default. Only the exact
              // coordinator endpoint requested is authoritative.
              http.url == requestURL
        else {
            return nil
        }
        if http.statusCode == 404 { return false }
        guard (200 ..< 300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["provider_id"] as? String == providerID,
              object["catalog_evidence_source"] as? String == "provider_reported",
              let buyerServing = object["buyer_serving"] as? Bool
        else {
            return nil
        }
        guard buyerServing else { return false }
        guard let admissionMode = object["catalog_admission_mode"] as? String,
              admissionMode == "current" || admissionMode == "previous"
        else {
            return nil
        }
        return true
    }
}
