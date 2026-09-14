import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore

typealias ModelCatalogRecommendationInputs = (
    demand: AutotuneStaticSelection<DemandRank>,
    candidate: AutotuneStaticSelection<CandidateCatalog>,
    rateCard: AutotuneStaticSelection<RateCardProjection>,
    artifactFeed: AutotuneStaticSelection<QualifiedArtifactFeed?>
)

/// Exact authorization inputs retained across the one permitted artifact hash.
/// Equality covers bytes, authenticated signer, effective version, warnings and
/// fallback class for all four signed selections.
struct ModelCatalogSignedInputBinding: Equatable {
    struct Leg: Equatable {
        let bytes: Data
        let signerKeyID: String?
        let effectiveVersion: String
        let warnings: [String]
        let usedFallback: Bool
    }
    let candidate: Leg
    let artifact: Leg
    let rate: Leg
    let demand: Leg

    init(_ inputs: ModelCatalogRecommendationInputs) {
        func leg<T>(_ selection: AutotuneStaticSelection<T>, version: String) -> Leg {
            .init(bytes: selection.selectedBytes, signerKeyID: selection.signerKeyID,
                  effectiveVersion: version, warnings: selection.warnings.map(\.rawValue).sorted(),
                  usedFallback: selection.usedFallback)
        }
        candidate = leg(inputs.candidate, version: inputs.candidate.value.version)
        artifact = leg(inputs.artifactFeed, version: inputs.artifactFeed.value?.releaseID ?? "absent")
        rate = leg(inputs.rateCard, version: inputs.rateCard.value.version)
        demand = leg(inputs.demand, version: inputs.demand.value.version)
    }
}

struct ModelCatalogTransactionAuthority: @unchecked Sendable {
    let modelKey: String
    let row: CandidateCatalog.Row
    let candidateDigest: String
    let artifactDigest: String
    let signerKeyID: String
    let estimatedBytes: Int64?
    let source: String

    static func resolve(target: String, inputs: ModelCatalogRecommendationInputs) throws -> Self {
        let matches = inputs.candidate.value.rows.filter { $0.key == target || $0.value.modelID == target }
        guard matches.count == 1, let (key, row) = matches.first,
              row.runtimeStatus == "recommendable",
              let revision = row.modelRevision, let hash = row.modelSHA256,
              let feed = inputs.artifactFeed.value,
              inputs.candidate.signerKeyID == feed.signerKeyID,
              inputs.artifactFeed.warnings.isDisjoint(with: [.catalogArtifactFeedIntegrityFailure, .catalogArtifactFeedUpdateRequired, .catalogArtifactFeedStale]),
              inputs.candidate.warnings.isDisjoint(with: [
                .candidateCatalogIntegrityFailure, .candidateCatalogStale, .candidateCatalogUpdateRequired
              ]),
              let model = feed.feed.models[key],
              model.primary.sourceRef.repoID == row.modelID,
              model.primary.sourceRef.revision == revision,
              model.primary.hash == hash,
              model.primary.hashAlgorithm == "macprovider.snapshot-manifest.v1",
              model.primary.runtimeFormat == "mlx_safetensors",
              model.primary.allowedRuntimeSources.contains("mlx_cache"),
              model.primary.verificationStatus == "verified"
        else { throw ModelCatalogTransactionError.authorityUnavailable }
        return Self(modelKey: key, row: row,
                    candidateDigest: AutotuneStaticInputs.candidateCatalogSHA256(bytes: inputs.candidate.selectedBytes),
                    artifactDigest: feed.feedSHA256, signerKeyID: feed.signerKeyID,
                    estimatedBytes: model.primary.sizeBytes > 0 ? Int64(model.primary.sizeBytes) : nil,
                    source: inputs.artifactFeed.usedFallback ? "static_signed" : "live_signed")
    }

    func matches(_ other: Self) -> Bool {
        modelKey == other.modelKey && row.modelID == other.row.modelID &&
        row.modelRevision == other.row.modelRevision && row.modelSHA256 == other.row.modelSHA256 &&
        candidateDigest == other.candidateDigest && artifactDigest == other.artifactDigest &&
        signerKeyID == other.signerKeyID && source == other.source && estimatedBytes == other.estimatedBytes
    }
}

enum ModelCatalogTransactionError: Error {
    case authorityUnavailable, invalidTransaction, busy, interrupted, cancelled, timedOut
    case insufficientSpace, cleanupRequired, lifecycleUnavailable, resultUnavailable
}

struct ModelCatalogTransactionSelector: Codable, Equatable, Sendable {
    let transactionID: String
    let target: String
    let kind: String
    let operationGeneration: String
}

struct ModelCatalogTransactionReservation: Equatable, Sendable {
    let transactionID: String
    let operationGeneration: String
}

struct ModelCatalogTransactionEvent: Codable, Equatable, Sendable {
    struct Progress: Codable, Equatable, Sendable {
        let stageLabelKey: String
        let heartbeat: Bool
        enum CodingKeys: String, CodingKey { case stageLabelKey = "stage_label_key", heartbeat }
    }
    var schema = "model_catalog_transaction_event.v1"
    let transactionID: String
    let transactionKind: String
    let operationGeneration: String?
    let modelKey: String
    let eventSequence: UInt64
    let emittedAt: String
    let state: String
    let progress: Progress?
    let errorCode: String?
    let warningCode: String?
    enum CodingKeys: String, CodingKey {
        case schema, state, progress
        case transactionID = "transaction_id", transactionKind = "transaction_kind", modelKey = "model_key"
        case operationGeneration = "operation_generation"
        case eventSequence = "event_sequence", emittedAt = "emitted_at", errorCode = "error_code", warningCode = "warning_code"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(transactionID, forKey: .transactionID)
        try c.encode(transactionKind, forKey: .transactionKind); try c.encode(modelKey, forKey: .modelKey)
        try c.encode(operationGeneration, forKey: .operationGeneration)
        try c.encode(eventSequence, forKey: .eventSequence); try c.encode(emittedAt, forKey: .emittedAt)
        try c.encode(state, forKey: .state)
        if let progress { try c.encode(progress, forKey: .progress) } else { try c.encodeNil(forKey: .progress) }
        if let errorCode { try c.encode(errorCode, forKey: .errorCode) } else { try c.encodeNil(forKey: .errorCode) }
        if let warningCode { try c.encode(warningCode, forKey: .warningCode) } else { try c.encodeNil(forKey: .warningCode) }
    }
}

struct ModelCatalogTransactionRecord: Codable, Sendable {
    var schema: String? = "model_catalog_transaction_journal.v1"
    let transactionID: String
    var operationGeneration: String? = UUID().uuidString.lowercased()
    var selector: ModelCatalogTransactionSelector? {
        guard let operationGeneration else { return nil }
        return .init(transactionID: transactionID, target: target, kind: kind, operationGeneration: operationGeneration)
    }
    let target: String
    let modelKey: String
    let kind: String
    let revision: String
    let sha256: String
    let candidateDigest: String
    let artifactDigest: String
    let signerKeyID: String
    let createdAt: Date
    var startedAt: Date?
    var artifactSealSHA256: String?
    var resultSHA256: String?
    var committed: Bool = false
    var cancelRequested: Bool = false
    var cleanupRequired: Bool = false
    var events: [ModelCatalogTransactionEvent] = []
    var attemptStartSequence: UInt64?
    var currentEvents: [ModelCatalogTransactionEvent] { events.filter { $0.eventSequence >= (attemptStartSequence ?? 1) } }
    var terminal: Bool { events.last.map { ["succeeded", "failed", "cancelled", "timed_out"].contains($0.state) } ?? false }
}

/// An OS-held owner lock proves liveness; PID reuse never revives an interrupted job.
final class ModelCatalogFileLock {
    let descriptor: Int32
    let resourceName: String
    init(_ url: URL, nonblocking: Bool = false, pinnedDirectory: ModelTransactionDirectory? = nil,
         afterFailureClose: (Int32) -> Void = { _ in }) throws {
        resourceName = url.lastPathComponent
        let directory = try pinnedDirectory ?? ModelTransactionDirectory.current(url.deletingLastPathComponent())
        let opened = try directory.openFile(url.lastPathComponent, flags: O_RDWR | O_CREAT)
        do {
            var st = stat()
            guard fstat(opened, &st) == 0, st.st_uid == getuid(), st.st_nlink == 1,
                  (st.st_mode & S_IFMT) == S_IFREG, st.st_mode & 0o077 == 0 else {
                throw ModelCatalogTransactionError.invalidTransaction
            }
            guard flock(opened, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
                throw ModelCatalogTransactionError.busy
            }
            // Assign ownership only after acquisition. A fully initialized class
            // runs deinit on throw; assigning earlier would close a failed FD twice.
            descriptor = opened
        } catch {
            close(opened)
            afterFailureClose(opened)
            throw error
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

struct ModelCatalogTransactionStore: Sendable {
    let root: URL
    var retentionBoundary: @Sendable (String) throws -> Void = { _ in }
    var boundContext: BoundModelTransactionContext? = nil
    var projectionIdentity: ModelTransactionProjectionStoreIdentity? = nil
    static func forConfig(_ config: AppConfig?) -> Self {
        Self(root: CachedModelArtifactResolver.forConfig(config).durableRoot.appendingPathComponent(".transactions"))
    }
    static func forContext(_ context: BoundModelTransactionContext) -> Self { Self(root: context.transactionRoot, boundContext: context) }
    func secure() throws {
        if let boundContext { try boundContext.validateStoreRoot() }
        if let projectionIdentity { try projectionIdentity.validateCurrent(durableRoot: root.deletingLastPathComponent(), transactionRoot: root) }
        _ = try ModelTransactionDirectory(root, create: boundContext == nil && projectionIdentity == nil)
    }
    func validatePinnedDirectory(_ directory: ModelTransactionDirectory) throws {
        let info = try directory.info()
        if let boundContext { try boundContext.validateStoreRoot(journal: info) }
        if let projectionIdentity {
            try projectionIdentity.validateCurrent(durableRoot: root.deletingLastPathComponent(), transactionRoot: root)
            guard info.st_dev >= 0, UInt64(info.st_dev) == projectionIdentity.journalDevice,
                  UInt64(info.st_ino) == projectionIdentity.journalInode else { throw ModelCatalogRetentionError.changed }
        }
    }
    func validateID(_ id: String) throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
    }
    func locked<T>(nonblocking: Bool = false, _ body: () throws -> T) throws -> T {
        try secure()
        return try ModelTransactionDirectory.scoped(root) {
            try validatePinnedDirectory(ModelTransactionDirectory.current(root))
            let lock = try ModelCatalogFileLock(root.appendingPathComponent(".journal-lock"), nonblocking: nonblocking)
            defer { withExtendedLifetime(lock) {} }
            return try body()
        }
    }
    func ownerLock(_ id: String) throws -> ModelCatalogFileLock {
        try validateID(id); try secure()
        let directory = try ModelTransactionDirectory.current(root)
        try validatePinnedDirectory(directory)
        return try ModelCatalogFileLock(root.appendingPathComponent(".owner-" + id), nonblocking: true, pinnedDirectory: directory)
    }
    func stagingURL(_ id: String) throws -> URL { try validateID(id); return root.appendingPathComponent("staging-" + id) }
    private func recordURL(_ id: String) throws -> URL { try validateID(id); return root.appendingPathComponent(id + ".json") }
    func load(_ id: String, target: String, cleanup: Bool = false) throws -> ModelCatalogTransactionRecord {
        try validateID(id)
        let data = try readPrivate(cleanup ? root.appendingPathComponent(id + ".cleanup") : try recordURL(id))
        let record = try JSONDecoder().decode(ModelCatalogTransactionRecord.self, from: data)
        guard record.transactionID == id, record.target == target, record.events.count <= 2_048 else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        try validate(record)
        return record
    }
    func load(_ selector: ModelCatalogTransactionSelector) throws -> ModelCatalogTransactionRecord {
        try validateID(selector.operationGeneration)
        guard ["prepare_model", "evaluate_model", "cleanup_staging"].contains(selector.kind) else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        var record = try load(selector.transactionID, target: selector.target, cleanup: selector.kind == "cleanup_staging")
        if record.selector != selector, selector.kind == "cleanup_staging" {
            let bytes = try readPrivate(root.appendingPathComponent(selector.transactionID + ".cleanup-" + selector.operationGeneration))
            record = try JSONDecoder().decode(ModelCatalogTransactionRecord.self, from: bytes)
            try validate(record)
            guard record.terminal else { throw ModelCatalogTransactionError.invalidTransaction }
        }
        guard record.selector == selector else { throw ModelCatalogTransactionError.invalidTransaction }
        return record
    }
    func load(_ selector: ModelCatalogTransactionSelector, budget: ModelTransactionWorkBudget) throws
        -> ModelCatalogTransactionRecord {
        try validateID(selector.operationGeneration)
        guard ["prepare_model", "evaluate_model", "cleanup_staging"].contains(selector.kind) else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        let primaryName = selector.transactionID + (selector.kind == "cleanup_staging" ? ".cleanup" : ".json")
        let primary = try evidence(primaryName, budget: budget)
        guard let bytes = primary.bytes else { throw ModelCatalogTransactionError.invalidTransaction }
        var record = try decodeRetentionRecord(bytes, id: selector.transactionID)
        if record.selector != selector, selector.kind == "cleanup_staging" {
            let history = try evidence(selector.transactionID + ".cleanup-" + selector.operationGeneration, budget: budget)
            guard let historyBytes = history.bytes else { throw ModelCatalogTransactionError.invalidTransaction }
            record = try decodeRetentionRecord(historyBytes, id: selector.transactionID)
            guard record.terminal else { throw ModelCatalogTransactionError.invalidTransaction }
        }
        guard record.target == selector.target, record.selector == selector else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        try budget.check()
        return record
    }
    func validate(_ record: ModelCatalogTransactionRecord) throws {
        try validateID(record.transactionID)
        if let generation = record.operationGeneration {
            try validateID(generation)
            guard record.schema == "model_catalog_transaction_journal.v1" else { throw ModelCatalogTransactionError.invalidTransaction }
        } else if let schema = record.schema, schema != "model_catalog_transaction_journal.v1" {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        let kinds = ["prepare_model", "evaluate_model", "cleanup_staging"]
        let states = ["queued", "running", "cancel_requested", "cancelled", "succeeded", "failed", "timed_out"]
        guard kinds.contains(record.kind), record.target == record.target.trimmingCharacters(in: .whitespacesAndNewlines),
              BYOMDiscoveryPrivacy.isSafeModelReference(record.target), BYOMDiscoveryPrivacy.isSafeModelReference(record.modelKey),
              record.modelKey.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
              !record.signerKeyID.isEmpty, !record.events.isEmpty, record.events.count <= 2_048,
              [record.sha256, record.candidateDigest, record.artifactDigest].allSatisfy({
                  $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
              }), record.revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        for (index, event) in record.events.enumerated() {
            guard event.schema == "model_catalog_transaction_event.v1", event.transactionID == record.transactionID,
                  event.transactionKind == record.kind, event.modelKey == record.modelKey,
                  event.operationGeneration == record.operationGeneration,
                  event.eventSequence == UInt64(index + 1), states.contains(event.state) else {
                throw ModelCatalogTransactionError.invalidTransaction
            }
        }
    }
    func cleanupRecords() throws -> [ModelCatalogTransactionRecord] {
        try cleanupRecordsFromIndex()
    }
    func readPrivate(_ url: URL) throws -> Data {
        guard ModelTransactionDirectory.normalized(url.deletingLastPathComponent()) == ModelTransactionDirectory.normalized(root) else {
            throw ModelCatalogRetentionError.unsafe
        }
        let directory = try ModelTransactionDirectory.current(root)
        try validatePinnedDirectory(directory)
        return try directory.read(url.lastPathComponent)
    }
    func writePrivate(_ data: Data, to destination: URL) throws {
        guard ModelTransactionDirectory.normalized(destination.deletingLastPathComponent()) == ModelTransactionDirectory.normalized(root) else {
            throw ModelCatalogRetentionError.unsafe
        }
        let directory = try ModelTransactionDirectory.current(root)
        try validatePinnedDirectory(directory)
        try directory.write(data, name: destination.lastPathComponent)
    }
    func append(_ record: inout ModelCatalogTransactionRecord, state: String, stage: String? = nil,
                error: String? = nil, warning: String? = nil) {
        record.events.append(ModelCatalogTransactionEvent(
            transactionID: record.transactionID, transactionKind: record.kind, operationGeneration: record.operationGeneration, modelKey: record.modelKey,
            eventSequence: UInt64(record.events.count + 1), emittedAt: ModelSwitchingWireCodec.timestamp(), state: state,
            progress: stage.map { .init(stageLabelKey: $0, heartbeat: true) }, errorCode: error, warningCode: warning))
    }
    /// The only successful evaluation delta is cleanup truth plus one frozen terminal event.
    func evaluationSuccessTerminal(preterminal: ModelCatalogTransactionRecord, cleanupRequired: Bool,
                                   event: ModelCatalogTransactionEvent? = nil) throws -> ModelCatalogTransactionRecord {
        try validate(preterminal)
        guard preterminal.kind == "evaluate_model", !preterminal.terminal, preterminal.committed,
              preterminal.startedAt != nil, preterminal.operationGeneration != nil,
              preterminal.resultSHA256?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              preterminal.artifactSealSHA256 == nil else { throw ModelCatalogTransactionError.invalidTransaction }
        var terminal = preterminal
        terminal.cleanupRequired = cleanupRequired
        if let event {
            guard event.state == "succeeded", event.progress == nil, event.errorCode == nil,
                  event.warningCode == (cleanupRequired ? "staging_cleanup_required" : nil),
                  !event.emittedAt.isEmpty else { throw ModelCatalogTransactionError.invalidTransaction }
            terminal.events.append(event)
        } else {
            append(&terminal, state: "succeeded", warning: cleanupRequired ? "staging_cleanup_required" : nil)
        }
        try validate(terminal)
        return terminal
    }

    func reserve(authority: ModelCatalogTransactionAuthority, kind: String) throws -> String {
        try reserveOperation(authority: authority, kind: kind).transactionID
    }
    func validatedCommittedResult(_ record: ModelCatalogTransactionRecord) throws -> Data {
        try validatedCommittedResult(record, data: readPrivate(root.appendingPathComponent(record.transactionID + ".result")))
    }
    func validatedCommittedResult(_ record: ModelCatalogTransactionRecord, data: Data) throws -> Data {
        guard record.kind == "evaluate_model", record.committed, let digest = record.resultSHA256 else {
            throw ModelCatalogTransactionError.resultUnavailable
        }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw ModelCatalogTransactionError.resultUnavailable
        }
        let parsed = try ModelsAdoptRecommendationCommand.parseRecommendation(data: data, enforceFreshness: false)
        guard parsed.targetModelID == record.modelKey, parsed.core.modelCatalogModelID == record.target,
              parsed.core.modelCatalogRevision == record.revision, parsed.core.modelArtifactSHA256 == record.sha256,
              parsed.core.modelCatalogSHA256 == record.sha256, parsed.core.modelCatalogHash == record.candidateDigest else {
            throw ModelCatalogTransactionError.resultUnavailable
        }
        return data
    }
    func latestCleanup(target: String) throws -> String? {
        try cleanupRecordsFromIndex().first(where: { $0.target == target })?.transactionID
    }
    func update(_ selector: ModelCatalogTransactionSelector,
                check: () throws -> Void = {},
                transform: (inout ModelCatalogTransactionRecord) throws -> Void) throws -> ModelCatalogTransactionRecord {
        try retryContention {
            let receipt = try captureActiveReceipt(selector: selector)
            var record = receipt.record
            try transform(&record)
            try check()
            try commit(record: record, receipt: receipt, check: check)
            return record
        }
    }
    func retryContention<T>(_ body: () throws -> T) throws -> T {
        let budget = ModelTransactionWorkBudget()
        while true {
            try budget.check(); try Task.checkCancellation()
            do { return try body() }
            catch ModelCatalogTransactionError.busy { }
            catch ModelCatalogRetentionError.changed { }
            usleep(10_000)
        }
    }
    /// Retry observations and CAS contention only; a started durability bundle is never replayed here.
    func retryBeforeMutation<T>(_ body: (_ beginMutation: () throws -> Void) throws -> T) throws -> T {
        let budget = ModelTransactionWorkBudget()
        while true {
            try budget.check(); try Task.checkCancellation()
            var mutationStarted = false
            do {
                return try body {
                    try budget.check(); try Task.checkCancellation()
                    mutationStarted = true
                }
            } catch ModelCatalogTransactionError.busy where !mutationStarted { }
            catch ModelCatalogRetentionError.changed where !mutationStarted { }
            usleep(10_000)
        }
    }
    func check(_ selector: ModelCatalogTransactionSelector) throws {
        try retryContention {
            try Task.checkCancellation()
            let receipt = try captureActiveReceipt(selector: selector)
            guard !receipt.record.cancelRequested else { throw ModelCatalogTransactionError.cancelled }
            guard Date().timeIntervalSince(receipt.record.startedAt ?? receipt.record.createdAt) < 1800 else {
                throw ModelCatalogTransactionError.timedOut
            }
            try locked(nonblocking: true) { try receipt.validateLocked(store: self) }
        }
    }
    func check(_ id: String, target: String, cleanup: Bool = false) throws {
        guard let selector = try load(id, target: target, cleanup: cleanup).selector else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        try check(selector)
    }
    func cleanup(_ id: String, checkCancellation: () throws -> Void = {}) throws {
        try validateID(id); try secure()
        let directory = try ModelTransactionDirectory.current(root)
        try validatePinnedDirectory(directory)
        let stagingName = "staging-" + id
        guard let initial = try directory.metadata(stagingName) else { return }
        guard initial.st_mode & S_IFMT == S_IFDIR, initial.st_uid == getuid() else { throw ModelCatalogTransactionError.cleanupRequired }
        let staging = openat(directory.fd, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard staging >= 0 else { throw ModelCatalogTransactionError.cleanupRequired }
        defer { close(staging) }
        var opened = stat()
        guard fstat(staging, &opened) == 0, opened.st_dev == initial.st_dev, opened.st_ino == initial.st_ino else {
            throw ModelCatalogTransactionError.cleanupRequired
        }
        var count = 0
        func active() throws {
            try checkCancellation(); try directory.validateCurrent(); try validatePinnedDirectory(directory)
        }
        func removeChildren(_ fd: Int32, depth: Int) throws {
            try active()
            guard depth <= 64 else { throw ModelCatalogTransactionError.cleanupRequired }
            let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }; throw ModelCatalogTransactionError.cleanupRequired
            }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                try checkCancellation(); errno = 0
                guard let item = readdir(stream) else {
                    guard errno == 0 else { throw ModelCatalogTransactionError.cleanupRequired }; break
                }
                let name = withUnsafeBytes(of: item.pointee.d_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                if name == "." || name == ".." { continue }
                count += 1; guard count <= 100_000 else { throw ModelCatalogTransactionError.cleanupRequired }
                names.append(name)
            }
            for name in names {
                try active()
                var before = stat()
                guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0, before.st_uid == getuid() else {
                    throw ModelCatalogTransactionError.cleanupRequired
                }
                let isDirectory = before.st_mode & S_IFMT == S_IFDIR
                if isDirectory {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw ModelCatalogTransactionError.cleanupRequired }
                    defer { close(child) }
                    var info = stat()
                    guard fstat(child, &info) == 0, info.st_dev == before.st_dev, info.st_ino == before.st_ino else {
                        throw ModelCatalogTransactionError.cleanupRequired
                    }
                    try removeChildren(child, depth: depth + 1)
                }
                try active()
                var current = stat()
                guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_dev == before.st_dev, current.st_ino == before.st_ino,
                      unlinkat(fd, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw ModelCatalogTransactionError.cleanupRequired }
            }
        }
        try removeChildren(staging, depth: 0)
        try active()
        guard let final = try directory.metadata(stagingName), final.st_dev == initial.st_dev, final.st_ino == initial.st_ino,
              unlinkat(directory.fd, stagingName, AT_REMOVEDIR) == 0, fsync(directory.fd) == 0 else {
            throw ModelCatalogTransactionError.cleanupRequired
        }
    }
    func reconcile(_ id: String, target: String, cancel: Bool = false, original: Bool = false) throws -> ModelCatalogTransactionRecord {
        let selector = try { () -> ModelCatalogTransactionSelector in
            let cleanup = !original && FileManager.default.fileExists(atPath: root.appendingPathComponent(id + ".cleanup").path)
            guard let selector = try load(id, target: target, cleanup: cleanup).selector else { throw ModelCatalogTransactionError.invalidTransaction }
            return selector
        }()
        return try reconcile(selector, cancel: cancel)
    }
    func validatedPreparationSeal(_ record: ModelCatalogTransactionRecord) throws -> ModelCatalogArtifactSeal {
        try validatedPreparationSeal(record, data: readPrivate(root.appendingPathComponent(record.transactionID + ".seal")))
    }
    func validatedPreparationSeal(_ record: ModelCatalogTransactionRecord, data: Data) throws -> ModelCatalogArtifactSeal {
        guard record.kind == "prepare_model", record.committed, let digest = record.artifactSealSHA256 else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        let seal = try JSONDecoder().decode(ModelCatalogArtifactSeal.self, from: data)
        try seal.validate(record: record)
        return seal
    }
    func reconcile(_ selector: ModelCatalogTransactionSelector, cancel: Bool = false,
                   deadline: Date = Date().addingTimeInterval(8), metadataCheck: () throws -> Void = {},
                   readBudget: ModelCatalogReadBudget? = nil,
                   workBudget incomingBudget: ModelTransactionWorkBudget? = nil,
                   requireRecommendationPublication: Bool = false) throws -> ModelCatalogTransactionRecord {
        let workBudget: ModelTransactionWorkBudget
        if let incomingBudget { workBudget = incomingBudget }
        else if let readBudget { workBudget = try readBudget.transactionBudget() }
        else { workBudget = .init() }
        // Archived terminal streams remain direct read-only evidence. Active
        // mutations capture and parse bodies before acquiring the journal lock.
        try workBudget.check()
        let historical = try load(selector, budget: workBudget)
        try workBudget.check()
        if historical.terminal {
            let original: ModelCatalogTransactionRecord
            if selector.kind == "cleanup_staging" {
                let primary = try evidence(selector.transactionID + ".json", budget: workBudget)
                guard let bytes = primary.bytes else { throw ModelCatalogRetentionError.unsafe }
                original = try decodeRetentionRecord(bytes, id: selector.transactionID)
                guard original.target == selector.target else { throw ModelCatalogTransactionError.invalidTransaction }
            } else { original = historical }
            try validateOriginalBindingEvidence(original, budget: workBudget)
            return historical
        }
        var owner: ModelCatalogFileLock?
        if historical.startedAt != nil || cancel {
            do { owner = try ownerLock(selector.transactionID) }
            catch ModelCatalogTransactionError.busy { /* The live owner consumes cancellation. */ }
        }
        defer { withExtendedLifetime(owner) {} }
        if owner != nil, selector.kind == "evaluate_model",
           let recovered = try recoverBoundEvaluationSuccess(selector: selector, budget: workBudget,
                                                              heldOwner: owner, check: {
               try workBudget.check()
                try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
           }) {
            do { try indexCompletedEvaluation(recovered, budget: workBudget) }
            catch {
                if requireRecommendationPublication { throw error }
                FileHandle.standardError.write(Data("recommendation index update pending\n".utf8))
            }
            return recovered
        }
        let receipt = try captureActiveReceipt(selector: selector, budget: workBudget, heldOwner: owner)
        var record = receipt.record
        if record.terminal {
            let original: ModelCatalogTransactionRecord
            if selector.kind == "cleanup_staging" {
                let primary = try evidence(selector.transactionID + ".json", budget: workBudget)
                guard let bytes = primary.bytes else { throw ModelCatalogRetentionError.unsafe }
                original = try decodeRetentionRecord(bytes, id: selector.transactionID)
            } else { original = record }
            try validateOriginalBindingEvidence(original, budget: workBudget)
            return record
        }
        if cancel, record.startedAt == nil, owner != nil {
            record.cancelRequested = true
            append(&record, state: "cancel_requested", stage: "cancelling")
            append(&record, state: "cancelled")
            try commit(record: record, receipt: receipt, check: { try workBudget.check() })
            return record
        }
        guard let owner else {
            if cancel && !record.cancelRequested && record.startedAt != nil {
                record.cancelRequested = true
                append(&record, state: "cancel_requested", stage: "cancelling")
                try commit(record: record, receipt: receipt, check: { try workBudget.check() })
            } else { try locked(nonblocking: true) { try receipt.validateLocked(store: self) } }
            return record
        }
        defer { withExtendedLifetime(owner) {} }
        var observation: ModelCatalogArtifactSnapshot.Observation?
        var commitmentEvidence: ModelTransactionFileEvidence?
        var didCommit = false
        if record.committed {
            if record.kind == "prepare_model" {
                do {
                    let evidence = try evidence(record.transactionID + ".seal", budget: workBudget)
                    guard let data = evidence.bytes else { throw ModelCatalogTransactionError.invalidTransaction }
                    let seal = try validatedPreparationSeal(record, data: data)
                    commitmentEvidence = evidence
                    let durable = DurableModelArtifactStore(root: root.deletingLastPathComponent())
                    let destination = try durable.artifactURL(modelID: record.target, revision: record.revision, sha256: record.sha256)
                    observation = try seal.snapshot.observe(directory: destination, deadline: deadline, check: metadataCheck)
                    didCommit = true
                } catch { didCommit = false }
            } else if record.kind == "evaluate_model" {
                do {
                    let evidence = try evidence(record.transactionID + ".result", budget: workBudget)
                    guard let data = evidence.bytes else { throw ModelCatalogTransactionError.resultUnavailable }
                    _ = try validatedCommittedResult(record, data: data)
                    commitmentEvidence = evidence; didCommit = true
                } catch { didCommit = false }
            }
        }
        try workBudget.check()
                try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
        let stagingExists = try ModelTransactionDirectory(root).metadata("staging-" + selector.transactionID) != nil
        try metadataCheck()
        try workBudget.check()
                try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
        let cleanupRequired = record.cleanupRequired || stagingExists
        if didCommit, record.kind == "evaluate_model", let resultEvidence = commitmentEvidence {
            let terminal = try evaluationSuccessTerminal(preterminal: record, cleanupRequired: cleanupRequired)
            record = try commitEvaluationSuccess(preterminal: receipt, terminal: terminal, result: resultEvidence,
                                                  budget: workBudget, check: {
                try workBudget.check()
                try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
            })
        } else {
            record.cleanupRequired = cleanupRequired
            append(&record, state: didCommit ? "succeeded" : "failed", error: didCommit ? nil : "owner_interrupted",
                   warning: record.cleanupRequired ? "staging_cleanup_required" : nil)
            try commit(record: record, receipt: receipt, check: {
                try workBudget.check()
                try HuggingFaceSnapshotDownloader.assertDeadlineActive(deadline)
                if didCommit { try commitmentEvidence?.validate(); try observation?.validatePlacement() }
            })
        }
        if didCommit && record.kind == "evaluate_model" {
            do { try indexCompletedEvaluation(record, budget: workBudget) }
            catch {
                if requireRecommendationPublication { throw error }
                FileHandle.standardError.write(Data("recommendation index update pending\n".utf8))
            }
        }
        return record
    }
    func result(_ id: String, target: String) throws -> Data {
        let selector = try load(id, target: target).selector
        guard let selector else { throw ModelCatalogTransactionError.resultUnavailable }
        return try result(selector)
    }
    func result(_ selector: ModelCatalogTransactionSelector, readBudget: ModelCatalogReadBudget? = nil) throws -> Data {
        guard selector.kind == "evaluate_model" else { throw ModelCatalogTransactionError.resultUnavailable }
        try readBudget?.check()
        let record = try reconcile(selector, readBudget: readBudget)
        try readBudget?.check()
        guard record.events.last?.state == "succeeded" else { throw ModelCatalogTransactionError.resultUnavailable }
        return try validatedCommittedResult(record)
    }
}

/// The stream writer tracks persisted sequence numbers, including cancellation
/// events written by a second CLI invocation.
final class ModelCatalogTransactionStream: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    func emit(_ events: [ModelCatalogTransactionEvent]) throws {
        lock.lock(); defer { lock.unlock() }
        for event in events where event.eventSequence > sequence {
            try ModelSwitchingWireCodec.printJSON(event)
            sequence = event.eventSequence
        }
    }
}

private final class ModelTransactionWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var cancelled = false
    func install(_ task: Task<Void, Error>) {
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        if cancel { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
}

struct ModelCatalogTransactionRunner: @unchecked Sendable {
    let config: AppConfig
    let configPath: URL
    let store: ModelCatalogTransactionStore
    var inputs: () async -> ModelCatalogRecommendationInputs = { await AutotuneStaticInputs().loadRecommendationInputs() }
    var downloader = HuggingFaceSnapshotDownloader()
    var boundArtifactResolver: CachedModelArtifactResolver?
    private var artifactResolver: CachedModelArtifactResolver { boundArtifactResolver ?? CachedModelArtifactResolver.forConfig(config) }
    var adoptionLockRoot: URL = RecommendationAdoptionJournalStore.defaultRoot
    var timeoutSeconds: TimeInterval = 1800
    var port = 19191
    var availableBytes: (URL) throws -> Int64 = {
        (try FileManager.default.attributesOfFileSystem(forPath: $0.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    var boundary: (String) throws -> Void = { _ in }
    var cleanupOwned: ((ModelCatalogTransactionStore, String) throws -> Void)?
    var detectConflict: () throws -> ProviderConflict = { try ProviderConflictDetector().detect() }
    var drainer = ProviderDrainer()
    var managedContext = (
        config: URL(fileURLWithPath: ConfigLoader.expandTilde(AppConfig.defaultConfigPath)).standardizedFileURL.resolvingSymlinksInPath(),
        secret: AutotuneHMACSecretStore.defaultPath
    )
    var hardware: (HMACIdentity) -> AutotuneRecommendHardware = {
        AutotuneRecommendHardware(fingerprint: MachineFingerprinter().sample(), hmacIdentity: $0)
    }
    var benchmarker: (CachedModelArtifactResolver, URL, @escaping () throws -> Void) throws -> AutotuneRecommendationBenchmarker = { resolver, logs, check in
        AutotuneRecommendationBenchmarker(telemetryDirectory: logs, artifactResolver: resolver,
            runnerFactory: { try CandidateProviderRunner(logDirectory: logs, publicationCheck: check) })
    }

    func run(id: String, target: String, kind: String, operationGeneration: String? = nil) async throws {
        let seed = try store.retryContention {
            let original = try store.load(id, target: target)
            guard let generation = operationGeneration ?? original.operationGeneration else { throw ModelCatalogTransactionError.invalidTransaction }
            let requested = ModelCatalogTransactionSelector(transactionID: id, target: target, kind: kind, operationGeneration: generation)
            return try store.captureActiveReceipt(selector: requested).record
        }
        guard let selector = seed.selector else { throw ModelCatalogTransactionError.invalidTransaction }
        guard seed.kind == kind, !seed.terminal, seed.startedAt == nil else { throw ModelCatalogTransactionError.invalidTransaction }
        let owner = try store.ownerLock(id)
        defer { withExtendedLifetime(owner) {} }
        let cancellation = ModelTransactionWorkCancellation()
        let lifetime = ModelTransactionOwnerLifetimeGuard(onFence: { cancellation.cancel() })
        defer { withExtendedLifetime(lifetime) {} }
        let adoption = try RecommendationAdoptionLock.acquire(configPath: configPath, root: adoptionLockRoot)
        defer { withExtendedLifetime(adoption) {} }
        let stream = ModelCatalogTransactionStream()
        let started = try store.update(selector, check: lifetime.checkPublicationAllowed) { record in
            guard !record.terminal, record.startedAt == nil, !record.cancelRequested,
                  Date().timeIntervalSince(record.createdAt) < 1800 else { throw ModelCatalogTransactionError.invalidTransaction }
            record.startedAt = Date()
            store.append(&record, state: "running", stage: kind == "prepare_model" ? "preparing" : "evaluating")
        }
        try lifetime.acknowledgeDurableHeartbeat()
        try stream.emit(started.events)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let work = Task {
            // Authority retrieval belongs to the cancellable owner, not the caller's preamble.
            try boundary("started")
            let selected = await inputs()
            try store.check(id, target: target)
            let authority = try ModelCatalogTransactionAuthority.resolve(target: target, inputs: selected)
            guard seed.candidateDigest == authority.candidateDigest, seed.artifactDigest == authority.artifactDigest,
                  seed.signerKeyID == authority.signerKeyID, seed.target == authority.row.modelID else {
                throw ModelCatalogTransactionError.authorityUnavailable
            }
            _ = try SupportedModels.validate(model: authority.modelKey, supportedModels: config.supportedModels)
            if kind == "prepare_model" {
                try await prepare(id: id, authority: authority, deadline: deadline, lifetime: lifetime)
            } else {
                let result = try await recommend(id: id, authority: authority, selected: selected, deadline: deadline, lifetime: lifetime)
                let fresh = await inputs()
                try Self.validateRecommendationInputs(initial: selected, fresh: fresh)
                let freshAuthority = try ModelCatalogTransactionAuthority.resolve(target: target, inputs: fresh)
                guard authority.matches(freshAuthority) else { throw ModelCatalogTransactionError.authorityUnavailable }
                try store.check(id, target: target)
                try boundary("before_result_capture")
                try store.retryBeforeMutation { beginMutation in
                    let receipt = try store.captureActiveReceipt(selector: selector)
                    var record = receipt.record
                    guard !record.cancelRequested, Date() < deadline else { throw ModelCatalogTransactionError.cancelled }
                    record.resultSHA256 = SHA256.hash(data: result).map { String(format: "%02x", $0) }.joined()
                    record.committed = true
                    try receipt.validateProspective(record: record)
                    let bytes = try JSONEncoder().encode(record)
                    try store.locked(nonblocking: true) {
                        try receipt.validateLocked(store: store)
                        try lifetime.checkPublicationAllowed()
                        try beginMutation()
                        try store.writePrivate(result, to: store.root.appendingPathComponent(id + ".result"))
                        try boundary("result_written")
                        try lifetime.checkPublicationAllowed()
                        try store.writePrivate(bytes, to: store.root.appendingPathComponent(id + ".json"))
                        try boundary("result_committed")
                    }
                }
            }
        }
        cancellation.install(work)
        let heartbeat = Task {
            var lastHeartbeat = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                do {
                    let receipt = try store.captureActiveReceipt(selector: selector)
                    var record = receipt.record
                    if DispatchTime.now().uptimeNanoseconds - lastHeartbeat >= 5_000_000_000 && !record.terminal {
                        store.append(&record, state: record.cancelRequested ? "cancel_requested" : "running",
                                     stage: record.cancelRequested ? "cancelling" : (kind == "prepare_model" ? "preparing" : "evaluating"))
                        try lifetime.checkPublicationAllowed()
                        try store.commit(record: record, receipt: receipt, check: lifetime.checkPublicationAllowed)
                        try lifetime.acknowledgeDurableHeartbeat()
                        lastHeartbeat = DispatchTime.now().uptimeNanoseconds
                    }
                    try stream.emit(record.events)
                    if record.cancelRequested || Date() >= deadline { work.cancel() }
                } catch ModelCatalogTransactionError.busy { continue }
                catch ModelCatalogRetentionError.changed { continue }
                catch { work.cancel() }
            }
        }
        defer { heartbeat.cancel() }
        var failure: Error?
        do { try await work.value } catch { failure = error }
        var cleanupFailed = false
        do { if let cleanupOwned { try cleanupOwned(store, id) } else { try store.cleanup(id, checkCancellation: lifetime.checkPublicationAllowed) } } catch { cleanupFailed = true }
        try boundary("before_terminal")
        var preparationObservation: ModelCatalogArtifactSnapshot.Observation?
        var commitmentEvidence: ModelTransactionFileEvidence?
        let current = try store.load(selector)
        if current.committed {
            do {
                let evidence = try store.evidence(id + (kind == "prepare_model" ? ".seal" : ".result"), budget: .init())
                guard let bytes = evidence.bytes else { throw ModelCatalogTransactionError.invalidTransaction }
                if kind == "prepare_model" {
                    let seal = try store.validatedPreparationSeal(current, data: bytes)
                    let destination = try artifactResolver.durableStore.artifactURL(modelID: current.target, revision: current.revision, sha256: current.sha256)
                    preparationObservation = try seal.snapshot.observe(directory: destination, deadline: Date().addingTimeInterval(8)) {
                        try boundary("seal_metadata")
                    }
                } else { _ = try store.validatedCommittedResult(current, data: bytes) }
                commitmentEvidence = evidence
            } catch { commitmentEvidence = nil; preparationObservation = nil }
        }
        let result: ModelCatalogTransactionRecord
        if kind == "evaluate_model", current.committed, let resultEvidence = commitmentEvidence {
            result = try store.retryContention {
                try lifetime.checkPublicationAllowed()
                let receipt = try store.captureActiveReceipt(selector: selector)
                let terminal = try store.evaluationSuccessTerminal(preterminal: receipt.record, cleanupRequired: cleanupFailed)
                return try store.commitEvaluationSuccess(preterminal: receipt, terminal: terminal, result: resultEvidence,
                                                         check: lifetime.checkPublicationAllowed)
            }
        } else {
            result = try store.update(selector, check: {
                try lifetime.checkPublicationAllowed()
                try commitmentEvidence?.validate()
                try preparationObservation?.validatePlacement()
            }) { record in
                record.cleanupRequired = cleanupFailed
                let committed = record.committed && commitmentEvidence != nil && (kind != "prepare_model" || preparationObservation != nil)
                let state = committed ? "succeeded" : (record.cancelRequested ? "cancelled" : (Date() >= deadline ? "timed_out" : "failed"))
                store.append(&record, state: state, error: committed || state == "cancelled" ? nil : "transaction_failed",
                             warning: record.cleanupRequired ? "staging_cleanup_required" : nil)
            }
        }
        try lifetime.acknowledgeDurableHeartbeat()
        if result.events.last?.state == "succeeded" && kind == "evaluate_model" {
            do { try store.indexCompletedEvaluation(result, check: lifetime.checkPublicationAllowed) }
            catch {
                try lifetime.checkPublicationAllowed()
                FileHandle.standardError.write(Data("recommendation index update pending\n".utf8))
            }
        }
        try stream.emit(result.events)
        heartbeat.cancel(); _ = await heartbeat.value
        if result.events.last?.state != "succeeded" { throw failure ?? ModelCatalogTransactionError.interrupted }
    }

    static func validateRecommendationInputs(initial: ModelCatalogRecommendationInputs, fresh: ModelCatalogRecommendationInputs) throws {
        let warnings = fresh.candidate.warnings.union(fresh.demand.warnings).union(fresh.rateCard.warnings)
        guard !AutotuneRecommendEngine.paidTrustBlocks(warnings),
              warnings.isDisjoint(with: [.candidateCatalogStale, .demandRankStale, .rateCardStale]),
              initial.candidate.selectedBytes == fresh.candidate.selectedBytes,
              initial.demand.selectedBytes == fresh.demand.selectedBytes,
              initial.rateCard.selectedBytes == fresh.rateCard.selectedBytes,
              initial.candidate.signerKeyID == fresh.candidate.signerKeyID,
              initial.demand.signerKeyID == fresh.demand.signerKeyID,
              initial.rateCard.signerKeyID == fresh.rateCard.signerKeyID else {
            throw ModelCatalogTransactionError.authorityUnavailable
        }
    }

    private func prepare(id: String, authority: ModelCatalogTransactionAuthority, deadline: Date, lifetime: ModelTransactionOwnerLifetimeGuard) async throws {
        try lifetime.checkPublicationAllowed()
        try store.check(id, target: authority.row.modelID)
        let staging = try store.stagingURL(id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let available = try availableBytes(staging)
        let expected = authority.estimatedBytes ?? Int64(64 * 1024 * 1024 * 1024)
        guard expected <= Int64.max / 3, available > expected * 2 + 256 * 1024 * 1024 else { throw ModelCatalogTransactionError.insufficientSpace }
        let snapshot = staging.appendingPathComponent("download")
        try await downloader.downloadSnapshot(modelID: authority.row.modelID, revision: authority.row.modelRevision!, to: snapshot, deadline: deadline)
        try store.check(id, target: authority.row.modelID)
        guard try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot, deadline: deadline, checkCancellation: {
            try lifetime.checkPublicationAllowed(); try boundary("hash_chunk"); try store.check(id, target: authority.row.modelID)
        }) == authority.row.modelSHA256 else {
            throw ModelCatalogTransactionError.authorityUnavailable
        }
        let durable = artifactResolver.durableStore
        let copy = staging.appendingPathComponent("verified-copy")
        try durable.stageVerifiedCopy(from: snapshot, to: copy, sha256: authority.row.modelSHA256!) {
            try lifetime.checkPublicationAllowed(); try boundary("copy_chunk"); try store.check(id, target: authority.row.modelID)
        }
        // Refresh authenticated inputs after the potentially long copy and before publication.
        let fresh = try ModelCatalogTransactionAuthority.resolve(target: authority.row.modelID, inputs: await inputs())
        guard authority.matches(fresh) else { throw ModelCatalogTransactionError.authorityUnavailable }
        try store.check(id, target: authority.row.modelID)
        let destination = try durable.artifactURL(modelID: authority.row.modelID, revision: authority.row.modelRevision!, sha256: authority.row.modelSHA256!)
        try lifetime.checkPublicationAllowed()
        let destinationParent = try durable.preparePublicationDirectory(destination)
        defer { close(destinationParent) }
        var incumbent = stat()
        let exists = lstat(destination.path, &incumbent) == 0
        if !exists && errno != ENOENT { throw ModelCatalogTransactionError.invalidTransaction }
        let verifiedPath = exists ? destination : copy
        let verifiedSnapshot = try ModelCatalogArtifactSnapshot.verified(directory: verifiedPath, sha256: authority.row.modelSHA256!, deadline: deadline) {
            try boundary("seal_verification"); try store.check(id, target: authority.row.modelID)
        }
        try boundary("before_publish")
        let observation = try verifiedSnapshot.observe(directory: verifiedPath, deadline: deadline) {
            try boundary("seal_metadata"); try store.check(id, target: authority.row.modelID)
        }
        try store.retryBeforeMutation { beginMutation in
            guard let selector = try store.load(id, target: authority.row.modelID).selector else { throw ModelCatalogTransactionError.invalidTransaction }
            let receipt = try store.captureActiveReceipt(selector: selector)
            var record = receipt.record
            guard !record.cancelRequested, Date() < deadline else { throw ModelCatalogTransactionError.cancelled }
            let seal = try ModelCatalogArtifactSeal(record: record, snapshot: verifiedSnapshot)
            let sealBytes = try JSONEncoder().encode(seal)
            record.artifactSealSHA256 = SHA256.hash(data: sealBytes).map { String(format: "%02x", $0) }.joined()
            record.committed = true
            try receipt.validateProspective(record: record)
            let bytes = try JSONEncoder().encode(record)
            try store.locked(nonblocking: true) {
                try receipt.validateLocked(store: store)
                try observation.validatePlacement()
                try lifetime.checkPublicationAllowed()
                try beginMutation()
                try store.writePrivate(sealBytes, to: store.root.appendingPathComponent(id + ".seal"))
                try lifetime.checkPublicationAllowed()
                try store.writePrivate(bytes, to: store.root.appendingPathComponent(id + ".json"))
                try boundary("publication_intent")
                try lifetime.checkPublicationAllowed()
                _ = try durable.publishSealedCopy(copy, destination: destination, observation: observation, existing: exists, destinationParent: destinationParent)
                try boundary("published")
            }
        }
    }

    private func recommend(id: String, authority: ModelCatalogTransactionAuthority,
                           selected: ModelCatalogRecommendationInputs, deadline: Date, lifetime: ModelTransactionOwnerLifetimeGuard) async throws -> Data {
        try lifetime.checkPublicationAllowed()
        let resolver = artifactResolver
        let path = try resolver.durableStore.artifactURL(modelID: authority.row.modelID,
                                                        revision: authority.row.modelRevision!, sha256: authority.row.modelSHA256!)
        _ = try resolver.durableStore.validatedContainedDirectory(path.path)
        let artifact = try resolver.verifiedExistingArtifact(for: authority.row, at: path, deadline: deadline)
        let warnings = selected.demand.warnings.union(selected.candidate.warnings).union(selected.rateCard.warnings)
        guard !AutotuneRecommendEngine.paidTrustBlocks(warnings),
              !warnings.contains(.rateCardStale), !warnings.contains(.demandRankStale) else {
            throw ModelCatalogTransactionError.authorityUnavailable
        }
        let conflict = try detectConflict()
        let defaultConfig = managedContext.config
        switch conflict {
        case .none: break
        case .foreground: throw ModelCatalogTransactionError.lifecycleUnavailable
        case .launchdManaged:
            guard configPath == defaultConfig else { throw ModelCatalogTransactionError.lifecycleUnavailable }
        }
        try lifetime.checkPublicationAllowed()
        let guardProcess = try drainer.startLaunchdCrashRestoreGuard(for: conflict)
        let needsRestore = conflict != .none
        var output: Data?
        var failure: Error?
        do {
            try lifetime.checkPublicationAllowed()
            if needsRestore, case .portStillOpen = try drainer.drain(conflict, port: port, graceSeconds: 30) {
                throw ModelCatalogTransactionError.lifecycleUnavailable
            }
            try store.check(id, target: authority.row.modelID)
            // Reuse existing HMAC identity without creating/rotating operator custody.
            // Explicit isolated configs use a transaction-root secret only.
            let secretPath = configPath == defaultConfig ? managedContext.secret : store.root.appendingPathComponent("autotune-hmac-secret")
            let secret: Data
            if configPath == defaultConfig {
                secret = try ModelTransactionDirectory(secretPath.deletingLastPathComponent()).read(secretPath.lastPathComponent)
            } else {
                try lifetime.checkPublicationAllowed()
                secret = try AutotuneHMACSecretStore(path: secretPath).loadOrCreate()
            }
            guard secret.count == 32 else { throw AutotuneRecommendError.noHMACSecret }
            let fingerprint = MachineFingerprinter().sample()
            let identity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint, providerID: config.providerID)
            let hardware = hardware(identity)
            var request = AutotuneRecommendRequest(hardware: hardware, demandRank: selected.demand.value,
                candidateCatalog: selected.candidate.value, candidateCatalogSHA256: authority.candidateDigest,
                rateCard: selected.rateCard.value, benchmarks: [:], warnings: warnings, generatedAt: Date(), donorMode: false, buyerTTFTCeilingMS: 0)
            let prefetched = PrefetchedModelArtifact(modelKey: authority.modelKey, modelID: authority.row.modelID,
                modelRevision: authority.row.modelRevision!, candidateRowIdentity: selected.candidate.value.rowIdentity(for: authority.modelKey)!,
                path: artifact.modelArgument, sha256: artifact.sha256)
            try lifetime.checkPublicationAllowed()
            var measured = try benchmarker(resolver, store.root.appendingPathComponent("probe-logs"), lifetime.checkPublicationAllowed)
            let makeRunner = measured.runnerFactory
            measured.runnerFactory = {
                try lifetime.checkPublicationAllowed()
                let runner = try makeRunner()
                runner.publicationCheck = lifetime.checkPublicationAllowed
                return runner
            }
            let outcomes = try await measured.benchmarks(
                request: request, targetContext: AutotuneCommand.spec023RecommendationProbeContext,
                gateTTFTMS: 60_000, replicates: 3, port: port, deadline: deadline,
                candidateModelIDs: [authority.row.modelID], prefetchedArtifacts: [authority.modelKey: prefetched])
            try store.check(id, target: authority.row.modelID)
            request.benchmarks = outcomes.benchmarks
            var result = AutotuneRecommendEngine().recommend(request)
            result.probeDiagnostics = outcomes.diagnostics
            guard let selectedScore = result.selectedCandidate, selectedScore.catalogKey == authority.modelKey,
                  let benchmark = outcomes.benchmarks[authority.modelKey] else { throw ModelCatalogTransactionError.resultUnavailable }
            let core = AutotuneCommand.recommendationCoreForConfig(selected: selectedScore, selectedBenchmark: benchmark,
                selectedRow: authority.row, catalogVersion: selected.candidate.value.version,
                catalogHash: authority.candidateDigest, hardware: hardware)
            output = Data(result.jsonString(serveConfig: core).utf8)
        } catch { failure = error }
        if needsRestore {
            try lifetime.checkPublicationAllowed()
            do { _ = try drainer.restore(conflict, restartForeground: false); guardProcess?.dismiss() }
            catch { throw ModelCatalogTransactionError.lifecycleUnavailable }
        }
        if let failure { throw failure }
        guard let output else { throw ModelCatalogTransactionError.resultUnavailable }
        return output
    }
}

struct ModelsPrepareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prepare", abstract: "Prepare an authenticated primary model without changing the serving model.")
    @Argument var target: String
    @Option var transactionID: String
    @Option var operationGeneration: String
    @Option var config: String?
    @OptionGroup var transactionContext: ModelTransactionContextOptions
    @Flag var confirm = false
    @Flag(name: .customLong("json")) var emitJSON = false
    func run() async throws { try await run(context: .production) }
    func run(context: ModelCommandExecutionContext) async throws {
        try await runModelCatalogTransaction(target: target, id: transactionID, generation: operationGeneration,
            config: config, options: transactionContext, confirm: confirm, json: emitJSON, kind: "prepare_model", context: context)
    }
}
struct ModelsRecommendPreparedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recommend-prepared", abstract: "Measure one verified prepared model for confirmed local activation.")
    @Argument var target: String
    @Option var transactionID: String
    @Option var operationGeneration: String
    @Option var config: String?
    @OptionGroup var transactionContext: ModelTransactionContextOptions
    @Flag var confirm = false
    @Flag(name: .customLong("json")) var emitJSON = false
    func run() async throws { try await run(context: .production) }
    func run(context: ModelCommandExecutionContext) async throws {
        try await runModelCatalogTransaction(target: target, id: transactionID, generation: operationGeneration,
            config: config, options: transactionContext, confirm: confirm, json: emitJSON, kind: "evaluate_model", context: context)
    }
}
private func modelCatalogTransactionSetup(config: String?, options: ModelTransactionContextOptions) throws
    -> (config: AppConfig, path: URL, store: ModelCatalogTransactionStore, resolver: CachedModelArtifactResolver) {
    let environment = ProcessInfo.processInfo.environment
    if options.transactionContextFD != nil {
        let bound = try ModelTransactionContextLoader.load(configPath: config, options: options,
            environment: environment, homeDirectory: ModelTransactionContextLoader.kernelHomeDirectory())
        let resolver = CachedModelArtifactResolver.forConfig(bound.config, environment: bound.environment, homeDirectory: bound.homeDirectory)
        guard resolver.durableRoot.standardizedFileURL == bound.durableRoot.standardizedFileURL else { throw ModelTransactionContextError.unavailable }
        return (bound.config, bound.configPath, .forContext(bound), resolver)
    }
    let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
    let path = URL(fileURLWithPath: ConfigLoader.expandTilde(config ?? environment["MACPROVIDER_CONFIG"] ?? AppConfig.defaultConfigPath))
        .standardizedFileURL.resolvingSymlinksInPath()
    return (resolved, path, .forConfig(resolved), .forConfig(resolved))
}
private func runModelCatalogTransaction(target: String, id: String, generation: String, config: String?,
    options: ModelTransactionContextOptions, confirm: Bool, json: Bool, kind: String, context: ModelCommandExecutionContext) async throws {
    try options.rejectControlOptions()
    guard confirm && json else { throw ValidationError("--confirm and --json are required; review authenticated trust and size in catalog-economics first") }
    let setup = try modelCatalogTransactionSetup(config: config, options: options)
    var runner = ModelCatalogTransactionRunner(config: setup.config, configPath: setup.path, store: setup.store,
        inputs: { await context.inputs().loadRecommendationInputs() })
    runner.boundArtifactResolver = setup.resolver
    runner.adoptionLockRoot = context.adoptionJournalRoot
    context.configureTransactionRunner(&runner)
    do { try await runner.run(id: id, target: target, kind: kind, operationGeneration: generation) }
    catch { throw ValidationError("model transaction did not complete; inspect its exact operation status") }
}
struct ModelsTransactionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transaction", abstract: "Read or cancel CLI-owned model transactions.",
        subcommands: [ModelsTransactionStatusCommand.self, ModelsTransactionCancelCommand.self, ModelsTransactionResultCommand.self])
}
struct ModelsTransactionStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @Argument var transactionID: String
    @Option var model: String
    @Option var expectedKind: String
    @Option var operationGeneration: String
    @Option var config: String?
    @OptionGroup var transactionContext: ModelTransactionContextOptions
    @Flag(name: .customLong("json")) var emitJSON = false
    func run() async throws {
        try modelCatalogTransactionRead(selector: .init(transactionID: transactionID, target: model,
            kind: expectedKind, operationGeneration: operationGeneration), config: config, options: transactionContext,
            json: emitJSON, cancel: false, result: false)
    }
}
struct ModelsTransactionCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cancel")
    @Argument var transactionID: String
    @Option var model: String
    @Option var expectedKind: String
    @Option var operationGeneration: String
    @Option var config: String?
    @OptionGroup var transactionContext: ModelTransactionContextOptions
    @Flag(name: .customLong("json")) var emitJSON = false
    func run() async throws {
        try modelCatalogTransactionRead(selector: .init(transactionID: transactionID, target: model,
            kind: expectedKind, operationGeneration: operationGeneration), config: config, options: transactionContext,
            json: emitJSON, cancel: true, result: false)
    }
}
struct ModelsTransactionResultCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "result")
    @Argument var transactionID: String
    @Option var model: String
    @Option var expectedKind: String
    @Option var operationGeneration: String
    @Option var config: String?
    @OptionGroup var transactionContext: ModelTransactionContextOptions
    @OptionGroup var readOptions: ModelCatalogReadOptions
    @Flag(name: .customLong("json")) var emitJSON = false
    func run() async throws { try await run(context: .production) }
    func run(context: ModelCommandExecutionContext) async throws {
        if readOptions.isPresent {
            guard emitJSON, !transactionContext.hasControlOptions, transactionContext.transactionContextFD == nil else {
                throw ModelCatalogReadError.contextChanged
            }
            try readOptions.validate(mode: [.result])
            let budget = ModelCatalogReadBudget(mode: .result)
            let lease = try ModelCatalogReadLease.start(options: readOptions, budget: budget,
                homeDirectory: { try context.projectionHome ?? ModelTransactionContextLoader.kernelHomeDirectory() })
            defer { withExtendedLifetime(lease) {} }
            let namespace = try ModelTransactionContextLoader.projectionEnvironment(context.projectionEnvironment)
            let home = try context.projectionHome ?? ModelTransactionContextLoader.kernelHomeDirectory()
            let prepared = try ModelTransactionContextLoader.prepareProjection(configPath: config, environment: namespace, homeDirectory: home)
            let bound = try ModelTransactionContextLoader.existingProjection(prepared, expectedDigest: readOptions.expectedContextSHA256!)
            let store = ModelCatalogTransactionStore.forContext(bound)
            let bytes = try store.result(.init(transactionID: transactionID, target: model,
                kind: expectedKind, operationGeneration: operationGeneration), readBudget: budget)
            _ = try ModelTransactionContextLoader.existingProjection(prepared, expectedDigest: bound.projectionDigest)
            try budget.check()
            guard bytes.count < 8_388_608 else { throw ModelCatalogReadError.readLimitExceeded }
            try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
            return
        }
        try modelCatalogTransactionRead(selector: .init(transactionID: transactionID, target: model,
            kind: expectedKind, operationGeneration: operationGeneration), config: config, options: transactionContext,
            json: emitJSON, cancel: false, result: true)
    }
}
private func modelCatalogTransactionRead(selector: ModelCatalogTransactionSelector, config: String?,
    options: ModelTransactionContextOptions, json: Bool, cancel: Bool, result: Bool) throws {
    let lease = try ModelTransactionControlLease.start(options: options)
    defer { withExtendedLifetime(lease) {} }
    guard json else { throw ValidationError("--json is required") }
    let setup = try modelCatalogTransactionSetup(config: config, options: options)
    do {
        if result { FileHandle.standardOutput.write(try setup.store.result(selector)); FileHandle.standardOutput.write(Data([10])) }
        else { for event in try setup.store.reconcile(selector, cancel: cancel).events { try ModelSwitchingWireCodec.printJSON(event) } }
    } catch { throw ValidationError("unknown, unavailable, or mismatched model transaction") }
}
struct ModelsCleanupStagingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup-staging", abstract: "Remove only one completed transaction's owned staging.")
    @Argument var transactionID: String
    @Option var model: String
    @Option var operationGeneration: String
    @Option var config: String?
    @OptionGroup var transactionContext: ModelTransactionContextOptions
    @Flag var confirm = false
    @Flag(name: .customLong("json")) var emitJSON = false
    func run() async throws {
        try transactionContext.rejectControlOptions()
        guard confirm && emitJSON else { throw ValidationError("--confirm and --json are required") }
        let store = try modelCatalogTransactionSetup(config: config, options: transactionContext).store
        let selector = ModelCatalogTransactionSelector(transactionID: transactionID, target: model,
            kind: "cleanup_staging", operationGeneration: operationGeneration)
        // Receipt capture validates exact generation before owner acquisition.
        _ = try store.retryContention { try store.captureActiveReceipt(selector: selector) }
        let owner = try store.ownerLock(transactionID)
        defer { withExtendedLifetime(owner) {} }
        let cancellation = ModelTransactionWorkCancellation()
        let lifetime = ModelTransactionOwnerLifetimeGuard(onFence: { cancellation.cancel() })
        defer { withExtendedLifetime(lifetime) {} }
        let stream = ModelCatalogTransactionStream()
        let original = try store.load(transactionID, target: model)
        guard original.terminal, original.cleanupRequired, let originalSelector = original.selector else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        let started = try store.update(selector, check: lifetime.checkPublicationAllowed) { cleanup in
            guard cleanup.startedAt == nil, !cleanup.terminal, !cleanup.cancelRequested,
                  Date().timeIntervalSince(cleanup.createdAt) < 1800 else { throw ModelCatalogTransactionError.invalidTransaction }
            cleanup.startedAt = Date()
            store.append(&cleanup, state: "running", stage: "cleanup")
        }
        try lifetime.acknowledgeDurableHeartbeat()
        try stream.emit(started.currentEvents)
        let id = transactionID
        let work = Task.detached {
            try store.cleanup(id) {
                try lifetime.checkPublicationAllowed()
                try store.check(selector)
            }
        }
        cancellation.install(work)
        let heartbeat = Task {
            var lastHeartbeat = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                do {
                    if DispatchTime.now().uptimeNanoseconds - lastHeartbeat < 5_000_000_000 { continue }
                    let record = try store.update(selector, check: lifetime.checkPublicationAllowed) { record in
                        guard !record.terminal else { throw ModelCatalogTransactionError.invalidTransaction }
                        store.append(&record, state: record.cancelRequested ? "cancel_requested" : "running", stage: "cleanup")
                    }
                    try lifetime.acknowledgeDurableHeartbeat()
                    lastHeartbeat = DispatchTime.now().uptimeNanoseconds
                    try stream.emit(record.currentEvents)
                    if record.cancelRequested { work.cancel() }
                } catch ModelCatalogTransactionError.busy { continue }
                catch ModelCatalogRetentionError.changed { continue }
                catch { work.cancel() }
            }
        }
        defer { heartbeat.cancel() }
        var failed = false
        do { try await work.value } catch { failed = true }
        let outcome = try store.retryBeforeMutation { beginMutation in
            let receipt = try store.captureActiveReceipt(selector: selector)
            let originalReceipt = try store.captureActiveReceipt(selector: originalSelector)
            var outcome = receipt.record
            let state = failed ? (outcome.cancelRequested ? "cancelled" : "failed") : "succeeded"
            store.append(&outcome, state: state, error: failed ? "cleanup_failed" : nil, warning: failed ? "staging_cleanup_required" : nil)
            var updatedOriginal = originalReceipt.record
            updatedOriginal.cleanupRequired = failed
            try receipt.validateProspective(record: outcome)
            try originalReceipt.validateProspective(record: updatedOriginal)
            let outcomeBytes = try JSONEncoder().encode(outcome), originalBytes = try JSONEncoder().encode(updatedOriginal)
            try store.locked(nonblocking: true) {
                try receipt.validateLocked(store: store); try originalReceipt.validateLocked(store: store)
                try lifetime.checkPublicationAllowed()
                try beginMutation()
                try store.writePrivate(outcomeBytes, to: store.root.appendingPathComponent(id + ".cleanup"))
                try lifetime.checkPublicationAllowed()
                try store.writePrivate(originalBytes, to: store.root.appendingPathComponent(id + ".json"))
            }
            return outcome
        }
        try lifetime.acknowledgeDurableHeartbeat()
        heartbeat.cancel(); _ = await heartbeat.value

        try stream.emit(outcome.currentEvents)
        if failed { throw ExitCode(1) }
    }
}

func makeModelCatalogLocalActions(inputs: ModelCatalogRecommendationInputs, config: AppConfig?, store explicitStore: ModelCatalogTransactionStore? = nil) -> [String: ModelCatalogLocalActions] {
    let store = explicitStore ?? ModelCatalogTransactionStore.forConfig(config)
    let budget = ModelCatalogReadBudget(mode: .quick)
    let inspection = ModelCatalogLocalInspection(root: store.root.deletingLastPathComponent(), budget: budget)
    return (try? makeCompleteModelCatalogLocalActions(inputs: inputs, config: config, store: store,
                                                     inspection: inspection, budget: budget)) ?? [:]
}

func makeCompleteModelCatalogLocalActions(inputs: ModelCatalogRecommendationInputs, config: AppConfig?,
    store: ModelCatalogTransactionStore, inspection: ModelCatalogLocalInspection, budget: ModelCatalogReadBudget,
    workBudget suppliedWorkBudget: ModelTransactionWorkBudget? = nil,
    reserve: Bool = true) throws -> [String: ModelCatalogLocalActions] {
    let workBudget = try suppliedWorkBudget ?? budget.transactionBudget()
    var result: [String: ModelCatalogLocalActions] = [:]
    for key in inputs.candidate.value.rows.keys.sorted() {
        try budget.check()
        guard let authority = try? ModelCatalogTransactionAuthority.resolve(target: key, inputs: inputs),
              (try? SupportedModels.validate(model: authority.modelKey, supportedModels: config?.supportedModels)) != nil else { continue }
        let identity = ModelCatalogLocalInspection.Key(modelKey: key, modelID: authority.row.modelID,
            revision: authority.row.modelRevision!, sha256: authority.row.modelSHA256!)
        let observed = try inspection.inspect(key: identity)
        let prepared = observed.state == .verified
        func action(_ kind: String, bytes: Int64? = nil) throws -> ModelCatalogEconomicsWire.Action {
            try budget.check()
            let reservation: ModelCatalogTransactionReservation
            if reserve { reservation = try store.reserveOperation(authority: authority, kind: kind, budget: workBudget) }
            else { reservation = .init(transactionID: "00000000-0000-4000-8000-000000000000", operationGeneration: "00000000-0000-4000-8000-000000000000") }
            return .init(available: true, requiresConfirmation: true, transactionKind: kind, transactionID: reservation.transactionID,
                         actionTimeoutSeconds: 1800, estimatedBytes: bytes, unavailableReason: nil, operationGeneration: reservation.operationGeneration)
        }
        let warnings = inputs.candidate.warnings.union(inputs.rateCard.warnings).union(inputs.demand.warnings)
        let evaluable = prepared && !AutotuneRecommendEngine.paidTrustBlocks(warnings) &&
            warnings.isDisjoint(with: [.candidateCatalogStale, .rateCardStale, .demandRankStale])
        let localBlock = observed.state == .invalid ? "local_artifact_invalid" : "local_verification_required"
        let prepare: ModelCatalogEconomicsWire.Action
        if observed.state == .missing { prepare = try action("prepare_model", bytes: authority.estimatedBytes) }
        else { prepare = .unavailable(prepared ? "already_prepared" : localBlock) }
        let evaluate: ModelCatalogEconomicsWire.Action = evaluable ? try action("evaluate_model") :
            .unavailable(prepared ? "prepared_authority_required" : localBlock)
        let adopt: ModelCatalogEconomicsWire.Action
        if evaluable {
            if reserve {
                adopt = try modelCatalogAdoptionAction(store: store, authority: authority, inputs: inputs,
                                                       budget: budget, workBudget: workBudget)
            }
            else { adopt = try action("adopt_recommendation") }
        } else { adopt = .unavailable(prepared ? "measured_recommendation_required" : localBlock) }
        result[key] = ModelCatalogLocalActions(targetModelID: authority.row.modelID, prepare: prepare, evaluate: evaluate,
            adoptRecommendation: adopt, cleanupStaging: .unavailable("use_recovery_action"))
    }
    try budget.check()
    return result
}

private func modelCatalogAdoptionAction(store: ModelCatalogTransactionStore, authority: ModelCatalogTransactionAuthority,
    inputs: ModelCatalogRecommendationInputs, budget: ModelCatalogReadBudget,
    workBudget: ModelTransactionWorkBudget) throws -> ModelCatalogEconomicsWire.Action {
    try budget.check()
    let hardware = MachineFingerprinter().sample()
    guard let record = try store.indexedRecommendation(authority: authority, inputs: inputs,
        chip: hardware.chip, memoryGB: hardware.ramGB, binaryVersion: hardware.binaryVersion,
        budget: workBudget, readBudget: budget, requireComplete: true) else {
        return .unavailable("measured_recommendation_required")
    }
    try budget.check()
    return .init(available: true, requiresConfirmation: true, transactionKind: "adopt_recommendation",
        transactionID: record.transactionID, actionTimeoutSeconds: 1800, estimatedBytes: nil, unavailableReason: nil,
        operationGeneration: record.operationGeneration)
}

/// Completes all recommendation journal recovery that can affect actions before
/// a cleanup inventory is captured. The same helper budget is used for every
/// target, so scanning multiple rows cannot renew the operation deadline.
func prepareCompleteModelCatalogRecommendationIndexes(inputs: ModelCatalogRecommendationInputs,
    config: AppConfig?, store: ModelCatalogTransactionStore, budget: ModelCatalogReadBudget,
    workBudget: ModelTransactionWorkBudget) throws {
    for key in inputs.candidate.value.rows.keys.sorted() {
        try workBudget.check()
        guard let authority = try? ModelCatalogTransactionAuthority.resolve(target: key, inputs: inputs),
              (try? SupportedModels.validate(model: authority.modelKey,
                                             supportedModels: config?.supportedModels)) != nil else { continue }
        _ = try store.prepareRecommendationIndex(target: authority.row.modelID, budget: workBudget,
                                                 readBudget: budget, requireComplete: true)
    }
    try workBudget.check()
}

func modelCatalogDiscoveryMatcher(inputs: ModelCatalogRecommendationInputs) -> BYOMCatalogMatcher {
    let candidateBlocked = !inputs.candidate.warnings.isDisjoint(with: [.candidateCatalogIntegrityFailure, .candidateCatalogUpdateRequired, .candidateCatalogStale])
    guard !candidateBlocked else { return BYOMCatalogMatcher(candidateBytes: Data(), artifactFeed: nil) }
    let artifactBlocked = !inputs.artifactFeed.warnings.isDisjoint(with: [.catalogArtifactFeedIntegrityFailure, .catalogArtifactFeedUpdateRequired, .catalogArtifactFeedStale])
    return BYOMCatalogMatcher(candidateBytes: inputs.candidate.selectedBytes, artifactFeed: artifactBlocked ? nil : inputs.artifactFeed.value)
}
