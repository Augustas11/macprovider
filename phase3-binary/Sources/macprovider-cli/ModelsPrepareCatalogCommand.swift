import ArgumentParser
import Darwin
import Foundation

// MARK: - models prepare-catalog

/// SPEC-010-R008 (v1.17) / SPEC-044-R014-4: the event-reporting catalog
/// preparation Malibu's Download action runs. It is the `--profile catalog`
/// preparation without `--repair-cache`, reported only as
/// `model_catalog_transaction_event.v1` lines so Malibu can show progress and
/// cancel it. It never changes config, the served model, admission, or
/// settlement.
struct ModelsPrepareCatalogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare-catalog",
        abstract: "Download and verify a signed catalog model, reporting progress as transaction events.",
        discussion: "Resolves the signed catalog row, downloads its pinned snapshot with the serve/autotune "
            + "downloader, verifies the signed hash and adopts it into the durable model store. stdout carries "
            + "only model_catalog_transaction_event.v1 lines: queued, running (stage downloading, at least every "
            + "10 s), then succeeded (exit 0), failed (exit 4 refused/untrusted/space/transfer, 5 verification) or, "
            + "after SIGINT/SIGTERM, cancel_requested and cancelled (exit 130) with this model's interrupted-download "
            + "leftovers removed. It never changes config or the active model."
    )

    @Argument(help: "Signed catalog key or model id, e.g. qwen/qwen3-8b.")
    var catalogKey: String

    @Option(name: .customLong("transaction-id"), help: "UUID v4 transaction id of the prepare action in models catalog-economics --json.")
    var transactionID: String

    @Flag(name: .customLong("json"), help: "Required: emit model_catalog_transaction_event.v1 lines on stdout.")
    var emitJSON = false

    @Option(help: "YAML config path used to resolve model_artifact_root. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    func run() async throws {
        guard emitJSON else {
            writeDiagnosticsStderr("models prepare-catalog is JSON-only; pass --json")
            throw ExitCode(2)
        }
        do {
            try ModelPreparationContracts.requireUUIDv4(transactionID, field: "transaction_id")
            try ModelPreparationContracts.requireSafeString(catalogKey, field: "model_key")
        } catch {
            writeDiagnosticsStderr("models prepare-catalog refused: transaction id must be a lowercase UUID v4 and the key a safe catalog key")
            throw ExitCode(2)
        }
        let appConfig = try loadDiagnosticsConfig(config, command: "models prepare-catalog")
        let sink = ModelsPrepareCatalogEventSink(transactionID: transactionID) { event in
            try? ModelSwitchingWireCodec.printJSON(event)
            fflush(stdout)
        }
        let cancellation = ModelsPrepareCatalogCancellation()
        let sources = Self.installCancellationSources { cancellation.request() }
        defer { sources.forEach { $0.cancel() } }
        let exitCode = await ModelsPrepareCatalogRunner.run(
            key: catalogKey,
            resolver: CachedModelArtifactResolver.forConfig(appConfig),
            config: config,
            sink: sink,
            cancellation: cancellation
        )
        if exitCode != 0 {
            throw ExitCode(exitCode)
        }
    }

    /// SIGINT/SIGTERM request cancellation so the downloader unwinds through
    /// its staging cleanup instead of dying mid-write.
    private static func installCancellationSources(_ cancel: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { cancel() }
            source.resume()
            return source
        }
    }
}

/// Serializes the transaction's events with one monotonic sequence, so the
/// progress loop, the signal handler and the terminal event cannot interleave
/// out of order or after the terminal event.
final class ModelsPrepareCatalogEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let transactionID: String
    private let write: @Sendable (ModelPreparationTransactionEvent) -> Void
    private var nextSequence = 1
    private var terminal = false

    init(transactionID: String, write: @escaping @Sendable (ModelPreparationTransactionEvent) -> Void) {
        self.transactionID = transactionID
        self.write = write
    }

    /// Returns false when nothing was written: after the terminal event, or
    /// when the event would violate the closed event contract.
    @discardableResult
    func emit(
        modelKey: String,
        state: ModelPreparationEventState,
        progress: ModelPreparationTransactionEvent.Progress? = nil,
        errorCode: ModelPreparationEventErrorCode? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal,
              let event = try? ModelPreparationTransactionEvent(
                  transactionID: transactionID,
                  transactionKind: .prepareModel,
                  modelKey: modelKey,
                  eventSequence: nextSequence,
                  emittedAt: ModelSwitchingWireCodec.timestamp(),
                  state: state,
                  progress: progress,
                  errorCode: errorCode,
                  warningCode: nil
              )
        else { return false }
        write(event)
        nextSequence += 1
        if [.succeeded, .failed, .timedOut, .cancelled].contains(state) {
            terminal = true
        }
        return true
    }
}

/// A one-way cancellation latch the signal handler sets and the runner reads.
final class ModelsPrepareCatalogCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var onRequest: (@Sendable () -> Void)?

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func request() {
        lock.lock()
        guard !requested else {
            lock.unlock()
            return
        }
        requested = true
        let handler = onRequest
        lock.unlock()
        handler?()
    }

    /// Installs the handler; runs it at once when cancellation already arrived.
    func onRequest(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        onRequest = handler
        let already = requested
        lock.unlock()
        if already { handler() }
    }
}

enum ModelsPrepareCatalogRunner {
    static let stageLabel = "downloading"

    struct Dependencies: Sendable {
        var resolveRow: @Sendable (String) async throws -> ModelArtifactSignedRow
        var prepare: @Sendable (ModelArtifactSignedRow, CachedModelArtifactResolver, String?) async -> ModelPrepareOutcome
        /// Bytes of completed files the downloader has staged so far.
        var stagedBytes: @Sendable (ModelArtifactSignedRow, CachedModelArtifactResolver) -> Int64
        /// Removes only this model's interrupted-download leftovers.
        var removePartials: @Sendable (ModelArtifactSignedRow, CachedModelArtifactResolver) -> Void
        /// At most 10 s (SPEC-044-R014-4); 8 s leaves margin and keeps a long download's output small.
        var progressIntervalNanoseconds: UInt64 = 8_000_000_000

        static let live = Dependencies(
            resolveRow: { try await ModelArtifactSignedRowResolver.resolve(key: $0) },
            prepare: { row, resolver, config in
                await ModelCatalogPreparation.prepare(row: row, resolver: resolver, repairCache: false, config: config)
            },
            stagedBytes: { row, resolver in
                let snapshots = resolver.snapshotURL(modelID: row.modelID, revision: row.revision).deletingLastPathComponent()
                let names = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
                return names.filter { $0.hasPrefix(".download-") }.reduce(Int64(0)) {
                    $0 + (ModelArtifactDiagnostics.regularFileBytes(in: snapshots.appendingPathComponent($1)) ?? 0)
                }
            },
            removePartials: { row, resolver in
                let partials = ModelArtifactDiagnostics.findPartials(row: row, resolver: resolver)
                _ = ModelArtifactDiagnostics.removePartials(partials, row: row, resolver: resolver)
            }
        )
    }

    /// Runs one transaction and returns the process exit status: 0 succeeded,
    /// 4 refused or failed before verification, 5 verification failed,
    /// 130 cancelled.
    static func run(
        key: String,
        resolver: CachedModelArtifactResolver,
        config: String?,
        sink: ModelsPrepareCatalogEventSink,
        cancellation: ModelsPrepareCatalogCancellation,
        dependencies: Dependencies = .live
    ) async -> Int32 {
        let row: ModelArtifactSignedRow
        do {
            row = try await dependencies.resolveRow(key)
        } catch {
            writeDiagnosticsStderr("models prepare-catalog refused: \(error)")
            sink.emit(modelKey: key, state: .failed, errorCode: .authorityUnavailable)
            return 4
        }
        let modelKey = row.catalogKey
        sink.emit(modelKey: modelKey, state: .queued)
        if cancellation.isRequested {
            sink.emit(modelKey: modelKey, state: .cancelRequested)
            sink.emit(modelKey: modelKey, state: .cancelled)
            return 130
        }

        let expected = row.artifactSizeBytes.map(Int64.init)
        func reportProgress() {
            guard !cancellation.isRequested else { return }
            var completed = dependencies.stagedBytes(row, resolver)
            if let expected { completed = min(completed, expected) }
            let progress = try? ModelPreparationTransactionEvent.Progress(
                stageLabelKey: stageLabel,
                bytesCompleted: max(0, completed),
                bytesExpected: expected,
                percentComplete: expected.flatMap { $0 > 0 ? min(100, Double(completed) / Double($0) * 100) : nil },
                heartbeat: true
            )
            sink.emit(modelKey: modelKey, state: .running, progress: progress)
        }
        reportProgress()

        let work = Task { await dependencies.prepare(row, resolver, config) }
        cancellation.onRequest {
            sink.emit(modelKey: modelKey, state: .cancelRequested)
            work.cancel()
        }
        let interval = dependencies.progressIntervalNanoseconds
        let progressLoop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                reportProgress()
            }
        }
        let outcome = await work.value
        progressLoop.cancel()
        _ = await progressLoop.value

        // A preparation that verified before the cancel could take effect is
        // reported as it is: the commit point had passed.
        if outcome.finalState == .readyVerified {
            sink.emit(modelKey: modelKey, state: .succeeded)
            writeDiagnosticsStderr("models prepare-catalog: \(outcome.finalLine)")
            return 0
        }
        if cancellation.isRequested {
            dependencies.removePartials(row, resolver)
            sink.emit(modelKey: modelKey, state: .cancelled)
            writeDiagnosticsStderr("models prepare-catalog cancelled: active model unchanged; interrupted download removed")
            return 130
        }
        let (code, exit) = failure(outcome)
        sink.emit(modelKey: modelKey, state: .failed, errorCode: code)
        writeDiagnosticsStderr("models prepare-catalog failed: \(code.rawValue): \(ModelArtifactDiagnostics.redact(outcome.finalLine, diagnosis: outcome.diagnosis))")
        return exit
    }

    static func failure(_ outcome: ModelPrepareOutcome) -> (ModelPreparationEventErrorCode, Int32) {
        if outcome.finalState == .hashMismatch {
            return (.verificationFailed, 5)
        }
        if outcome.error?.contains("insufficient_disk_space") == true {
            return (.insufficientDiskSpace, 4)
        }
        if outcome.downloadAttempted, [.mismatch, .unverifiable].contains(outcome.diagnosis.verdict) {
            return (.verificationFailed, 5)
        }
        return (.transferFailed, 4)
    }
}
