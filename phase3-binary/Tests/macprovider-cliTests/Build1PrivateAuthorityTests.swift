import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class Build1PrivateAuthorityTests: XCTestCase {
    func testCommittedOrcaRouterAuthorityVerifiesAndRemainsPrivate() throws {
        let fixture = Self.committedFixture()
        // This signed authority binds the historical catalog, not the current bake.
        let candidateBytes = Data(Self.historicalCandidateCatalogJSON().utf8)
        XCTAssertEqual(Build1PrivateAuthorityLoader.sha256Hex(candidateBytes), "559a058f65093b70e1115a152eac4466a4c40eb5854055f61849aea395b0e666")
        let authority = try Build1PrivateAuthorityLoader.load(
            authorityURL: fixture.authority,
            signatureURL: fixture.signature,
            now: Self.date("2026-10-02T00:00:00Z"),
            candidateBytes: candidateBytes
        )

        XCTAssertEqual(authority.catalogKey, Build1PrivatePrepareProfile.modelKey)
        XCTAssertEqual(authority.modelID, Build1PrivatePrepareProfile.modelID)
        XCTAssertEqual(authority.revision, Build1PrivatePrepareProfile.revision)
        XCTAssertEqual(authority.artifactID, Build1PrivatePrepareProfile.artifactID)
        XCTAssertEqual(authority.hashAlgorithm, Build1PrivatePrepareProfile.hashAlgorithm)
        XCTAssertEqual(authority.hash, Build1PrivatePrepareProfile.hash)
        XCTAssertEqual(authority.sizeBytes, Build1PrivatePrepareProfile.sizeBytes)
        XCTAssertEqual(authority.feedSignerKeyID, Build1PrivatePrepareProfile.signerKeyID)

        let catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(
            Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        )
        XCTAssertNil(catalog.rows[Build1PrivatePrepareProfile.modelKey])
    }

    /// The signed authority binds the 2026-10-01 activation catalog: rewind the
    /// current bake's release stamp and drop the rows admitted after it.
    private static func historicalCandidateCatalogJSON() -> String {
        var json = AutotuneStaticInputs.bakedCandidateCatalogJSON
            .replacingOccurrences(of: "published-2026-10-20-glm53-flash-cb-ceiling-v1", with: "published-2026-10-01-artifact-feed-activation-v1")
            .replacingOccurrences(of: "2026-10-18T00:00:00Z", with: "2026-10-01T04:20:42Z")
        if let start = json.range(of: "\"mlx-community/qwen2-vl-2b-instruct-4bit\":"),
           let next = json.range(of: "\"nvidia/nemotron-3-nano-30b-a3b\":", range: start.upperBound..<json.endIndex) {
            json.removeSubrange(start.lowerBound..<next.lowerBound)
        }
        // The last row: drop it with its leading comma, keeping the rows object's brace.
        if let start = json.range(of: ",\"zai-org/glm-5.3-flash\":"),
           let end = json.range(of: "}},\"source\":\"operator_curated_autotune_candidate_catalog\"",
                                range: start.upperBound..<json.endIndex) {
            json.removeSubrange(start.lowerBound..<json.index(after: end.lowerBound))
        }
        return json
    }

    func testCommittedAuthorityRejectsTampering() throws {
        let fixture = Self.committedFixture()
        let temporary = try temporaryFixture()
        var bytes = try Data(contentsOf: fixture.authority)
        let original = Data("94723099062".utf8)
        let replacement = Data("94723099063".utf8)
        let range = try XCTUnwrap(bytes.range(of: original))
        bytes.replaceSubrange(range, with: replacement)
        try bytes.write(to: temporary.authority)
        try Data(contentsOf: fixture.signature).write(to: temporary.signature)

        XCTAssertThrowsError(
            try Build1PrivateAuthorityLoader.load(
                authorityURL: temporary.authority,
                signatureURL: temporary.signature,
                now: Self.date("2026-10-02T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? Build1PrivateAuthorityError, .invalid("signature_invalid"))
        }
    }

    // expires_at is structural only (#1938): the signed authority keeps
    // verifying after its calendar date; only a future generated_at is refused.
    func testAuthorityRemainsValidPastExpiresAt() throws {
        let fixture = Self.committedFixture()
        let candidateBytes = Data(Self.historicalCandidateCatalogJSON().utf8)
        let authority = try Build1PrivateAuthorityLoader.load(
            authorityURL: fixture.authority,
            signatureURL: fixture.signature,
            now: Self.date("2027-06-01T00:00:00Z"),
            candidateBytes: candidateBytes
        )
        XCTAssertEqual(authority.hash, Build1PrivatePrepareProfile.hash)

        XCTAssertThrowsError(
            try Build1PrivateAuthorityLoader.load(
                authorityURL: fixture.authority,
                signatureURL: fixture.signature,
                now: Self.date("2026-09-01T00:00:00Z"),
                candidateBytes: candidateBytes
            )
        ) { error in
            XCTAssertEqual(error as? Build1PrivateAuthorityError, .invalid("release_or_freshness_invalid"))
        }
    }

    func testAuthorityRejectsArtifactDriftEvenWithValidSignatureDecision() throws {
        let fixture = try mutableFixture()
        var root = fixture.root
        var artifact = root["artifact"] as! [String: Any]
        artifact["hash"] = String(repeating: "0", count: 64)
        root["artifact"] = artifact
        try Self.write(root, to: fixture.urls.authority)

        XCTAssertThrowsError(
            try Build1PrivateAuthorityLoader.load(
                authorityURL: fixture.urls.authority,
                signatureURL: fixture.urls.signature,
                now: Self.date("2026-10-02T00:00:00Z"),
                verifySignature: { _, _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? Build1PrivateAuthorityError, .invalid("artifact_tuple_mismatch"))
        }
    }

    func testAuthorityRejectsWhenPrivateTupleAppearsInCandidateCatalog() throws {
        let fixture = try mutableFixture()
        var candidate = try JSONSerialization.jsonObject(
            with: Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        ) as! [String: Any]
        var rows = candidate["rows"] as! [String: Any]
        rows[Build1PrivatePrepareProfile.modelKey] = rows[Build1LaneAPrepareProfile.catalogKey]
        candidate["rows"] = rows
        let candidateBytes = try JSONSerialization.data(
            withJSONObject: candidate,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        var root = fixture.root
        var guardObject = root["catalog_guard"] as! [String: Any]
        guardObject["candidate_catalog_sha256"] = Build1PrivateAuthorityLoader.sha256Hex(candidateBytes)
        guardObject["candidate_release_id"] = candidate["version"]
        root["catalog_guard"] = guardObject
        try Self.write(root, to: fixture.urls.authority)

        XCTAssertThrowsError(
            try Build1PrivateAuthorityLoader.load(
                authorityURL: fixture.urls.authority,
                signatureURL: fixture.urls.signature,
                now: Self.date("2026-10-02T00:00:00Z"),
                candidateBytes: candidateBytes,
                verifySignature: { _, _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? Build1PrivateAuthorityError, .invalid("public_catalog_guard_failed"))
        }
    }

    func testAuthorityRejectsUnknownFields() throws {
        let fixture = try mutableFixture()
        var root = fixture.root
        root["unexpected"] = true
        try Self.write(root, to: fixture.urls.authority)

        XCTAssertThrowsError(
            try Build1PrivateAuthorityLoader.load(
                authorityURL: fixture.urls.authority,
                signatureURL: fixture.urls.signature,
                now: Self.date("2026-10-02T00:00:00Z"),
                verifySignature: { _, _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? Build1PrivateAuthorityError, .invalid("authority_keys_invalid"))
        }
    }

    func testAuthorityRejectsSymlinkBeforeReading() throws {
        let committed = Self.committedFixture()
        let temporary = try temporaryFixture()
        try FileManager.default.createSymbolicLink(
            at: temporary.authority,
            withDestinationURL: committed.authority
        )
        try Data(contentsOf: committed.signature).write(to: temporary.signature)

        XCTAssertThrowsError(
            try Build1PrivateAuthorityLoader.load(
                authorityURL: temporary.authority,
                signatureURL: temporary.signature,
                now: Self.date("2026-10-02T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? Build1PrivateAuthorityError, .invalid("authority_unavailable"))
        }
    }

    private typealias FixtureURLs = (authority: URL, signature: URL)

    private static func committedFixture() -> FixtureURLs {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let authority = package
            .appendingPathComponent("catalog/build1-private/orcarouter-qwen3.8-27b-uncensored-authority.json")
        return (authority, authority.appendingPathExtension("sig"))
    }

    private func temporaryFixture() throws -> FixtureURLs {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("build1-private-authority-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (
            directory.appendingPathComponent("authority.json"),
            directory.appendingPathComponent("authority.json.sig")
        )
    }

    private func mutableFixture() throws -> (urls: FixtureURLs, root: [String: Any]) {
        let committed = Self.committedFixture()
        let urls = try temporaryFixture()
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: committed.authority)) as! [String: Any]
        try Self.write(root, to: urls.authority)
        let sidecar: [String: Any] = [
            "alg": "ed25519",
            "key_id": Build1PrivatePrepareProfile.signerKeyID,
            "signature": Data(repeating: 0, count: 64).base64EncodedString(),
        ]
        try Self.write(sidecar, to: urls.signature)
        return (urls, root)
    }

    private static func write(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ).write(to: url)
    }

    private static func date(_ raw: String) -> Date {
        ISO8601DateFormatter.autotuneInternet.date(from: raw)!
    }

}
