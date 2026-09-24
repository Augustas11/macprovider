import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

enum Build1LaneAPrepareProfile {
    static let profile = "build1-lane-a"
    static let catalogKey = "meta-llama/llama-3.2-3b-instruct"
    static let artifactModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    static let artifactID = "mlx-4bit"
    static let artifactRevision = "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"
    static let artifactHash = "e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90"
    static let runtimeSource = "mlx_cache"
    /// SPEC-044 preparation precondition: `estimated_bytes` must be positive
    /// and at most 1 TiB before Prepare can be available.
    static let maxArtifactSizeBytes = Int(ModelPreparationContracts.maxEstimatedBytes)
    static let unsupportedReason = "artifact_authority_unavailable"
    static let configUnavailableReason = "config_unavailable"
    static let invalidTimeoutReason = "invalid_timeout"

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
              artifact.sizeBytes > 0,
              artifact.sizeBytes <= Build1LaneAPrepareProfile.maxArtifactSizeBytes
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

/// Serializes `model_catalog_transaction_event.v1` frames for one prepare
/// transaction with a monotonic sequence. Shared between the command and the
/// staging task so cancellation and progress cannot interleave out of order.
final class Build1LaneAPrepareEventEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let transactionID: String
    private var nextSequence = 1

    init(transactionID: String) {
        self.transactionID = transactionID
    }

    var emittedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextSequence - 1
    }

    func emit(
        modelKey: String = Build1LaneAPrepareProfile.catalogKey,
        state: ModelPreparationEventState,
        progress: ModelPreparationTransactionEvent.Progress? = nil,
        errorCode: ModelPreparationEventErrorCode? = nil,
        warningCode: ModelPreparationEventWarningCode? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let event = try ModelPreparationTransactionEvent(
            transactionID: transactionID,
            transactionKind: .prepareModel,
            modelKey: modelKey,
            eventSequence: nextSequence,
            emittedAt: ModelSwitchingWireCodec.timestamp(),
            state: state,
            progress: progress,
            errorCode: errorCode,
            warningCode: warningCode
        )
        try ModelSwitchingWireCodec.printJSON(event)
        fflush(stdout)
        nextSequence += 1
    }
}

struct ModelsPrepareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Prepare a signed catalog model (--profile catalog) or the Build 1 Lane A model.",
        discussion: "--profile catalog (implied by --repair-cache) downloads the signed catalog row's pinned "
            + "snapshot with the serve/autotune downloader, verifies its canonical hash, and prints one final "
            + "state: ready (verified), downloaded but hash mismatch (see verify-artifact), or incomplete "
            + "(retry: <command>). The default build1-lane-a profile is the JSON-only staging transaction."
    )

    @Argument(help: "Catalog key or model id. The build1-lane-a profile accepts only the approved Build 1 Llama 3B tuple.")
    var catalogKey: String

    @Flag(name: .customLong("json"), help: "Emit model_catalog_transaction_event.v1 frames (build1-lane-a) or one model_prepare_result.v1 object (catalog) on stdout.")
    var emitJSON = false

    @Flag(help: "build1-lane-a only: confirm a staging-only preparation attempt after reviewing models catalog-economics --json.")
    var yes = false

    @Option(help: "Preparation profile: build1-lane-a (default) or catalog.")
    var profile: String?

    @Flag(help: "Catalog profile: remove only this model's interrupted-download leftovers and an unverifiable pinned cache snapshot, then download again. Implies --profile catalog.")
    var repairCache = false

    @Option(help: "build1-lane-a only: explicit staging coordinator URL. Only loopback and approved staging hosts are accepted.")
    var coordinatorURL: String?

    @Option(help: "YAML config path used to resolve model_artifact_root. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "build1-lane-a only: abort staging after this many seconds and report timed_out. Unset means no deadline.")
    var timeoutSeconds: Int?

    func run() async throws {
        if profile == ModelsCatalogPrepareRunner.profile || (profile == nil && repairCache) {
            let laneAOnly = [
                yes ? "--yes" : nil,
                coordinatorURL == nil ? nil : "--coordinator-url",
                timeoutSeconds == nil ? nil : "--timeout-seconds",
            ].compactMap { $0 }
            guard laneAOnly.isEmpty else {
                writePrepareStderr("models prepare refused: \(laneAOnly.joined(separator: ", ")) applies only to --profile \(Build1LaneAPrepareProfile.profile), not --profile \(ModelsCatalogPrepareRunner.profile)")
                throw ExitCode(2)
            }
            try await ModelsCatalogPrepareRunner.run(
                key: catalogKey,
                repairCache: repairCache,
                emitJSON: emitJSON,
                config: config
            )
            return
        }
        guard emitJSON else {
            writePrepareStderr("models prepare is JSON-only in this release; pass --json")
            throw ExitCode(2)
        }

        let emitter = Build1LaneAPrepareEventEmitter(transactionID: UUID().uuidString.lowercased())

        func fail(
            reason: String,
            modelKey: String,
            errorCode: ModelPreparationEventErrorCode = .actionUnavailable
        ) throws -> Never {
            try emitter.emit(modelKey: modelKey, state: .failed, errorCode: errorCode)
            writePrepareStderr("models prepare refused: \(reason)")
            throw ExitCode(2)
        }

        guard yes else {
            try fail(reason: "confirmation_required", modelKey: normalizedModelKey())
        }
        guard (profile ?? Build1LaneAPrepareProfile.profile) == Build1LaneAPrepareProfile.profile, !repairCache else {
            try fail(reason: "unsupported_profile", modelKey: normalizedModelKey())
        }
        guard Build1LaneAPrepareProfile.isApprovedCatalogKey(catalogKey) else {
            try fail(reason: "unsupported_model_tuple", modelKey: normalizedModelKey())
        }
        guard Build1LaneAPrepareProfile.coordinatorIsAllowedForStaging(coordinatorURL) else {
            try fail(reason: "staging_coordinator_required", modelKey: normalizedModelKey())
        }
        if let timeoutSeconds, timeoutSeconds <= 0 {
            try fail(reason: Build1LaneAPrepareProfile.invalidTimeoutReason, modelKey: normalizedModelKey())
        }

        try emitter.emit(state: .queued)
        let authority: Build1LaneAArtifactAuthority
        do {
            authority = try await Build1LaneAArtifactAuthorityResolver.resolve(coordinatorURL: coordinatorURL)
        } catch {
            try fail(
                reason: Build1LaneAPrepareProfile.unsupportedReason,
                modelKey: Build1LaneAPrepareProfile.catalogKey,
                errorCode: .authorityUnavailable
            )
        }
        try emitter.emit(
            state: .running,
            progress: try ModelPreparationTransactionEvent.Progress(
                stageLabelKey: "artifact_authority_verified",
                bytesCompleted: 0,
                bytesExpected: Int64(authority.sizeBytes),
                percentComplete: 0,
                heartbeat: nil
            )
        )

        // Resolve the durable root the same way `serve` preflight does so the
        // adopted copy is the one the provider runtime will load. Config is
        // read only; nothing here changes the active model.
        let appConfig: AppConfig
        do {
            appConfig = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        } catch {
            try fail(
                reason: Build1LaneAPrepareProfile.configUnavailableReason,
                modelKey: Build1LaneAPrepareProfile.catalogKey,
                errorCode: .rootUnavailable
            )
        }
        writePrepareStderr(Self.disclosureLine(for: authority))

        let deadline = timeoutSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }
        let coordinatorURL = self.coordinatorURL
        let stager = Build1LaneAArtifactStager.makeStager(appConfig, deadline) {
            try await Build1LaneAArtifactAuthorityResolver.resolve(coordinatorURL: coordinatorURL)
        }
        let work = Task {
            try await stager.stageAndAdopt(authority: authority) { stage, bytesCompleted, bytesExpected in
                try emitter.emit(
                    state: .running,
                    progress: try ModelPreparationTransactionEvent.Progress(
                        stageLabelKey: stage.rawValue,
                        bytesCompleted: bytesCompleted,
                        bytesExpected: bytesExpected,
                        percentComplete: Self.percent(completed: bytesCompleted, expected: bytesExpected),
                        heartbeat: nil
                    )
                )
            }
        }
        let signalSources = Self.installCancellationSources { work.cancel() }
        defer { signalSources.forEach { $0.cancel() } }

        let staged: Build1LaneAStagedArtifact
        do {
            staged = try await work.value
        } catch let error as Build1LaneAArtifactStagingError {
            try Self.emitStagingFailure(error, emitter: emitter)
        } catch is CancellationError {
            try Self.emitStagingFailure(.cancelled, emitter: emitter)
        } catch {
            try Self.emitStagingFailure(.transferFailed(String(describing: error)), emitter: emitter)
        }

        try emitter.emit(state: .succeeded)
        if staged.stagingCleanupRequired {
            writePrepareStderr("models prepare warning: \(ModelPreparationEventWarningCode.stagingCleanupRequired.rawValue)")
        }
        writePrepareStderr(
            "models prepare adopted \(authority.modelID)@\(authority.revision) "
                + "\(authority.hashAlgorithm)=\(staged.sha256) adopted_bytes=\(staged.adoptedBytes) "
                + "reused_durable_artifact=\(staged.reusedDurableArtifact); "
                + "preparation grants no admission, settlement, earnings, rewards, payouts, or production activation"
        )
    }

    private static func emitStagingFailure(
        _ error: Build1LaneAArtifactStagingError,
        emitter: Build1LaneAPrepareEventEmitter
    ) throws -> Never {
        switch error {
        case .cancelled:
            try emitter.emit(state: .cancelRequested)
            try emitter.emit(state: .cancelled)
            writePrepareStderr("models prepare cancelled: active model unchanged; durable store left as found")
            throw ExitCode(130)
        case .timedOut:
            try emitter.emit(state: .timedOut, errorCode: .timedOut)
            writePrepareStderr("models prepare timed out: active model unchanged; durable store left as found")
            throw ExitCode(2)
        default:
            let code = errorCode(for: error)
            try emitter.emit(state: .failed, errorCode: code)
            writePrepareStderr("models prepare failed: \(code.rawValue)\(detail(for: error))")
            throw ExitCode(2)
        }
    }

    private static func errorCode(for error: Build1LaneAArtifactStagingError) -> ModelPreparationEventErrorCode {
        switch error {
        case .rootUnavailable: return .rootUnavailable
        case .authorityUnavailable: return .authorityUnavailable
        case .authorityMismatch: return .artifactIdentityMismatch
        case .operationConflict: return .operationConflict
        case .insufficientDiskSpace: return .insufficientDiskSpace
        case .transferFailed: return .transferFailed
        case .verificationFailed: return .verificationFailed
        case .publicationFailed: return .publicationFailed
        case .timedOut: return .timedOut
        case .cancelled: return .internalError
        }
    }

    /// Operator-local diagnostics only. Never includes private paths, tokens,
    /// or the durable root.
    private static func detail(for error: Build1LaneAArtifactStagingError) -> String {
        switch error {
        case .insufficientDiskSpace(let required, let available):
            return " required_bytes=\(required) available_bytes=\(available)"
        case .verificationFailed(let expected, let actual):
            return " expected=\(expected) actual=\(actual)"
        default:
            return ""
        }
    }

    private static func disclosureLine(for authority: Build1LaneAArtifactAuthority) -> String {
        "models prepare staging \(authority.modelID)@\(authority.revision) "
            + "artifact=\(authority.artifactID) \(authority.hashAlgorithm)=\(authority.hash) "
            + "size_bytes=\(authority.sizeBytes) runtime_source=\(Build1LaneAPrepareProfile.runtimeSource) "
            + "release=\(authority.releaseID) signer=\(authority.feedSignerKeyID) feed_sha256=\(authority.feedSHA256); "
            + "staging-only, no admission or earnings are granted"
    }

    private static func percent(completed: Int64?, expected: Int64?) -> Double? {
        guard let completed, let expected, expected > 0 else { return nil }
        return min(100, max(0, Double(completed) / Double(expected) * 100))
    }

    /// SIGINT/SIGTERM cancel the staging task so the downloader unwinds through
    /// its own staging-directory cleanup and the command reports
    /// `cancel_requested` then `cancelled` instead of dying mid-write.
    private static func installCancellationSources(_ cancel: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { cancel() }
            source.resume()
            return source
        }
    }

    private func normalizedModelKey() -> String {
        Build1LaneAPrepareProfile.isApprovedCatalogKey(catalogKey)
            ? Build1LaneAPrepareProfile.catalogKey
            : "unsupported"
    }
}

private func prepareModelIDKey(_ modelID: String) -> String {
    modelID.lowercased(with: nil)
}

private func writePrepareStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
