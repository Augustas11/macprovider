import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class AcceptanceCandidateMetadataTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let controlCommit = String(repeating: "b", count: 40)
    private let tag = "v1.8.35"
    private let runID = "123456789"
    private let checksums = Data("0123456789abcdef  macprovider-cli-v1.8.35-darwin-arm64.tar.gz\n".utf8)

    func testValidMetadataBindsExactCandidateIdentity() throws {
        let parsed = try AcceptanceCandidateMetadata.loadValidated(
            metadata: try makeMetadata(),
            checksums: checksums,
            expectedTag: tag,
            expectedCandidateCommit: commit,
            expectedControlCommit: controlCommit,
            expectedRunID: runID,
            expectedRunAttempt: 2,
            now: try timestamp("2026-07-14T12:30:00Z")
        )

        XCTAssertEqual(
            parsed.compatibilitySetID,
            "Augustas11/macprovider:v1.8.35@\(commit)"
        )
    }

    func testSignaturePayloadHasCryptographicDomainPrefix() throws {
        let metadata = try makeMetadata()
        let payload = AcceptanceCandidateMetadata.signaturePayload(metadata: metadata)

        XCTAssertTrue(payload.starts(with: Data("macprovider.acceptance-candidate.v1\n".utf8)))
        XCTAssertNotEqual(payload, metadata)
        XCTAssertNotEqual(payload, checksums)
    }

    func testCommittedAcceptanceKeyIsValidAndDistinctFromProduction() throws {
        let acceptanceKey = try P256.Signing.PublicKey(
            pemRepresentation: AcceptanceCandidateMetadata.signingPublicKeyPEM
        )
        let productionKey = try P256.Signing.PublicKey(
            pemRepresentation: SelfUpdate.checksumPublicKeyPEM
        )

        XCTAssertNotEqual(acceptanceKey.rawRepresentation, productionKey.rawRepresentation)
    }

    func testWrongChannelIsRejectedEvenWhenCanonical() throws {
        XCTAssertThrowsError(try validate(overrides: ["channel": "production"])) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.acceptanceMetadataInvalid("signature_domain").description
            )
        }
    }

    func testWrongExpectedCommitAndRunAreRejected() throws {
        XCTAssertThrowsError(
            try AcceptanceCandidateMetadata.loadValidated(
                metadata: try makeMetadata(),
                checksums: checksums,
                expectedTag: tag,
                expectedCandidateCommit: String(repeating: "c", count: 40),
                expectedControlCommit: controlCommit,
                expectedRunID: runID,
                expectedRunAttempt: 2,
                now: try timestamp("2026-07-14T12:30:00Z")
            )
        )
        XCTAssertThrowsError(
            try AcceptanceCandidateMetadata.loadValidated(
                metadata: try makeMetadata(),
                checksums: checksums,
                expectedTag: tag,
                expectedCandidateCommit: commit,
                expectedControlCommit: controlCommit,
                expectedRunID: "987654321",
                expectedRunAttempt: 2,
                now: try timestamp("2026-07-14T12:30:00Z")
            )
        )
    }

    func testExpiredMetadataIsRejected() throws {
        XCTAssertThrowsError(
            try validate(
                overrides: [
                    "issued_at": "2026-07-13T12:00:00Z",
                    "expires_at": "2026-07-14T12:00:00Z",
                ]
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.acceptanceMetadataInvalid("expired").description
            )
        }
    }

    private func validate(overrides: [String: String]) throws -> AcceptanceCandidateMetadata {
        try AcceptanceCandidateMetadata.loadValidated(
            metadata: try makeMetadata(overrides: overrides),
            checksums: checksums,
            expectedTag: tag,
            expectedCandidateCommit: commit,
            expectedControlCommit: controlCommit,
            expectedRunID: runID,
            expectedRunAttempt: 2,
            now: try timestamp("2026-07-14T12:30:00Z")
        )
    }

    private func makeMetadata(overrides: [String: String] = [:]) throws -> Data {
        let checksumDigest = SHA256.hash(data: checksums).map { String(format: "%02x", $0) }.joined()
        var object: [String: Any] = [
            "channel": "acceptance",
            "checksums": ["name": "checksums.txt", "sha256": checksumDigest],
            "candidate_commit": commit,
            "candidate_ref": "refs/heads/fix/585-provider-lifecycle-option2",
            "control_commit": controlCommit,
            "compatibility_set_id": "Augustas11/macprovider:\(tag)@\(commit)",
            "expires_at": "2026-07-14T13:00:00Z",
            "issued_at": "2026-07-14T12:00:00Z",
            "repository": "Augustas11/macprovider",
            "run_id": runID,
            "run_attempt": 2,
            "schema_version": "macprovider.acceptance-candidate.v1",
            "signing": [
                "algorithm": "ecdsa-p256-sha256",
                "key_id": "macprovider-acceptance-p256-v1",
            ],
            "tag": tag,
        ]
        for (key, value) in overrides { object[key] = value }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }

    private func timestamp(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: raw))
    }
}
