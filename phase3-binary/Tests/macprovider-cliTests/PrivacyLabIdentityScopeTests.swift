import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class PrivacyLabIdentityScopeTests: XCTestCase {
    func testDefaultPathDoesNotRequestLabScope() throws {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider-lab-default.yaml")
        config.privacyClassBeta = true
        config.relayBlindEnabled = true
        config.credentialStore = .keychain
        config.coordinatorURL = "wss://coordinator.malibu.tech/v2/provider"
        config.relayBlindStateDirectory = "/private/tmp/macprovider-lab-unused"

        XCTAssertNil(try PrivacyLabIdentityScope.validatedIfRequested(
            config: config,
            isolateLifecycle: true,
            requested: false
        ))
    }

    func testLabScopeRequestRequiresIsolatedLifecycleOnlyWhenRequested() throws {
        let root = try makeOwnerOnlyRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var config = labConfig(root: root)
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validatedIfRequested(
            config: config,
            isolateLifecycle: false,
            requested: true
        )) {
            XCTAssertEqual($0 as? PrivacyLabIdentityScopeError, .isolateLifecycleRequired)
        }

        config.privacyClassBeta = false
        XCTAssertNil(try PrivacyLabIdentityScope.validatedIfRequested(
            config: config,
            isolateLifecycle: false,
            requested: true
        ))
    }

    func testValidatedScopeIsStableForSameRootAndDistinctAcrossRoots() throws {
        let firstRoot = try makeOwnerOnlyRoot()
        let secondRoot = try makeOwnerOnlyRoot()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let first = try PrivacyLabIdentityScope.validated(
            config: labConfig(root: firstRoot),
            isolateLifecycle: true
        )
        let repeated = try PrivacyLabIdentityScope.validated(
            config: labConfig(root: firstRoot),
            isolateLifecycle: true
        )
        let second = try PrivacyLabIdentityScope.validated(
            config: labConfig(root: secondRoot),
            isolateLifecycle: true
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first.secureEnclaveLabel, second.secureEnclaveLabel)
        XCTAssertNotEqual(first.secureEnclaveFileURL, second.secureEnclaveFileURL)
        XCTAssertEqual(first.secureEnclaveFileURL.deletingLastPathComponent().path, firstRoot.path)
        XCTAssertEqual(first.secureEnclaveFileURL.lastPathComponent, "se-attestation-p256.lab.v1")
    }

    func testLiteralIPv6LoopbackIsAccepted() throws {
        let root = try makeOwnerOnlyRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var config = labConfig(root: root)
        config.coordinatorURL = "ws://[::1]:19080/v2/provider"

        let scope = try PrivacyLabIdentityScope.validated(config: config, isolateLifecycle: true)
        XCTAssertEqual(scope.stateRoot.path, root.path)
    }

    func testNegativeGatesRejectBeforeIdentitySelection() throws {
        let root = try makeOwnerOnlyRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = labConfig(root: root)

        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: config, isolateLifecycle: false)) {
            XCTAssertEqual($0 as? PrivacyLabIdentityScopeError, .isolateLifecycleRequired)
        }

        config = labConfig(root: root)
        config.credentialStore = .keychain
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: config, isolateLifecycle: true)) {
            XCTAssertEqual($0 as? PrivacyLabIdentityScopeError, .protectedFileRequired)
        }

        config = labConfig(root: root)
        config.coordinatorURL = "ws://localhost:19080/v2/provider"
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: config, isolateLifecycle: true)) {
            XCTAssertEqual($0 as? PrivacyLabIdentityScopeError, .loopbackLiteralRequired)
        }

        config = labConfig(root: root)
        config.coordinatorURL = "wss://coordinator.malibu.tech/v2/provider"
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: config, isolateLifecycle: true)) {
            XCTAssertEqual($0 as? PrivacyLabIdentityScopeError, .loopbackLiteralRequired)
        }

        config = labConfig(root: root)
        config.coordinatorURL = "ftp://127.0.0.1/v2/provider"
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: config, isolateLifecycle: true)) {
            XCTAssertEqual($0 as? PrivacyLabIdentityScopeError, .loopbackLiteralRequired)
        }
    }

    func testStateRootMustBeCanonicalOwnedDirectory() throws {
        let root = try makeOwnerOnlyRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var relative = labConfig(root: root)
        relative.relayBlindStateDirectory = "relative/state"
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: relative, isolateLifecycle: true)) {
            XCTAssertEqual($0 as? PrivacyLabIdentityScopeError, .stateRootRequired)
        }

        var nonCanonical = labConfig(root: root)
        nonCanonical.relayBlindStateDirectory = root.appendingPathComponent("..").appendingPathComponent(root.lastPathComponent).path
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: nonCanonical, isolateLifecycle: true)) {
            XCTAssertEqual($0 as? PrivacyLabIdentityScopeError, .stateRootNotCanonical)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        var unsafe = labConfig(root: root)
        unsafe.relayBlindStateDirectory = root.path
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: unsafe, isolateLifecycle: true)) {
            guard case .stateRootUnsafe = $0 as? PrivacyLabIdentityScopeError else {
                return XCTFail("expected stateRootUnsafe, got \($0)")
            }
        }
    }

    func testStateRootSymlinkComponentIsRejectedBeforeIdentitySelection() throws {
        let realRoot = try makeOwnerOnlyRoot()
        let linkRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("privacy-lab-symlink-\(UUID().uuidString)", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: linkRoot)
            try? FileManager.default.removeItem(at: realRoot)
        }
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)

        var config = labConfig(root: linkRoot)
        config.relayBlindStateDirectory = linkRoot.path
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: config, isolateLifecycle: true)) {
            guard case .stateRootSymlink = $0 as? PrivacyLabIdentityScopeError else {
                return XCTFail("expected stateRootSymlink, got \($0)")
            }
        }
    }

    func testExistingScopedFallbackFileMustStayInsideOwnerPrivateRegularFile() throws {
        let root = try makeOwnerOnlyRoot()
        let target = try makeOwnerOnlyRoot().appendingPathComponent("escape")
        defer {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: root)
        }
        let fallback = root.appendingPathComponent("se-attestation-p256.lab.v1", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: fallback, withDestinationURL: target)

        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: labConfig(root: root), isolateLifecycle: true)) {
            guard case .stateRootUnsafe = $0 as? PrivacyLabIdentityScopeError else {
                return XCTFail("expected stateRootUnsafe, got \($0)")
            }
        }

        try FileManager.default.removeItem(at: fallback)
        try Data("existing-scoped-se-wrapper".utf8).write(to: fallback)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fallback.path)
        XCTAssertThrowsError(try PrivacyLabIdentityScope.validated(config: labConfig(root: root), isolateLifecycle: true)) {
            guard case .stateRootUnsafe = $0 as? PrivacyLabIdentityScopeError else {
                return XCTFail("expected stateRootUnsafe, got \($0)")
            }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallback.path)
        XCTAssertNoThrow(try PrivacyLabIdentityScope.validated(config: labConfig(root: root), isolateLifecycle: true))
    }

    private func labConfig(root: URL) -> AppConfig {
        var config = AppConfig.defaults(configPath: root.appendingPathComponent("config.yaml").path)
        config.privacyClassBeta = true
        config.relayBlindEnabled = true
        config.credentialStore = .protectedFile
        config.coordinatorURL = "ws://127.0.0.1:19080/v2/provider"
        config.relayBlindStateDirectory = root.path
        return config
    }

    private func makeOwnerOnlyRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("privacy-lab-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}
