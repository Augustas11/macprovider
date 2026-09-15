import ArgumentParser
import Foundation

enum Build1LaneAPrepareProfile {
    static let profile = "build1-lane-a"
    static let catalogKey = "meta-llama/llama-3.2-3b-instruct"
    static let artifactModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    static let unsupportedReason = "artifact_authority_unavailable"

    private static let stagingCoordinatorHosts: Set<String> = [
        "api-staging.malibu.tech",
        "staging-api.malibu.tech",
    ]

    static func isApprovedCatalogKey(_ value: String) -> Bool {
        prepareModelIDKey(value) == prepareModelIDKey(catalogKey)
            || prepareModelIDKey(value) == prepareModelIDKey(artifactModelID)
    }

    static func coordinatorIsAllowedForStaging(_ rawValue: String?) -> Bool {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let components = URLComponents(string: rawValue),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              ["ws", "wss", "http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return false
        }
        let normalizedHost = normalizeCoordinatorHost(host)
        return isLoopbackHost(normalizedHost) || stagingCoordinatorHosts.contains(normalizedHost)
    }

    private static func normalizeCoordinatorHost(_ host: String) -> String {
        var normalized = host
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

struct ModelsPrepareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Prepare the Build 1 Lane A model under staging-only guards."
    )

    @Argument(help: "Lane A catalog key. Only the approved Build 1 Llama 3B tuple is accepted.")
    var catalogKey: String

    @Flag(name: .customLong("json"), help: "Emit model_catalog_transaction_event.v1 frames on stdout.")
    var emitJSON = false

    @Flag(help: "Confirm a staging-only preparation attempt after reviewing models catalog-economics --json.")
    var yes = false

    @Option(help: "Preparation profile. The only accepted value is build1-lane-a.")
    var profile: String = Build1LaneAPrepareProfile.profile

    @Option(help: "Explicit staging coordinator URL. Only loopback and approved staging hosts are accepted.")
    var coordinatorURL: String?

    func run() async throws {
        guard emitJSON else {
            writePrepareStderr("models prepare is JSON-only in this release; pass --json")
            throw ExitCode(2)
        }

        let transactionID = UUID().uuidString.lowercased()

        func fail(
            reason: String,
            errorCode: ModelPreparationEventErrorCode = .actionUnavailable
        ) throws -> Never {
            try emitFailedEvent(
                transactionID: transactionID,
                modelKey: normalizedModelKey(),
                errorCode: errorCode
            )
            writePrepareStderr("models prepare refused: \(reason)")
            throw ExitCode(2)
        }

        guard yes else {
            try fail(reason: "confirmation_required")
        }
        guard profile == Build1LaneAPrepareProfile.profile else {
            try fail(reason: "unsupported_profile")
        }
        guard Build1LaneAPrepareProfile.isApprovedCatalogKey(catalogKey) else {
            try fail(reason: "unsupported_model_tuple")
        }
        guard Build1LaneAPrepareProfile.coordinatorIsAllowedForStaging(coordinatorURL) else {
            try fail(reason: "staging_coordinator_required")
        }

        try emitQueuedEvent(transactionID: transactionID)
        try emitFailedEvent(
            transactionID: transactionID,
            modelKey: Build1LaneAPrepareProfile.catalogKey,
            eventSequence: 2,
            errorCode: .authorityUnavailable
        )
        writePrepareStderr("models prepare refused: \(Build1LaneAPrepareProfile.unsupportedReason)")
        throw ExitCode(2)
    }

    private func normalizedModelKey() -> String {
        Build1LaneAPrepareProfile.isApprovedCatalogKey(catalogKey)
            ? Build1LaneAPrepareProfile.catalogKey
            : "unsupported"
    }

    private func emitQueuedEvent(transactionID: String) throws {
        try ModelSwitchingWireCodec.printJSON(ModelPreparationTransactionEvent(
            transactionID: transactionID,
            transactionKind: .prepareModel,
            modelKey: Build1LaneAPrepareProfile.catalogKey,
            eventSequence: 1,
            emittedAt: ModelSwitchingWireCodec.timestamp(),
            state: .queued,
            progress: nil,
            errorCode: nil,
            warningCode: nil
        ))
    }

    private func emitFailedEvent(
        transactionID: String,
        modelKey: String,
        eventSequence: Int = 1,
        errorCode: ModelPreparationEventErrorCode
    ) throws {
        try ModelSwitchingWireCodec.printJSON(ModelPreparationTransactionEvent(
            transactionID: transactionID,
            transactionKind: .prepareModel,
            modelKey: modelKey,
            eventSequence: eventSequence,
            emittedAt: ModelSwitchingWireCodec.timestamp(),
            state: .failed,
            progress: nil,
            errorCode: errorCode,
            warningCode: nil
        ))
    }
}

private func prepareModelIDKey(_ modelID: String) -> String {
    modelID.lowercased(with: nil)
}

private func writePrepareStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
