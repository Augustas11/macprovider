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

struct RegisterRequest: Codable, Equatable {
    let providerID: String
    let identityPubkey: String
    let hardwareSummary: [String: String]
    let appAttestObject: String?
    let appAttestKeyID: String?
    let referralCode: String?
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
            "referral_code": referralCode ?? NSNull(),
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
        referralCode: String? = nil,
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
            referralCode: referralCode,
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
            referralCode: referralCode,
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
            referralCode: request.referralCode,
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
        referralCode: String?,
        nonce: String,
        timestampUTC: String
    ) -> CanonicalJSONValue {
        .object([
            "provider_id": .string(providerID),
            "identity_pubkey": .string(identityPubkey),
            "hardware_summary": .object(hardwareSummary.mapValues { .string($0) }),
            "app_attest_object": appAttestObject.map(CanonicalJSONValue.string) ?? .null,
            "app_attest_key_id": appAttestKeyID.map(CanonicalJSONValue.string) ?? .null,
            "referral_code": referralCode.map(CanonicalJSONValue.string) ?? .null,
            "nonce": .string(nonce),
            "ts_utc": .string(timestampUTC)
        ])
    }
}

enum RegisterClientError: Error, Equatable {
    case httpStatus(Int)
    case invalidCoordinatorWSURL(reason: String)
    case noPersistedAttempt
}

// PROD-H5: a signed register attempt persisted durably so a lost response or an
// app restart does not force a re-sign. Re-signing shifts the timestamp/nonce,
// which the coordinator's ±60s skew window and post-recovery cooldown reject;
// replaying the EXACT persisted bytes is what the coordinator (Go lane) exempts
// from ordinary skew/cooldown for a committed attempt. The attempt is cleared
// only after the returned bearer is durably installed, so recovery survives
// across restarts.
struct PendingRegisterAttempt: Codable, Equatable {
    let request: RegisterRequest
    let bearerProof: String?
    let coordinatorBaseURL: URL
    let createdAt: Date
}

enum PendingRegisterAttemptStore {
    static func fileURL(paths: ProviderPaths = .current) -> URL {
        paths.appSupport.appendingPathComponent("pending-register-attempt.json")
    }

    static func save(_ attempt: PendingRegisterAttempt, paths: ProviderPaths = .current) throws {
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(attempt)
        let url = fileURL(paths: paths)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(paths: ProviderPaths = .current) -> PendingRegisterAttempt? {
        guard let data = try? Data(contentsOf: fileURL(paths: paths)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingRegisterAttempt.self, from: data)
    }

    static func clear(paths: ProviderPaths = .current) {
        try? FileManager.default.removeItem(at: fileURL(paths: paths))
    }

    static func hasPending(paths: ProviderPaths = .current) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(paths: paths).path)
    }
}

extension RegisterClient {
    /// PROD-H5: register durably. Persists the exact signed attempt BEFORE the
    /// first send so a lost response or crash leaves a recoverable committed
    /// attempt, sends it, and clears it only after `installBearer` durably
    /// stores the returned credential. If installing the bearer fails, the
    /// attempt is deliberately left on disk so the next launch can replay it.
    @discardableResult
    func registerDurably(
        _ request: RegisterRequest,
        bearerProof: String? = nil,
        paths: ProviderPaths = .current,
        installBearer: (RegisterResponse) async throws -> Void
    ) async throws -> RegisterResponse {
        let attempt = PendingRegisterAttempt(
            request: request,
            bearerProof: bearerProof,
            coordinatorBaseURL: coordinatorBaseURL,
            createdAt: Date()
        )
        try PendingRegisterAttemptStore.save(attempt, paths: paths)
        return try await completePersistedRegister(paths: paths, installBearer: installBearer)
    }

    /// Replays a persisted attempt (if any) against its original coordinator and
    /// installs the credential, clearing the attempt on success. Returns nil
    /// when there is nothing to recover. Call on app launch to re-drive a
    /// register whose response was lost before the bearer was installed —
    /// replaying the identical signed bytes across the restart.
    @discardableResult
    func recoverPersistedRegister(
        paths: ProviderPaths = .current,
        installBearer: (RegisterResponse) async throws -> Void
    ) async throws -> RegisterResponse? {
        guard PendingRegisterAttemptStore.hasPending(paths: paths) else { return nil }
        return try await completePersistedRegister(paths: paths, installBearer: installBearer)
    }

    private func completePersistedRegister(
        paths: ProviderPaths,
        installBearer: (RegisterResponse) async throws -> Void
    ) async throws -> RegisterResponse {
        guard let attempt = PendingRegisterAttemptStore.load(paths: paths) else {
            throw RegisterClientError.noPersistedAttempt
        }
        // Replay against the coordinator the attempt was signed for; reuse this
        // client's injected session so tests and redirect-guarding are honored.
        let client = attempt.coordinatorBaseURL == coordinatorBaseURL
            ? self
            : RegisterClient(coordinatorBaseURL: attempt.coordinatorBaseURL, session: session)
        let response = try await client.postRegister(attempt.request, bearerProof: attempt.bearerProof)
        try await installBearer(response)
        PendingRegisterAttemptStore.clear(paths: paths)
        return response
    }
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
