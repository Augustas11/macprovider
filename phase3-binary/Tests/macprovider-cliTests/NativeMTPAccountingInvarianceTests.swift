import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPAccountingInvarianceTests: XCTestCase {
    private static let validModelHash =
        "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"
    private static let settlementTupleKeys: Set<String> = [
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
    private static let settlementUsageKeys: Set<String> = [
        "billable_input_tokens",
        "billable_output_tokens",
        "delivered_output_bytes",
        "observed_input_tokens",
        "observed_output_tokens",
    ]
    private static let buyerUsageTokenKeys: Set<String> = [
        "prompt_tokens",
        "cached_prompt_tokens",
        "completion_tokens",
        "total_tokens",
    ]

    func testNativeMTPBuyerUsageReportsOnlyOrdinaryTokenCounts() {
        let ordinary = CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: 11,
            cachedPromptTokens: 0,
            completionTokens: 4,
            modelHashObserved: Self.validModelHash,
            settlementDisposition: .eligibleOwner
        )
        let accelerated = nativeMTPAcceleratedCompletion(
            promptTokens: 11,
            completionTokens: 4,
            generatedCompletionTokens: 9
        )

        for pair in [
            (ordinary: InferenceRelay.usage(ordinary), accelerated: InferenceRelay.usage(accelerated)),
            (ordinary: RouterHandler.usage(ordinary), accelerated: RouterHandler.usage(accelerated)),
        ] {
            XCTAssertEqual(pair.accelerated["prompt_tokens"] as? Int, pair.ordinary["prompt_tokens"] as? Int)
            XCTAssertEqual(pair.accelerated["cached_prompt_tokens"] as? Int, 0)
            XCTAssertEqual(pair.accelerated["cached_prompt_tokens"] as? Int, pair.ordinary["cached_prompt_tokens"] as? Int)
            XCTAssertEqual(pair.accelerated["completion_tokens"] as? Int, pair.ordinary["completion_tokens"] as? Int)
            XCTAssertEqual(pair.accelerated["total_tokens"] as? Int, pair.ordinary["total_tokens"] as? Int)
            XCTAssertNoNativeMTPAccountingFields(pair.accelerated)
        }
    }

    func testNativeMTPReceiptUsageUsesOnlySettlementV04UsageKeys() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let tuple = try settlementTuple(
            input: settlementInput(key: key, content: "answer", promptTokens: 8, completionTokens: 3),
            key: key
        )

        XCTAssertEqual(Set(tuple.keys), Self.settlementTupleKeys)
        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual(Set(usage.keys), Self.settlementUsageKeys)
        XCTAssertEqual(usage["observed_input_tokens"] as? Int, 8)
        XCTAssertEqual(usage["observed_output_tokens"] as? Int, 3)
        XCTAssertEqual(usage["billable_input_tokens"] as? Int, 8)
        XCTAssertEqual(usage["billable_output_tokens"] as? Int, 3)
        XCTAssertNoNativeMTPAccountingFields(usage)
    }

    func testPreoutputFallbackBillsNothingAndKeepsOnlyObservedOrdinaryUsage() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(0..<32))
        let tuple = try settlementTuple(
            input: settlementInput(
                key: key,
                content: "",
                promptTokens: 8,
                completionTokens: 3,
                terminalState: "runtime_error"
            ),
            key: key
        )

        let usage = try XCTUnwrap(tuple["usage"] as? [String: Any])
        XCTAssertEqual(Set(usage.keys), Self.settlementUsageKeys)
        XCTAssertEqual(usage["observed_input_tokens"] as? Int, 8)
        XCTAssertEqual(usage["observed_output_tokens"] as? Int, 3)
        XCTAssertEqual(usage["billable_input_tokens"] as? Int, 0)
        XCTAssertEqual(usage["billable_output_tokens"] as? Int, 0)
        XCTAssertEqual(usage["delivered_output_bytes"] as? Int, 0)
        XCTAssertNoNativeMTPAccountingFields(usage)
    }

    func testPostoutputUnattestedFailureCannotEmitSuccessTokenUsage() {
        let failure = nativeMTPAcceleratedCompletion(
            promptTokens: 11,
            completionTokens: 4,
            generatedCompletionTokens: 9,
            settlementDisposition: .usageUnattested
        )

        for usage in [InferenceRelay.usage(failure), RouterHandler.usage(failure)] {
            for key in Self.buyerUsageTokenKeys {
                XCTAssertNil(usage[key], "\(key) must not be emitted for unattested postoutput failure")
            }
            XCTAssertNoNativeMTPAccountingFields(usage)
        }
    }

    func testCancelledNativeMTPPrefixWithoutBoundaryProofBecomesUnattested() {
        let result = CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: 8,
            cachedPromptTokens: 0,
            completionTokens: 3,
            generatedCompletionTokens: 7,
            modelHashObserved: Self.validModelHash,
            settlementDisposition: .eligibleOwner,
            specDecodeDraftedTokens: 12,
            specDecodeAcceptedTokens: 6,
            specDecodeGeneration: 2,
            loopbackPrefixCompletionTokens: [0: 0, 6: 3]
        )

        let offBoundary = result.cancelledPrefixUsage(deliveredContent: "ans")
        XCTAssertEqual(offBoundary.settlementDisposition, .usageUnattested)
        XCTAssertNil(InferenceRelay.usage(offBoundary)["completion_tokens"])
        XCTAssertNil(RouterHandler.usage(offBoundary)["completion_tokens"])
    }

    private func nativeMTPAcceleratedCompletion(
        promptTokens: Int,
        completionTokens: Int,
        generatedCompletionTokens: Int,
        settlementDisposition: ContinuousBatchSettlementDisposition = .eligibleOwner
    ) -> CompletionResult {
        CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: promptTokens,
            cachedPromptTokens: 0,
            completionTokens: completionTokens,
            generatedCompletionTokens: generatedCompletionTokens,
            generationMilliseconds: 25,
            modelHashObserved: Self.validModelHash,
            settlementDisposition: settlementDisposition,
            specDecodeDraftedTokens: 12,
            specDecodeAcceptedTokens: 6,
            specDecodeGeneration: 2
        )
    }

    private func settlementTuple(
        input: SettlementReceiptInput,
        key: Curve25519.Signing.PrivateKey
    ) throws -> [String: Any] {
        let builder = ReceiptBuilder(keyStore: NativeMTPAccountingReceiptKeyStore(key: key))
        let receipt = try builder.buildSettlement(providerId: "provider-a", input: input)
        let tupleData = try XCTUnwrap(Data(base64Encoded: String(receipt.split(separator: ".")[0])))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: tupleData) as? [String: Any])
    }

    private func settlementInput(
        key: Curve25519.Signing.PrivateKey,
        content: String,
        promptTokens: Int,
        completionTokens: Int,
        terminalState: String = "normal_done"
    ) throws -> SettlementReceiptInput {
        let metadata = try XCTUnwrap(SettlementReceiptMetadata(wire: [
            "account_scope": "acct_sha256:" + String(repeating: "1", count: 64),
            "request_id": "req-native-mtp-accounting",
            "attempt_n": 0,
            "provider_id": "provider-a",
            "provider_receipt_key_id": receiptKeyID(key.publicKey.rawRepresentation),
            "model_id": "fixture-model",
            "expected_catalog_model_hash": Self.validModelHash,
            "catalog_id": "catalog-a",
            "catalog_body_digest": String(repeating: "2", count: 64),
            "route_snapshot_digest": String(repeating: "3", count: 64),
            "route_snapshot_policy_version": "spec048-r011",
            "route_snapshot_mode": "observe",
            "prompt_hash": String(repeating: "4", count: 64),
            "output_prefix_start_byte": 5,
            "pending_deadline_seconds": 120,
        ]))
        return SettlementReceiptInput(
            metadata: metadata,
            modelHash: Self.validModelHash,
            content: content,
            toolCalls: nil,
            finishReason: "stop",
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            terminalState: terminalState,
            terminalStateUnixMS: 1_800_000_000_123,
            issuedAtUnixMS: 1_800_000_000_124
        )
    }

    private func receiptKeyID(_ pubkey: Data) -> String {
        let digest = SHA256.hash(data: pubkey)
        return "ed25519-sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private func XCTAssertNoNativeMTPAccountingFields(
    _ object: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let forbidden = [
        "accepted",
        "billing",
        "draft",
        "mtp",
        "native_mtp",
        "reward",
        "settlement",
        "spec_decode",
        "trust",
    ]
    for key in object.keys {
        let normalized = key.lowercased()
        XCTAssertFalse(
            forbidden.contains(where: normalized.contains),
            "unexpected accelerated-accounting field \(key)",
            file: file,
            line: line
        )
    }
}

private final class NativeMTPAccountingReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
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
