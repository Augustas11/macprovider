import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelTransactionContextTests: XCTestCase {
    private struct Fixture {
        let home: URL
        let config: URL
        let root: URL
        var environment: [String: String] { ["HOME": home.path, "PATH": "/usr/bin:/bin"] }
        init() throws {
            home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("model-context-" + UUID().uuidString.lowercased())
            config = home.appendingPathComponent(".config/macprovider/config.yaml")
            root = home.appendingPathComponent("models")
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try Data("model: model-a\nmodel_artifact_root: \(root.path)\n".utf8).write(to: config)
            XCTAssertEqual(chmod(config.path, 0o600), 0)
        }
        func remove() { try? FileManager.default.removeItem(at: home) }
        func prepare() throws -> PreparedModelTransactionContext {
            try ModelTransactionContextLoader.prepareProjection(configPath: config.path, environment: environment, homeDirectory: home)
        }
        func bind() throws -> BoundModelTransactionContext {
            let prepared = try prepare()
            let setup = try ModelCatalogTransactionStore.prepareProjectionStore(prepared)
            return try ModelTransactionContextLoader.finalizeProjection(context: prepared, storeIdentity: setup.identity)
        }
        func expectation(_ digest: String) throws -> [String: Any] {
            var info = stat()
            XCTAssertEqual(lstat(config.path, &info), 0)
            return ["schema": "model_transaction_context_expectation.v1", "transaction_context_sha256": digest,
                    "config_path": config.path, "config_device": UInt64(info.st_dev), "config_inode": UInt64(info.st_ino),
                    "config_size": UInt64(info.st_size), "config_sha256": SHA256.hash(data: try Data(contentsOf: config)).map { String(format: "%02x", $0) }.joined(),
                    "uid": UInt64(geteuid()), "home_directory": home.path]
        }
        func load(_ expected: [String: Any], environment alternate: [String: String]? = nil) throws -> BoundModelTransactionContext {
            let data = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
            var descriptors: [Int32] = [0, 0]
            XCTAssertEqual(pipe(&descriptors), 0)
            defer { close(descriptors[0]) }
            let count = data.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
            close(descriptors[1])
            XCTAssertEqual(count, data.count)
            var options = ModelTransactionContextOptions()
            options.transactionContextFD = descriptors[0]
            return try ModelTransactionContextLoader.load(configPath: config.path, options: options,
                environment: alternate ?? environment, homeDirectory: home)
        }
    }

    func testFirstProjectionSetupAndExactBoundInvocation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let prepared = try fixture.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        let setup = try ModelCatalogTransactionStore.prepareProjectionStore(prepared)
        let bound = try ModelTransactionContextLoader.finalizeProjection(context: prepared, storeIdentity: setup.identity)
        XCTAssertEqual(bound.projectionDigest.count, 64)
        XCTAssertEqual(bound.config.model, "model-a")
        let loaded = try fixture.load(fixture.expectation(bound.projectionDigest))
        XCTAssertEqual(loaded.projectionDigest, bound.projectionDigest)
        XCTAssertEqual(loaded.transactionRoot, bound.transactionRoot)
    }

    func testMissingRootBoundInvocationDoesNotCreateAnything() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let expected = try fixture.expectation(String(repeating: "a", count: 64))
        XCTAssertThrowsError(try fixture.load(expected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    func testConfigReplacementFailsOldExpectationWithoutTouchingOtherRoot() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bound = try fixture.bind()
        let expected = try fixture.expectation(bound.projectionDigest)
        let other = fixture.home.appendingPathComponent("other-models")
        let replacement = fixture.config.deletingLastPathComponent().appendingPathComponent("replacement.yaml")
        try Data("model: model-b\nmodel_artifact_root: \(other.path)\n".utf8).write(to: replacement)
        XCTAssertEqual(chmod(replacement.path, 0o600), 0)
        XCTAssertEqual(rename(replacement.path, fixture.config.path), 0)
        let before = try FileManager.default.contentsOfDirectory(atPath: bound.transactionRoot.path)
        XCTAssertThrowsError(try fixture.load(expected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bound.transactionRoot.path), before)
    }

    func testFinalizationRejectsReplacedConfigWithoutRebindingCapturedValues() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let prepared = try fixture.prepare()
        let setup = try ModelCatalogTransactionStore.prepareProjectionStore(prepared)
        let replacement = fixture.config.deletingLastPathComponent().appendingPathComponent("replacement.yaml")
        try Data("model: model-b\nmodel_artifact_root: \(fixture.home.path)/other\n".utf8).write(to: replacement)
        XCTAssertEqual(chmod(replacement.path, 0o600), 0)
        XCTAssertEqual(rename(replacement.path, fixture.config.path), 0)
        XCTAssertThrowsError(try ModelTransactionContextLoader.finalizeProjection(context: prepared, storeIdentity: setup.identity))
        XCTAssertEqual(prepared.config.model, "model-a")
        XCTAssertEqual(prepared.durableRoot.resolvingSymlinksInPath().path, fixture.root.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("other").path))
    }

    func testRootReplacementCannotRebindProjectionOrControl() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let prepared = try fixture.prepare()
        let setup = try ModelCatalogTransactionStore.prepareProjectionStore(prepared)
        let bound = try ModelTransactionContextLoader.finalizeProjection(context: prepared, storeIdentity: setup.identity)
        let expected = try fixture.expectation(bound.projectionDigest)
        try FileManager.default.moveItem(at: fixture.root, to: fixture.home.appendingPathComponent("old-models"))
        try FileManager.default.createDirectory(at: bound.transactionRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try ModelTransactionContextLoader.finalizeProjection(context: prepared, storeIdentity: setup.identity))
        XCTAssertThrowsError(try fixture.load(expected))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: bound.transactionRoot.path).isEmpty)
    }

    func testForeignContextFieldsAndEnvironmentFailClosed() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bound = try fixture.bind()
        let expected = try fixture.expectation(bound.projectionDigest)
        for key in ["transaction_context_sha256", "config_sha256", "config_path", "home_directory", "schema"] {
            var bad = expected
            bad[key] = key.contains("sha256") ? String(repeating: "f", count: 64) : "wrong"
            XCTAssertThrowsError(try fixture.load(bad), key)
        }
        for key in ["config_device", "config_inode", "config_size", "uid"] {
            var bad = expected; bad[key] = UInt64.max
            XCTAssertThrowsError(try fixture.load(bad), key)
            bad[key] = true
            XCTAssertThrowsError(try fixture.load(bad), key)
        }
        var unknown = expected; unknown["unknown"] = "value"
        XCTAssertThrowsError(try fixture.load(unknown))
        for key in ["MACPROVIDER_MODEL_ARTIFACT_ROOT", "HF_HOME", "HF_HUB_CACHE", "MACPROVIDER_CONFIG"] {
            var environment = fixture.environment; environment[key] = fixture.home.path
            XCTAssertThrowsError(try fixture.load(expected, environment: environment), key)
        }
    }

    func testUnsafeConfigAndSymlinkAncestorsNeverPrepareRoots() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        XCTAssertEqual(chmod(fixture.config.path, 0o644), 0)
        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertEqual(chmod(fixture.config.path, 0o600), 0)
        let original = fixture.config.deletingLastPathComponent().appendingPathComponent("original.yaml")
        try FileManager.default.moveItem(at: fixture.config, to: original)
        try FileManager.default.createSymbolicLink(at: fixture.config, withDestinationURL: original)
        XCTAssertThrowsError(try fixture.prepare())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }
}
