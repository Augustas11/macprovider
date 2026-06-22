import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore

enum ReceiptKeyRotationError: Error, CustomStringConvertible, Equatable {
    case missingProviderID
    case controlSocketUnavailable(String)
    case controlSocketRejected(String)
    case reconnectFailed(String)
    case committedButPublicationUnconfirmed(String)

    var description: String {
        switch self {
        case .missingProviderID:
            return "rotate-key requires provider_id in config, env, or --provider-id"
        case let .controlSocketUnavailable(message):
            return "receipt key rotation requires a running serve process: \(message)"
        case let .controlSocketRejected(message):
            return "receipt key rotation rejected: \(message)"
        case let .reconnectFailed(message):
            return "receipt key rotation reconnect failed: \(message)"
        case let .committedButPublicationUnconfirmed(message):
            return "receipt key rotation committed locally but publication is unconfirmed: \(message)"
        }
    }
}

struct RotateKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate-key",
        abstract: "Ask the running provider process to rotate its receipt signing key."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Stable provider identifier. Overrides MACPROVIDER_PROVIDER_ID and config file provider_id.")
    var providerID: String?

    @Option(help: "Control socket path. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path.")
    var ctlSocketPath: String?

    func run() async throws {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(
                providerID: providerID,
                configPath: config,
                enableReceipts: true,
                ctlSocketPath: ctlSocketPath
            )
        )
        try await Self.requestRotation(config: resolved)
        print("receipt key rotation accepted")
    }

    static func requestRotation(config: AppConfig) async throws {
        guard let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            throw ReceiptKeyRotationError.missingProviderID
        }
        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: config.ctlSocketPath)
        let connection: ControlSocketConnection
        do {
            connection = try await ControlSocketClient.connect(socketPath: socketPath)
        } catch ControlSocketConnectError.socketAbsent(let path) {
            throw ReceiptKeyRotationError.controlSocketUnavailable("control socket absent at \(path)")
        } catch ControlSocketConnectError.connectionRefused(let path) {
            throw ReceiptKeyRotationError.controlSocketUnavailable("control socket refused connection at \(path)")
        } catch {
            throw ReceiptKeyRotationError.controlSocketUnavailable(String(describing: error))
        }
        defer { Task { await connection.close() } }
        try await connection.send(.rotateReceiptKeyRequest(providerID: providerID))
        let response = try await connection.receive(timeout: 180)
        guard case let .rotateReceiptKeyResult(status, message) = response else {
            throw ReceiptKeyRotationError.controlSocketRejected("unexpected control response: \(response)")
        }
        switch status {
        case .accepted:
            return
        case .committedUnconfirmed:
            throw ReceiptKeyRotationError.committedButPublicationUnconfirmed(message ?? "publication unconfirmed")
        case .rejected:
            throw ReceiptKeyRotationError.controlSocketRejected(message ?? "unknown error")
        }
    }

    static func rotateActiveProvider(
        providerID: String,
        keyStore: ReceiptKeyStoring,
        coordinatorClient: ReceiptKeyRotatingCoordinatorClient
    ) async throws {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty else {
            throw ReceiptKeyRotationError.missingProviderID
        }
        _ = try keyStore.loadOrGenerate(providerId: trimmedProviderID)
        let candidate = Curve25519.Signing.PrivateKey()
        do {
            try await coordinatorClient.reconnectWithNewKey(candidate) {
                try keyStore.swapToCurrent(providerId: trimmedProviderID, newKey: candidate)
            }
        } catch let error as CoordinatorReceiptRotationCommittedRecoveryFailed {
            throw ReceiptKeyRotationError.committedButPublicationUnconfirmed(String(describing: error))
        } catch {
            throw ReceiptKeyRotationError.reconnectFailed(String(describing: error))
        }
    }
}
