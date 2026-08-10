import Foundation

/// Reads the coordinator's buyer-routing verdict. A provider WebSocket session
/// proves transport, while this endpoint applies the coordinator's full pool,
/// catalog, capacity, and routing eligibility checks.
enum CoordinatorReadinessClient {
    struct ExpectedCatalogEnvelope: Equatable, Sendable {
        let releaseID: String
        let policyVersion: String
        let candidateSHA256: String
        let signerKeyID: String
        let rowIdentity: String
    }

    static func readinessURL(
        coordinatorURL: String?,
        providerID: String?,
        assignedID: String?
    ) -> URL? {
        guard let coordinatorURL,
              let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty,
              let assignedID = assignedID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !assignedID.isEmpty,
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
            URLQueryItem(name: "assigned_id", value: assignedID),
            URLQueryItem(name: "details", value: "readiness"),
        ]
        components.fragment = nil
        return components.url
    }

    static func fetch(
        coordinatorURL: String?,
        providerID: String?,
        assignedID: String?,
        expected: ExpectedCatalogEnvelope? = nil,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> Bool? {
        guard let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let assignedID = assignedID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = readinessURL(
                  coordinatorURL: coordinatorURL,
                  providerID: providerID,
                  assignedID: assignedID
              )
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
                return verdict(
                    data: data,
                    response: response,
                    requestURL: url,
                    providerID: providerID,
                    assignedID: assignedID,
                    expected: expected
                )
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
        providerID: String,
        assignedID: String,
        expected: ExpectedCatalogEnvelope? = nil
    ) -> Bool? {
        guard let http = response as? HTTPURLResponse,
              // URLSession follows redirects by default. Only the exact
              // coordinator endpoint requested is authoritative.
              http.url == requestURL
        else {
            return nil
        }
        // A 404 here usually means the coordinator no longer has the specific
        // assigned session the app last observed (for example immediately after
        // a coordinator drain/restart or provider reconnect). Treat that as an
        // indeterminate readiness refresh instead of authoritative
        // not_buyer_serving so Malibu does not tell a verified provider it is
        // ineligible during assigned_id churn.
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["provider_id"] as? String == providerID,
              object["assigned_id"] as? String == assignedID,
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
        if let expected {
            guard object["catalog_release_id"] as? String == expected.releaseID,
                  object["catalog_policy_version"] as? String == expected.policyVersion,
                  normalizedDigest(object["catalog_candidate_sha256"] as? String) == normalizedDigest(expected.candidateSHA256),
                  object["catalog_signer_key_id"] as? String == expected.signerKeyID,
                  normalizedDigest(object["catalog_row_identity"] as? String) == normalizedDigest(expected.rowIdentity)
            else {
                return nil
            }
        }
        return true
    }

    private static func normalizedDigest(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              value.count == 64,
              value.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              })
        else {
            return nil
        }
        return value
    }
}
