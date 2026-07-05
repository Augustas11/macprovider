import CryptoKit
import Foundation
import Security

enum CanonicalJSONError: Error {
    case nonFiniteNumber
    case invalidStringEncoding
}

enum CanonicalJSONValue: Equatable {
    case object([String: CanonicalJSONValue])
    case array([CanonicalJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

enum CanonicalJSON {
    static func encode(_ value: CanonicalJSONValue) throws -> Data {
        let text = try canonicalString(value)
        guard let data = text.data(using: .utf8) else {
            throw CanonicalJSONError.invalidStringEncoding
        }
        return data
    }

    static func canonicalString(_ value: CanonicalJSONValue) throws -> String {
        switch value {
        case let .object(dict):
            let pairs = try dict.keys.sorted(by: utf16LessThan).map { key in
                try "\(quote(key)):\(canonicalString(dict[key]!))"
            }
            return "{\(pairs.joined(separator: ","))}"
        case let .array(values):
            return try "[\(values.map { try canonicalString($0) }.joined(separator: ","))]"
        case let .string(value):
            return try quote(value.precomposedStringWithCanonicalMapping)
        case let .number(value):
            return value
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    static func quote(_ raw: String) throws -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5c: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0c: out += "\\f"
            case 0x0a: out += "\\n"
            case 0x0d: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1f:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    private static func utf16LessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }
}

struct RegisterRequest: Equatable {
    let providerID: String
    let identityPubkey: String
    let hardwareSummary: [String: String]
    let appAttestObject: String?
    let appAttestKeyID: String?
    let nonce: String
    let timestampUTC: String
    let signature: String

    var jsonObject: [String: Any] {
        [
            "provider_id": providerID,
            "identity_pubkey": identityPubkey,
            "hardware_summary": hardwareSummary,
            "app_attest_object": appAttestObject ?? NSNull(),
            "app_attest_key_id": appAttestKeyID ?? NSNull(),
            "nonce": nonce,
            "ts_utc": timestampUTC,
            "signature": signature
        ]
    }

    var fieldNames: Set<String> {
        Set(jsonObject.keys)
    }
}

struct RegisterResponse: Decodable, Equatable {
    let providerID: String
    let providerToken: String
    let trustTier: String
    let coordinatorWebSocketURL: URL

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case providerToken = "provider_token"
        case trustTier = "trust_tier"
        case coordinatorWebSocketURL = "coordinator_ws_url"
    }
}

struct RegisterClient {
	let coordinatorBaseURL: URL
	private let session: URLSession?

	init(coordinatorBaseURL: URL, session: URLSession? = nil) {
		self.coordinatorBaseURL = coordinatorBaseURL
		self.session = session
	}

    func makeSignedRequest(
        identityKey: Curve25519.Signing.PrivateKey,
        hardwareSummary: [String: String] = Self.currentHardwareSummary(),
        appAttestObject: Data? = nil,
        appAttestKeyID: Data? = nil,
        nonce: String = Self.makeNonce(),
        timestamp: Date = Date()
    ) throws -> RegisterRequest {
        let providerID = ProviderIdentity.providerID(for: identityKey)
        let timestampUTC = Self.rfc3339UTC(timestamp)
        let body = Self.unsignedBody(
            providerID: providerID,
            identityPubkey: identityKey.publicKey.rawRepresentation.base64EncodedString(),
            hardwareSummary: hardwareSummary,
            appAttestObject: appAttestObject?.base64EncodedString(),
            appAttestKeyID: appAttestKeyID?.base64EncodedString(),
            nonce: nonce,
            timestampUTC: timestampUTC
        )
        let canonical = try CanonicalJSON.encode(body)
        let signature = try ProviderIdentity.sign(canonical, using: identityKey).base64EncodedString()
        return RegisterRequest(
            providerID: providerID,
            identityPubkey: identityKey.publicKey.rawRepresentation.base64EncodedString(),
            hardwareSummary: hardwareSummary,
            appAttestObject: appAttestObject?.base64EncodedString(),
            appAttestKeyID: appAttestKeyID?.base64EncodedString(),
            nonce: nonce,
            timestampUTC: timestampUTC,
            signature: signature
        )
    }

    func postRegister(_ requestBody: RegisterRequest, bearerProof: String? = nil) async throws -> RegisterResponse {
        var request = URLRequest(url: coordinatorBaseURL.appendingPathComponent("v1/providers/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerProof {
            request.setValue("Bearer \(bearerProof)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody.jsonObject, options: [.sortedKeys])

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
			throw RegisterClientError.httpStatus(http.statusCode)
		}
        let decoded = try JSONDecoder().decode(RegisterResponse.self, from: data)
        try Self.validateCoordinatorWSURL(decoded.coordinatorWebSocketURL, expectedBase: coordinatorBaseURL)
        return decoded
    }

    /// Validate that the register response's coordinator_ws_url is same-origin
    /// with the registrar the App used. Guards against a compromised register
    /// endpoint (or MITM able to tamper with the response body) steering the
    /// provider bearer token to an attacker-controlled WebSocket origin.
    static func validateCoordinatorWSURL(_ url: URL, expectedBase: URL) throws {
        let expectedScheme: String
        switch expectedBase.scheme?.lowercased() {
        case "https": expectedScheme = "wss"
        case "http": expectedScheme = "ws"
        default:
            throw RegisterClientError.invalidCoordinatorWSURL(
                reason: "expected base URL scheme must be http(s)"
            )
        }
        guard let scheme = url.scheme?.lowercased(), scheme == expectedScheme else {
            throw RegisterClientError.invalidCoordinatorWSURL(
                reason: "scheme must be \(expectedScheme), got \(url.scheme ?? "<nil>")"
            )
        }
        guard let host = url.host?.lowercased(),
              let expectedHost = expectedBase.host?.lowercased(),
              host == expectedHost else {
            throw RegisterClientError.invalidCoordinatorWSURL(
                reason: "host must be \(expectedBase.host ?? "<nil>"), got \(url.host ?? "<nil>")"
            )
        }
        let defaultExpectedPort = expectedScheme == "wss" ? 443 : 80
        let expectedPort = expectedBase.port ?? (expectedScheme == "wss" ? 443 : 80)
        let actualPort = url.port ?? defaultExpectedPort
        guard actualPort == expectedPort else {
            throw RegisterClientError.invalidCoordinatorWSURL(
                reason: "port must be \(expectedPort), got \(actualPort)"
            )
        }
        guard url.user == nil, url.password == nil else {
            throw RegisterClientError.invalidCoordinatorWSURL(
                reason: "userinfo is not permitted"
            )
        }
        guard !url.path.isEmpty else {
            throw RegisterClientError.invalidCoordinatorWSURL(
                reason: "path must be non-empty"
            )
        }
    }

    static func canonicalRegisterPayloadWithoutSignature(_ request: RegisterRequest) throws -> Data {
        try CanonicalJSON.encode(unsignedBody(
            providerID: request.providerID,
            identityPubkey: request.identityPubkey,
            hardwareSummary: request.hardwareSummary,
            appAttestObject: request.appAttestObject,
            appAttestKeyID: request.appAttestKeyID,
            nonce: request.nonce,
            timestampUTC: request.timestampUTC
        ))
    }

    static func identitySignaturePayload(
        authAttemptID: String,
        providerID: String,
        binaryVersion: String,
        providerECDHPublicKey: String,
        transcriptSHA256: String
    ) throws -> Data {
        try CanonicalJSON.encode(.object([
            "auth_attempt_id": .string(authAttemptID),
            "provider_id": .string(providerID),
            "binary_version": .string(binaryVersion),
            "provider_ecdh_public_key": .string(providerECDHPublicKey),
            "transcript_sha256": .string(transcriptSHA256)
        ]))
    }

    static func currentHardwareSummary() -> [String: String] {
        let info = ProcessInfo.processInfo
        let version = OperatingSystemVersion(
            majorVersion: info.operatingSystemVersion.majorVersion,
            minorVersion: info.operatingSystemVersion.minorVersion,
            patchVersion: info.operatingSystemVersion.patchVersion
        )
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return [
            "chip": "Apple Silicon",
            "unified_memory_gb": String(max(1, info.physicalMemory / 1_073_741_824)),
            "macos_version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "app_version": appVersion
        ]
    }

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func rfc3339UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func unsignedBody(
        providerID: String,
        identityPubkey: String,
        hardwareSummary: [String: String],
        appAttestObject: String?,
        appAttestKeyID: String?,
        nonce: String,
        timestampUTC: String
    ) -> CanonicalJSONValue {
        .object([
            "provider_id": .string(providerID),
            "identity_pubkey": .string(identityPubkey),
            "hardware_summary": .object(hardwareSummary.mapValues { .string($0) }),
            "app_attest_object": appAttestObject.map(CanonicalJSONValue.string) ?? .null,
            "app_attest_key_id": appAttestKeyID.map(CanonicalJSONValue.string) ?? .null,
            "nonce": .string(nonce),
            "ts_utc": .string(timestampUTC)
        ])
    }
}

enum RegisterClientError: Error, Equatable {
    case httpStatus(Int)
    case invalidCoordinatorWSURL(reason: String)
}

enum ProviderBearerURLSession {
    static func make() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: ProviderBearerRedirectGuard(), delegateQueue: nil)
    }
}

final class ProviderBearerRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let newURL = request.url,
              let originalOrigin = Self.origin(for: originalURL),
              let newOrigin = Self.origin(for: newURL),
              originalOrigin.scheme == "https",
              newOrigin.scheme == "https"
        else {
            completionHandler(nil)
            return
        }
        guard originalOrigin != newOrigin else {
            completionHandler(request)
            return
        }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(stripped)
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    private static func origin(for url: URL) -> Origin? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else {
            return nil
        }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return Origin(scheme: scheme, host: host, port: port)
    }
}
