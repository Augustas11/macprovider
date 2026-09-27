import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class Build1PrivateAuthorityTests: XCTestCase {
    func testCommittedOrcaRouterAuthorityVerifiesAndRemainsPrivate() throws {
        let fixture = Self.committedFixture()
        let authority = try Build1PrivateAuthorityLoader.load(
            authorityURL: fixture.authority,
            signatureURL: fixture.signature,
            now: Self.date("2026-09-27T00:00:00Z")
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
                now: Self.date("2026-09-27T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? Build1PrivateAuthorityError, .invalid("signature_invalid"))
        }
    }

    func testAuthorityRejectsExpiredRelease() throws {
        let fixture = Self.committedFixture()
        XCTAssertThrowsError(
            try Build1PrivateAuthorityLoader.load(
                authorityURL: fixture.authority,
                signatureURL: fixture.signature,
                now: Self.date("2026-10-11T00:00:00Z")
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
                now: Self.date("2026-09-27T00:00:00Z"),
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
        root["catalog_guard"] = guardObject
        try Self.write(root, to: fixture.urls.authority)

        XCTAssertThrowsError(
            try Build1PrivateAuthorityLoader.load(
                authorityURL: fixture.urls.authority,
                signatureURL: fixture.urls.signature,
                now: Self.date("2026-09-27T00:00:00Z"),
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
                now: Self.date("2026-09-27T00:00:00Z"),
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
                now: Self.date("2026-09-27T00:00:00Z")
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
