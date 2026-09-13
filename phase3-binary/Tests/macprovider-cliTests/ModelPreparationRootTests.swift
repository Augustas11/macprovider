import Darwin
import Foundation
@testable import macprovider_cli
import XCTest

final class ModelPreparationRootTests: XCTestCase {
    func testBootstrapCreatesPrivateStateNamespaceAndRawStableRootIdentity() throws {
        let fixture = try StoreFixture.make("model-prep-root")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try fixture.store.bootstrap()
        let second = try fixture.store.bootstrap()

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.namespacePath.hasSuffix("/artifact/.macprovider-prepared-v3"))
        try assertMode(fixture.authority, type: S_IFDIR, mode: 0o700)
        try assertMode(fixture.authority.appendingPathComponent("state", isDirectory: true), type: S_IFDIR, mode: 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.authority.appendingPathComponent("state-tmp", isDirectory: true).path))
        for leaf in ModelPreparationPrivateStore.lockLeaves {
            try assertMode(fixture.authority.appendingPathComponent(leaf), type: S_IFREG, mode: 0o600, expectedLinkCount: 1)
        }
        let namespace = fixture.artifact.appendingPathComponent(".macprovider-prepared-v3", isDirectory: true)
        try assertMode(namespace, type: S_IFDIR, mode: 0o700)
        try assertMode(namespace.appendingPathComponent("objects", isDirectory: true), type: S_IFDIR, mode: 0o700)
        try assertMode(namespace.appendingPathComponent("work/staging", isDirectory: true), type: S_IFDIR, mode: 0o700)
        try assertMode(namespace.appendingPathComponent("work/unpublished", isDirectory: true), type: S_IFDIR, mode: 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("bootstrap-tmp", isDirectory: true).path))

        let identityURL = namespace.appendingPathComponent("root.identity")
        try assertMode(identityURL, type: S_IFREG, mode: 0o600, expectedLinkCount: 1)
        try assertNoExtendedACL(identityURL)
        let raw = try Data(contentsOf: identityURL)
        XCTAssertThrowsError(try ModelPreparationContracts.decode(ModelPreparationPrivateStateEnvelope.self, from: raw, maxBytes: ModelPreparationContracts.privateStateEnvelopeMaxBytes))
        let identity = try ModelPreparationContracts.decode(ModelPreparationRootIdentityRecord.self, from: raw, maxBytes: ModelPreparationContracts.rootIdentityRecordMaxBytes)
        XCTAssertEqual(identity.canonicalPath, first.rootLocator.canonicalPath)
        XCTAssertEqual(identity.stDev, first.rootLocator.stDev)
        XCTAssertEqual(identity.stIno, first.rootLocator.stIno)
        XCTAssertEqual(try identity.digest, first.rootLocator.rootIdentityDigest)
    }

    func testBootstrapFailsClosedWhenRootIdentityMissingButBootstrapEvidenceExists() throws {
        let fixture = try StoreFixture.make("model-prep-root-temp-evidence")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.store.bootstrap()
        let namespace = fixture.artifact.appendingPathComponent(".macprovider-prepared-v3", isDirectory: true)
        let identity = namespace.appendingPathComponent("root.identity")
        let raw = try Data(contentsOf: identity)
        try FileManager.default.removeItem(at: identity)
        let temp = namespace.appendingPathComponent("root.identity.22222222-2222-4222-8222-222222222222.tmp")
        try raw.write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)

        XCTAssertThrowsError(try fixture.store.bootstrap()) { error in
            XCTAssert(String(describing: error).contains("ambiguous namespace evidence"), String(describing: error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: identity.path))
    }

    func testBootstrapRejectsRootIdentityTempBeforeCreatingNamespaceSkeleton() throws {
        let root = try temporaryDirectory("model-prep-root-temp-only")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let artifact = root.appendingPathComponent("artifact", isDirectory: true)
        let namespace = artifact.appendingPathComponent(".macprovider-prepared-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = namespace.appendingPathComponent("root.identity.22222222-2222-4222-8222-222222222222.tmp")
        try Data("ambiguous".utf8).write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)

        let store = ModelPreparationPrivateStore(authorityRoot: authority, artifactRoot: artifact)
        XCTAssertThrowsError(try store.bootstrap()) { error in
            XCTAssert(String(describing: error).contains("ambiguous namespace evidence"), String(describing: error))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("root.identity").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("objects", isDirectory: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: namespace.appendingPathComponent("work", isDirectory: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: authority.appendingPathComponent("state", isDirectory: true).path))
    }

    func testBootstrapPreservesInvalidRootIdentityAndRejectsSymlinkRoot() throws {
        let fixture = try StoreFixture.make("model-prep-root-invalid")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.store.bootstrap()
        let identity = fixture.artifact.appendingPathComponent(".macprovider-prepared-v3/root.identity")
        let sentinel = Data("not-root".utf8)
        try sentinel.write(to: identity)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)
        XCTAssertThrowsError(try fixture.store.bootstrap())
        XCTAssertEqual(try Data(contentsOf: identity), sentinel)

        let root = try temporaryDirectory("model-prep-root-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let outside = real.appendingPathComponent("sentinel")
        try Data("outside".utf8).write(to: outside)
        let store = ModelPreparationPrivateStore(authorityRoot: root.appendingPathComponent("authority", isDirectory: true), artifactRoot: link)
        XCTAssertThrowsError(try store.bootstrap())
        XCTAssertEqual(try String(contentsOf: outside), "outside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent(".macprovider-prepared-v3").path))
    }

    func testBootstrapRejectsWeakCallerControlledAncestorsBeforeCreatingChildren() throws {
        let root = try temporaryDirectory("model-prep-root-weak-ancestor")
        defer { try? FileManager.default.removeItem(at: root) }
        let weak = root.appendingPathComponent("weak", isDirectory: true)
        try FileManager.default.createDirectory(at: weak, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        let sentinel = weak.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let store = ModelPreparationPrivateStore(
            authorityRoot: weak.appendingPathComponent("authority", isDirectory: true),
            artifactRoot: weak.appendingPathComponent("artifact", isDirectory: true)
        )

        XCTAssertThrowsError(try store.bootstrap()) { error in
            XCTAssert(String(describing: error).contains("ancestor writable by non-owner"), String(describing: error))
        }
        XCTAssertEqual(try String(contentsOf: sentinel), "unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: weak.appendingPathComponent("authority", isDirectory: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: weak.appendingPathComponent("artifact", isDirectory: true).path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: weak.path)
        try addReadACLEntry(to: weak)
        XCTAssertThrowsError(try store.bootstrap()) { error in
            XCTAssert(String(describing: error).contains("extended ACL"), String(describing: error))
        }
        XCTAssertEqual(try String(contentsOf: sentinel), "unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: weak.appendingPathComponent("authority", isDirectory: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: weak.appendingPathComponent("artifact", isDirectory: true).path))
    }

    func testBootstrapRejectsExistingRootIdentityWithExtendedACL() throws {
        let fixture = try StoreFixture.make("model-prep-root-acl")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.store.bootstrap()
        let identity = fixture.artifact.appendingPathComponent(".macprovider-prepared-v3/root.identity")
        try addReadACLEntry(to: identity)
        XCTAssertThrowsError(try fixture.store.bootstrap()) { error in
            XCTAssert(String(describing: error).contains("extended ACL"), String(describing: error))
        }
    }
}
