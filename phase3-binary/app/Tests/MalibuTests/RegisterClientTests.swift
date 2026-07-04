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
            binaryVersion: 2,
            providerECDHPublicKey: "ecdh",
            transcriptSHA256: "hash"
        )
        XCTAssertEqual(
            String(data: payload, encoding: .utf8),
            #"{"auth_attempt_id":"auth-1","binary_version":2,"provider_ecdh_public_key":"ecdh","provider_id":"p_abc","transcript_sha256":"hash"}"#
        )
    }

    func testSharedSpec026RegisterFixtureCanonicalizes() throws {
        let fixture = try loadRegisterFixture()
        let canonical = try CanonicalJSON.encode(try canonicalValue(from: fixture.bodyWithoutSignature))
        XCTAssertEqual(String(data: canonical, encoding: .utf8), fixture.canonicalWithoutSignature)
    }

    private struct RegisterFixture: Decodable {
        let bodyWithoutSignature: JSONValue
        let canonicalWithoutSignature: String

        enum CodingKeys: String, CodingKey {
            case bodyWithoutSignature = "body_without_signature"
            case canonicalWithoutSignature = "canonical_without_signature"
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
