import Foundation
import XCTest
@testable import malibu_cli

// MARK: - SE Liveness Tests (Phase 1, Track P1-C)
//
// These tests exercise the provider side of the se_liveness_challenge /
// se_liveness_response protocol without a real Secure Enclave, using
// SELivenessTestSigning to inject a deterministic P-256 key.

final class SELivenessTests: XCTestCase {

    // MARK: - SELivenessTestSigning unit tests

    func testTestSigningGeneratesKey() throws {
        let signer = try SELivenessTestSigning.generate()
        let pubKeyData = Data(base64Encoded: signer.publicKeyBase64)
        XCTAssertNotNil(pubKeyData, "publicKeyBase64 must decode")
        XCTAssertEqual(pubKeyData?.count, 64, "P-256 raw public key is 64 bytes (X||Y)")
    }

    func testTestSigningProducesVerifiableSignature() throws {
        let signer = try SELivenessTestSigning.generate()
        let message = "abc123xyz2026-01-01T00:00:00Z".data(using: .utf8)!
        let sig = try signer.sign(message)
        XCTAssertFalse(sig.isEmpty, "signature must not be empty")

        // Verify the DER signature round-trips through SecKeyVerifySignature.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        // Reconstruct uncompressed key (add 0x04 prefix)
        var rawPub = Data([0x04])
        rawPub.append(Data(base64Encoded: signer.publicKeyBase64)!)
        var importError: Unmanaged<CFError>?
        guard let pubKey = SecKeyCreateWithData(
            rawPub as CFData,
            attributes as CFDictionary,
            &importError
        ) else {
            XCTFail("could not reconstruct public key: \(importError!.takeRetainedValue())")
            return
        }
        var verifyError: Unmanaged<CFError>?
        let valid = SecKeyVerifySignature(
            pubKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            sig as CFData,
            &verifyError
        )
        XCTAssertTrue(valid, "signature must verify with corresponding public key")
    }

    // MARK: - CoordinatorClient SE liveness handler tests

    /// A minimal mock that records outbound messages so tests can inspect them.
    private final class MessageCapture: @unchecked Sendable {
        var sent: [[String: Any]] = []
        let lock = NSLock()

        func record(_ msg: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            sent.append(msg)
        }

        func last() -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            return sent.last
        }
    }

    /// Helper: builds a minimal inbound `se_liveness_challenge` dict.
    private func challengeDict(nonce: String = "testnonce123", timestamp: String = "2026-01-01T00:00:00Z") -> [String: Any] {
        ["type": "se_liveness_challenge", "version": 1, "nonce": nonce, "timestamp": timestamp]
    }

    func testSELivenessSigningProtocolConformance() throws {
        // The protocol has exactly two requirements. Verify the test signer
        // satisfies them without runtime error.
        let signer: any SELivenessSigning = try SELivenessTestSigning.generate()
        let data = "probe".data(using: .utf8)!
        let sig = try signer.sign(data)
        XCTAssertFalse(sig.isEmpty)
        XCTAssertFalse(signer.publicKeyBase64.isEmpty)
    }
}
