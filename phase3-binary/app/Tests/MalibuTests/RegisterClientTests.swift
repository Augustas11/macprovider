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
            nonce: String(repeating: "a", count: 64),
            timestamp: Date(timeIntervalSince1970: 1_783_082_460)
        )

        XCTAssertEqual(request.fieldNames, [
            "provider_id",
            "identity_pubkey",
            "hardware_summary",
            "app_attest_object",
            "app_attest_key_id",
            "nonce",
            "ts_utc",
            "signature"
        ])
        XCTAssertFalse(request.fieldNames.contains("binary_version"))
        XCTAssertFalse(request.fieldNames.contains("provider_name"))
        XCTAssertFalse(request.fieldNames.contains("signature_alg"))

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
