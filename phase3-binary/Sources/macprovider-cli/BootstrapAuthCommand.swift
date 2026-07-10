import ArgumentParser
import Foundation
import MacProviderCore

/// Installer-only credential acquisition. The coordinator completes the
/// ordinary cryptographic handshake but closes immediately after minting a
/// token; this command never creates a routable provider session.
struct BootstrapAuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bootstrap-auth",
        abstract: "Acquire and persist a first-install provider credential."
    )

    @Option(help: "YAML config path. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Maximum seconds to wait for credential persistence.")
    var timeoutSeconds: Int = 30

    func run() async throws {
        guard timeoutSeconds > 0 && timeoutSeconds <= 120 else {
            throw ValidationError("--timeout-seconds must be in 1...120")
        }
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        if Self.hasToken(resolved.providerToken) {
            return
        }
        guard let providerID = resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            throw ValidationError("provider_id is required before credential bootstrap")
        }
        guard Self.isCredentialBootstrapPrincipal(providerID) else {
            throw ValidationError(
                "tokenless credential bootstrap requires a fresh high-entropy mp-* provider ID; existing predictable IDs require operator ownership"
            )
        }
        guard resolved.coordinatorURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ValidationError("coordinator_url is required before credential bootstrap")
        }

        let runtime = try await ModelRuntime(modelID: nil)
        let status = ProviderStatus(
            modelID: resolved.model,
            modelLoaded: false,
            capacity: ProviderCapacity(
                maxContextOverride: resolved.maxContextOverride,
                maxConcurrencyOverride: resolved.maxConcurrencyOverride
            )
        )
        // Persist the Ed25519 receipt identity before opening the socket. If
        // the auth response or config write is lost, a retry proves a fresh
        // challenge under this exact same Keychain key and can replace only
        // its own unused bootstrap token, including after its initial TTL.
        let receiptKeyStore = KeychainReceiptKeyStore()
        let currentReceiptKey = try receiptKeyStore.loadOrGenerate(providerId: providerID)
        let receiptKey = try receiptKeyStore.loadOrStoreBootstrapIdentity(
            providerId: providerID,
            candidate: currentReceiptKey
        )
        let receiptPublicKey = Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
        guard let client = CoordinatorClient(
            config: resolved,
            modelRuntime: runtime,
            providerStatus: status,
            providerReceiptPublicKey: receiptPublicKey,
            credentialBootstrap: true,
            bootstrapReceiptSigningKey: receiptKey
        ) else {
            throw ValidationError("credential bootstrap requires a secure wss coordinator_url")
        }

        await client.start()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        do {
            while Date() < deadline {
                if Self.persistedToken(configPath: resolved.configPath) {
                    await client.stop()
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
        throw ValidationError("coordinator did not persist a provider token before the bootstrap timeout")
    }

    static func persistedToken(configPath: String) -> Bool {
        let loaded = try? ConfigLoader.load(
            cli: CLIOverrides(configPath: configPath),
            environment: [:]
        )
        return hasToken(loaded?.providerToken)
    }

    static func isCredentialBootstrapPrincipal(_ providerID: String) -> Bool {
        let prefix = "mp-"
        guard providerID.hasPrefix(prefix), providerID.utf8.count == prefix.utf8.count + 32 else {
            return false
        }
        return providerID.dropFirst(prefix.count).utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func hasToken(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
