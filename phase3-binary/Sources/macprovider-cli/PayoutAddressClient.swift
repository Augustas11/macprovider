import Foundation

/// Read model for GET /providers/{provider_id}/payout-address/challenge.
public struct PayoutChallenge: Codable, Equatable, Sendable {
    public let verifyingContract: String
    public let chainID: UInt64
    public let domainName: String
    public let domainVersion: String
    public let chain: String
    public let serverTsUTC: Int64
    public let registeredAddress: String?
    public let pendingUntilUTC: String?
    public let payoutAllowed: Bool?

    enum CodingKeys: String, CodingKey {
        case verifyingContract = "verifying_contract"
        case chainID = "chain_id"
        case domainName = "domain_name"
        case domainVersion = "domain_version"
        case chain
        case serverTsUTC = "server_ts_utc"
        case registeredAddress = "registered_address"
        case pendingUntilUTC = "pending_until_utc"
        case payoutAllowed = "payout_allowed"
    }
}

/// Success body for POST /providers/{provider_id}/payout-address.
public struct PayoutAddressRegistrationResult: Codable, Equatable, Sendable {
    public let chain: String
    public let pendingUntilUTC: String
    public let status: String
    public let httpStatus: Int

    enum CodingKeys: String, CodingKey {
        case chain
        case pendingUntilUTC = "pending_until_utc"
        case status
    }

    public init(chain: String, pendingUntilUTC: String, status: String, httpStatus: Int) {
        self.chain = chain
        self.pendingUntilUTC = pendingUntilUTC
        self.status = status
        self.httpStatus = httpStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chain = try c.decode(String.self, forKey: .chain)
        pendingUntilUTC = try c.decode(String.self, forKey: .pendingUntilUTC)
        status = try c.decode(String.self, forKey: .status)
        httpStatus = 0
    }
}

public enum PayoutAddressClientError: Error, Equatable, Sendable {
    case invalidCoordinatorURL
    case missingProviderID
    case missingBearer
    case httpStatus(Int, errorCode: String?)
    case unavailable
    case decodeFailed
}

/// Coordinator HTTP client for SPEC-016 §3 payout-address registration.
/// Named surface matches the brief's CoordinatorClient methods; lives as a
/// standalone client (same pattern as ProviderEarningsClient) so the CLI
/// subcommand and unit tests do not need the WebSocket actor.
struct PayoutAddressClient: Sendable {
    let providerID: String
    let challengeURL: URL
    let registerURL: URL
    private let session: URLSession?

    init(coordinatorURL: String?, providerID: String, session: URLSession? = nil) throws {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PayoutAddressClientError.missingProviderID }
        guard let urls = Self.endpoints(from: coordinatorURL, providerID: trimmed) else {
            throw PayoutAddressClientError.invalidCoordinatorURL
        }
        self.providerID = trimmed
        self.challengeURL = urls.challenge
        self.registerURL = urls.register
        self.session = session
    }

    init(challengeURL: URL, registerURL: URL, providerID: String, session: URLSession? = nil) {
        self.challengeURL = challengeURL
        self.registerURL = registerURL
        self.providerID = providerID
        self.session = session
    }

    static func endpoints(from coordinatorURL: String?, providerID: String) -> (challenge: URL, register: URL)? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        // TLS is mandatory: the provider_token travels as a Bearer
        // header to this URL, so a plaintext base would leak the
        // token (→ payout-address hijack). Only https / wss (which
        // upgrades to https) are accepted; ws / http and every other
        // scheme are rejected. Matches ClaimCommand.refreshURL and
        // AutotuneRecommend's https-only enforcement.
        switch components.scheme?.lowercased() {
        case "wss":
            components.scheme = "https"
        case "https":
            break
        default:
            return nil
        }
        guard components.host?.isEmpty == false else { return nil }
        let pathSegmentAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let escaped = providerID.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        components.percentEncodedPath = "/providers/\(escaped)/payout-address/challenge"
        guard let challenge = components.url else { return nil }
        components.percentEncodedPath = "/providers/\(escaped)/payout-address"
        guard let register = components.url else { return nil }
        return (challenge, register)
    }

    /// GET challenge — current hot-wallet verifyingContract for EIP-712 domain.
    func fetchPayoutChallenge(bearerToken: String) async throws -> PayoutChallenge {
        try Self.requireTLS(challengeURL)
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw PayoutAddressClientError.missingBearer }
        var request = URLRequest(url: challengeURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, http) = try await perform(request)
        guard (200..<300).contains(http.statusCode) else {
            throw PayoutAddressClientError.httpStatus(http.statusCode, errorCode: Self.errorCode(from: data))
        }
        do {
            return try JSONDecoder().decode(PayoutChallenge.self, from: data)
        } catch {
            throw PayoutAddressClientError.decodeFailed
        }
    }

    /// POST registration with EIP-712 proof-of-possession.
    func registerPayoutAddress(
        bearerToken: String,
        chain: String,
        address: String,
        nonce: String,
        tsUtc: UInt64,
        signature: String
    ) async throws -> PayoutAddressRegistrationResult {
        try Self.requireTLS(registerURL)
        let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw PayoutAddressClientError.missingBearer }
        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "chain": chain,
            "address": address,
            "nonce": nonce,
            "ts_utc": tsUtc,
            "signature": signature,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await perform(request)
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw PayoutAddressClientError.httpStatus(http.statusCode, errorCode: Self.errorCode(from: data))
        }
        do {
            var result = try JSONDecoder().decode(PayoutAddressRegistrationResult.self, from: data)
            result = PayoutAddressRegistrationResult(
                chain: result.chain,
                pendingUntilUTC: result.pendingUntilUTC,
                status: result.status,
                httpStatus: http.statusCode
            )
            return result
        } catch {
            throw PayoutAddressClientError.decodeFailed
        }
    }

    /// Fail-closed TLS gate applied BEFORE the bearer token is read
    /// or attached, so a plaintext (`http://`) endpoint can never
    /// exfiltrate the provider_token. Covers both the string-parsed
    /// (`endpoints`) and direct-URL initializers.
    static func requireTLS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw PayoutAddressClientError.invalidCoordinatorURL
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
            do {
                (data, response) = try await ephemeral.data(for: request)
            } catch {
                throw PayoutAddressClientError.unavailable
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw PayoutAddressClientError.unavailable
        }
        return (data, http)
    }

    static func errorCode(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["error"] as? String,
              !code.isEmpty
        else {
            return nil
        }
        return code
    }

    /// Map coordinator error responses to operator-facing copy for Malibu.
    static func userMessage(for error: PayoutAddressClientError) -> String {
        switch error {
        case .invalidCoordinatorURL:
            return "Coordinator URL is not configured."
        case .missingProviderID:
            return "Provider identity is missing from local config."
        case .missingBearer:
            return "Provider access token is unavailable."
        case .unavailable:
            return "Could not reach the coordinator. Check your network and try again."
        case .decodeFailed:
            return "Unexpected response from the coordinator."
        case let .httpStatus(code, errorCode):
            switch (code, errorCode) {
            case (400, "bad_format"): return "Wallet address format is invalid."
            case (400, "checksum_mismatch"): return "Wallet address checksum is invalid."
            case (400, "signature_mismatch"): return "Signature did not match the connected wallet."
            case (400, "signature_skew"): return "Signature timestamp is outside the allowed window. Try again."
            case (400, "nonce_replayed"): return "This signature was already used. Start again."
            case (400, "denylist"): return "This address cannot be registered."
            case (400, "missing_field"): return "Registration request was incomplete."
            case (400, let c): return "Registration rejected (\(c ?? "bad_request"))."
            case (401, _): return "Provider access token was rejected. Repair saved access."
            case (403, _): return "This provider token cannot register a wallet for that identity."
            case (409, _): return "Payouts are not yet enabled by the operator for this provider."
            case (429, _): return "Too many registration attempts. Wait and try again."
            case (503, _): return "Hot-wallet rotation is in progress. Retry later."
            default: return "Registration failed (HTTP \(code)\(errorCode.map { ": \($0)" } ?? ""))."
            }
        }
    }
}
