import Foundation

/// Last-confirmed coordinator `true` survives indeterminate `/v1/pool/check`
/// results (timeout, 404, 429-exhaustion). Authoritative `false` still demotes.
enum CoordinatorBuyerServingHold {
    static func resolve(
        latest: Bool?,
        lastConfirmedTrue: Bool
    ) -> (verdict: Bool?, lastConfirmedTrue: Bool) {
        switch latest {
        case .some(true):
            return (true, true)
        case .some(false):
            return (false, false)
        case .none:
            return lastConfirmedTrue ? (true, true) : (nil, false)
        }
    }
}

/// Reads the coordinator's buyer-routing verdict. A provider WebSocket session
/// proves transport, while this endpoint applies the coordinator's full pool,
/// catalog, capacity, and routing eligibility checks.
enum CoordinatorReadinessClient {
    /// Closed coordinator reasons for `buyer_serving: false` that an accepted
    /// session must be HELD through rather than dropped and reconnected.
    enum BuyerServingHold: String, Equatable, Sendable {
        /// SPEC-047-R003(iv): the session is bound to a BYOM candidate whose
        /// admission is pending (`offer_submitted` … `catalog_priced`). Buyer
        /// serving needs `settlement_capable`, and `settlement_capable` needs
        /// THIS live session to stay bound and hash-verified at approval time;
        /// SPEC-047-R006 clears the binding on every disconnect. The
        /// coordinator derives the hold from its registry binding and the
        /// admission store; it is never provider-asserted.
        case modelAdmissionPending = "model_admission_pending"
        /// SPEC-022-R002 R-2.7 / SPEC-001 v1.9.21: verified-model settlement is
        /// in `enforce` and the network Tier-2 catalog carries no route-snapshot
        /// material for the served model, so the coordinator cannot route
        /// buyers to it. Only a catalog update clears it; reconnecting cannot.
        /// The coordinator names it only to a session that advertised
        /// `tier2_capabilities.catalog_material_hold_v1`.
        case catalogMaterialMissing = "catalog_material_missing"
    }

    /// The coordinator's buyer-routing verdict for one accepted session.
    /// `nil`/`false`/`true` literals keep the three-valued `Bool?` reading
    /// (indeterminate / authoritative not-serving / confirmed) that every
    /// existing consumer relies on; only `notServing` can carry a hold.
    enum Readiness: Equatable, Sendable, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
        case confirmed
        case notServing(hold: BuyerServingHold?)
        case indeterminate

        init(booleanLiteral value: Bool) {
            self = value ? .confirmed : .notServing(hold: nil)
        }

        init(nilLiteral: ()) {
            self = .indeterminate
        }

        /// Lift a plain three-valued verdict (no hold information).
        init(buyerServing: Bool?) {
            switch buyerServing {
            case .some(true): self = .confirmed
            case .some(false): self = .notServing(hold: nil)
            case .none: self = .indeterminate
            }
        }

        var buyerServing: Bool? {
            switch self {
            case .confirmed: return true
            case .notServing: return false
            case .indeterminate: return nil
            }
        }
    }

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
        await fetchReadiness(
            coordinatorURL: coordinatorURL,
            providerID: providerID,
            assignedID: assignedID,
            expected: expected,
            timeout: timeout,
            session: session
        ).buyerServing
    }

    static func fetchReadiness(
        coordinatorURL: String?,
        providerID: String?,
        assignedID: String?,
        expected: ExpectedCatalogEnvelope? = nil,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async -> Readiness {
        guard let providerID = providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let assignedID = assignedID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = readinessURL(
                  coordinatorURL: coordinatorURL,
                  providerID: providerID,
                  assignedID: assignedID
              )
        else {
            return .indeterminate
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
                return readiness(
                    data: data,
                    response: response,
                    requestURL: url,
                    providerID: providerID,
                    assignedID: assignedID,
                    expected: expected
                )
            } catch {
                return .indeterminate
            }
        }
        return .indeterminate
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
        readiness(
            data: data,
            response: response,
            requestURL: requestURL,
            providerID: providerID,
            assignedID: assignedID,
            expected: expected
        ).buyerServing
    }

    static func readiness(
        data: Data,
        response: URLResponse,
        requestURL: URL,
        providerID: String,
        assignedID: String,
        expected: ExpectedCatalogEnvelope? = nil
    ) -> Readiness {
        guard let http = response as? HTTPURLResponse,
              // URLSession follows redirects by default. Only the exact
              // coordinator endpoint requested is authoritative.
              http.url == requestURL
        else {
            return .indeterminate
        }
        // A 404 here usually means the coordinator no longer has the specific
        // assigned session the app last observed (for example immediately after
        // a coordinator drain/restart or provider reconnect). Treat that as an
        // indeterminate readiness refresh instead of authoritative
        // not_buyer_serving so Malibu does not tell a verified provider it is
        // ineligible during assigned_id churn.
        if http.statusCode == 404 { return .indeterminate }
        guard (200 ..< 300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["provider_id"] as? String == providerID,
              object["assigned_id"] as? String == assignedID,
              object["catalog_evidence_source"] as? String == "provider_reported",
              let buyerServing = object["buyer_serving"] as? Bool
        else {
            return .indeterminate
        }
        guard buyerServing else {
            // The hold is meaningful only on an authoritative `false`; an
            // unknown value is no hold (fail closed to the reconnect path).
            let hold = (object["buyer_serving_hold"] as? String).flatMap(BuyerServingHold.init(rawValue:))
            return .notServing(hold: hold)
        }
        guard let admissionMode = object["catalog_admission_mode"] as? String,
              admissionMode == "current" || admissionMode == "previous"
        else {
            return .indeterminate
        }
        if let expected {
            guard object["catalog_release_id"] as? String == expected.releaseID,
                  object["catalog_policy_version"] as? String == expected.policyVersion,
                  normalizedDigest(object["catalog_candidate_sha256"] as? String) == normalizedDigest(expected.candidateSHA256),
                  object["catalog_signer_key_id"] as? String == expected.signerKeyID,
                  normalizedDigest(object["catalog_row_identity"] as? String) == normalizedDigest(expected.rowIdentity)
            else {
                return .indeterminate
            }
        }
        return .confirmed
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
