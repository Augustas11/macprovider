import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class ReceiptBuilderTests: XCTestCase {
    // SPEC-015 §M.0 — v0.3 receipt MUST contain exactly these nine keys.
    private static let v03TupleKeys: Set<String> = [
        "model_hash",
        "model_id",
        "output_hash",
        "prompt_hash",
        "provider_pubkey",
        "receipt_version",
        "ttft_ms",
        "tokens_out",
        "unix_ts",
    ]

    private static let validModelHash =
        "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"

    func testBuildSignsTupleAndSignatureSelfVerifies() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))
        let receipt = try builder.build(
            providerId: "provider-a",
            input: ReceiptInput(
                modelId: "fixture-model",
                request: PromptCanonicalizerTests.fixtureRequest(),
                outputContent: "answer",
                outputToolCalls: nil,
                finishReason: "stop",
                ttftMs: 123,
                tokensOut: 4,
                unixTsSeconds: 1_800_000_000,
                modelHash: Self.validModelHash
            )
        )

        let pieces = receipt.split(separator: ".")
        XCTAssertEqual(pieces.count, 2)
        let tupleData = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
        let providerPubkey = try XCTUnwrap(tuple["provider_pubkey"] as? String)
        let publicKeyData = try XCTUnwrap(Data(base64Encoded: providerPubkey))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

        XCTAssertEqual(Set(tuple.keys), Self.v03TupleKeys)
        XCTAssertEqual(tuple["receipt_version"] as? String, "3")
        XCTAssertEqual(tuple["model_hash"] as? String, Self.validModelHash)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: tupleData))
    }

    // SPEC-015 §M.2.3 — null model_hash for warm-swap-disabled providers.
    func testBuildEmitsJSONNullForAbsentModelHash() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))
        let receipt = try builder.build(
            providerId: "provider-a",
            input: ReceiptInput(
                modelId: "fixture-model",
                request: PromptCanonicalizerTests.fixtureRequest(),
                outputContent: "answer",
                outputToolCalls: nil,
                finishReason: "stop",
                ttftMs: 123,
                tokensOut: 4,
                unixTsSeconds: 1_800_000_000,
                modelHash: nil
            )
        )

        let tupleData = try XCTUnwrap(Data(base64Encoded: String(receipt.split(separator: ".")[0])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
        XCTAssertEqual(Set(tuple.keys), Self.v03TupleKeys)
        XCTAssertTrue(tuple["model_hash"] is NSNull, "model_hash must be JSON null, not absent or empty string")
    }

    // SPEC-015 §M.0 — JCS canonical order is UTF-16 code-unit lex.
    func testCanonicalTupleIsAlphabeticalUtf16Order() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))
        let receipt = try builder.build(
            providerId: "provider-a",
            input: ReceiptInput(
                modelId: "fixture-model",
                request: PromptCanonicalizerTests.fixtureRequest(),
                outputContent: "answer",
                outputToolCalls: nil,
                finishReason: "stop",
                ttftMs: 123,
                tokensOut: 4,
                unixTsSeconds: 1_800_000_000,
                modelHash: Self.validModelHash
            )
        )

        let tupleBytes = try XCTUnwrap(Data(base64Encoded: String(receipt.split(separator: ".")[0])))
        let canonical = try XCTUnwrap(String(data: tupleBytes, encoding: .utf8))
        // Spot-check the order of key positions — UTF-16 lex order
        // for these ASCII keys is alphabetical.
        let expectedOrder: [String] = [
            "\"model_hash\":",
            "\"model_id\":",
            "\"output_hash\":",
            "\"prompt_hash\":",
            "\"provider_pubkey\":",
            "\"receipt_version\":",
            "\"tokens_out\":",
            "\"ttft_ms\":",
            "\"unix_ts\":",
        ]
        var cursor = canonical.startIndex
        for key in expectedOrder {
            guard let range = canonical.range(of: key, range: cursor..<canonical.endIndex) else {
                XCTFail("missing or out-of-order key \(key) in canonical tuple: \(canonical)")
                return
            }
            cursor = range.upperBound
        }
    }

    // SPEC-015 §M.0 — model_hash MUST be 64-char lowercase hex when present.
    func testBuildRejectsMalformedModelHash() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))

        let invalid = [
            "",                                                                       // empty
            "ABCDEFabcdef0123456789ABCDEFabcdef0123456789ABCDEFabcdef0123456789",    // uppercase
            "g000000000000000000000000000000000000000000000000000000000000000",    // non-hex char
            "deadbeef",                                                              // too short
            String(repeating: "a", count: 65),                                       // too long
            "sha256:" + String(repeating: "a", count: 64),                           // prefix
        ]

        for bad in invalid {
            XCTAssertThrowsError(try builder.build(
                providerId: "provider-a",
                input: ReceiptInput(
                    modelId: "fixture-model",
                    request: PromptCanonicalizerTests.fixtureRequest(),
                    outputContent: "",
                    outputToolCalls: nil,
                    finishReason: "error",
                    ttftMs: 0,
                    tokensOut: 0,
                    unixTsSeconds: 1,
                    modelHash: bad
                )
            ), "expected reject on hash \"\(bad)\"") { error in
                XCTAssertEqual(error as? ReceiptBuilder.Error, .invalidModelHash, "hash=\"\(bad)\"")
            }
        }
    }

    // SPEC-015 §3.4 v0.3 — header value ≤ ~1025 ASCII bytes.
    func testV03ReceiptFitsWireSizeBudget() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))
        let receipt = try builder.build(
            providerId: "provider-a",
            input: ReceiptInput(
                modelId: String(repeating: "x", count: 64),
                request: PromptCanonicalizerTests.fixtureRequest(),
                outputContent: "answer",
                outputToolCalls: nil,
                finishReason: "stop",
                ttftMs: 99_999_999,
                tokensOut: 99_999_999,
                unixTsSeconds: 9_999_999_999,
                modelHash: Self.validModelHash
            )
        )

        // SPEC-015 §3.4 v0.3 — the projected ceiling is ≤ ~1025 bytes
        // for the worst-case 9-field tuple. A 10% overhead margin
        // covers test-fixture prompt/output sizes that touch the
        // upper bound; anything beyond that signals an envelope
        // regression that needs spec revisit.
        XCTAssertLessThanOrEqual(receipt.utf8.count, 1025, "v0.3 receipt envelope exceeded the SPEC-015 §3.4 v0.3 ≤1025-byte projection")
        XCTAssertLessThanOrEqual(receipt.utf8.count, 4096, "v0.3 receipt MUST fit in §3.4 nginx headroom budget")
    }

    func testBuildRejectsNonASCIIModelId() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))

        XCTAssertThrowsError(try builder.build(
            providerId: "provider-a",
            input: ReceiptInput(
                modelId: "fixture-\u{2603}",
                request: PromptCanonicalizerTests.fixtureRequest(),
                outputContent: "",
                outputToolCalls: nil,
                finishReason: "error",
                ttftMs: 0,
                tokensOut: 0,
                unixTsSeconds: 1,
                modelHash: nil
            )
        )) { error in
            XCTAssertEqual(error as? ReceiptBuilder.Error, .nonASCIIModelId)
        }
    }

    func testBuildRequiresExistingCurrentKey() throws {
        let builder = ReceiptBuilder(keyStore: EmptyReceiptKeyStore())

        XCTAssertThrowsError(try builder.build(
            providerId: "provider-a",
            input: ReceiptInput(
                modelId: "fixture-model",
                request: PromptCanonicalizerTests.fixtureRequest(),
                outputContent: "",
                outputToolCalls: nil,
                finishReason: "error",
                ttftMs: 0,
                tokensOut: 0,
                unixTsSeconds: 1,
                modelHash: nil
            )
        )) { error in
            XCTAssertEqual(
                error as? ReceiptBuilder.Error,
                .missingCurrentReceiptKey(providerId: "provider-a")
            )
        }
    }
}
private final class FixedReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey

    init(key: Curve25519.Signing.PrivateKey) {
        self.key = key
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        key
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private final class EmptyReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        nil
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}
