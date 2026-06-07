import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MacProviderCore

@main
struct MacProviderCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macprovider-cli",
        abstract: "OpenAI-compatible Mac Provider inference CLI.",
        version: CoordinatorClient.binaryVersion,
        subcommands: [ServeCommand.self, SelfTestCommand.self, StatusCommand.self, UpdateCommand.self, UninstallCommand.self, ModelsCommand.self],
        defaultSubcommand: ServeCommand.self
    )
}

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the local inference server and coordinator client."
    )

    @Option(help: "Local HTTP port to bind. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Coordinator WebSocket URL. Overrides MACPROVIDER_COORDINATOR_URL and config file coordinator_url.")
    var coordinator: String?

    @Option(help: "Stable provider identifier sent in the coordinator hello message. Must match the coordinator's config.providers[] entry. Overrides MACPROVIDER_PROVIDER_ID and config file provider_id. If unset, a per-instance UUID is generated (suitable for dev/test only).")
    var providerID: String?

    @Option(help: "Public HTTPS endpoint for HTTP-forwarding mode. If omitted, the provider defaults to WS-tunneled mode unless config overrides it.")
    var endpointURL: String?

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Log level: trace, debug, info, notice, warning, error, critical.")
    var logLevel: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths) this provider can serve. Overrides MACPROVIDER_SUPPORTED_MODELS and config key supported_models. When unset, the binary publishes supported_models: [model_id] (single-entry, per SPEC-010 v1.5 R-3.6.2).")
    var supportedModels: String?

    @Flag(name: .customLong("publish-supported-models"), inversion: .prefixedNo, help: "Opt into publishing the supported_models catalog to the coordinator's /v1/status echo (SPEC-010 v1.5 R-3.6.4). Default off.")
    var publishSupportedModels: Bool?

    @Flag(name: .customLong("enable-warm-swap"), inversion: .prefixedNo, help: "Opt into the operator-pushed warm model swap workflow (SPEC-011 v0.5). Default off. When off, the binary follows the SPEC-001 v1.2.4 synchronous-load path; no control socket is opened.")
    var enableWarmSwap: Bool?

    @Option(help: "Drain timeout in seconds for an in-flight warm swap (SPEC-011 v0.5 §3.4 / §3.9). Default 30. Only meaningful when --enable-warm-swap is set.")
    var swapDrainTimeoutSeconds: Int?

    @Option(help: "Control socket path. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock. Only meaningful when --enable-warm-swap is set.")
    var ctlSocketPath: String?

    // Phase 1E reads/writes this path for the cooldown soft guard; Phase 1C only plumbs it.
    @Option(help: "CLI-side cooldown state file. Overrides MACPROVIDER_SWITCH_STATE_PATH and config switch_state_path. Default $HOME/Library/Application Support/macprovider-cli/last-switch.ts. Cooldown soft guard lands in Phase 1E.")
    var switchStatePath: String?

    static func runSupportedModelsPreflight(_ resolved: inout AppConfig) throws {
        if resolved.supportedModels != nil {
            do {
                let catalog = try SupportedModels.validate(
                    model: resolved.model ?? "",
                    supportedModels: resolved.supportedModels
                )
                resolved.supportedModels = catalog
            } catch let error as SupportedModelsValidationError {
                FileHandle.standardError.write(Data(("\(error)\n").utf8))
                throw ExitCode(2)
            }
        }
    }

    static func runDrainTimeoutPreflight(_ resolved: AppConfig) throws {
        if !(5...600).contains(resolved.swapDrainTimeoutSeconds) {
            FileHandle.standardError.write(Data((
                "--swap-drain-timeout-seconds \(resolved.swapDrainTimeoutSeconds) out of range 5...600\n"
            ).utf8))
            throw ExitCode(2)
        }
    }

    func run() async throws {
        var resolved = try ConfigLoader.load(
            cli: CLIOverrides(
                port: port,
                model: model,
                coordinatorURL: coordinator,
                providerID: providerID,
                endpointURL: endpointURL,
                configPath: config,
                logLevel: logLevel,
                supportedModels: SupportedModels.parseCSV(supportedModels),
                publishesSupportedModels: publishSupportedModels,
                enableWarmSwap: enableWarmSwap,
                swapDrainTimeoutSeconds: swapDrainTimeoutSeconds,
                ctlSocketPath: ctlSocketPath,
                switchStatePath: switchStatePath
            )
        )

        try Self.runSupportedModelsPreflight(&resolved)
        try Self.runDrainTimeoutPreflight(resolved)

        printResolvedConfiguration(resolved)

        let modelRuntime = try await ModelRuntime(
            modelID: resolved.model,
            maxContextTokensOverride: resolved.maxContextOverride,
            warmSwapEnabled: resolved.enableWarmSwap,
            swapDrainTimeoutSeconds: resolved.swapDrainTimeoutSeconds
        )
        // MLX generation is currently guarded by a process-local semaphore of 1.
        // Advertise the real runtime concurrency until the runtime is proven safe
        // for parallel generation.
        let capacityDefaults = ProviderCapacity(
            maxContextOverride: resolved.maxContextOverride,
            maxConcurrencyOverride: 1
        )
        let throughputEstimate = await modelRuntime.measureStartupThroughput()
        let providerStatus = ProviderStatus(
            modelID: resolved.model,
            modelLoaded: await modelRuntime.isLoaded,
            capacity: capacityDefaults.withThroughputEstimate(throughputEstimate),
            modelHash: await modelRuntime.loadedModelHash
        )
        await modelRuntime.setProviderStatus(providerStatus)
        let coordinatorClient = CoordinatorClient(
            config: resolved,
            modelRuntime: modelRuntime,
            providerStatus: providerStatus,
            attestationGenerator: ManagedDeviceAttestationGenerator(artifactPath: resolved.tier2MDAArtifactPath)
        )
        let controlSocket: ControlSocketServer?
        if resolved.enableWarmSwap {
            let socketURL = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
            controlSocket = ControlSocketServer(
                socketPath: socketURL,
                modelRuntime: modelRuntime,
                supportedModels: resolved.supportedModels
            )
            do {
                try await controlSocket?.start()
            } catch {
                if let serverError = error as? ControlSocketServerError,
                   serverError != .staleSocket(path: socketURL.path) {
                    FileHandle.standardError.write(Data(("\(serverError.description)\n").utf8))
                }
                throw ExitCode(1)
            }
        } else {
            controlSocket = nil
        }
        await coordinatorClient?.start()
        let server = HTTPServer(config: resolved, modelRuntime: modelRuntime, providerStatus: providerStatus)
        let terminationHandlers = installTerminationHandlers(coordinatorClient: coordinatorClient, controlSocket: controlSocket)
        defer {
            Task {
                await controlSocket?.stop()
                await coordinatorClient?.stop()
            }
            terminationHandlers.forEach { $0.cancel() }
        }
        try withExtendedLifetime(terminationHandlers) {
            try server.run()
        }
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show local provider status."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Local HTTP port to query. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    func run() async throws {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(port: port, configPath: config)
        )
        let status = try await LocalStatusClient.fetch(port: resolved.port)
        let latest = try? await SelfUpdate(currentVersion: CoordinatorClient.binaryVersion, releasesAPIURL: nil).latestVersionCached()
        print(LocalStatusFormatter.format(status, latestVersion: latest))
    }
}

struct SelfTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-test",
        abstract: "Load the configured model and run a startup inference smoke test."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    func run() async throws {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(model: model, configPath: config)
        )
        let runtime = try await ModelRuntime(
            modelID: resolved.model,
            maxContextTokensOverride: resolved.maxContextOverride
        )
        guard await runtime.isLoaded else {
            throw ValidationError("Model not loaded")
        }
        let throughput = await runtime.measureStartupThroughput(maxTokens: 4)
        guard throughput > 0 else {
            throw ValidationError("Startup inference self-test produced no tokens")
        }
        print("self-test passed: throughput_tps=\(throughput)")
    }
}

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for or install the latest macprovider-cli release."
    )

    @Flag(help: "Check for updates without downloading or replacing the binary.")
    var check = false

    @Option(help: "GitHub latest-release API URL. Defaults to the public macprovider release repository.")
    var releasesAPIURL: String?

    func run() async throws {
        try await SelfUpdate(
            currentVersion: CoordinatorClient.binaryVersion,
            releasesAPIURL: releasesAPIURL
        ).run(checkOnly: check)
    }
}

private func installTerminationHandlers(
    coordinatorClient: CoordinatorClient?,
    controlSocket: ControlSocketServer?
) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            Task {
                await controlSocket?.stop()
                await coordinatorClient?.drainAndExit(reason: "\(signalName(signalNumber)) received")
                Darwin.exit(0)
            }
        }
        source.resume()
        return source
    }
}

private func signalName(_ signalNumber: Int32) -> String {
    switch signalNumber {
    case SIGTERM:
        return "SIGTERM"
    case SIGINT:
        return "SIGINT"
    default:
        return "signal \(signalNumber)"
    }
}

private func printResolvedConfiguration(_ config: AppConfig) {
    print("macprovider-cli config")
    print("  port: \(config.port)")
    print("  model: \(config.model ?? "<unset>")")
    print("  coordinator_url: \(config.coordinatorURL ?? "<unset>")")
    print("  provider_id: \(config.providerID ?? "<unset, will use per-instance UUID>")")
    print("  endpoint_url: \(config.endpointURL ?? "<unset, WS-tunneled>")")
    print("  config: \(config.configPath)")
    print("  log_level: \(config.logLevel.rawValue)")
    print("  log_format: \(config.logFormat.rawValue)")
    print("  tier2_mda_artifact_path: \(config.tier2MDAArtifactPath ?? "<unset>")")
}
