import ArgumentParser
import Foundation
import MacProviderCore

/// Installer-only credential acquisition. The coordinator completes the
/// ordinary cryptographic handshake but closes immediately after minting a
/// token; this command never creates a routable provider session.
struct BootstrapAuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bootstrap-auth",
        abstract: "Acquire and persist a first-install provider credential.",
        shouldDisplay: false
    )

    @Option(help: "YAML config path. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Maximum seconds to wait for credential persistence.")
    var timeoutSeconds: Int = 30

    @Option(help: "Owner-only referral-code file used only for first credential bootstrap.")
    var referralCodeFile: String?

    @Flag(help: "Use a replacement-scoped referral journal for an explicit fresh-provider replacement.")
    var replaceReferralJournal = false

    func run() async throws {
        do {
            try await runBootstrap()
        } catch let failure as ReferralBootstrapFailure {
            Self.emitReferralFailure(failure)
            throw ExitCode(failure.exitCode)
        }
    }

    private func runBootstrap() async throws {
        guard timeoutSeconds > 0 && timeoutSeconds <= 120 else {
            throw ValidationError("--timeout-seconds must be in 1...120")
        }
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        guard let providerID = resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            throw ValidationError("provider_id is required before credential bootstrap")
        }
        let providerCredentialStore = KeychainProviderCredentialStore()
        let referralInput = try referralCodeFile.map { try ReferralCodeFile.read(path: $0) }
        let receiptKeyStore = KeychainReceiptKeyStore()
        if let configToken = resolved.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configToken.isEmpty {
            try providerCredentialStore.importIfAbsentOrMatches(
                providerID: providerID,
                token: configToken
            )
            if let referralInput {
                try Self.reconcilePersistedReferral(
                    providerID: providerID,
                    receiptPublicKey: try Self.persistedBootstrapReceiptPublicKey(
                        providerID: providerID,
                        store: receiptKeyStore
                    ),
                    input: referralInput,
                    journal: try Self.referralJournal(
                        providerID: providerID,
                        replacingIncumbentProvider: replaceReferralJournal
                    )
                )
            }
            return
        }
        if try Self.storedCredentialPresent(providerID: providerID, store: providerCredentialStore) {
            if let referralInput {
                try Self.reconcilePersistedReferral(
                    providerID: providerID,
                    receiptPublicKey: try Self.persistedBootstrapReceiptPublicKey(
                        providerID: providerID,
                        store: receiptKeyStore
                    ),
                    input: referralInput,
                    journal: try Self.referralJournal(
                        providerID: providerID,
                        replacingIncumbentProvider: replaceReferralJournal
                    )
                )
            }
            return
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
        // its own unused bootstrap token, including after its initial TTL
        // while the coordinator's recovery-retention window remains open.
        let currentReceiptKey = try receiptKeyStore.loadOrGenerate(providerId: providerID)
        let receiptKey = try receiptKeyStore.loadOrStoreBootstrapIdentity(
            providerId: providerID,
            candidate: currentReceiptKey
        )
        let receiptPublicKey = Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
        let referralJournal = try referralInput.map { _ in
            try Self.referralJournal(
                providerID: providerID,
                replacingIncumbentProvider: replaceReferralJournal
            )
        }
        let referralAttempt: ReferralBootstrapAttempt?
        if let referralInput, let referralJournal {
            referralAttempt = try referralJournal.prepare(
                providerID: providerID,
                receiptPublicKey: receiptPublicKey,
                input: referralInput
            )
        } else {
            referralAttempt = nil
        }
        guard let client = CoordinatorClient(
            config: resolved,
            modelRuntime: runtime,
            providerStatus: status,
            providerReceiptPublicKey: receiptPublicKey,
            credentialBootstrap: true,
            bootstrapReceiptSigningKey: receiptKey,
            bootstrapReferralCode: referralInput?.code,
            providerCredentialStore: providerCredentialStore
        ) else {
            throw ValidationError("credential bootstrap requires a secure wss coordinator_url")
        }

        await client.start()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        do {
            while Date() < deadline {
                if Self.persistedToken(
                    providerID: providerID,
                    store: providerCredentialStore
                ) {
                    await client.stop()
                    if let referralInput, let referralJournal {
                        try Self.reconcilePersistedReferral(
                            providerID: providerID,
                            receiptPublicKey: receiptPublicKey,
                            input: referralInput,
                            journal: referralJournal
                        )
                    }
                    return
                }
                if let failure = await client.credentialBootstrapTerminalReferralFailure() {
                    await client.stop()
                    if let referralJournal, let referralAttempt {
                        try referralJournal.markTerminal(
                            attemptID: referralAttempt.attemptID,
                            failure: failure
                        )
                    }
                    throw failure
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
        if referralInput != nil {
            throw ReferralBootstrapFailure(kind: .unavailable)
        }
        throw ValidationError("coordinator did not persist a provider token before the bootstrap timeout")
    }

    static func persistedToken(
        providerID: String,
        store: any ProviderCredentialStoring = KeychainProviderCredentialStore()
    ) -> Bool {
        hasToken(try? store.load(providerID: providerID))
    }

    static func storedCredentialPresent(
        providerID: String,
        store: any ProviderCredentialStoring
    ) throws -> Bool {
        hasToken(try store.load(providerID: providerID))
    }

    static func reconcilePersistedReferral(
        providerID: String,
        receiptPublicKey: String,
        input: ReferralCodeInput,
        journal: ReferralBootstrapJournal
    ) throws {
        guard try journal.reconcilePersistedCredential(
            providerID: providerID,
            receiptPublicKey: receiptPublicKey,
            input: input
        ) != nil else {
            // A credential without the exact pending provider+code binding is
            // an incumbent identity, not proof that this referral was redeemed.
            throw ReferralBootstrapFailure(kind: .conflict)
        }
        try ReferralCodeFile.removeIfUnchanged(input)
    }

    private static func persistedBootstrapReceiptPublicKey(
        providerID: String,
        store: KeychainReceiptKeyStore
    ) throws -> String {
        guard let receiptKey = try store.loadBootstrapIdentity(providerId: providerID) else {
            throw ReferralBootstrapFailure(kind: .conflict)
        }
        return Data(receiptKey.publicKey.rawRepresentation).base64EncodedString()
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

    static func referralJournal(
        providerID: String,
        replacingIncumbentProvider: Bool
    ) throws -> ReferralBootstrapJournal {
        if replacingIncumbentProvider {
            guard isCredentialBootstrapPrincipal(providerID) else {
                throw ValidationError("--replace-referral-journal requires a fresh mp-* provider_id")
            }
            return ReferralBootstrapJournal.replacementJournal(providerID: providerID)
        }
        return ReferralBootstrapJournal(url: ReferralBootstrapJournal.defaultURL())
    }

    private static func hasToken(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func emitReferralFailure(_ failure: ReferralBootstrapFailure) {
        FileHandle.standardError.write(Data(
            "referral_bootstrap_error=\(failure.kind.rawValue)\n".utf8
        ))
    }
}
