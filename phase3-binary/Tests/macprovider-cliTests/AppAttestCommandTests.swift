import ArgumentParser
import Foundation
import MacProviderCore
@testable import macprovider_cli
import XCTest

final class AppAttestCommandTests: XCTestCase {
    private let providerID = "mp-0123456789abcdef0123456789abcdef"
    private let token = "app-attest-test-bearer"
    private let challenge = Data(repeating: 0xA1, count: 32).base64EncodedString()
    private let keyID = Data(repeating: 0xB2, count: 32).base64EncodedString()

    override func tearDown() {
        AppAttestMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - argument validation

    func testSubmitParsesValidArguments() throws {
        let command = try AppAttestSubmitCommand.parse(["--challenge", challenge, "--key-id", keyID])
        XCTAssertEqual(command.challenge, challenge)
        XCTAssertEqual(command.keyId, keyID)
    }

    func testSubmitRejectsWrongLengthOrNonBase64Arguments() {
        let short = Data(repeating: 1, count: 31).base64EncodedString()
        let urlSafe = String(repeating: "-", count: 43) + "="
        for args in [
            ["--challenge", short, "--key-id", keyID],
            ["--challenge", challenge, "--key-id", short],
            ["--challenge", urlSafe, "--key-id", keyID],
            ["--challenge", challenge],
        ] {
            XCTAssertThrowsError(try AppAttestSubmitCommand.parse(args), "\(args)")
        }
    }

    func testCommandsNeverAcceptATokenOnArgv() {
        XCTAssertThrowsError(try AppAttestChallengeCommand.parse(["--provider-token", "x"]))
        XCTAssertThrowsError(try AppAttestChallengeCommand.parse(["--token", "x"]))
        XCTAssertThrowsError(
            try AppAttestSubmitCommand.parse(["--challenge", challenge, "--key-id", keyID, "--token", "x"])
        )
    }

    func testSubmitBodyValidatesAttestation() throws {
        XCTAssertThrowsError(try AppAttestClient.submitBody(challenge: challenge, keyID: keyID, attestation: ""))
        XCTAssertThrowsError(try AppAttestClient.submitBody(challenge: challenge, keyID: keyID, attestation: "not base64!"))
        let tooLarge = Data(repeating: 7, count: AppAttestClient.maxAttestationBytes + 1).base64EncodedString()
        XCTAssertThrowsError(try AppAttestClient.submitBody(challenge: challenge, keyID: keyID, attestation: tooLarge))
        let atLimit = Data(repeating: 7, count: AppAttestClient.maxAttestationBytes).base64EncodedString()
        XCTAssertNoThrow(try AppAttestClient.submitBody(challenge: challenge, keyID: keyID, attestation: atLimit))
    }

    func testSubmitBodyHasExactlyThreeKeysAndTrimsStdinWhitespace() throws {
        let attestation = Data([0x01, 0x02, 0xFF]).base64EncodedString()
        let body = try AppAttestClient.submitBody(
            challenge: challenge,
            keyID: keyID,
            attestation: "  \(attestation)\n"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["challenge": challenge, "key_id": keyID, "attestation": attestation])
    }

    func testBoundedInputRejectsOversizedStdin() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(repeating: 0x41, count: 100))
        try pipe.fileHandleForWriting.close()
        XCTAssertThrowsError(try AppAttestClient.readBoundedInput(pipe.fileHandleForReading, limit: 99))

        let ok = Pipe()
        ok.fileHandleForWriting.write(Data(repeating: 0x41, count: 99))
        try ok.fileHandleForWriting.close()
        XCTAssertEqual(try AppAttestClient.readBoundedInput(ok.fileHandleForReading, limit: 99).count, 99)
    }

    // MARK: - request shape and response handling

    func testChallengePostsEmptyObjectWithBearerAndPrintsOneLineJSON() async throws {
        var captured: URLRequest?
        var capturedBody = Data()
        let response = #"{"status":"challenge","provider_id":"mp-x","challenge":"\#(challenge)","client_data":"a/b \"q\"","expires_at":"2026-10-11T00:00:00Z"}"#
        let client = try makeClient { request, body in
            captured = request
            capturedBody = body
            return (200, Data(response.utf8))
        }

        let outcome = await client.challenge()

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://coordinator.example.test/v1/providers/app-attest/challenge")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(capturedBody, Data("{}".utf8))
        guard case .success(let line) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(line.last, 0x0a)
        XCTAssertEqual(line.filter { $0 == 0x0a }.count, 1)
        let printed = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: String])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: String])
        XCTAssertEqual(printed, original)
        XCTAssertEqual(printed["client_data"], "a/b \"q\"")
    }

    func testSubmitPostsBodyVerbatimWithBearer() async throws {
        var captured: URLRequest?
        var capturedBody = Data()
        let client = try makeClient { request, body in
            captured = request
            capturedBody = body
            return (200, Data(#"{"status":"recorded","provider_id":"mp-x"}"#.utf8))
        }
        let attestation = Data(repeating: 9, count: 40).base64EncodedString()
        let body = try AppAttestClient.submitBody(challenge: challenge, keyID: keyID, attestation: attestation)

        let outcome = await client.submit(body: body)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://coordinator.example.test/v1/providers/app-attest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: capturedBody) as? [String: String])
        XCTAssertEqual(Set(sent.keys), ["challenge", "key_id", "attestation"])
        XCTAssertEqual(sent["attestation"], attestation)
        XCTAssertEqual(outcome, .success(Data(#"{"provider_id":"mp-x","status":"recorded"}"#.utf8 + [0x0a])))
    }

    func testErrorStatusesMapToDistinctExitCodesWithoutEchoingMessages() async throws {
        let cases: [(Int, String, Int32, String)] = [
            (401, #"{"error":"unauthorized","message":"\u001b[31mx"}"#, AppAttestClient.ExitStatus.unauthorized, "HTTP 401 unauthorized"),
            (429, #"{"error":"rate_limited","message":"slow"}"#, AppAttestClient.ExitStatus.rateLimited, "HTTP 429 rate_limited"),
            (503, #"{"error":"app_attest_unavailable"}"#, AppAttestClient.ExitStatus.unavailable, "HTTP 503 app_attest_unavailable"),
            (409, #"{"error":"challenge_invalid"}"#, AppAttestClient.ExitStatus.failure, "HTTP 409 challenge_invalid"),
            (422, #"{"error":"app_attest_rejected"}"#, AppAttestClient.ExitStatus.failure, "HTTP 422 app_attest_rejected"),
            (400, #"{"error":"Bad Code\n"}"#, AppAttestClient.ExitStatus.failure, "HTTP 400"),
            (500, "not json", AppAttestClient.ExitStatus.failure, "HTTP 500"),
        ]
        for (status, body, exitCode, message) in cases {
            XCTAssertEqual(
                AppAttestClient.outcome(statusCode: status, data: Data(body.utf8)),
                .failure(exitCode: exitCode, message: message),
                "HTTP \(status)"
            )
        }
        let client = try makeClient { _, _ in (429, Data(#"{"error":"rate_limited"}"#.utf8)) }
        let outcome = await client.challenge()
        XCTAssertEqual(outcome, .failure(exitCode: AppAttestClient.ExitStatus.rateLimited, message: "HTTP 429 rate_limited"))
    }

    func testSuccessWithoutStatusIsAFailure() {
        XCTAssertEqual(
            AppAttestClient.outcome(statusCode: 200, data: Data(#"{"provider_id":"mp-x"}"#.utf8)),
            .failure(exitCode: AppAttestClient.ExitStatus.failure, message: "HTTP 200 with an unexpected response body")
        )
        XCTAssertEqual(
            AppAttestClient.outcome(statusCode: 200, data: Data("[]".utf8)),
            .failure(exitCode: AppAttestClient.ExitStatus.failure, message: "HTTP 200 with an unexpected response body")
        )
    }

    func testMissingCredentialFailsBeforeNetwork() async throws {
        var called = false
        AppAttestMockURLProtocol.requestHandler = { _, _ in
            called = true
            return (200, Data())
        }
        let client = AppAttestClient(
            config: try makeTokenlessConfig(),
            credentialStore: InMemoryProviderCredentialStore(),
            session: mockSession()
        )
        let outcome = await client.challenge()
        guard case .failure(let code, let message) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(code, AppAttestClient.ExitStatus.failure)
        XCTAssertTrue(message.hasPrefix("provider credential unavailable"), message)
        XCTAssertFalse(called)
    }

    // MARK: - helpers

    private func makeClient(
        handler: @escaping (URLRequest, Data) throws -> (Int, Data)
    ) throws -> AppAttestClient {
        AppAttestMockURLProtocol.requestHandler = handler
        return AppAttestClient(
            config: try makeTokenlessConfig(),
            credentialStore: InMemoryProviderCredentialStore(values: [providerID: token]),
            session: mockSession()
        )
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppAttestMockURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }

    private func makeTokenlessConfig() throws -> AppConfig {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-attest-config-\(UUID().uuidString).yaml")
        let yaml = """
        provider_id: "\(providerID)"
        coordinator_url: "wss://coordinator.example.test/ws/provider"
        """
        try Data(yaml.utf8).write(to: configURL, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: configURL) }
        return try ConfigLoader.load(cli: CLIOverrides(configPath: configURL.path), environment: [:])
    }
}

private final class AppAttestMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest, Data) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request, Self.body(of: request))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}
