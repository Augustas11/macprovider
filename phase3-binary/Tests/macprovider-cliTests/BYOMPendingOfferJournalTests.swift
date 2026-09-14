import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class BYOMPendingOfferJournalTests: XCTestCase {
    func testRestartLoadsExactEnvelopeAndPrivateFileModes() throws {
        let fixture = try makeFixture()
        var operation: BYOMPendingOfferJournal.Operation? = try operation(fixture)
        let record = try XCTUnwrap(operation).persist(fixture.package.request, replacing: nil)
        let recorded = try recordURL(fixture)
        let before = try Data(contentsOf: recorded)
        operation = nil
        let restarted = try self.operation(fixture)
        XCTAssertEqual(try restarted.load()?.envelope, fixture.package.request)
        XCTAssertEqual(try restarted.load()?.generation, record.generation)
        XCTAssertEqual(try Data(contentsOf: recorded), before)
        let mode = try FileManager.default.attributesOfItem(atPath: recorded.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let rootMode = try FileManager.default.attributesOfItem(atPath: recorded.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(rootMode?.intValue, 0o700)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains(fixture.key.rawRepresentation.base64EncodedString()))
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("Bearer"))
    }

    func testOperationLockAndGenerationRejectCompetingOrLateWrites() throws {
        let fixture = try makeFixture()
        let first = try operation(fixture)
        let record = try first.persist(fixture.package.request, replacing: nil)
        XCTAssertThrowsError(try operation(fixture))
        XCTAssertThrowsError(try first.persist(fixture.package.request, replacing: "stale-generation"))
        XCTAssertThrowsError(try first.reconcile(generation: "stale-generation", terminal: true))
        XCTAssertEqual(try first.load()?.generation, record.generation)
        let next = try first.persist(fixture.package.request, replacing: record.generation)
        XCTAssertThrowsError(try first.reconcile(generation: record.generation, terminal: true))
        XCTAssertEqual(try first.load()?.generation, next.generation)
        try first.reconcile(generation: next.generation, terminal: true)
        XCTAssertNil(try first.load())
        let replacement = try first.persist(fixture.package.request, replacing: nil)
        XCTAssertThrowsError(try first.reconcile(generation: next.generation, terminal: true))
        XCTAssertEqual(try first.load()?.generation, replacement.generation)
    }

    func testCorruptCrossIdentityAndUnknownFieldRecordsFailClosed() throws {
        let fixture = try makeFixture()
        let operation = try self.operation(fixture)
        _ = try operation.persist(fixture.package.request, replacing: nil)
        let url = try recordURL(fixture)
        let original = try Data(contentsOf: url)
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try operation.load())
        for field in ["provider_id", "candidate_id"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var envelope = try XCTUnwrap(object["envelope"] as? [String: Any])
            envelope[field] = "substituted"
            object["envelope"] = envelope
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertThrowsError(try operation.load())
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["untrusted_extra"] = "unexpected"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try operation.load())
    }

    func testSymlinkRootAndRecordAreRejectedWithoutFollowingThem() throws {
        let fixture = try makeFixture()
        let parent = fixture.namespace.deletingLastPathComponent()
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journal = parent.appendingPathComponent("pending-offers")
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)
        XCTAssertThrowsError(try operation(fixture))
        try FileManager.default.removeItem(at: journal)
        let operation = try self.operation(fixture)
        _ = try operation.persist(fixture.package.request, replacing: nil)
        let url = try recordURL(fixture)
        let outsideFile = outside.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: url, to: outsideFile)
        let bytes = try Data(contentsOf: outsideFile)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outsideFile)
        XCTAssertThrowsError(try operation.load())
        XCTAssertEqual(try Data(contentsOf: outsideFile), bytes)
    }

    func testCountAndPayloadBoundsPreventPublication() throws {
        let fixture = try makeFixture()
        let operation = try self.operation(fixture)
        let journal = fixture.namespace.deletingLastPathComponent().appendingPathComponent("pending-offers")
        for index in 0..<BYOMPendingOfferJournal.maxRecords {
            try Data("occupied".utf8).write(to: journal.appendingPathComponent("occupied-\(index).json"))
        }
        XCTAssertThrowsError(try operation.persist(fixture.package.request, replacing: nil))
        XCTAssertNil(try operation.load())
        let large = try BYOMOfferSubmissionBuilder.makePackage(
            providerID: fixture.package.request.providerID, candidate: fixture.candidate,
            admissionIdentity: fixture.key, evaluationDigestSHA256: nil,
            requestedDisclosureClass: "non_earning_provider_asserted",
            cliVersion: String(repeating: "x", count: BYOMPendingOfferJournal.maxBytes)
        )
        XCTAssertThrowsError(try operation.persist(large.request, replacing: nil))
    }

    func testRepositoryRootIsRejectedWithoutCreatingJournal() throws {
        let fixture = try makeFixture()
        var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            root.deleteLastPathComponent()
        }
        let existing = FileManager.default.fileExists(atPath: root.appendingPathComponent("pending-offers").path)
        XCTAssertThrowsError(try BYOMPendingOfferJournal.Operation(
            namespaceURL: root.appendingPathComponent("test-namespace"),
            providerID: fixture.package.request.providerID, candidateID: fixture.package.request.candidateID
        ))
        XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent("pending-offers").path), existing)
    }

    func testAnotherRepositoryCannotBeUsedAsJournalRoot() throws {
        let fixture = try makeFixture()
        let other = fixture.namespace.deletingLastPathComponent().appendingPathComponent("other-repo")
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".git"),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try BYOMPendingOfferJournal.Operation(namespaceURL: other.appendingPathComponent("namespace"),
            providerID: fixture.package.request.providerID, candidateID: fixture.package.request.candidateID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("pending-offers").path))
    }

    func testUnsafePermissionsFailWithoutChmodOrPublication() throws {
        let fixture = try makeFixture()
        let parent = fixture.namespace.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        XCTAssertThrowsError(try operation(fixture))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("pending-offers").path))
    }

    private struct Fixture {
        let namespace: URL
        let candidate: BYOMDiscoveryWire.Candidate
        let key: Curve25519.Signing.PrivateKey
        let package: BYOMOfferSubmissionPackage
    }

    private func operation(_ fixture: Fixture) throws -> BYOMPendingOfferJournal.Operation {
        try BYOMPendingOfferJournal.Operation(namespaceURL: fixture.namespace,
            providerID: fixture.package.request.providerID, candidateID: fixture.package.request.candidateID)
    }

    private func recordURL(_ fixture: Fixture) throws -> URL {
        let root = fixture.namespace.deletingLastPathComponent().appendingPathComponent("pending-offers")
        return try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? fm.removeItem(at: root) }
        let namespace = root.appendingPathComponent("namespace")
        _ = BYOMDiscoveryNamespaceStore().provisionNamespaceIfMissing(at: namespace)
        let cache = root.appendingPathComponent("hf")
        let snapshot = cache.appendingPathComponent("models--mlx-community--Tiny-1B-4bit/snapshots/" + String(repeating: "1", count: 40))
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: snapshot.appendingPathComponent("weights.safetensors"))
        let candidate = try XCTUnwrap(BYOMMLXCacheDiscovery(
            cacheRoot: cache, namespace: Data(contentsOf: namespace),
            catalogMatcher: BYOMCatalogMatcher(candidateBytes: Data(), artifactFeed: nil)
        ).discover().candidates.first)
        let key = Curve25519.Signing.PrivateKey()
        return Fixture(namespace: namespace, candidate: candidate, key: key,
                       package: try BYOMOfferSubmissionBuilder.makePackage(
                        providerID: "journal-provider", candidate: candidate, admissionIdentity: key,
                        evaluationDigestSHA256: nil, requestedDisclosureClass: "non_earning_provider_asserted"
                       ))
    }
}
