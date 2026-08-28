import ArgumentParser
import Darwin
import LocalAuthentication
import MacProviderCore
import Security
import XCTest
@testable import malibu_cli

final class ProviderCredentialStoreTests: XCTestCase {
    func testProtectedFileCredentialSurvivesFreshStoreAndReportsProtectedSource() throws {
        let root = temporaryCredentialRoot("provider-restart")
        defer { removeTemporaryRoot(root) }
        let firstStore = ProtectedFileProviderCredentialStore(rootDirectory: root)

        try firstStore.importIfAbsentOrMatches(providerID: "provider-a", token: "fleet-token")

        let freshStore = ProtectedFileProviderCredentialStore(rootDirectory: root)
        XCTAssertEqual(try freshStore.load(providerID: "provider-a"), "fleet-token")
        var config = AppConfig.defaults(configPath: root.deletingLastPathComponent().appendingPathComponent("config.yaml").path)
        config.providerID = "provider-a"
        let status = try ProviderCredentialResolver.resolve(
            config: &config,
            store: freshStore,
            authoritativeSource: .protectedFile
        )
        XCTAssertEqual(status.source, .protectedFile)
        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.restartSafe)
    }

    func testProtectedFileCredentialPreservesImportAndReplaceSemantics() throws {
        let root = temporaryCredentialRoot("provider-semantics")
        defer { removeTemporaryRoot(root) }
        let store = ProtectedFileProviderCredentialStore(rootDirectory: root)

        try store.importIfAbsentOrMatches(providerID: "provider-a", token: "first-token")
        XCTAssertNoThrow(try store.importIfAbsentOrMatches(providerID: "provider-a", token: "first-token"))
        XCTAssertThrowsError(
            try store.importIfAbsentOrMatches(providerID: "provider-a", token: "conflicting-token")
        ) { error in
            XCTAssertEqual(error as? ProviderCredentialStoreError, .conflict(providerID: "provider-a"))
        }

        try store.replace(providerID: "provider-a", token: "rotated-token")
        XCTAssertEqual(try store.load(providerID: "provider-a"), "rotated-token")
    }

    func testProtectedFileCredentialUsesOwnerOnlyDirectoriesAndFile() throws {
        let root = temporaryCredentialRoot("provider-permissions")
        defer { removeTemporaryRoot(root) }
        let store = ProtectedFileProviderCredentialStore(rootDirectory: root)
        try store.replace(providerID: "provider-a", token: "fleet-token")

        let tokenURL = store.tokenURL(providerID: "provider-a")
        XCTAssertEqual(tokenURL.lastPathComponent, "provider-token.v1")
        try assertPOSIXMode(root, type: S_IFDIR, mode: 0o700)
        try assertPOSIXMode(root.appendingPathComponent("provider-bearers"), type: S_IFDIR, mode: 0o700)
        try assertPOSIXMode(tokenURL.deletingLastPathComponent(), type: S_IFDIR, mode: 0o700)
        try assertPOSIXMode(tokenURL, type: S_IFREG, mode: 0o600, expectedLinkCount: 1)
        try assertNoExtendedACL(tokenURL)

        let entries = try FileManager.default.contentsOfDirectory(atPath: tokenURL.deletingLastPathComponent().path)
        XCTAssertFalse(entries.contains(where: { $0.contains(".tmp-") }))
    }

    func testProtectedFileCredentialRejectsSymlinkAndHardLinkCustody() throws {
        let root = temporaryCredentialRoot("provider-links")
        defer { removeTemporaryRoot(root) }
        let store = ProtectedFileProviderCredentialStore(rootDirectory: root)
        try store.replace(providerID: "provider-a", token: "fleet-token")
        let tokenURL = store.tokenURL(providerID: "provider-a")
        let hardLink = tokenURL.deletingLastPathComponent().appendingPathComponent("token-hardlink")
        try FileManager.default.linkItem(at: tokenURL, to: hardLink)

        XCTAssertThrowsError(try store.load(providerID: "provider-a")) { error in
            guard case ProtectedFileCredentialCustodyError.unsafe(_, let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "hard link")
        }

        try FileManager.default.removeItem(at: hardLink)
        try FileManager.default.removeItem(at: tokenURL)
        let target = root.deletingLastPathComponent().appendingPathComponent("outside-token")
        try Data("outside-token".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: target)

        XCTAssertThrowsError(try store.load(providerID: "provider-a")) { error in
            guard case ProtectedFileCredentialCustodyError.unsafe(_, let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "symlink")
        }
    }

    func testProtectedFileCredentialRejectsSymlinkAncestor() throws {
        let base = temporaryCredentialRoot("provider-symlink-ancestor").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let root = link.appendingPathComponent("protected-credentials", isDirectory: true)
        let store = ProtectedFileProviderCredentialStore(rootDirectory: root)

        XCTAssertThrowsError(try store.replace(providerID: "provider-a", token: "fleet-token")) { error in
            guard case ProtectedFileCredentialCustodyError.unsafe(_, let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "ancestor is a symlink")
        }
    }

    func testCredentialStoreFactoryKeepsKeychainDefaultAndSelectsProtectedFileExplicitly() {
        var config = AppConfig.defaults(configPath: "/tmp/macprovider/config.yaml")
        XCTAssertEqual(ProviderCredentialStoreFactory.credentialSource(for: config), .cliKeychain)
        XCTAssertTrue(ProviderCredentialStoreFactory.providerStore(for: config) is KeychainProviderCredentialStore)

        config.credentialStore = .protectedFile
        XCTAssertEqual(ProviderCredentialStoreFactory.credentialSource(for: config), .protectedFile)
        XCTAssertTrue(ProviderCredentialStoreFactory.providerStore(for: config) is ProtectedFileProviderCredentialStore)
    }

    func testProtectedFileFailureDoesNotFallBackToLayeredCredential() throws {
        let store = InMemoryProviderCredentialStore(loadError: TestCredentialStoreError.unavailable)
        var config = AppConfig.defaults(configPath: "/tmp/config.yaml")
        config.providerID = "provider-a"
        config.providerToken = "layered-token"

        let status = try ProviderCredentialResolver.resolve(
            config: &config,
            store: store,
            authoritativeSource: .protectedFile
        )

        XCTAssertNil(config.providerToken)
        XCTAssertEqual(status.source, .protectedFile)
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertFalse(status.restartSafe)
        XCTAssertEqual(status.recoveryAction, .retry)
    }

    func testProtectedFileResolverDoesNotRebuildMissingCredentialFromLayeredConfig() throws {
        let store = InMemoryProviderCredentialStore()
        var config = AppConfig.defaults(configPath: "/tmp/config.yaml")
        config.providerID = "provider-a"
        config.providerToken = "layered-token"
        config.credentialStore = .protectedFile

        let status = try ProviderCredentialResolver.resolve(
            config: &config,
            store: store,
            authoritativeSource: .protectedFile
        )

        XCTAssertNil(config.providerToken)
        XCTAssertNil(try store.load(providerID: "provider-a"))
        XCTAssertEqual(status.source, .protectedFile)
        XCTAssertEqual(status.state, .missing)
        XCTAssertFalse(status.restartSafe)
        XCTAssertEqual(status.recoveryAction, .restoreOrReenroll)
    }

    func testResolverPrefersExistingCLIKeychainCredentialOverStaleConfig() throws {
        let store = InMemoryProviderCredentialStore(values: ["provider-a": "fresh-token"])
        var config = AppConfig.defaults(configPath: "/tmp/config.yaml")
        config.providerID = "provider-a"
        config.providerToken = "stale-token"

        let status = try ProviderCredentialResolver.resolve(config: &config, store: store)

        XCTAssertEqual(config.providerToken, "fresh-token")
        XCTAssertEqual(status, ProviderCredentialStatus(source: .cliKeychain, state: .conflict, restartSafe: true))
    }

    func testResolverImportsConfigCredentialWhenCLIKeychainIsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-yaml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: transition-token\n".write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let store = InMemoryProviderCredentialStore()
        var config = AppConfig.defaults(configPath: configURL.path)
        config.providerID = "provider-a"
        config.providerToken = "transition-token"

        let status = try ProviderCredentialResolver.resolve(config: &config, store: store)

        XCTAssertEqual(try store.load(providerID: "provider-a"), "transition-token")
        XCTAssertEqual(config.providerToken, "transition-token")
        XCTAssertTrue(status.restartSafe)
        XCTAssertTrue(status.migrationPending)
    }

    func testResolverImportsExternalCredentialWithoutClaimingYAMLMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\n".write(to: configURL, atomically: true, encoding: .utf8)
        let store = InMemoryProviderCredentialStore()
        var config = AppConfig.defaults(configPath: configURL.path)
        config.providerID = "provider-a"
        config.providerToken = "external-token"

        let status = try ProviderCredentialResolver.resolve(config: &config, store: store)

        XCTAssertEqual(try store.load(providerID: "provider-a"), "external-token")
        XCTAssertEqual(
            status,
            ProviderCredentialStatus(source: .cliKeychain, state: .ready, restartSafe: true)
        )
        XCTAssertFalse(status.migrationPending)
    }

    func testResolverReportsStaleYAMLAgainstExternalAuthoritativeCredential() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-stale-yaml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: stale-token\n".write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )
        let store = InMemoryProviderCredentialStore()
        var config = AppConfig.defaults(configPath: configURL.path)
        config.providerID = "provider-a"
        config.providerToken = "external-token"

        let status = try ProviderCredentialResolver.resolve(config: &config, store: store)

        XCTAssertEqual(try store.load(providerID: "provider-a"), "external-token")
        XCTAssertEqual(
            status,
            ProviderCredentialStatus(source: .cliKeychain, state: .conflict, restartSafe: true)
        )
        XCTAssertFalse(status.migrationPending)
    }

    func testResolverKeepsPrivateConfigFallbackWhenKeychainIsUnavailable() throws {
        let store = InMemoryProviderCredentialStore(loadError: TestCredentialStoreError.unavailable)
        var config = AppConfig.defaults(configPath: "/tmp/config.yaml")
        config.providerID = "provider-a"
        config.providerToken = "transition-token"

        let status = try ProviderCredentialResolver.resolve(config: &config, store: store)

        XCTAssertEqual(config.providerToken, "transition-token")
        XCTAssertEqual(status.source, .configFallback)
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.recoveryAction, .retry)
        XCTAssertFalse(status.restartSafe)
        XCTAssertFalse(status.migrationPending)
    }

    func testCredentialFailureTaxonomyDistinguishesLockedDeniedAndCorrupt() {
        let locked = ProviderCredentialStatus.failure(
            ProviderCredentialStoreError.readFailed(providerID: "provider-a", status: errSecInteractionNotAllowed),
            fallbackAvailable: false
        )
        XCTAssertEqual(locked.state, .locked)
        XCTAssertEqual(locked.recoveryAction, .unlockKeychain)

        let unavailable = ProviderCredentialStatus.failure(
            ProviderCredentialStoreError.readFailed(providerID: "provider-a", status: errSecNotAvailable),
            fallbackAvailable: false
        )
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.recoveryAction, .retry)

        let denied = ProviderCredentialStatus.failure(
            ProviderCredentialStoreError.readFailed(providerID: "provider-a", status: errSecAuthFailed),
            fallbackAvailable: true
        )
        XCTAssertEqual(denied.state, .permissionDenied)
        XCTAssertEqual(denied.source, .configFallback)
        XCTAssertEqual(denied.recoveryAction, .authorizeKeychain)

        let corrupt = ProviderCredentialStatus.failure(
            ProviderCredentialStoreError.invalidStoredToken(providerID: "provider-a"),
            fallbackAvailable: true
        )
        XCTAssertEqual(corrupt.state, .corrupt)
        XCTAssertEqual(corrupt.recoveryAction, .repairFromProtectedSource)

        for status in [errSecInteractionRequired, errSecDatabaseLocked] {
            let result = ProviderCredentialStatus.failure(
                ProviderCredentialStoreError.readFailed(providerID: "provider-a", status: status),
                fallbackAvailable: true
            )
            XCTAssertEqual(result.state, .locked, "status=\(status)")
            XCTAssertEqual(result.recoveryAction, .unlockKeychain, "status=\(status)")
            XCTAssertFalse(result.migrationPending)
        }

        let notLoggedIn = ProviderCredentialStatus.failure(
            ProviderCredentialStoreError.readFailed(providerID: "provider-a", status: errSecNotLoggedIn),
            fallbackAvailable: true
        )
        XCTAssertEqual(notLoggedIn.state, .notLoggedIn)
        XCTAssertEqual(notLoggedIn.recoveryAction, .login)

        for status in [
            errSecDecode, errSecReadOnly, errSecNoSuchKeychain, errSecInvalidKeychain,
            errSecNoDefaultKeychain, errSecDataNotAvailable,
        ] {
            let result = ProviderCredentialStatus.failure(
                ProviderCredentialStoreError.readFailed(providerID: "provider-a", status: status),
                fallbackAvailable: true
            )
            XCTAssertEqual(result.state, .keychainFailure, "status=\(status)")
            XCTAssertEqual(result.recoveryAction, .repairKeychain, "status=\(status)")
            XCTAssertNotEqual(result.recoveryAction, .repairFromProtectedSource, "status=\(status)")
        }

        let incompatible = ProviderCredentialStatus.failure(
            ProviderCredentialStoreError.readFailed(providerID: "provider-a", status: errSecMissingEntitlement),
            fallbackAvailable: true
        )
        XCTAssertEqual(incompatible.state, .incompatible)
        XCTAssertEqual(incompatible.recoveryAction, .updateOrReinstall)
    }

    func testResolverDistinguishesLostCredentialFromUnconfiguredInstall() throws {
        let store = InMemoryProviderCredentialStore()
        var config = AppConfig.defaults(configPath: "/tmp/config.yaml")
        config.providerID = "provider-a"

        let status = try ProviderCredentialResolver.resolve(config: &config, store: store)

        XCTAssertEqual(status.state, .missing)
        XCTAssertEqual(status.recoveryAction, .restoreOrReenroll)
        XCTAssertFalse(status.restartSafe)
    }

    func testResolverReportsExplicitStateWhenOnlyCredentialStoreIsUnavailable() throws {
        let store = InMemoryProviderCredentialStore(loadError: TestCredentialStoreError.unavailable)
        var config = AppConfig.defaults(configPath: "/tmp/config.yaml")
        config.providerID = "provider-a"

        let status = try ProviderCredentialResolver.resolve(config: &config, store: store)

        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.source, .none)
        XCTAssertEqual(status.recoveryAction, .retry)
        XCTAssertFalse(status.restartSafe)
    }

    func testCredentialImportAndFreshVerificationUseExactConfigToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: secret-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        let store = InMemoryProviderCredentialStore()

        XCTAssertEqual(
            try CredentialsImportCommand.importCredential(configPath: config.path, store: store),
            "provider-a"
        )
        XCTAssertEqual(
            try CredentialsVerifyCommand.verifyCredential(configPath: config.path, store: store),
            "provider-a"
        )

        try "provider_id: provider-a\nprovider_token: different-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertThrowsError(
            try CredentialsVerifyCommand.verifyCredential(configPath: config.path, store: store)
        )
    }

    func testCredentialImportNeverOverwritesAuthoritativeKeychainValue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: stale-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        let store = InMemoryProviderCredentialStore(values: ["provider-a": "authoritative-token"])

        XCTAssertThrowsError(
            try CredentialsImportCommand.importCredential(configPath: config.path, store: store)
        ) { error in
            XCTAssertEqual(
                error as? ProviderCredentialStoreError,
                .conflict(providerID: "provider-a")
            )
        }
        XCTAssertEqual(try store.load(providerID: "provider-a"), "authoritative-token")
    }

    func testTokenlessVerificationDistinguishesMissingCredential() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CredentialsVerifyCommand.verifyCredential(
                configPath: config.path,
                store: InMemoryProviderCredentialStore()
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderCredentialStoreError,
                .missing(providerID: "provider-a")
            )
        }
        XCTAssertEqual(CredentialsVerifyCommand.missingCredentialExitCode, ExitCode(3))
    }

    func testCredentialStatusIsVersionedRedactedAndNonMutating() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: recovery-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let store = InMemoryProviderCredentialStore()

        let result = try CredentialsStatusCommand.inspect(configPath: config.path, store: store)
        let payload = result.jsonObject(operation: "status")

        XCTAssertEqual(result.status.state, .missing)
        XCTAssertEqual(result.status.recoveryAction, .repairFromProtectedSource)
        XCTAssertFalse(result.status.migrationPending)
        XCTAssertNil(try store.load(providerID: "provider-a"))
        XCTAssertEqual(payload["contract_version"] as? Int, 1)
        XCTAssertEqual(payload["provider_id"] as? String, "provider-a")
        XCTAssertNil(payload["token"])
        XCTAssertFalse(String(describing: payload).contains("recovery-token"))
    }

    func testCredentialRepairUsesOnlyExactProtectedSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: recovery-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let store = InMemoryProviderCredentialStore()

        let result = try CredentialsRepairCommand.repair(configPath: config.path, store: store)

        XCTAssertEqual(try store.load(providerID: "provider-a"), "recovery-token")
        XCTAssertEqual(result.status.state, .ready)
        XCTAssertTrue(result.status.restartSafe)
        XCTAssertTrue(result.status.migrationPending)
    }

    func testCredentialRepairRefusesConflictAndUnavailableStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-repair-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: recovery-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        let conflict = InMemoryProviderCredentialStore(values: ["provider-a": "authoritative-token"])
        XCTAssertThrowsError(
            try CredentialsRepairCommand.repair(configPath: config.path, store: conflict)
        ) { error in
            XCTAssertEqual(error as? CredentialsRepairCommand.RepairError, .blocked(.conflict))
        }
        XCTAssertEqual(try conflict.load(providerID: "provider-a"), "authoritative-token")

        let unavailable = InMemoryProviderCredentialStore(loadError: TestCredentialStoreError.unavailable)
        XCTAssertThrowsError(
            try CredentialsRepairCommand.repair(configPath: config.path, store: unavailable)
        ) { error in
            XCTAssertEqual(error as? CredentialsRepairCommand.RepairError, .blocked(.unavailable))
        }
    }

    func testCredentialRepairRejectsUnprotectedOrSymlinkedSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-unprotected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: recovery-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        let store = InMemoryProviderCredentialStore()

        XCTAssertThrowsError(
            try CredentialsRepairCommand.repair(configPath: config.path, store: store)
        )
        XCTAssertNil(try store.load(providerID: "provider-a"))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let symlink = directory.appendingPathComponent("config-link.yaml")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: config)
        XCTAssertThrowsError(
            try CredentialsRepairCommand.repair(configPath: symlink.path, store: store)
        )
        XCTAssertNil(try store.load(providerID: "provider-a"))

        let hardLink = directory.appendingPathComponent("config-hardlink.yaml")
        try FileManager.default.linkItem(at: config, to: hardLink)
        XCTAssertThrowsError(
            try CredentialsRepairCommand.repair(configPath: config.path, store: store)
        )
        XCTAssertNil(try store.load(providerID: "provider-a"))
    }

    func testCredentialRepairBindsExpectedProviderIdentityBeforeMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-b\nprovider_token: recovery-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let store = InMemoryProviderCredentialStore()

        XCTAssertThrowsError(try CredentialsRepairCommand.repair(
            configPath: config.path,
            expectedProviderID: "provider-a",
            store: store
        ))
        XCTAssertNil(try store.load(providerID: "provider-a"))
        XCTAssertNil(try store.load(providerID: "provider-b"))
    }

    func testCredentialRepairRefusesConcurrentAuthoritativeRotation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-repair-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nprovider_token: recovery-token\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let store = ConcurrentRotationCredentialStore()

        XCTAssertThrowsError(
            try CredentialsRepairCommand.repair(configPath: config.path, store: store)
        ) { error in
            XCTAssertEqual(error as? ProviderCredentialStoreError, .conflict(providerID: "provider-a"))
        }
        XCTAssertEqual(try store.load(providerID: "provider-a"), "rotated-token")
    }

    func testCredentialRestartProofRequiresFreshNewLaunchdBuyerServingInstance() throws {
        let now = Date()
        let proof = try makeCredentialRestartProof(
            observedAt: now,
            migrationPending: false
        )

        let result = CredentialRestartProver.validateBuyerServingProof(
            proof,
            expectedProviderID: "provider-a",
            previousServiceInstance: "instance-old",
            launchdPID: 4_321,
            now: now,
            restartRequestedAt: now.addingTimeInterval(-1),
            currentBootSession: "boot-a"
        )

        XCTAssertEqual(result?.providerID, "provider-a")
        XCTAssertEqual(result?.status.source, .cliKeychain)
        XCTAssertEqual(result?.status.state, .ready)
        XCTAssertEqual(result?.status.restartSafe, true)
        XCTAssertEqual(result?.status.migrationPending, false)
    }

    func testCredentialRestartProofRejectsStaleOrUnprovenAdmission() throws {
        let now = Date()
        let valid = try makeCredentialRestartProof(observedAt: now, migrationPending: false)
        let stale = try makeCredentialRestartProof(
            observedAt: now.addingTimeInterval(-31),
            migrationPending: false
        )
        let migrationPending = try makeCredentialRestartProof(observedAt: now, migrationPending: true)

        XCTAssertNil(CredentialRestartProver.validateBuyerServingProof(
            valid,
            expectedProviderID: "provider-a",
            previousServiceInstance: "instance-new",
            launchdPID: 4_321,
            now: now,
            restartRequestedAt: now.addingTimeInterval(-1),
            currentBootSession: "boot-a"
        ))
        XCTAssertNil(CredentialRestartProver.validateBuyerServingProof(
            valid,
            expectedProviderID: "provider-a",
            previousServiceInstance: "instance-old",
            launchdPID: 9_999,
            now: now,
            restartRequestedAt: now.addingTimeInterval(-1),
            currentBootSession: "boot-a"
        ))
        XCTAssertNil(CredentialRestartProver.validateBuyerServingProof(
            stale,
            expectedProviderID: "provider-a",
            previousServiceInstance: "instance-old",
            launchdPID: 4_321,
            now: now,
            restartRequestedAt: now.addingTimeInterval(-1),
            currentBootSession: "boot-a"
        ))
        XCTAssertNil(CredentialRestartProver.validateBuyerServingProof(
            migrationPending,
            expectedProviderID: "provider-a",
            previousServiceInstance: "instance-old",
            launchdPID: 4_321,
            now: now,
            restartRequestedAt: now.addingTimeInterval(-1),
            currentBootSession: "boot-a"
        ))
    }

    func testCredentialRestartProofRestartsAndPollsConfiguredProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-credential-restart-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nport: 9999\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        let proof = try makeCredentialRestartProof(observedAt: Date(), migrationPending: false)
        let restarted = LockedFlag()
        let fetchedPort = LockedInt()

        let result = try await CredentialRestartProver.restartAndProve(
            configPath: config.path,
            expectedProviderID: "provider-a",
            previousServiceInstance: "instance-old",
            timeout: 1,
            pollInterval: 0.01,
            restart: { restarted.set() },
            fetchStatus: { port in
                fetchedPort.set(port)
                return proof
            },
            launchdPID: { 4_321 },
            listenerOwnerPID: { $0 == 9_999 ? 4_321 : nil },
            bootSession: { "boot-a" }
        )

        XCTAssertEqual(result.providerID, "provider-a")
        XCTAssertTrue(restarted.value)
        XCTAssertEqual(fetchedPort.value, 9_999)
    }

    func testCredentialRestartProofUsesProtectedFileSourceAndSystemDomain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-protected-restart-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nport: 9999\ncredential_store: protected_file\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        let proof = try makeCredentialRestartProof(
            observedAt: Date(),
            migrationPending: false,
            source: "protected_file"
        )

        let loaded = try CredentialsImportCommand.loadConfig(configPath: config.path)
        XCTAssertEqual(CredentialRestartProver.launchdDomain(for: loaded, environment: [:]), "system")
        XCTAssertEqual(
            CredentialRestartProver.launchdDomain(
                for: loaded,
                environment: ["MACPROVIDER_LAUNCHD_DOMAIN": "gui/501"]
            ),
            "system"
        )

        let result = try await CredentialRestartProver.restartAndProve(
            configPath: config.path,
            expectedProviderID: "provider-a",
            previousServiceInstance: "instance-old",
            timeout: 1,
            pollInterval: 0.01,
            restart: {},
            fetchStatus: { _ in proof },
            launchdPID: { 4_321 },
            listenerOwnerPID: { $0 == 9_999 ? 4_321 : nil },
            bootSession: { "boot-a" }
        )

        XCTAssertEqual(result.status.source, .protectedFile)
        XCTAssertTrue(result.status.restartSafe)
    }

    func testProtectedFileCredentialStatusPreservesSourceWhenMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-protected-status-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\ncredential_store: protected_file\n".write(
            to: config,
            atomically: true,
            encoding: .utf8
        )
        let loaded = try CredentialsImportCommand.loadConfig(configPath: config.path)

        let result = try CredentialsStatusCommand.inspect(
            configPath: config.path,
            store: ProtectedFileProviderCredentialStore(
                rootDirectory: directory.appendingPathComponent("protected")
            ),
            authoritativeSource: .protectedFile
        )

        XCTAssertEqual(loaded.credentialStore, .protectedFile)
        XCTAssertEqual(result.status.source, ProviderCredentialStatus.Source.protectedFile)
        XCTAssertEqual(result.status.state, ProviderCredentialStatus.State.missing)
    }

    func testProtectedFileRootCanBePinnedOutsideStagedConfigDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-protected-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagedConfig = directory.appendingPathComponent("staging/config.yaml")
        try FileManager.default.createDirectory(
            at: stagedConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "provider_id: provider-a\ncredential_store: protected_file\n".write(
            to: stagedConfig,
            atomically: true,
            encoding: .utf8
        )
        let liveRoot = directory.appendingPathComponent("live/protected-credentials")
        setenv("MACPROVIDER_PROTECTED_CREDENTIAL_ROOT", liveRoot.path, 1)
        defer { unsetenv("MACPROVIDER_PROTECTED_CREDENTIAL_ROOT") }

        let config = try CredentialsImportCommand.loadConfig(configPath: stagedConfig.path)

        XCTAssertEqual(
            ProviderCredentialStoreFactory.protectedFileRoot(for: config).standardizedFileURL,
            liveRoot.standardizedFileURL
        )
    }

    func testKeychainQueriesAreNonInteractiveAndNeverContainPlaintextMetadata() {
        let base = KeychainProviderCredentialStore.baseQuery(providerID: "provider-a")
        XCTAssertEqual(base[kSecAttrService as String] as? String, KeychainProviderCredentialStore.service)
        XCTAssertEqual(base[kSecAttrAccount as String] as? String, "provider-a")
        let context = base[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
        XCTAssertNil(base[kSecValueData as String])

        let add = KeychainProviderCredentialStore.addQuery(
            providerID: "provider-a",
            tokenData: Data("secret-token".utf8)
        )
        XCTAssertNil(add[kSecAttrAccessible as String])
        XCTAssertNil(add[kSecUseDataProtectionKeychain as String])
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
    }

    private func makeCredentialRestartProof(
        observedAt: Date,
        migrationPending: Bool,
        source: String = "cli_keychain"
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: [
            "local_status_contract": [
                "version": 1,
                "minimum_reader_version": 1,
                "lifecycle_owner": "malibu_cli",
                "capabilities": [
                    "buyer_serving_authority_v1",
                    "credential_status_v1",
                    "service_instance_v1",
                    "status_observation_v1",
                ],
            ],
            "provider_id": "provider-a",
            "network_state": "buyer_serving",
            "coordinator": ["connected": true],
            "observation": [
                "id": "observation-a",
                "observed_at": formatter.string(from: observedAt),
                "valid_for_ms": 30_000,
            ],
            "service_instance": [
                "instance_id": "instance-new",
                "pid": 4_321,
                "boot_session": "boot-a",
                "started_at": formatter.string(from: observedAt),
                "role": "serve",
            ],
            "credential": [
                "source": source,
                "state": "ready",
                "restart_safe": true,
                "migration_pending": migrationPending,
            ],
        ])
    }

    private func temporaryCredentialRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("protected-credentials", isDirectory: true)
    }

    private func removeTemporaryRoot(_ root: URL) {
        let parent = root.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    private func assertPOSIXMode(
        _ url: URL,
        type: mode_t,
        mode: mode_t,
        expectedLinkCount: UInt16? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0, file: file, line: line)
        XCTAssertEqual(info.st_mode & S_IFMT, type, file: file, line: line)
        XCTAssertEqual(info.st_mode & 0o777, mode, file: file, line: line)
        XCTAssertEqual(info.st_uid, geteuid(), file: file, line: line)
        if let expectedLinkCount {
            XCTAssertEqual(info.st_nlink, expectedLinkCount, file: file, line: line)
        }
    }

    private func assertNoExtendedACL(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0, file: file, line: line)
        guard fd >= 0 else { return }
        defer { close(fd) }
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            XCTAssertTrue(errno == 0 || errno == ENOENT, file: file, line: line)
            return
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        XCTAssertEqual(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry), 0, file: file, line: line)
        XCTAssertNil(entry, file: file, line: line)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    var value: Int? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Int) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private enum TestCredentialStoreError: Error, Equatable {
    case unavailable
}

final class InMemoryProviderCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private let loadError: Error?
    private let replaceError: Error?

    init(
        values: [String: String] = [:],
        loadError: Error? = nil,
        replaceError: Error? = nil
    ) {
        self.values = values
        self.loadError = loadError
        self.replaceError = replaceError
    }

    func load(providerID: String) throws -> String? {
        if let loadError { throw loadError }
        lock.lock()
        defer { lock.unlock() }
        return values[providerID]
    }

    func replace(providerID: String, token: String) throws {
        if let replaceError { throw replaceError }
        lock.lock()
        values[providerID] = token
        lock.unlock()
    }

    func importIfAbsentOrMatches(providerID: String, token: String) throws {
        if let loadError { throw loadError }
        if let replaceError { throw replaceError }
        lock.lock()
        defer { lock.unlock() }
        if let existing = values[providerID], existing != token {
            throw ProviderCredentialStoreError.conflict(providerID: providerID)
        }
        values[providerID] = token
    }

    func repairCorruptIfStillCorrupt(providerID: String, token: String) throws {
        if let loadError { throw loadError }
        if let replaceError { throw replaceError }
        lock.lock()
        defer { lock.unlock() }
        if let existing = values[providerID], existing != token {
            throw ProviderCredentialStoreError.conflict(providerID: providerID)
        }
        values[providerID] = token
    }

    func deleteAll() throws {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}

private final class ConcurrentRotationCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var firstLoad = true
    private var value: String?

    func load(providerID: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if firstLoad {
            firstLoad = false
            throw ProviderCredentialStoreError.invalidStoredToken(providerID: providerID)
        }
        return value
    }

    func importIfAbsentOrMatches(providerID: String, token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let value, value != token {
            throw ProviderCredentialStoreError.conflict(providerID: providerID)
        }
        value = token
    }

    func replace(providerID: String, token: String) throws {
        lock.lock()
        value = token
        lock.unlock()
    }

    func repairCorruptIfStillCorrupt(providerID: String, token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        value = "rotated-token"
        throw ProviderCredentialStoreError.conflict(providerID: providerID)
    }

    func deleteAll() throws {
        lock.lock()
        value = nil
        lock.unlock()
    }
}
