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
        XCTAssertEqual(status, ProviderCredentialStatus(source: .configFallback, state: .degraded, restartSafe: false))
    }

    func testResolverFailsExplicitlyWhenOnlyCredentialStoreIsUnavailable() {
        let store = InMemoryProviderCredentialStore(loadError: TestCredentialStoreError.unavailable)
        var config = AppConfig.defaults(configPath: "/tmp/config.yaml")
        config.providerID = "provider-a"

        XCTAssertThrowsError(try ProviderCredentialResolver.resolve(config: &config, store: store)) { error in
            XCTAssertEqual(error as? TestCredentialStoreError, .unavailable)
        }
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

    func deleteAll() throws {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}
