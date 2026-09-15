import ArgumentParser
import Foundation

enum Build1LaneAPrepareProfile {
    static let profile = "build1-lane-a"
    static let catalogKey = "meta-llama/llama-3.2-3b-instruct"
    static let artifactModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    static let artifactID = "mlx-4bit"
    static let artifactRevision = "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"
    static let artifactHash = "e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90"
    static let runtimeSource = "mlx_cache"
    static let unsupportedReason = "artifact_authority_unavailable"
    static let stagingUnavailableReason = "artifact_staging_not_implemented"

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
        if isLoopbackHost(normalizedHost) {
            return true
        }
        guard stagingCoordinatorHosts.contains(normalizedHost),
              ["wss", "https"].contains(scheme),
              components.port == nil || components.port == 443
        else {
            return false
        }
        return true
    }

    static func stagingFeedBaseURL(from rawValue: String?) -> URL? {
        guard coordinatorIsAllowedForStaging(rawValue),
              let rawValue,
              var components = URLComponents(string: rawValue)
        else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            return nil
        }
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
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

struct Build1LaneAArtifactAuthority: Equatable, Sendable {
    var catalogKey: String
    var modelID: String
    var revision: String
    var artifactID: String
    var hashAlgorithm: String
    var hash: String
    var sizeBytes: Int
    var feedSHA256: String
    var feedSignerKeyID: String
    var releaseID: String
}

enum Build1LaneAArtifactAuthorityError: Error, Equatable, Sendable {
    case staticCatalogUnavailable
    case staticCatalogTupleMismatch
    case stagingCoordinatorUnavailable
    case artifactAuthorityUnavailable([String])
    case artifactTupleMismatch
}

enum Build1LaneAArtifactAuthorityResolver {
    nonisolated(unsafe) static var makeStaticInputs: @Sendable (URL) -> AutotuneStaticInputs = { _ in
        AutotuneStaticInputs(fetch: fetchNoRedirect)
    }

    private static let maxArtifactFeedBytes = 2 * 1024 * 1024
    private static let maxArtifactSignatureBytes = 64 * 1024

    private static let noRedirectSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }()

    static func resolve(coordinatorURL: String?) async throws -> Build1LaneAArtifactAuthority {
        guard let baseURL = Build1LaneAPrepareProfile.stagingFeedBaseURL(from: coordinatorURL) else {
            throw Build1LaneAArtifactAuthorityError.stagingCoordinatorUnavailable
        }
        let candidateBytes = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let catalog: CandidateCatalog
        do {
            catalog = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
        } catch {
            throw Build1LaneAArtifactAuthorityError.staticCatalogUnavailable
        }
        guard let row = catalog.rows[Build1LaneAPrepareProfile.catalogKey],
              row.modelID == Build1LaneAPrepareProfile.artifactModelID,
              row.modelRevision == Build1LaneAPrepareProfile.artifactRevision,
              row.modelSHA256 == Build1LaneAPrepareProfile.artifactHash,
              row.runtimeStatus == "recommendable"
        else {
            throw Build1LaneAArtifactAuthorityError.staticCatalogTupleMismatch
        }

        let candidate = AutotuneStaticSelection(
            value: catalog,
            selectedBytes: candidateBytes,
            warnings: [],
            usedFallback: false,
            signerKeyID: AutotuneStaticInputs.bakedCatalogSignerKeyID
        )
        let inputs = makeStaticInputs(baseURL)
        let selection = await inputs.loadLiveArtifactFeed(candidate: candidate, baseURL: baseURL)
        guard selection.warnings.isEmpty, let qualified = selection.value else {
            throw Build1LaneAArtifactAuthorityError.artifactAuthorityUnavailable(selection.warnings.map(\.rawValue).sorted())
        }
        guard let model = qualified.feed.models[Build1LaneAPrepareProfile.catalogKey],
              model.primaryArtifactID == Build1LaneAPrepareProfile.artifactID
        else {
            throw Build1LaneAArtifactAuthorityError.artifactTupleMismatch
        }
        let artifact = model.primary
        guard artifact.runtimeFormat == ArtifactFeed.primaryFormat,
              artifact.sourceRef.repoID == Build1LaneAPrepareProfile.artifactModelID,
              artifact.sourceRef.revision == Build1LaneAPrepareProfile.artifactRevision,
              artifact.hashAlgorithm == "macprovider.snapshot-manifest.v1",
              artifact.hash == Build1LaneAPrepareProfile.artifactHash,
              artifact.allowedRuntimeSources == [Build1LaneAPrepareProfile.runtimeSource],
              artifact.verificationStatus == "verified",
              artifact.sizeBytes > 0
        else {
            throw Build1LaneAArtifactAuthorityError.artifactTupleMismatch
        }
        return Build1LaneAArtifactAuthority(
            catalogKey: Build1LaneAPrepareProfile.catalogKey,
            modelID: Build1LaneAPrepareProfile.artifactModelID,
            revision: Build1LaneAPrepareProfile.artifactRevision,
            artifactID: Build1LaneAPrepareProfile.artifactID,
            hashAlgorithm: artifact.hashAlgorithm,
            hash: artifact.hash,
            sizeBytes: artifact.sizeBytes,
            feedSHA256: qualified.feedSHA256,
            feedSignerKeyID: qualified.signerKeyID,
            releaseID: qualified.releaseID
        )
    }

    private static func fetchNoRedirect(_ url: URL) async throws -> Data {
        let maxBytes = url.path.hasSuffix(".sig") ? maxArtifactSignatureBytes : maxArtifactFeedBytes
        let (bytes, response) = try await noRedirectSession.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw AutotuneRecommendError.invalidStaticJSON("HTTP \(http.statusCode)")
        }
        if response.expectedContentLength > Int64(maxBytes) {
            throw AutotuneRecommendError.invalidStaticJSON("response too large")
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            if data.count >= maxBytes {
                throw AutotuneRecommendError.invalidStaticJSON("response too large")
            }
            data.append(byte)
        }
        return data
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
        let authority: Build1LaneAArtifactAuthority
        do {
            authority = try await Build1LaneAArtifactAuthorityResolver.resolve(coordinatorURL: coordinatorURL)
        } catch {
            try emitFailedEvent(
                transactionID: transactionID,
                modelKey: Build1LaneAPrepareProfile.catalogKey,
                eventSequence: 2,
                errorCode: .authorityUnavailable
            )
            writePrepareStderr("models prepare refused: \(Build1LaneAPrepareProfile.unsupportedReason)")
            throw ExitCode(2)
        }
        try emitAuthorityVerifiedEvent(transactionID: transactionID, authority: authority)
        try emitFailedEvent(
            transactionID: transactionID,
            modelKey: Build1LaneAPrepareProfile.catalogKey,
            eventSequence: 3,
            errorCode: .actionUnavailable
        )
        writePrepareStderr("models prepare refused: \(Build1LaneAPrepareProfile.stagingUnavailableReason)")
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

    private func emitAuthorityVerifiedEvent(transactionID: String, authority: Build1LaneAArtifactAuthority) throws {
        try ModelSwitchingWireCodec.printJSON(ModelPreparationTransactionEvent(
            transactionID: transactionID,
            transactionKind: .prepareModel,
            modelKey: authority.catalogKey,
            eventSequence: 2,
            emittedAt: ModelSwitchingWireCodec.timestamp(),
            state: .running,
            progress: try ModelPreparationTransactionEvent.Progress(
                stageLabelKey: "artifact_authority_verified",
                bytesCompleted: 0,
                bytesExpected: Int64(authority.sizeBytes),
                percentComplete: 0,
                heartbeat: nil
            ),
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
