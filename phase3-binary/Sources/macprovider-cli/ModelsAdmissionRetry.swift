import ArgumentParser
import MacProviderCore
import Foundation

/// A fresh signed retry of an existing pending offer. This never interprets a
/// local model or successful preparation as coordinator admission authority.
struct ModelsAdmissionRetryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retry",
        abstract: "Retry a pending model admission using fresh provider authentication."
    )

    @Argument(help: "Candidate id or served model reference from models discover --json.")
    var candidate: String

    @Flag(name: .customLong("json"), help: "Emit model_admission_status.v1 coordinator readback.")
    var emitJSON = false

    @Flag(help: "Confirm a signed coordinator retry of this pending offer.")
    var yes = false

    @Option(help: "Provider YAML config path.")
    var config: String?

    @Option(help: "Coordinator URL override.")
    var coordinatorURL: String?

    @Option(help: "Provider identifier override.")
    var providerID: String?

    @Option(help: ArgumentHelp("CLI-owned discovery namespace path.", visibility: .hidden))
    var localDiscoveryNamespacePath: String?

    func validate() throws {
        guard emitJSON, yes else {
            throw ValidationError("models admission retry requires --yes --json")
        }
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("models admission retry requires a candidate")
        }
    }

    func run() async throws {
        try await run(context: .production)
    }

    func run(context: ModelCommandExecutionContext) async throws {
        try validate()
        do {
            let resolved = try loadModelAdmissionConfig(
                config: config, coordinatorURL: coordinatorURL, providerID: providerID
            )
            let inputs = await context.inputs().loadRecommendationInputs()
            let runtime = try makeRuntime(
                environment: context.discoveryEnvironment(.production(
                    namespacePath: localDiscoveryNamespacePath,
                    mlxCacheDir: nil, ollamaOrigin: "http://127.0.0.1:11434",
                    config: resolved.config,
                    catalogMatcher: BYOMCatalogMatcher(
                        candidateBytes: inputs.candidate.selectedBytes,
                        artifactFeed: inputs.artifactFeed.value
                    )
                )),
                config: resolved.config,
                coordinatorURL: resolved.coordinatorURL, context: context
            )
            let status = try await runtime.retryOffer(providerID: resolved.providerID, target: candidate)
            try ModelSwitchingWireCodec.printJSON(status)
        } catch let error as BYOMModelAdmissionError {
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
            throw ExitCode(2)
        }
    }

    func makeRuntime(environment: BYOMDiscoveryEnvironment, config: AppConfig,
                     coordinatorURL: String, context: ModelCommandExecutionContext = .production) throws -> BYOMModelAdmissionRuntime {
        BYOMModelAdmissionRuntime(
            environment: environment,
            credentialStore: context.providerStore(config),
            identityStore: context.identityStore(config),
            client: try context.admissionClient(coordinatorURL)
        )
    }

}
