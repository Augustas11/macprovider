import CryptoKit
import Darwin
import Foundation

private struct ModelTransactionMigrationSource: Codable {
    struct Entry: Codable { let id: String; let phase: String }
    let schema: String
    let migrationID: String
    let sourceSHA256: String
    let sourceGeneration: UInt64
    let entries: [Entry]
}
private struct ModelTransactionMigrationProgress: Codable {
    struct Entry: Codable {
        let id: String
        let phase: String
        let provenance: String
        let originSHA256: String
        let sourcePrimarySHA256: String?
    }
    struct Observation: Codable {
        enum Value: Codable { case absent; case bytes(String); case metadata(String) }
        let name: String
        let value: Value
    }
    struct Pending: Codable {
        let position: Int
        let entry: Entry
        let originBytes: Data
        let observations: [Observation]
    }
    let schema: String
    let migrationID: String
    let sourceFileSHA256: String
    var generation: UInt64
    var phase: String
    var entries: [Entry]
    var pending: Pending?
    var intendedIndexSHA256: String?
    var intendedIndexGeneration: UInt64?
}

/// Operation-local decoded authority. Each use checks the same pinned files;
/// the receipt is never cached across operations or persisted as a new format.
struct ModelTransactionMigrationCompletionReceipt {
    let sourceFile: ModelTransactionFileEvidence
    let progressFile: ModelTransactionFileEvidence
    let migrationID: String
    let sourceSHA256: String
    let initialGeneration: UInt64
    let budget: ModelTransactionWorkBudget

    func validateFiles() throws {
        try sourceFile.validate(); try progressFile.validate(); try budget.check()
    }
    func validateLocked(_ index: ModelTransactionActiveIndex) throws {
        try validateFiles()
        guard ["model_catalog_active_index.v3", "model_catalog_active_index.v4"].contains(index.schema),
              index.migrationID == migrationID,
              index.migrationSourceSHA256 == sourceSHA256, index.generation >= initialGeneration else {
            throw ModelCatalogRetentionError.migration
        }
    }
}

extension ModelCatalogTransactionStore {
    private static let bindingMigrationName = ".binding-migration"
    private func migrationDirectory() throws -> ModelTransactionDirectory {
        try ModelTransactionDirectory.current(root).child(Self.bindingMigrationName)
    }
    private func migrationFile(_ name: String, budget: ModelTransactionWorkBudget) throws -> ModelTransactionFileEvidence {
        try ModelTransactionFileEvidence(directory: migrationDirectory(), name: name,
            maxBytes: name == "source.json" ? 262_144 : Self.indexLimit, budget: budget,
            observe: { try retentionBoundary("migration_bulk_read") })
    }
    private func migrationIndexEvidence(budget: ModelTransactionWorkBudget) throws -> ModelTransactionFileEvidence {
        try ModelTransactionFileEvidence(directory: retentionDirectory(), name: "active.json", maxBytes: Self.indexLimit, budget: budget)
    }
    private func metadataDigest(_ value: stat) -> String {
        digest(Data("\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_uid):\(value.st_gid):\(value.st_mode):\(value.st_nlink):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)".utf8))
    }
    private struct MigrationCapture {
        let values: [ModelTransactionMigrationProgress.Observation]
        let files: [ModelTransactionFileEvidence]
        let metadata: [(String, String?)]
        func validate(_ store: ModelCatalogTransactionStore) throws {
            for item in files { try item.validate() }
            let directory = try ModelTransactionDirectory.current(store.root)
            for (name, hash) in metadata {
                guard try directory.metadata(name).map(store.metadataDigest) == hash else { throw ModelCatalogRetentionError.changed }
            }
        }
    }
    private func migrationCapture(_ id: String, budget: ModelTransactionWorkBudget) throws -> MigrationCapture {
        var values: [ModelTransactionMigrationProgress.Observation] = [], files: [ModelTransactionFileEvidence] = []
        var metadata: [(String, String?)] = []
        let directory = try ModelTransactionDirectory.current(root)
        for name in [id + ".json", id + ".result", id + ".seal", id + ".cleanup", id + ".success-binding", id + ".retired", "staging-" + id] {
            try budget.check()
            if name.hasPrefix("staging-") {
                let hash = try directory.metadata(name).map(metadataDigest)
                metadata.append((name, hash)); values.append(.init(name: name, value: hash.map { .metadata($0) } ?? .absent))
                continue
            }
            do {
                let file = try evidence(name, budget: budget)
                files.append(file); values.append(.init(name: name, value: file.sha256.map { .bytes($0) } ?? .absent))
            } catch {
                try budget.check()
                let hash = try directory.metadata(name).map(metadataDigest)
                guard let hash else { throw ModelCatalogRetentionError.changed }
                metadata.append((name, hash)); values.append(.init(name: name, value: .metadata(hash)))
            }
        }
        return .init(values: values, files: files, metadata: metadata)
    }
    private func migrationOrigin(id: String, capture: MigrationCapture) throws -> ModelTransactionOrigin {
        let primary = capture.files.first { $0.name == id + ".json" }
        let hash = primary?.sha256
        var legacy = false
        if let bytes = primary?.bytes, let record = try? decodeRetentionRecord(bytes, id: id),
           record.operationGeneration == nil, record.terminal, !record.cleanupRequired,
           capture.metadata.allSatisfy({ $0.1 == nil }),
           capture.files.first(where: { $0.name == id + ".success-binding" })?.bytes == nil,
           capture.files.first(where: { $0.name == id + ".retired" })?.bytes == nil {
            do {
                let result = capture.files.first { $0.name == id + ".result" }!
                let seal = capture.files.first { $0.name == id + ".seal" }!
                let cleanup = capture.files.first { $0.name == id + ".cleanup" }!
                if let data = result.bytes { _ = try validatedCommittedResult(record, data: data) }
                else if record.resultSHA256 != nil || (record.kind == "evaluate_model" && record.events.last?.state == "succeeded") { throw ModelCatalogRetentionError.unsafe }
                if let data = seal.bytes { _ = try validatedPreparationSeal(record, data: data) }
                else if record.artifactSealSHA256 != nil { throw ModelCatalogRetentionError.unsafe }
                if let data = cleanup.bytes {
                    let stream = try decodeRetentionRecord(data, id: id)
                    guard stream.operationGeneration == nil, stream.kind == "cleanup_staging", stream.terminal,
                          stream.target == record.target else { throw ModelCatalogRetentionError.unsafe }
                }
                legacy = true
            } catch { legacy = false }
        }
        return .init(schema: "model_catalog_transaction_origin.v1", transactionID: id,
                     provenance: legacy ? .legacySnapshot(primarySHA256: hash!) : .protectedSnapshot(primarySHA256: hash))
    }
    private func validateMigration(_ source: ModelTransactionMigrationSource, progress: ModelTransactionMigrationProgress,
                                   sourceHash: String) throws {
        guard !ModelTransactionDirectory.hasScopedDirectory else { throw ModelCatalogRetentionError.unsafe }
        try retentionBoundary("migration_validate")
        guard source.schema == "model_catalog_binding_migration_source.v1",
              progress.schema == "model_catalog_binding_migration_progress.v1",
              source.migrationID == progress.migrationID, progress.sourceFileSHA256 == sourceHash,
              source.entries.count <= Self.activeTransactionLimit, Set(source.entries.map(\.id)).count == source.entries.count,
              progress.entries.count <= source.entries.count, progress.generation > 0, progress.generation < UInt64.max,
              source.sourceGeneration > 0, source.sourceGeneration < UInt64.max,
              ["classifying", "finalizing", "complete"].contains(progress.phase) else { throw ModelCatalogRetentionError.migration }
        try validateID(source.migrationID)
        for (position, item) in source.entries.enumerated() {
            try validateID(item.id)
            guard ["active", "allocating"].contains(item.phase) else { throw ModelCatalogRetentionError.migration }
            if position > 0, source.entries[position - 1].id >= item.id { throw ModelCatalogRetentionError.migration }
        }
        for (position, item) in progress.entries.enumerated() {
            guard item.id == source.entries[position].id, item.phase == source.entries[position].phase,
                  ["legacy_snapshot", "protected_snapshot"].contains(item.provenance) else { throw ModelCatalogRetentionError.migration }
        }
        if let pending = progress.pending {
            guard progress.phase == "classifying", pending.position == progress.entries.count,
                  pending.position < source.entries.count, pending.entry.id == source.entries[pending.position].id,
                  pending.entry.phase == source.entries[pending.position].phase,
                  pending.originBytes.count <= 16_384, digest(pending.originBytes) == pending.entry.originSHA256 else { throw ModelCatalogRetentionError.migration }
            let origin = try closedDecode(ModelTransactionOrigin.self, pending.originBytes)
            guard origin.schema == "model_catalog_transaction_origin.v1", origin.transactionID == pending.entry.id,
                  origin.provenance.name == pending.entry.provenance,
                  ["legacy_snapshot", "protected_snapshot"].contains(origin.provenance.name) else { throw ModelCatalogRetentionError.migration }
        }
        if progress.phase != "classifying" {
            guard progress.pending == nil, progress.entries.count == source.entries.count,
                  progress.intendedIndexSHA256 != nil, progress.intendedIndexGeneration != nil else { throw ModelCatalogRetentionError.migration }
        } else if progress.intendedIndexSHA256 != nil || progress.intendedIndexGeneration != nil { throw ModelCatalogRetentionError.migration }
    }
    func captureMigrationCompletion(budget: ModelTransactionWorkBudget = .init()) throws -> ModelTransactionMigrationCompletionReceipt {
        let sourceFile = try migrationFile("source.json", budget: budget)
        let progressFile = try migrationFile("progress.json", budget: budget)
        return try migrationCompletion(sourceFile: sourceFile, progressFile: progressFile, budget: budget)
    }
    private func migrationCompletion(sourceFile: ModelTransactionFileEvidence, progressFile: ModelTransactionFileEvidence,
                                     budget: ModelTransactionWorkBudget) throws -> ModelTransactionMigrationCompletionReceipt {
        guard !ModelTransactionDirectory.hasScopedDirectory,
              let sourceBytes = sourceFile.bytes, let sourceHash = sourceFile.sha256,
              let progressBytes = progressFile.bytes else { throw ModelCatalogRetentionError.migration }
        try retentionBoundary("migration_decode")
        let source = try closedDecode(ModelTransactionMigrationSource.self, sourceBytes)
        let progress = try closedDecode(ModelTransactionMigrationProgress.self, progressBytes)
        try validateMigration(source, progress: progress, sourceHash: sourceHash)
        guard progress.phase == "complete", let initial = progress.intendedIndexGeneration else {
            throw ModelCatalogRetentionError.migration
        }
        try budget.check()
        return .init(sourceFile: sourceFile, progressFile: progressFile, migrationID: progress.migrationID,
                     sourceSHA256: sourceHash, initialGeneration: initial, budget: budget)
    }
    private func recaptureMigrationProgress(_ expected: Data, budget: ModelTransactionWorkBudget) throws -> ModelTransactionFileEvidence {
        try retentionBoundary("migration_before_progress_recapture")
        let file = try migrationFile("progress.json", budget: budget)
        guard file.bytes == expected else { throw ModelCatalogRetentionError.changed }
        return file
    }
    func initializeBindingMigration(budget: ModelTransactionWorkBudget,
                                    initialIndex supplied: ModelTransactionIndexReceipt? = nil) throws -> ModelTransactionMigrationCompletionReceipt {
        let rootDirectory = try ModelTransactionDirectory.current(root)
        let initialIndex = try supplied ?? captureIndexReceipt(budget: budget, requireCompleted: false)
        try locked(nonblocking: true) { try initialIndex.validateLocked(store: self, requireCompleted: false) }
        let existing = initialIndex.index
        if ["model_catalog_active_index.v3", "model_catalog_active_index.v4"].contains(existing.schema) {
            let progressFile = try migrationFile("progress.json", budget: budget)
            guard let data = progressFile.bytes else { throw ModelCatalogRetentionError.migration }
            let progress = try closedDecode(ModelTransactionMigrationProgress.self, data)
            if progress.phase == "complete" {
                let receipt = try migrationCompletion(sourceFile: migrationFile("source.json", budget: budget), progressFile: progressFile, budget: budget)
                try locked(nonblocking: true) {
                    try initialIndex.validateLocked(store: self, requireCompleted: false); try receipt.validateLocked(existing)
                }
                return receipt
            }
            if existing.schema == "model_catalog_active_index.v4" {
                let receipt = try migrationCompletion(sourceFile: migrationFile("source.json", budget: budget), progressFile: progressFile, budget: budget)
                try locked(nonblocking: true) {
                    try initialIndex.validateLocked(store: self, requireCompleted: false); try receipt.validateLocked(existing)
                }
                return receipt
            }
            guard progress.phase == "finalizing" else { throw ModelCatalogRetentionError.migration }
        }
        let bootstrap = try ModelCatalogFileLock(root.appendingPathComponent(".retention-bootstrap"), nonblocking: true)
        defer { withExtendedLifetime(bootstrap) {} }
        if try rootDirectory.metadata(Self.bindingMigrationName) == nil {
            let indexEvidence = try migrationIndexEvidence(budget: budget)
            guard let indexData = indexEvidence.bytes else { throw ModelCatalogRetentionError.migration }
            let index = try closedDecode(ModelTransactionActiveIndex.self, indexData)
            guard index.schema == "model_catalog_active_index.v2", index.generation < UInt64.max else { throw ModelCatalogRetentionError.migration }
            let temporaryName = Self.bindingMigrationName + ".init"
            let sourceBytes: Data, progressBytes: Data
            if try rootDirectory.metadata(temporaryName) != nil {
                let temporary = try rootDirectory.child(temporaryName)
                guard try temporary.entries(limit: 2, check: budget.check).allSatisfy({ ["source.json", "progress.json"].contains($0) }) else { throw ModelCatalogRetentionError.migration }
                let sourceFile = try ModelTransactionFileEvidence(directory: temporary, name: "source.json", maxBytes: 262_144, budget: budget)
                let progressFile = try ModelTransactionFileEvidence(directory: temporary, name: "progress.json", maxBytes: Self.indexLimit, budget: budget)
                // No per-UUID decision or origin can precede the atomic prepared
                // directory publication. Only this unexposed empty state can be
                // completed from the exact source; prepared progress never resets.
                guard sourceFile.bytes != nil || progressFile.bytes == nil else { throw ModelCatalogRetentionError.migration }
                let source: ModelTransactionMigrationSource
                if let bytes = sourceFile.bytes { source = try closedDecode(ModelTransactionMigrationSource.self, bytes) }
                else {
                    source = .init(schema: "model_catalog_binding_migration_source.v1", migrationID: UUID().uuidString.lowercased(),
                        sourceSHA256: digest(indexData), sourceGeneration: index.generation,
                        entries: index.entries.sorted { $0.id < $1.id }.map { .init(id: $0.id, phase: $0.phase) })
                }
                sourceBytes = try canonicalData(source)
                let progress: ModelTransactionMigrationProgress
                if let bytes = progressFile.bytes { progress = try closedDecode(ModelTransactionMigrationProgress.self, bytes) }
                else {
                    progress = .init(schema: "model_catalog_binding_migration_progress.v1", migrationID: source.migrationID,
                        sourceFileSHA256: digest(sourceBytes), generation: 1, phase: "classifying", entries: [])
                }
                progressBytes = try canonicalData(progress)
                try validateMigration(source, progress: progress, sourceHash: digest(sourceBytes))
                guard source.sourceSHA256 == indexEvidence.sha256, progress.entries.isEmpty, progress.pending == nil,
                      progress.phase == "classifying", progress.generation == 1 else { throw ModelCatalogRetentionError.migration }
                try locked(nonblocking: true) {
                    try indexEvidence.validate(); try sourceFile.validate(); try progressFile.validate(); try budget.check()
                    if sourceFile.bytes == nil { try temporary.write(sourceBytes, name: "source.json", exclusive: true, maxBytes: 262_144) }
                    if progressFile.bytes == nil { try temporary.write(progressBytes, name: "progress.json", exclusive: true, maxBytes: Self.indexLimit) }
                }
            } else {
                let source = ModelTransactionMigrationSource(schema: "model_catalog_binding_migration_source.v1",
                    migrationID: UUID().uuidString.lowercased(), sourceSHA256: digest(indexData), sourceGeneration: index.generation,
                    entries: index.entries.sorted { $0.id < $1.id }.map { .init(id: $0.id, phase: $0.phase) })
                sourceBytes = try canonicalData(source)
                progressBytes = try canonicalData(ModelTransactionMigrationProgress(schema: "model_catalog_binding_migration_progress.v1",
                    migrationID: source.migrationID, sourceFileSHA256: digest(sourceBytes), generation: 1, phase: "classifying", entries: []))
                try budget.check()
                try locked(nonblocking: true) {
                    try indexEvidence.validate(); try budget.check()
                    let temporary = try rootDirectory.child(temporaryName, create: true)
                    try temporary.write(sourceBytes, name: "source.json", exclusive: true, maxBytes: 262_144)
                    try retentionBoundary("binding_migration_initial_source")
                    try budget.check()
                    try temporary.write(progressBytes, name: "progress.json", exclusive: true, maxBytes: Self.indexLimit)
                    try retentionBoundary("binding_migration_initial_progress")
                }
            }
            try locked(nonblocking: true) {
                try indexEvidence.validate(); try budget.check()
                guard try rootDirectory.metadata(Self.bindingMigrationName) == nil,
                      renameat(rootDirectory.fd, temporaryName, rootDirectory.fd, Self.bindingMigrationName) == 0,
                      fsync(rootDirectory.fd) == 0 else { throw ModelCatalogRetentionError.migration }
                try retentionBoundary("binding_migration_prepared")
            }
        }
        var heldOwner: ModelCatalogFileLock?
        var heldID: String?
        defer { withExtendedLifetime(heldOwner) {} }
        let sourceFile = try migrationFile("source.json", budget: budget)
        var progressFile = try migrationFile("progress.json", budget: budget)
        guard let sourceData = sourceFile.bytes, let sourceHash = sourceFile.sha256,
              let progressData = progressFile.bytes else { throw ModelCatalogRetentionError.migration }
        try retentionBoundary("migration_decode")
        let source = try closedDecode(ModelTransactionMigrationSource.self, sourceData)
        var progress = try closedDecode(ModelTransactionMigrationProgress.self, progressData)
        try validateMigration(source, progress: progress, sourceHash: sourceHash)
        let indexFile = try migrationIndexEvidence(budget: budget)
        guard let indexData = indexFile.bytes else { throw ModelCatalogRetentionError.migration }
        let index = try closedDecode(ModelTransactionActiveIndex.self, indexData)
        while true {
            try budget.check()
            guard progress.generation < UInt64.max else { throw ModelCatalogRetentionError.migration }
            if progress.phase == "complete" {
                let receipt = try migrationCompletion(sourceFile: sourceFile, progressFile: progressFile, budget: budget)
                try locked(nonblocking: true) { try indexFile.validate(); try receipt.validateLocked(index) }
                return receipt
            }
            if progress.phase == "finalizing" {
                var next = ModelTransactionActiveIndex(schema: "model_catalog_active_index.v3", migrationID: source.migrationID,
                    migrationSourceSHA256: sourceHash, generation: source.sourceGeneration + 1,
                    entries: progress.entries.map { .init(id: $0.id, phase: $0.phase, originSHA256: $0.originSHA256, provenance: $0.provenance) })
                next.entries.sort { $0.id < $1.id }
                let bytes = try canonicalData(next)
                guard digest(bytes) == progress.intendedIndexSHA256, next.generation == progress.intendedIndexGeneration,
                      indexFile.sha256 == source.sourceSHA256 || indexFile.sha256 == progress.intendedIndexSHA256 else { throw ModelCatalogRetentionError.migration }
                progress.phase = "complete"; progress.generation += 1
                let completedBytes = try canonicalData(progress)
                try locked(nonblocking: true) {
                    try sourceFile.validate(); try progressFile.validate(); try indexFile.validate(); try budget.check()
                    if indexFile.sha256 != digest(bytes) { try retentionDirectory().write(bytes, name: "active.json", maxBytes: Self.indexLimit) }
                    try retentionBoundary("binding_migration_index")
                    try budget.check()
                    try migrationDirectory().write(completedBytes, name: "progress.json", maxBytes: Self.indexLimit)
                    try retentionBoundary("binding_migration_complete")
                }
                let completedFile = try recaptureMigrationProgress(completedBytes, budget: budget)
                return ModelTransactionMigrationCompletionReceipt(sourceFile: sourceFile, progressFile: completedFile,
                    migrationID: progress.migrationID, sourceSHA256: sourceHash,
                    initialGeneration: next.generation, budget: budget)
            }
            guard indexFile.sha256 == source.sourceSHA256 else { throw ModelCatalogRetentionError.migration }
            if progress.entries.count == source.entries.count {
                let next = ModelTransactionActiveIndex(schema: "model_catalog_active_index.v3", migrationID: source.migrationID,
                    migrationSourceSHA256: sourceHash, generation: source.sourceGeneration + 1,
                    entries: progress.entries.map { .init(id: $0.id, phase: $0.phase, originSHA256: $0.originSHA256, provenance: $0.provenance) })
                progress.phase = "finalizing"; progress.intendedIndexSHA256 = digest(try canonicalData(next))
                progress.intendedIndexGeneration = next.generation; progress.generation += 1
                let bytes = try canonicalData(progress)
                try locked(nonblocking: true) {
                    try sourceFile.validate(); try progressFile.validate(); try indexFile.validate(); try budget.check()
                    try migrationDirectory().write(bytes, name: "progress.json", maxBytes: Self.indexLimit)
                    try retentionBoundary("binding_migration_finalizing")
                }
                progressFile = try recaptureMigrationProgress(bytes, budget: budget)
                continue
            }
            let id = source.entries[progress.entries.count].id
            if heldID != id { heldOwner = try ownerLock(id); heldID = id }
            let capture = try migrationCapture(id, budget: budget)
            let originFile = try evidence(id + ".origin", budget: budget, maxBytes: 16_384)
            if let pending = progress.pending {
                guard try canonicalData(capture.values) == canonicalData(pending.observations),
                      originFile.bytes == nil || originFile.bytes == pending.originBytes else { throw ModelCatalogRetentionError.migration }
                progress.entries.append(pending.entry); progress.pending = nil; progress.generation += 1
                let bytes = try canonicalData(progress)
                try retentionBoundary("migration_acknowledgment_captured")
                try locked(nonblocking: true) {
                    try sourceFile.validate(); try progressFile.validate(); try indexFile.validate(); try capture.validate(self); try originFile.validate(); try budget.check()
                    if originFile.bytes == nil { try rootDirectory.write(pending.originBytes, name: id + ".origin", exclusive: true, maxBytes: 16_384) }
                    try retentionBoundary("binding_migration_origin")
                    try budget.check()
                    try migrationDirectory().write(bytes, name: "progress.json", maxBytes: Self.indexLimit)
                    try retentionBoundary("binding_migration_acknowledged")
                }
                progressFile = try recaptureMigrationProgress(bytes, budget: budget)
                withExtendedLifetime(heldOwner) {}; heldOwner = nil; heldID = nil
            } else {
                guard originFile.bytes == nil else { throw ModelCatalogRetentionError.migration }
                let origin = try migrationOrigin(id: id, capture: capture), bytes = try bindingBytes(origin)
                let entry = ModelTransactionMigrationProgress.Entry(id: id, phase: source.entries[progress.entries.count].phase,
                    provenance: origin.provenance.name, originSHA256: digest(bytes),
                    sourcePrimarySHA256: capture.files.first(where: { $0.name == id + ".json" })?.sha256)
                progress.pending = .init(position: progress.entries.count, entry: entry, originBytes: bytes, observations: capture.values)
                progress.generation += 1
                let progressBytes = try canonicalData(progress)
                try retentionBoundary("migration_decision_captured")
                try locked(nonblocking: true) {
                    try sourceFile.validate(); try progressFile.validate(); try indexFile.validate(); try capture.validate(self); try originFile.validate(); try budget.check()
                    try migrationDirectory().write(progressBytes, name: "progress.json", maxBytes: Self.indexLimit)
                    try retentionBoundary("binding_migration_decision")
                }
                progressFile = try recaptureMigrationProgress(progressBytes, budget: budget)
            }
            try budget.yield(after: progress.entries.count)
        }
    }
}
