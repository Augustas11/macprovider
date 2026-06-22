import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class ReceiptBuilderTests: XCTestCase {
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
                unixTsSeconds: 1_800_000_000
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

        XCTAssertEqual(Set(tuple.keys), [
            "model_id",
            "prompt_hash",
            "output_hash",
            "provider_pubkey",
            "ttft_ms",
            "tokens_out",
            "unix_ts",
        ])
        XCTAssertTrue(publicKey.isValidSignature(signature, for: tupleData))
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
                unixTsSeconds: 1
            )
        )) { error in
            XCTAssertEqual(error as? ReceiptBuilder.Error, .nonASCIIModelId)
        }
    }
}
private final class FixedReceiptKeyStore: ReceiptKeyStoring {
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
