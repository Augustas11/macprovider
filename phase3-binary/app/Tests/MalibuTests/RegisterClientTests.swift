import CryptoKit
import XCTest
@testable import Malibu

final class RegisterClientTests: XCTestCase {
    func testCanonicalJSONSortsByUTF16AndEscapesStrings() throws {
        let value: CanonicalJSONValue = .object([
            "z": .string("line\nbreak"),
            "a": .number("2"),
            "nested": .object(["b": .bool(true), "a": .null])
        ])
        let data = try CanonicalJSON.encode(value)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"a":2,"nested":{"a":null,"b":true},"z":"line\nbreak"}"#)
    }

    func testRegisterBodyUsesOnlySpecFieldsAndSignatureVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let client = RegisterClient(coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!)
        let request = try client.makeSignedRequest(
            identityKey: key,
            hardwareSummary: [
                "chip": "M3 Max",
                "unified_memory_gb": "64",
                "macos_version": "14.5",
                "app_version": "1.0.3"
            ],
            referralCode: "MAL1-S-k1-seed-TEST",
            nonce: String(repeating: "a", count: 64),
            timestamp: Date(timeIntervalSince1970: 1_783_082_460)
        )

        XCTAssertEqual(request.fieldNames, [
            "provider_id",
            "identity_pubkey",
            "hardware_summary",
            "app_attest_object",
            "app_attest_key_id",
            "referral_code",
            "nonce",
            "ts_utc",
            "signature"
        ])
        XCTAssertFalse(request.fieldNames.contains("binary_version"))
        XCTAssertFalse(request.fieldNames.contains("provider_name"))
        XCTAssertFalse(request.fieldNames.contains("signature_alg"))
        XCTAssertEqual(request.referralCode, "MAL1-S-k1-seed-TEST")

        let canonical = try RegisterClient.canonicalRegisterPayloadWithoutSignature(request)
        let signature = Data(base64Encoded: request.signature)
        XCTAssertNotNil(signature)
        XCTAssertTrue(key.publicKey.isValidSignature(signature!, for: canonical))
    }

    func testIdentitySignaturePayloadCanonicalShape() throws {
        let payload = try RegisterClient.identitySignaturePayload(
            authAttemptID: "auth-1",
            providerID: "p_abc",
            binaryVersion: "1.8.6",
            providerECDHPublicKey: "ecdh",
            transcriptSHA256: "hash"
        )
        XCTAssertEqual(
            String(data: payload, encoding: .utf8),
            #"{"auth_attempt_id":"auth-1","binary_version":"1.8.6","provider_ecdh_public_key":"ecdh","provider_id":"p_abc","transcript_sha256":"hash"}"#
        )
    }

    func testValidateCoordinatorWSURLAcceptsExpectedOrigin() throws {
        let base = URL(string: "https://coordinator.streamvc.live")!
        let ws = URL(string: "wss://coordinator.streamvc.live/v2/provider")!
        XCTAssertNoThrow(try RegisterClient.validateCoordinatorWSURL(ws, expectedBase: base))
    }

    func testValidateCoordinatorWSURLAcceptsExpectedOriginWithExplicitDefaultPort() throws {
        let base = URL(string: "https://coordinator.streamvc.live")!
        let ws = URL(string: "wss://coordinator.streamvc.live:443/v2/provider")!
        XCTAssertNoThrow(try RegisterClient.validateCoordinatorWSURL(ws, expectedBase: base))
    }

    func testValidateCoordinatorWSURLRejectsInsecureScheme() {
        let base = URL(string: "https://coordinator.streamvc.live")!
        let ws = URL(string: "ws://coordinator.streamvc.live/v2/provider")!
        XCTAssertThrowsError(try RegisterClient.validateCoordinatorWSURL(ws, expectedBase: base)) { error in
            guard case let RegisterClientError.invalidCoordinatorWSURL(reason) = error else {
                return XCTFail("expected invalidCoordinatorWSURL, got \(error)")
            }
            XCTAssertTrue(reason.contains("scheme must be wss"), reason)
        }
    }

    func testValidateCoordinatorWSURLRejectsAttackerHost() {
        let base = URL(string: "https://coordinator.streamvc.live")!
        let ws = URL(string: "wss://attacker.example.com/v2/provider")!
        XCTAssertThrowsError(try RegisterClient.validateCoordinatorWSURL(ws, expectedBase: base)) { error in
            guard case let RegisterClientError.invalidCoordinatorWSURL(reason) = error else {
                return XCTFail("expected invalidCoordinatorWSURL, got \(error)")
            }
            XCTAssertTrue(reason.contains("host must be"), reason)
        }
    }

    func testValidateCoordinatorWSURLRejectsUnexpectedPort() {
        let base = URL(string: "https://coordinator.streamvc.live")!
        let ws = URL(string: "wss://coordinator.streamvc.live:8443/v2/provider")!
        XCTAssertThrowsError(try RegisterClient.validateCoordinatorWSURL(ws, expectedBase: base)) { error in
            guard case let RegisterClientError.invalidCoordinatorWSURL(reason) = error else {
                return XCTFail("expected invalidCoordinatorWSURL, got \(error)")
            }
            XCTAssertTrue(reason.contains("port must be"), reason)
        }
    }

    func testValidateCoordinatorWSURLRejectsUserinfo() {
        let base = URL(string: "https://coordinator.streamvc.live")!
        let ws = URL(string: "wss://attacker@coordinator.streamvc.live/v2/provider")!
        XCTAssertThrowsError(try RegisterClient.validateCoordinatorWSURL(ws, expectedBase: base)) { error in
            guard case let RegisterClientError.invalidCoordinatorWSURL(reason) = error else {
                return XCTFail("expected invalidCoordinatorWSURL, got \(error)")
            }
            XCTAssertTrue(reason.contains("userinfo"), reason)
        }
    }

    func testValidateCoordinatorWSURLRejectsEmptyPath() {
        let base = URL(string: "https://coordinator.streamvc.live")!
        let ws = URL(string: "wss://coordinator.streamvc.live")!
        XCTAssertThrowsError(try RegisterClient.validateCoordinatorWSURL(ws, expectedBase: base)) { error in
            guard case let RegisterClientError.invalidCoordinatorWSURL(reason) = error else {
                return XCTFail("expected invalidCoordinatorWSURL, got \(error)")
            }
            XCTAssertTrue(reason.contains("path must be non-empty"), reason)
        }
    }

    func testValidateCoordinatorWSURLAcceptsHttpToWsForDevBase() throws {
        let base = URL(string: "http://127.0.0.1:8080")!
        let ws = URL(string: "ws://127.0.0.1:8080/v2/provider")!
        XCTAssertNoThrow(try RegisterClient.validateCoordinatorWSURL(ws, expectedBase: base))
    }

    func testProviderBearerRedirectGuardStripsAuthorizationOnSameHostDifferentPortRedirect() throws {
        let redirected = decideProviderBearerRedirect(
            originalURL: URL(string: "https://coordinator.example/v1/providers/register")!,
            redirectTo: URL(string: "https://coordinator.example:4443/v1/providers/register")!
        )

        XCTAssertEqual(redirected?.url?.port, 4443)
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
    }

    func testProviderBearerRedirectGuardRejectsNonHTTPSRedirect() throws {
        let redirected = decideProviderBearerRedirect(
            originalURL: URL(string: "https://coordinator.example/v1/providers/register")!,
            redirectTo: URL(string: "http://coordinator.example/v1/providers/register")!
        )

        XCTAssertNil(redirected)
    }

    func testSharedSpec026RegisterFixtureCanonicalizes() throws {
        let fixture = try loadRegisterFixture()
        XCTAssertEqual(fixture.schema, "spec026_register_jcs_v1")
        XCTAssertGreaterThanOrEqual(fixture.objects.count, 5)
        for row in fixture.objects {
            let canonical = try CanonicalJSON.encode(try canonicalValue(from: row.body))
            XCTAssertEqual(String(data: canonical, encoding: .utf8), row.expectedCanonical, row.id)
            if case let .object(body) = row.body {
                XCTAssertNil(body["current_provider_token"], row.id)
            }
        }
    }

    // PROD-H5: a signed register attempt round-trips through disk unchanged, so
    // a replay after restart re-sends the EXACT same signed bytes rather than
    // re-signing (which would shift ts/nonce and trip skew/cooldown).
    func testPendingRegisterAttemptRoundTripsThroughDisk() throws {
        let paths = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: paths.appSupport) }
        let key = Curve25519.Signing.PrivateKey()
        let request = try RegisterClient(coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!)
            .makeSignedRequest(
                identityKey: key,
                referralCode: "MAL1-S-k1-seed-TEST",
                nonce: String(repeating: "a", count: 64),
                timestamp: Date(timeIntervalSince1970: 1_783_082_460)
            )
        let attempt = PendingRegisterAttempt(
            request: request,
            bearerProof: "proof",
            coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!,
            createdAt: Date(timeIntervalSince1970: 1_783_082_460)
        )
        XCTAssertFalse(PendingRegisterAttemptStore.hasPending(paths: paths))
        try PendingRegisterAttemptStore.save(attempt, paths: paths)
        XCTAssertTrue(PendingRegisterAttemptStore.hasPending(paths: paths))

        let loaded = try XCTUnwrap(PendingRegisterAttemptStore.load(paths: paths))
        XCTAssertEqual(loaded, attempt)
        XCTAssertEqual(loaded.request, request)

        PendingRegisterAttemptStore.clear(paths: paths)
        XCTAssertFalse(PendingRegisterAttemptStore.hasPending(paths: paths))
        XCTAssertNil(PendingRegisterAttemptStore.load(paths: paths))
    }

    // PROD-H5: a register whose response is lost before the bearer is installed
    // leaves the committed attempt on disk; a fresh client (simulated restart)
    // replays the identical signed bytes and clears the attempt only once the
    // bearer is installed.
    func testLostResponseRecoversAcrossRestartWithIdenticalBytes() async throws {
        let paths = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: paths.appSupport) }
        let base = URL(string: "https://coordinator.streamvc.live")!
        let responseJSON = Data(#"""
        {"provider_id":"p_abc","provider_token":"tok","trust_tier":"provisional","coordinator_ws_url":"wss://coordinator.streamvc.live/v2/provider"}
        """#.utf8)
        StubURLProtocol.capturedBodies = []
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, responseJSON)
        }
        defer { StubURLProtocol.responder = nil }

        let key = Curve25519.Signing.PrivateKey()
        let request = try RegisterClient(coordinatorBaseURL: base).makeSignedRequest(
            identityKey: key,
            nonce: String(repeating: "b", count: 64),
            timestamp: Date(timeIntervalSince1970: 1_783_082_460)
        )

        // First attempt sends, but installing the bearer "crashes" — the attempt
        // must survive on disk.
        let client1 = RegisterClient(coordinatorBaseURL: base, session: makeStubSession())
        do {
            _ = try await client1.registerDurably(request, bearerProof: "proof", paths: paths) { _ in
                throw NSError(domain: "install", code: 1)
            }
            XCTFail("expected install failure to propagate")
        } catch {}
        XCTAssertTrue(PendingRegisterAttemptStore.hasPending(paths: paths))

        // Restart: a brand-new client recovers from disk and replays.
        let client2 = RegisterClient(coordinatorBaseURL: base, session: makeStubSession())
        var recovered: RegisterResponse?
        let result = try await client2.recoverPersistedRegister(paths: paths) { resp in recovered = resp }
        XCTAssertEqual(result?.providerToken, "tok")
        XCTAssertEqual(recovered?.providerToken, "tok")
        XCTAssertFalse(PendingRegisterAttemptStore.hasPending(paths: paths))

        XCTAssertEqual(StubURLProtocol.capturedBodies.count, 2)
        XCTAssertEqual(StubURLProtocol.capturedBodies[0], StubURLProtocol.capturedBodies[1])
    }

    func testRecoverPersistedRegisterIsNoOpWithoutAttempt() async throws {
        let paths = makeTempPaths()
        defer { try? FileManager.default.removeItem(at: paths.appSupport) }
        let client = RegisterClient(coordinatorBaseURL: URL(string: "https://coordinator.streamvc.live")!, session: makeStubSession())
        var installed = false
        let result = try await client.recoverPersistedRegister(paths: paths) { _ in installed = true }
        XCTAssertNil(result)
        XCTAssertFalse(installed)
    }

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempPaths() -> ProviderPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-register-tests-\(UUID().uuidString)", isDirectory: true)
        let configRoot = root.appendingPathComponent("config", isDirectory: true)
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        return ProviderPaths(
            configFile: configRoot.appendingPathComponent("config.yaml"),
            controlSocket: appSupport.appendingPathComponent("agent.sock"),
            cliLogFile: root.appendingPathComponent("logs/malibu-cli.log"),
            launchdStdoutLog: root.appendingPathComponent("logs/macprovider.out.log"),
            launchdStderrLog: root.appendingPathComponent("logs/macprovider.err.log"),
            appSupport: appSupport,
            appMarkerFile: appSupport.appendingPathComponent(".installed-by-app"),
            onboardingStateFile: appSupport.appendingPathComponent("onboarding.json"),
            downloadsDirectory: appSupport.appendingPathComponent("Downloads", isDirectory: true)
        )
    }

    private struct RegisterFixture: Decodable {
        let schema: String
        let objects: [RegisterFixtureRow]
    }

    private struct RegisterFixtureRow: Decodable {
        let id: String
        let body: JSONValue
        let expectedCanonical: String

        enum CodingKeys: String, CodingKey {
            case id
            case body
            case expectedCanonical = "expected_canonical"
        }
    }

    private enum JSONValue: Decodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else {
                self = .array(try container.decode([JSONValue].self))
            }
        }
    }

    private func loadRegisterFixture() throws -> RegisterFixture {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("phase4-coordinator/test/jcs_fixtures/spec026_register.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RegisterFixture.self, from: data)
    }

    private func decideProviderBearerRedirect(originalURL: URL, redirectTo newURL: URL) -> URLRequest? {
        let session = URLSession.shared
        let task = session.dataTask(with: originalURL)
        var request = URLRequest(url: newURL)
        request.setValue("Bearer provider-token", forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": newURL.absoluteString]
        )!
        let waiter = expectation(description: "redirect completion")
        var redirected: URLRequest?
        ProviderBearerRedirectGuard().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        ) { result in
            redirected = result
            waiter.fulfill()
        }
        wait(for: [waiter], timeout: 1)
        return redirected
    }

    private func canonicalValue(from value: JSONValue) throws -> CanonicalJSONValue {
        switch value {
        case let .object(dict):
            return .object(try dict.mapValues { try canonicalValue(from: $0) })
        case let .array(values):
            return .array(try values.map { try canonicalValue(from: $0) })
        case let .string(value):
            return .string(value)
        case let .number(value):
            XCTAssertEqual(value.rounded(), value)
            return .number(String(Int(value)))
        case let .bool(value):
            return .bool(value)
        case .null:
            return .null
        }
    }
}

/// Test double that captures each request's body (reading the streamed body
/// URLSession produces) and returns a canned response, used to prove the
/// PROD-H5 replay re-sends identical signed bytes.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedBodies.append(Self.body(of: request))
        let (response, data) = Self.responder?(request)
            ?? (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}
