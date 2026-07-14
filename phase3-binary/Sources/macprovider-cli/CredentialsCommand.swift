import ArgumentParser
import Foundation
import MacProviderCore

struct CredentialsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "credentials",
        abstract: "Manage CLI-owned provider credentials.",
        subcommands: [CredentialsImportCommand.self, CredentialsVerifyCommand.self]
    )
}

struct CredentialsImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import the provider token from a private config file into CLI-owned Keychain storage."
    )

    @Option(help: "YAML config path containing provider_id and provider_token.")
    var config: String

    func run() throws {
        let providerID = try Self.importCredential(
            configPath: config,
            store: KeychainProviderCredentialStore()
        )
        Self.printResult(operation: "import", providerID: providerID)
    }

    static func importCredential(
        configPath: String,
        store: any ProviderCredentialStoring
    ) throws -> String {
        let loaded = try loadConfig(configPath: configPath)
        let providerID = try requiredProviderID(loaded)
        guard let token = loaded.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw ValidationError("credential import requires provider_token in the selected config")
        }
        try store.importIfAbsentOrMatches(providerID: providerID, token: token)
        guard try store.load(providerID: providerID) == token else {
            throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
        }
        return providerID
    }

    fileprivate static func loadConfig(configPath: String) throws -> AppConfig {
        try ConfigLoader.load(
            cli: CLIOverrides(configPath: configPath),
            environment: [:]
        )
    }

    fileprivate static func requiredProviderID(_ config: AppConfig) throws -> String {
        guard let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            throw ValidationError("credential operation requires provider_id in the selected config")
        }
        return providerID
    }

    fileprivate static func printResult(operation: String, providerID: String) {
        let payload: [String: Any] = [
            "credential_store": KeychainProviderCredentialStore.service,
            "operation": operation,
            "provider_id": providerID,
            "restart_safe": true,
            "status": "ok",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            print("credential \(operation) succeeded for \(providerID)")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }
}

struct CredentialsVerifyCommand: ParsableCommand {
    /// Installer contract: tokenless verification returns this code only when
    /// no item exists. Locked, denied, corrupt, and other Keychain failures
    /// retain their ordinary nonzero error so callers never bootstrap over an
    /// unavailable authoritative store.
    static let missingCredentialExitCode = ExitCode(3)

    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a fresh CLI process can read the exact credential in a private config file."
    )

    @Option(help: "YAML config path containing provider_id and provider_token.")
    var config: String

    func run() throws {
        do {
            let providerID = try Self.verifyCredential(
                configPath: config,
                store: KeychainProviderCredentialStore()
            )
            CredentialsImportCommand.printResult(operation: "verify", providerID: providerID)
        } catch ProviderCredentialStoreError.missing(let providerID) {
            let message = "provider credential Keychain item is missing for \(providerID)\n"
            FileHandle.standardError.write(Data(message.utf8))
            throw Self.missingCredentialExitCode
        }
    }

    static func verifyCredential(
        configPath: String,
        store: any ProviderCredentialStoring
    ) throws -> String {
        let loaded = try CredentialsImportCommand.loadConfig(configPath: configPath)
        let providerID = try CredentialsImportCommand.requiredProviderID(loaded)
        let stored = try store.load(providerID: providerID)
        if let expected = loaded.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty {
            guard stored == expected else {
                throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
            }
            return providerID
        }
        guard let stored else {
            throw ProviderCredentialStoreError.missing(providerID: providerID)
        }
        guard !stored.isEmpty else {
            throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
        }
        return providerID
    }
}
