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
        subcommands: [ServeCommand.self, SelfTestCommand.self, StatusCommand.self, UpdateCommand.self, UninstallCommand.self],
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

    func run() async throws {
        let resolved = try ConfigLoader.load(
            cli: CLIOverrides(
                port: port,
                model: model,
                coordinatorURL: coordinator,
                providerID: providerID,
                endpointURL: endpointURL,
                configPath: config,
                logLevel: logLevel
            )
        )

        printResolvedConfiguration(resolved)

        let modelRuntime = try await ModelRuntime(
            modelID: resolved.model,
            maxContextTokensOverride: resolved.maxContextOverride
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
            capacity: capacityDefaults.withThroughputEstimate(throughputEstimate)
        )
        let coordinatorClient = CoordinatorClient(config: resolved, modelRuntime: modelRuntime, providerStatus: providerStatus)
        await coordinatorClient?.start()
        let server = HTTPServer(config: resolved, modelRuntime: modelRuntime, providerStatus: providerStatus)
        let terminationHandler = installTerminationHandler(coordinatorClient: coordinatorClient)
        defer {
            Task {
                await coordinatorClient?.stop()
            }
            terminationHandler.cancel()
        }
        try withExtendedLifetime(terminationHandler) {
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

    @Option(help: "GitHub latest-release API URL. Defaults to the public macprovider-poc repository.")
    var releasesAPIURL: String?

    func run() async throws {
        try await SelfUpdate(
            currentVersion: CoordinatorClient.binaryVersion,
            releasesAPIURL: releasesAPIURL
        ).run(checkOnly: check)
    }
}

private func installTerminationHandler(coordinatorClient: CoordinatorClient?) -> DispatchSourceSignal {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
    source.setEventHandler {
        Task {
            await coordinatorClient?.drainAndExit(reason: "SIGTERM received")
            Darwin.exit(0)
        }
    }
    source.resume()
    return source
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
}
