import CryptoKit
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ReceiptAuditTests: XCTestCase {
    func testReceiptIssuedPayloadCarriesOnlyAllowedEventFields() throws {
        let payload = try payloadObject(ReceiptAudit.issuedPayload(
            providerID: "provider-a",
            requestID: "req-1",
            modelID: "fixture-model",
            tokensOut: 7,
            ttftMs: 12,
            unixTs: 1_800_000_000
        ))

        XCTAssertEqual(payload["event"] as? String, "receipt_issued")
        XCTAssertEqual(payload["provider_id"] as? String, "provider-a")
        XCTAssertEqual(payload["request_id"] as? String, "req-1")
        XCTAssertEqual(payload["model_id"] as? String, "fixture-model")
        XCTAssertEqual(payload["tokens_out"] as? Int, 7)
        XCTAssertEqual(payload["ttft_ms"] as? Int, 12)
        XCTAssertEqual(payload["unix_ts"] as? Int, 1_800_000_000)
        for forbidden in ["provider_pubkey", "prompt_hash", "output_hash", "signature", "receipt"] {
            XCTAssertNil(payload[forbidden], "receipt_issued leaked forbidden field \(forbidden)")
        }
    }

    func testReceiptOmittedPayloadSupportsEverySpecReason() throws {
        let expected = Set([
            "pre_v1_6_binary",
            "no_keypair",
            "model_swap_violation",
            "pre_token_cancel",
            "streaming_request",
            "construction_failed",
            "write_failed",
        ])
        let got = try Set(ReceiptOmissionReason.allCases.map { reason in
            let payload = try payloadObject(ReceiptAudit.omittedPayload(providerID: "provider-a", requestID: "req-1", reason: reason))
            XCTAssertEqual(payload["event"] as? String, "receipt_omitted")
            XCTAssertEqual(payload["provider_id"] as? String, "provider-a")
            XCTAssertEqual(payload["request_id"] as? String, "req-1")
            XCTAssertNil(payload["prompt_hash"])
            XCTAssertNil(payload["output_hash"])
            XCTAssertNil(payload["signature"])
            return try XCTUnwrap(payload["reason"] as? String)
        })
        XCTAssertEqual(got, expected)
    }

    func testReceiptResultMapsMissingBuilderToPreV16Binary() throws {
        let result = try RouterHandler.receiptHeaderResult(
            providerID: "provider-a",
            receiptBuilder: nil,
            request: fixtureRequest(),
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 1,
            tokensOut: 1,
            unixTsSeconds: 1
        )
        XCTAssertEqual(result, RouterHandler.ReceiptHeaderResult.omitted(.preV16Binary))
    }

    func testReceiptResultMapsMissingKeypairToNoKeypair() throws {
        let result = try RouterHandler.receiptHeaderResult(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: AuditEmptyReceiptKeyStore()),
            request: fixtureRequest(),
            outputContent: "answer",
            outputToolCalls: nil,
            finishReason: "stop",
            ttftMs: 1,
            tokensOut: 1,
            unixTsSeconds: 1
        )
        XCTAssertEqual(result, RouterHandler.ReceiptHeaderResult.omitted(.noKeypair))
    }

    func testErrorReceiptResultMapsNonNullUsageSuppressionToPreTokenCancel() throws {
        let result = try RouterHandler.errorReceiptHeaderResult(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: AuditFixedReceiptKeyStore(key: Curve25519.Signing.PrivateKey())),
            request: fixtureRequest(),
            error: APIError(status: 499, message: "cancelled", type: "server_error", code: "buyer_cancelled"),
            startedAt: Date()
        )
        XCTAssertEqual(result, RouterHandler.ErrorReceiptHeaderResult.omitted(.preTokenCancel))
    }


    func testErrorReceiptResultLeavesUnrelatedNonNullUsageErrorUnaudited() throws {
        let result = try RouterHandler.errorReceiptHeaderResult(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: AuditFixedReceiptKeyStore(key: Curve25519.Signing.PrivateKey())),
            request: fixtureRequest(),
            error: APIError(status: 503, message: "loading", type: "server_error", code: "provider_loading"),
            startedAt: Date()
        )
        XCTAssertEqual(result, RouterHandler.ErrorReceiptHeaderResult.notReceiptEligible)
    }

    func testErrorReceiptResultMapsSwapDrainSuppressionToModelSwapViolation() throws {
        let result = try RouterHandler.errorReceiptHeaderResult(
            providerID: "provider-a",
            receiptBuilder: ReceiptBuilder(keyStore: AuditFixedReceiptKeyStore(key: Curve25519.Signing.PrivateKey())),
            request: fixtureRequest(),
            error: APIError(status: 503, message: "drain", type: "server_error", code: "swap_drain_timeout"),
            startedAt: Date()
        )
        XCTAssertEqual(result, RouterHandler.ErrorReceiptHeaderResult.omitted(.modelSwapViolation))
    }
}

private func payloadObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func fixtureRequest() throws -> ChatCompletionRequest {
    try parseRequest([
        "model": "fixture-model",
        "messages": [["role": "user", "content": "hello"]],
    ])
}

private final class AuditFixedReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let key: Curve25519.Signing.PrivateKey

    init(key: Curve25519.Signing.PrivateKey) {
        self.key = key
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey { key }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? { key }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}

private final class AuditEmptyReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey { Curve25519.Signing.PrivateKey() }
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? { nil }
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {}
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {}
}
