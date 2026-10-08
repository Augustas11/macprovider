import ArgumentParser
import Foundation
import MacProviderCore

struct PrivacyClassCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "privacy-class",
        abstract: "Inspect the operator-constrained privacy class identity.",
        subcommands: [PrivacyClassIdentityCommand.self]
    )
}

struct PrivacyClassIdentityCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity",
        abstract: "Print public Secure Enclave and relay-blind identity material for operator pinning."
    )

    @Option(name: .customLong("state-dir"), help: "Absolute relay-blind state directory. Defaults to relay_blind_state_directory from config.")
    var stateDir: String?

    @Option(name: .customLong("config"), help: "YAML config path. Used when --state-dir or --model is omitted.")
    var config: String?

    @Option(name: .customLong("model"), help: "Model id in the relay-blind key scope. Repeat for each model. Defaults to the configured model list.")
    var model: [String] = []

    @Flag(name: .customLong("lab-identity-scope"), help: "Use the isolated privacy lab identity scope. Requires --isolate-lifecycle, protected_file credentials, a literal loopback coordinator, and an explicit 0700 state root.")
    var labIdentityScope = false

    @Flag(name: .customLong("isolate-lifecycle"), help: "Required with --lab-identity-scope; mirrors serve's isolated lifecycle lab gate.")
    var isolateLifecycle = false

    func run() throws {
        let resolved = try Self.resolve(
            stateDir: stateDir,
            configPath: config,
            models: model,
            labIdentityScope: labIdentityScope,
            isolateLifecycle: isolateLifecycle
        )
        let se = try Self.loadSecureEnclave(scope: resolved.labScope)
        let relay = try PrivacyClassIdentityReport.relayBlindPublic(
            stateDirectory: resolved.stateDirectory,
            models: resolved.models
        )
        let code = PrivacyCodeSignature.readSelf()
        let object = PrivacyClassIdentityReport.document(
            sePublicKey: se.publicKey,
            seKeyBackend: se.backend,
            relayBlindIdentityPublicKey: relay.publicKey,
            relayBlindFingerprint: relay.fingerprint,
            codeCDHash: code.cdhashHex,
            teamID: code.teamID,
            binaryVersion: CoordinatorClient.binaryVersion
        )
        FileHandle.standardOutput.write(try PrivacyClassIdentityReport.encode(object))
    }

    private static func resolve(
        stateDir: String?,
        configPath: String?,
        models: [String],
        labIdentityScope: Bool = false,
        isolateLifecycle: Bool = false
    ) throws -> (stateDirectory: URL, models: [String], labScope: PrivacyLabIdentityScope?) {
        if let stateDir, !models.isEmpty {
            guard isAbsoluteDirectory(stateDir) else { try fail("state_directory_missing") }
            guard !labIdentityScope else { try fail("lab_identity_scope_requires_config") }
            return (URL(fileURLWithPath: stateDir, isDirectory: true), models, nil)
        }
        let loaded: AppConfig
        do {
            loaded = try ConfigLoader.load(cli: CLIOverrides(
                configPath: configPath,
                supportedModels: models.isEmpty ? nil : models,
                relayBlindStateDirectory: stateDir
            ))
        } catch {
            try fail("config_invalid")
        }
        let path = loaded.relayBlindStateDirectory ?? ""
        guard isAbsoluteDirectory(path) else { try fail("state_directory_missing") }
        let scope = !models.isEmpty ? models : (loaded.supportedModels ?? [loaded.model].compactMap { $0 })
        guard !scope.isEmpty else { try fail("model_scope_missing") }
        let labScope: PrivacyLabIdentityScope?
        if labIdentityScope {
            do {
                labScope = try PrivacyLabIdentityScope.validated(
                    config: loaded,
                    isolateLifecycle: isolateLifecycle
                )
            } catch {
                try fail("lab_identity_scope_invalid")
            }
        } else {
            labScope = nil
        }
        return (URL(fileURLWithPath: path, isDirectory: true), scope, labScope)
    }

    private static func loadSecureEnclave(scope: PrivacyLabIdentityScope? = nil) throws -> (publicKey: String, backend: String) {
        #if arch(arm64)
        do {
            let identity = try SecureEnclaveIdentity.loadOrCreate(
                label: scope?.secureEnclaveLabel,
                quiet: true,
                fileBackedURL: scope?.secureEnclaveFileURL
            )
            let backend = identity.backendName
            guard backend == PrivacyClassConstants.seBackendFile
                    || backend == PrivacyClassConstants.seBackendKeychain else {
                try fail("se_identity")
            }
            return (identity.publicKeyBase64, backend)
        } catch SecureEnclaveIdentityError.secureEnclaveUnavailable {
            try fail("se_unavailable")
        } catch let exit as ExitCode {
            throw exit
        } catch {
            try fail("se_identity")
        }
        #else
        // SecureEnclaveIdentity is arm64-only; the universal build's x86_64
        // slice has no Secure Enclave to report.
        try fail("se_unavailable")
        #endif
    }

    private static func isAbsoluteDirectory(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 1 && trimmed.hasPrefix("/")
    }

    private static func fail(_ reason: String) throws -> Never {
        let line = "FATAL privacy_class_identity_failed reason=\(reason)\n"
        FileHandle.standardError.write(Data(line.utf8))
        try? FileHandle.standardError.synchronize()
        throw ExitCode(1)
    }
}

enum PrivacyClassIdentityReport {
    static func relayBlindPublic(
        stateDirectory: URL,
        models: [String]
    ) throws -> (publicKey: String, fingerprint: String) {
        do {
            let manager = try RelayBlindKeyManager(directory: stateDirectory, models: models)
            return (manager.identityPublicKeyBase64URL(), manager.identityFingerprintBase64URL())
        } catch {
            let line = "FATAL privacy_class_identity_failed reason=relay_blind_identity\n"
            FileHandle.standardError.write(Data(line.utf8))
            try? FileHandle.standardError.synchronize()
            throw ExitCode(1)
        }
    }

    /// Public pinning material only. No private key bytes, ciphertext, or prompts.
    static func document(
        sePublicKey: String,
        seKeyBackend: String,
        relayBlindIdentityPublicKey: String,
        relayBlindFingerprint: String,
        codeCDHash: String,
        teamID: String,
        binaryVersion: String
    ) -> [String: String] {
        [
            "se_public_key": sePublicKey,
            "se_key_backend": seKeyBackend,
            "relay_blind_identity_public_key": relayBlindIdentityPublicKey,
            "relay_blind_fingerprint": relayBlindFingerprint,
            "code_cdhash": codeCDHash,
            "team_id": teamID,
            "binary_version": binaryVersion,
        ]
    }

    static func encode(_ object: [String: String]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        return data
    }
}
