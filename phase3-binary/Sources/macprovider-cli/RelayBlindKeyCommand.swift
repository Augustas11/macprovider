import ArgumentParser
import Foundation

struct RelayBlindKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relay-blind-key",
        abstract: "Inspect or rotate the dedicated relay-blind provider keys.",
        subcommands: [Describe.self, Rotate.self, Revoke.self]
    )

    struct Describe: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print public key records for operator pinning.")
        @Option var stateDir: String
        @Option var model: [String]

        func run() throws {
            let manager = try RelayBlindKeyCommand.makeManager(stateDir: stateDir, models: model)
            try RelayBlindKeyCommand.writeJSON([
                "identity_public_key": manager.identityPublicKeyBase64URL(),
                "identity_fingerprint": manager.identityFingerprintBase64URL(),
                "relay_blind_key_records": try manager.currentRecords().map(\.wireObject),
            ])
        }
    }

    struct Rotate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rotate the X25519 encryption key, print replacement public records, and require a provider restart.")
        @Option var stateDir: String
        @Option var model: [String]

        func run() throws {
            let manager = try RelayBlindKeyCommand.makeManager(stateDir: stateDir, models: model)
            _ = try manager.rotate()
            try RelayBlindKeyCommand.writeJSON([
                "identity_public_key": manager.identityPublicKeyBase64URL(),
                "identity_fingerprint": manager.identityFingerprintBase64URL(),
                "provider_restart_required": true,
                "relay_blind_key_records": try manager.currentRecords().map(\.wireObject),
            ])
        }
    }

    struct Revoke: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Durably revoke one current X25519 key record.")
        @Option var stateDir: String
        @Option var model: [String]
        @Option var kid: String

        func run() throws {
            let manager = try RelayBlindKeyCommand.makeManager(stateDir: stateDir, models: model)
            try manager.revoke(kid: kid)
            try RelayBlindKeyCommand.writeJSON(["revoked_kid": kid, "state": "revoked"])
        }
    }

    private static func makeManager(stateDir: String, models: [String]) throws -> RelayBlindKeyManager {
        guard stateDir.hasPrefix("/") else { throw ValidationError("--state-dir must be absolute") }
        return try RelayBlindKeyManager(
            directory: URL(fileURLWithPath: stateDir, isDirectory: true),
            models: models,
            maxEncryptedRequestBytes: 1_048_576
        )
    }

    private static func writeJSON(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
