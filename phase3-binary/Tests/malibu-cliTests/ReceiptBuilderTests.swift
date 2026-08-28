import CryptoKit
import Foundation
import XCTest
@testable import malibu_cli

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

    private static let v04TupleKeys: Set<String> = [
        "account_scope",
        "attempt_n",
        "catalog_body_digest",
        "catalog_id",
        "expected_catalog_model_hash",
        "issued_at_unix_ms",
        "model_hash",
        "model_id",
        "output_hash",
        "output_prefix_end_byte",
        "output_prefix_start_byte",
        "prompt_hash",
        "provider_id",
        "provider_receipt_key_id",
        "receipt_version",
        "request_id",
        "route_snapshot_digest",
        "route_snapshot_mode",
        "route_snapshot_policy_version",
        "signature_key_alg",
        "terminal_state",
        "terminal_state_ts_unix_ms",
        "usage",
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

    func testBuildSettlementSignsStrictV04Tuple() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))
        let receipt = try builder.buildSettlement(
            providerId: "provider-a",
            input: settlementInput(key: key)
        )

        let pieces = receipt.split(separator: ".")
        XCTAssertEqual(pieces.count, 2)
        let tupleData = try XCTUnwrap(Data(base64Encoded: String(pieces[0])))
        let signature = try XCTUnwrap(Data(base64Encoded: String(pieces[1])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey.rawRepresentation)

        XCTAssertEqual(Set(tuple.keys), Self.v04TupleKeys)
        XCTAssertEqual(tuple["receipt_version"] as? String, "4")
        XCTAssertEqual(tuple["signature_key_alg"] as? String, "Ed25519")
        XCTAssertEqual(tuple["model_hash"] as? String, Self.validModelHash)
        XCTAssertFalse(tuple["model_hash"] is NSNull)
        XCTAssertEqual(tuple["provider_receipt_key_id"] as? String, receiptKeyID(key.publicKey.rawRepresentation))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: tupleData))

        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual(
            Set(usage.keys),
            ["billable_input_tokens", "billable_output_tokens", "delivered_output_bytes", "observed_input_tokens", "observed_output_tokens"]
        )
        XCTAssertFalse(usage.keys.contains { $0.hasPrefix("spec_decode") })
        XCTAssertNil(usage["drafted_tokens"])
        XCTAssertNil(usage["accepted_tokens"])
        XCTAssertEqual(usage["billable_input_tokens"] as? Int, 8)
        XCTAssertEqual(usage["billable_output_tokens"] as? Int, 3)
    }

    func testBuildSettlementNormalizesOutputContentForHashAndBytes() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))
        let base = settlementInput(key: key)
        let rawContent = "line1\r\nline2\rcafe\u{301}"
        let normalizedContent = "line1\nline2\ncaf\u{00e9}"
        let input = SettlementReceiptInput(
            metadata: base.metadata,
            modelHash: base.modelHash,
            content: rawContent,
            toolCalls: nil,
            finishReason: base.finishReason,
            promptTokens: base.promptTokens,
            completionTokens: base.completionTokens,
            terminalState: base.terminalState,
            terminalStateUnixMS: base.terminalStateUnixMS,
            issuedAtUnixMS: base.issuedAtUnixMS
        )

        let receipt = try builder.buildSettlement(providerId: "provider-a", input: input)
        let tupleData = try XCTUnwrap(Data(base64Encoded: String(receipt.split(separator: ".")[0])))
        let tuple = try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
        let outputEnd = try XCTUnwrap((tuple["output_prefix_end_byte"] as? NSNumber)?.int64Value)
        XCTAssertEqual(outputEnd, base.metadata.outputPrefixStartByte + Int64(normalizedContent.utf8.count))
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual((usage["delivered_output_bytes"] as? NSNumber)?.int64Value, Int64(normalizedContent.utf8.count))

        let expectedOutputHash = try RFC8785JCS.sha256Hex(of: .object([
            "content": .string(normalizedContent),
            "finish_reason": .string(base.finishReason),
            "output_prefix_end_byte": .int(Int(outputEnd)),
            "output_prefix_start_byte": .int(Int(base.metadata.outputPrefixStartByte)),
            "terminal_state": .string(base.terminalState),
            "tool_calls": .null,
        ]))
        XCTAssertEqual(tuple["output_hash"] as? String, expectedOutputHash)
    }

    func testBuildSettlementRejectsWrongReceiptKeyID() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let builder = ReceiptBuilder(keyStore: FixedReceiptKeyStore(key: key))
        var input = settlementInput(key: key)
        input = SettlementReceiptInput(
            metadata: SettlementReceiptMetadata(wire: [
                "account_scope": input.metadata.accountScope,
                "request_id": input.metadata.requestID,
                "attempt_n": input.metadata.attemptN,
                "provider_id": input.metadata.providerID,
                "provider_receipt_key_id": "ed25519-sha256:" + String(repeating: "0", count: 64),
                "model_id": input.metadata.modelID,
                "expected_catalog_model_hash": input.metadata.expectedCatalogModelHash,
                "catalog_id": input.metadata.catalogID,
                "catalog_body_digest": input.metadata.catalogBodyDigest,
                "route_snapshot_digest": input.metadata.routeSnapshotDigest,
                "route_snapshot_policy_version": input.metadata.routeSnapshotPolicyVersion,
                "route_snapshot_mode": input.metadata.routeSnapshotMode,
                "prompt_hash": input.metadata.promptHash,
                "output_prefix_start_byte": input.metadata.outputPrefixStartByte,
                "pending_deadline_seconds": input.metadata.pendingDeadlineSeconds,
            ])!,
            modelHash: input.modelHash,
            content: input.content,
            toolCalls: input.toolCalls,
            finishReason: input.finishReason,
            promptTokens: input.promptTokens,
            completionTokens: input.completionTokens,
            terminalState: input.terminalState,
            terminalStateUnixMS: input.terminalStateUnixMS,
            issuedAtUnixMS: input.issuedAtUnixMS
        )

        XCTAssertThrowsError(try builder.buildSettlement(providerId: "provider-a", input: input)) { error in
            XCTAssertEqual(error as? ReceiptBuilder.Error, .settlementFieldMismatch("provider_receipt_key_id"))
        }
    }

    private func settlementInput(key: Curve25519.Signing.PrivateKey) -> SettlementReceiptInput {
        let metadata = SettlementReceiptMetadata(wire: [
            "account_scope": "acct_sha256:" + String(repeating: "1", count: 64),
            "request_id": "req-v04",
            "attempt_n": 0,
            "provider_id": "provider-a",
            "provider_receipt_key_id": receiptKeyID(key.publicKey.rawRepresentation),
            "model_id": "fixture-model",
            "expected_catalog_model_hash": Self.validModelHash,
            "catalog_id": "catalog-a",
            "catalog_body_digest": String(repeating: "2", count: 64),
            "route_snapshot_digest": String(repeating: "3", count: 64),
            "route_snapshot_policy_version": "spec022-prereq-v0",
            "route_snapshot_mode": "observe",
            "prompt_hash": String(repeating: "4", count: 64),
            "output_prefix_start_byte": 5,
            "pending_deadline_seconds": 120,
        ])!
        return SettlementReceiptInput(
            metadata: metadata,
            modelHash: Self.validModelHash,
            content: "answer",
            toolCalls: nil,
            finishReason: "stop",
            promptTokens: 8,
            completionTokens: 3,
            terminalState: "normal_done",
            terminalStateUnixMS: 1_800_000_000_123,
            issuedAtUnixMS: 1_800_000_000_124
        )
    }

    private func receiptKeyID(_ pubkey: Data) -> String {
        let digest = SHA256.hash(data: pubkey)
        return "ed25519-sha256:" + digest.map { String(format: "%02x", $0) }.joined()
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
