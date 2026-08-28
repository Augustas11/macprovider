import CryptoKit
import Foundation
import XCTest
@testable import malibu_cli

/// SPEC-015 v0.3 §M.0 / §M.1.5 — golden fixtures locking the
/// byte-exact JCS canonical encoding of the 9-field tuple so the
/// Swift signer and the Go verifier (phase7-verify, Step 5) produce
/// identical canonical bytes for identical inputs.
final class JCSGoldenFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Input: Decodable {
            let model_id: String
            let model_hash: String?
            let output_content: String
            let finish_reason: String
            let ttft_ms: Int64
            let tokens_out: Int64
            let unix_ts: Int64
        }
        let description: String
        let input: Input
        let provider_pubkey_seed_b64: String
        let canonical_jcs_sha256_hex: String
        let canonical_jcs_length: Int
    }

    private static let fixtureNames = ["non_null_hash", "null_hash"]

    func testV03JCSFixturesProduceLockedCanonicalBytes() throws {
        for name in Self.fixtureNames {
            let fixture = try Self.loadFixture(named: name)
            let canonical = try Self.canonicalBytes(for: fixture)
            let actualHash = Self.sha256Hex(of: canonical)

            // Self-locking pattern: on first commit the fixture's
            // expected hash is empty. Print + fail so the operator
            // can paste in the correct values; subsequent runs hit
            // the assertion below.
            if fixture.canonical_jcs_sha256_hex.isEmpty || fixture.canonical_jcs_length == 0 {
                XCTFail("""
                Fixture \(name) is missing locked values. Paste these into the JSON:
                  canonical_jcs_sha256_hex: \(actualHash)
                  canonical_jcs_length: \(canonical.utf8.count)
                Canonical JCS bytes (first 200 chars):
                  \(String(canonical.prefix(200)))
                """)
                continue
            }

            XCTAssertEqual(actualHash, fixture.canonical_jcs_sha256_hex,
                           "fixture \(name): JCS canonical bytes drifted from the locked SHA-256")
            XCTAssertEqual(canonical.utf8.count, fixture.canonical_jcs_length,
                           "fixture \(name): canonical byte length drifted")
        }
    }

    // SPEC-015 §M.1.5 — JCS canonicalization for the v0.1/v0.2
    // 7-field tuple must remain byte-identical (this regression
    // test proves `RFC8785JCS.swift` did not silently change shape
    // when v0.3 added two more keys).
    func testLegacyV01V027FieldTupleCanonicalizesUnchanged() throws {
        let publicKeyB64 = "y/UYwxsuTKfWXsxC1MRVN7Pi4qe5dRXyAvxhwM5g8sM="
        let legacyTuple: RFC8785JCS.Value = .object([
            "model_id": .string("fixture-model"),
            "prompt_hash": .string(String(repeating: "a", count: 64)),
            "output_hash": .string(String(repeating: "b", count: 64)),
            "provider_pubkey": .string(publicKeyB64),
            "ttft_ms": .int(7),
            "tokens_out": .int(2),
            "unix_ts": .int(1_800_000_000),
        ])

        let canonical = try RFC8785JCS.canonicalString(legacyTuple)
        // Locked v0.1/v0.2 canonical encoding: JCS sorted keys,
        // UTF-16 lex order, ASCII alphabetical. The exact byte
        // sequence must remain identical to the v0.1.3-LOCK era.
        let expected = "{\"model_id\":\"fixture-model\",\"output_hash\":\"\(String(repeating: "b", count: 64))\",\"prompt_hash\":\"\(String(repeating: "a", count: 64))\",\"provider_pubkey\":\"\(publicKeyB64)\",\"tokens_out\":2,\"ttft_ms\":7,\"unix_ts\":1800000000}"
        XCTAssertEqual(canonical, expected, "v0.1/v0.2 7-field JCS canonicalization regressed")
    }

    // MARK: helpers

    private static func loadFixture(named: String) throws -> Fixture {
        let url = try fixturesURL().appendingPathComponent("\(named).json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private static func canonicalBytes(for fixture: Fixture) throws -> String {
        let seed = try XCTUnwrap(Data(base64Encoded: fixture.provider_pubkey_seed_b64))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let promptRequest = try PromptCanonicalizerTests.fixtureRequest()
        let promptHash = try PromptCanonicalizer.promptHash(for: promptRequest)
        let outputHash = try OutputCanonicalizer.outputHash(
            content: fixture.input.output_content,
            toolCalls: nil,
            finishReason: fixture.input.finish_reason
        )
        let modelHashValue: RFC8785JCS.Value
        if let hash = fixture.input.model_hash {
            modelHashValue = .string(hash)
        } else {
            modelHashValue = .null
        }
        let tuple: RFC8785JCS.Value = .object([
            "model_hash": modelHashValue,
            "model_id": .string(fixture.input.model_id),
            "output_hash": .string(outputHash),
            "prompt_hash": .string(promptHash),
            "provider_pubkey": .string(key.publicKey.rawRepresentation.base64EncodedString()),
            "receipt_version": .string(ReceiptBuilder.receiptVersionV03),
            "tokens_out": .int(Int(fixture.input.tokens_out)),
            "ttft_ms": .int(Int(fixture.input.ttft_ms)),
            "unix_ts": .int(Int(fixture.input.unix_ts)),
        ])
        return try RFC8785JCS.canonicalString(tuple)
    }

    private static func sha256Hex(of value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fixturesURL() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("SPEC015_v03_jcs")
    }
}
