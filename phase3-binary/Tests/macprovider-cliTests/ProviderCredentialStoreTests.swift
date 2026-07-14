import ArgumentParser
import LocalAuthentication
import MacProviderCore
import Security
import XCTest
@testable import macprovider_cli

final class ProviderCredentialStoreTests: XCTestCase {
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
        migrationPending: Bool
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try JSONSerialization.data(withJSONObject: [
            "local_status_contract": [
                "version": 1,
                "minimum_reader_version": 1,
                "lifecycle_owner": "macprovider_cli",
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
                "source": "cli_keychain",
                "state": "ready",
                "restart_safe": true,
                "migration_pending": migrationPending,
            ],
        ])
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
