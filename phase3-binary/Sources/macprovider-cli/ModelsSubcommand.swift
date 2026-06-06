import ArgumentParser
import Foundation
import MacProviderCore

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Inspect or switch the provider warm model.",
        subcommands: [
            ModelsListCommand.self,
            ModelsSwitchCommand.self,
            ModelsStatusCommand.self,
        ]
    )
}

struct ModelsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List models known to this provider (warm/idle)."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths). Overrides MACPROVIDER_SUPPORTED_MODELS and config supported_models.")
    var supportedModels: String?

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock.")
    var ctlSocketPath: String?

    func run() async throws {
        let resolved = try loadModelsConfig(config: config, model: model, supportedModels: supportedModels, ctlSocketPath: ctlSocketPath)
        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        do {
            let (connection, status) = try await connectAndReadStatus(socketPath: socketPath)
            await connection.close()
            printModelsTable(currentModelID: status.currentModelID, supportedModels: resolved.supportedModels ?? [status.currentModelID])
        } catch ControlSocketConnectError.socketAbsent(let path) {
            print("serve not running; warm-swap disabled")
            writeStderr("macprovider-cli serve is not running on this host (no control socket at \(path))")
            printModelsTable(currentModelID: nil, supportedModels: idleCatalog(from: resolved))
            return
        } catch ControlSocketConnectError.connectionRefused(let path) {
            writeStderr("stale control socket at \(path) (no listener); remove the file and restart serve")
            throw ExitCode(4)
        } catch ControlSocketConnectError.handshakeTimeout {
            writeStderr("serve is running but warm-swap is not enabled (or serve is unresponsive); restart serve with --enable-warm-swap")
            throw ExitCode(4)
        }
    }
}

struct ModelsSwitchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch the provider to another supported model."
    )

    @Argument(help: "Target HuggingFace model ID or local path.")
    var targetModelID: String

    @Flag(help: "Accepted in Phase 1C; cooldown bypass behavior lands in Phase 1E.")
    var force = false

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "Current HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths). Overrides MACPROVIDER_SUPPORTED_MODELS and config supported_models.")
    var supportedModels: String?

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock.")
    var ctlSocketPath: String?

    // Phase 1E reads/writes this path for the cooldown soft guard; Phase 1C only stores it.
    @Option(help: "CLI-side cooldown state file. Overrides MACPROVIDER_SWITCH_STATE_PATH and config switch_state_path. Default $HOME/Library/Application Support/macprovider-cli/last-switch.ts. Cooldown soft guard lands in Phase 1E.")
    var switchStatePath: String?

    func run() async throws {
        // Stored for Phase 1E cooldown bypass/read-write behavior; intentionally unused in 1C.
        _ = ModelsSwitchOptions(force: force, switchStatePath: switchStatePath)
        let resolved = try loadModelsConfig(
            config: config,
            model: model,
            supportedModels: supportedModels,
            ctlSocketPath: ctlSocketPath,
            switchStatePath: switchStatePath
        )

        do {
            _ = try SupportedModels.validate(model: targetModelID, supportedModels: resolved.supportedModels)
        } catch SupportedModelsValidationError.modelNotInCatalog {
            writeStderr("switch target \(targetModelID) not in --supported-models")
            throw ExitCode(2)
        } catch let error as SupportedModelsValidationError {
            writeStderr("\(error)")
            throw ExitCode(2)
        }

        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        let (connection, _) = try await connectAndReadStatusOrExit(socketPath: socketPath)
        let requestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await connection.send(.switchRequest(targetModelID: targetModelID, requestedAtMs: requestedAtMs))
        let ack = try await connection.receive()
        guard case let .switchAck(accepted, reason, currentTarget, secondsRemaining) = ack else {
            writeStderr("expected switch_ack")
            await connection.close()
            throw ExitCode(4)
        }

        guard accepted else {
            await connection.close()
            switch reason {
            case .loadingInProgress:
                let currentTarget = currentTarget ?? "<unknown>"
                writeStderr("provider is already loading \(currentTarget); refusing to start a second swap. Wait for current switch to complete (macprovider-cli models status)")
                throw ExitCode(3)
            case .cooldown:
                writeStderr("swap on cooldown for \(secondsRemaining ?? 0)s. Re-issue with --force to bypass")
                throw ExitCode(6)
            default:
                writeStderr("switch rejected")
                throw ExitCode(4)
            }
        }

        while true {
            let frame = try await connection.receive()
            guard case let .switchProgress(state, elapsedMs, reason) = frame else {
                continue
            }
            writeStderr("switch_progress state=\(state.rawValue) elapsed_ms=\(elapsedMs)")
            switch state {
            case .loaded:
                await connection.close()
                return
            case .failed:
                await connection.close()
                writeStderr("swap failed: \(reason ?? "unknown")")
                throw ExitCode(5)
            case .loading, .draining:
                continue
            }
        }
    }
}

struct ModelsStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the running provider warm-swap status."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths). Overrides MACPROVIDER_SUPPORTED_MODELS and config supported_models.")
    var supportedModels: String?

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock.")
    var ctlSocketPath: String?

    func run() async throws {
        let resolved = try loadModelsConfig(config: config, model: model, supportedModels: supportedModels, ctlSocketPath: ctlSocketPath)
        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        let (connection, status) = try await connectAndReadStatusOrExit(socketPath: socketPath)
        await connection.close()
        let data = try ControlSocketCodec.encode(.statusResponse(currentModelID: status.currentModelID, runtimeState: status.runtimeState))
        print(String(decoding: data.dropLast(), as: UTF8.self))
    }
}

struct ModelsSwitchOptions: Sendable, Equatable {
    let force: Bool
    // Phase 1E reads/writes this path for the cooldown soft guard; Phase 1C only preserves it.
    let switchStatePath: String?
}

private struct ModelsStatus: Sendable, Equatable {
    let currentModelID: String
    let runtimeState: SwapState
}

private func loadModelsConfig(
    config: String?,
    model: String?,
    supportedModels: String?,
    ctlSocketPath: String?,
    switchStatePath: String? = nil
) throws -> AppConfig {
    try ConfigLoader.load(
        cli: CLIOverrides(
            model: model,
            configPath: config,
            supportedModels: SupportedModels.parseCSV(supportedModels),
            ctlSocketPath: ctlSocketPath,
            switchStatePath: switchStatePath
        )
    )
}

private func connectAndReadStatusOrExit(socketPath: URL) async throws -> (ControlSocketConnection, ModelsStatus) {
    do {
        return try await connectAndReadStatus(socketPath: socketPath)
    } catch ControlSocketConnectError.socketAbsent(let path) {
        writeStderr("macprovider-cli serve is not running on this host (no control socket at \(path))")
        throw ExitCode(4)
    } catch ControlSocketConnectError.connectionRefused(let path) {
        writeStderr("stale control socket at \(path) (no listener); remove the file and restart serve")
        throw ExitCode(4)
    } catch ControlSocketConnectError.handshakeTimeout {
        writeStderr("serve is running but warm-swap is not enabled (or serve is unresponsive); restart serve with --enable-warm-swap")
        throw ExitCode(4)
    }
}

private func connectAndReadStatus(socketPath: URL) async throws -> (ControlSocketConnection, ModelsStatus) {
    let connection = try await ControlSocketClient.connect(socketPath: socketPath)
    try await connection.send(.statusRequest)
    do {
        let frame = try await connection.receive(timeout: 2.0)
        guard case let .statusResponse(currentModelID, runtimeState) = frame else {
            await connection.close()
            throw ControlSocketConnectError.handshakeTimeout(path: socketPath.path)
        }
        return (connection, ModelsStatus(currentModelID: currentModelID, runtimeState: runtimeState))
    } catch ControlSocketConnectionError.timedOut {
        await connection.close()
        throw ControlSocketConnectError.handshakeTimeout(path: socketPath.path)
    }
}

private func idleCatalog(from config: AppConfig) -> [String] {
    if let supportedModels = config.supportedModels, !supportedModels.isEmpty {
        return supportedModels
    }
    if let model = config.model {
        return [model]
    }
    return []
}

private func printModelsTable(currentModelID: String?, supportedModels: [String]) {
    print("model_id\tstate")
    var rows = supportedModels
    if let currentModelID, !rows.contains(where: { $0.lowercased(with: nil) == currentModelID.lowercased(with: nil) }) {
        rows.insert(currentModelID, at: 0)
    }
    for modelID in rows {
        let state = currentModelID != nil && modelID.lowercased(with: nil) == currentModelID?.lowercased(with: nil) ? "warm" : "idle"
        print("\(modelID)\t\(state)")
    }
}

private func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
