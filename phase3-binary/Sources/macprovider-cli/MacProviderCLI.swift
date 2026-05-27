import ArgumentParser
import Darwin
import Dispatch
import Foundation
import MacProviderCore

@main
struct MacProviderCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macprovider-cli",
        abstract: "OpenAI-compatible Mac Provider inference CLI."
    )

    @Option(help: "Local HTTP port to bind. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Coordinator WebSocket URL. Overrides MACPROVIDER_COORDINATOR_URL and config file coordinator_url.")
    var coordinator: String?

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
                configPath: config,
                logLevel: logLevel
            )
        )

        printResolvedConfiguration(resolved)

        let modelRuntime = try await ModelRuntime(
            modelID: resolved.model,
            maxContextTokensOverride: resolved.maxContextOverride
        )
        let capacityDefaults = ProviderCapacity(
            maxContextOverride: resolved.maxContextOverride,
            maxConcurrencyOverride: resolved.maxConcurrencyOverride
        )
        let throughputEstimate = await modelRuntime.measureStartupThroughput()
        let providerStatus = ProviderStatus(
            modelID: resolved.model,
            modelLoaded: await modelRuntime.isLoaded,
            capacity: capacityDefaults.withThroughputEstimate(throughputEstimate)
        )
        let coordinatorClient = CoordinatorClient(config: resolved, providerStatus: providerStatus)
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
    print("  config: \(config.configPath)")
    print("  log_level: \(config.logLevel.rawValue)")
    print("  log_format: \(config.logFormat.rawValue)")
}
