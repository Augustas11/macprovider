import Darwin
import Foundation

struct ModelTransactionReservationClass: Codable {
    struct Allocated: Codable {
        let operationGeneration: String
        let kind: String
        let createdAt: Date
        let target: String
        let modelKey: String
        let revision: String
        let sha256: String
        let candidateDigest: String
        let artifactDigest: String
        let signerKeyID: String
        let reuseTupleSHA256: String
    }
    enum Provenance: Codable {
        case allocated(Allocated)
        case legacySnapshot
        case protectedSnapshot

        var name: String {
            switch self {
            case .allocated: return "allocated"
            case .legacySnapshot: return "legacy_snapshot"
            case .protectedSnapshot: return "protected_snapshot"
            }
        }
    }

    let schema: String
    let transactionID: String
    let originSHA256: String
    let provenance: Provenance
}

struct ModelTransactionReservationLeft: Codable {
    let schema: String
    let transactionID: String
    let operationGeneration: String
    let originSHA256: String
    let classSHA256: String
    let firstObservedNonreusablePrimarySHA256: String
    let reason: String
}

private struct ModelTransactionReservationMigrationSource: Codable {
    struct Entry: Codable {
        let id: String
        let originSHA256: String
        let provenance: String
        let allocatedGeneration: String?
    }
    let schema: String
    let migrationID: String
    let originalFormatSHA256: String
    let originalIndexSHA256: String
    let originalIndexGeneration: UInt64
    let bindingMigrationID: String
    let bindingSourceSHA256: String
    let entries: [Entry]
}

private struct ModelTransactionReservationMigrationProgress: Codable {
    struct Entry: Codable {
        let id: String
        let classSHA256: String
        var leftSHA256: String?
    }
    let schema: String
    let migrationID: String
    let sourceSHA256: String
    var generation: UInt64
    var phase: String
    var prefixLength: Int
    var entries: [Entry]
}

private struct ModelTransactionReservationPublication: Codable {
    struct NextEntry: Codable {
        let classSHA256: String
        let leftSHA256: String?
    }
    let schema: String
    let transactionID: String
    let allocatedGeneration: String?
    let migrationID: String
    let sourceSHA256: String
    let oldIndexGeneration: UInt64
    let oldIndexSHA256: String
    let originalPrimarySHA256: String
    let originSHA256: String
    let previousClassSHA256: String?
    let previousLeftSHA256: String?
    let previousProgressSHA256: String
    let classBytes: Data
    let leftBytes: Data?
    let nextEntry: NextEntry
}

private struct ModelTransactionReservationInstall: Codable {
    let schema: String
    let installID: String
    let migrationID: String
    let sourceSHA256: String
    let progressSHA256: String
    let preparedIndexSHA256: String
    let preparedIndexGeneration: UInt64
    let finalizingGeneration: UInt64
    let completedIndexSHA256: String
}

struct ModelTransactionReservationCompletionReceipt {
    let sourceFile: ModelTransactionFileEvidence
    let progressFile: ModelTransactionFileEvidence
    let installFile: ModelTransactionFileEvidence
    let completedIndexFile: ModelTransactionFileEvidence
    let migrationID: String
    let sourceSHA256: String
    let progressSHA256: String
    let installID: String
    let completedGeneration: UInt64
    let budget: ModelTransactionWorkBudget

    func validateFiles() throws {
        try sourceFile.validate()
        try progressFile.validate()
        try installFile.validate()
        try completedIndexFile.validate()
        try budget.check()
    }

    func validateLocked(_ index: ModelTransactionActiveIndex) throws {
        try validateFiles()
        guard index.schema == "model_catalog_active_index.v4",
              index.reservationPhase == "complete",
              index.reservationMigrationID == migrationID,
              index.reservationSourceSHA256 == sourceSHA256,
              index.reservationProgressSHA256 == progressSHA256,
              index.reservationInstallID == installID,
              index.reservationInstallReceiptSHA256 == nil,
              index.generation >= completedGeneration else {
            throw ModelCatalogRetentionError.migration
        }
    }
}

struct ModelTransactionReservationAuthorityReceipt {
    let classification: ModelTransactionReservationClass
    let classFile: ModelTransactionFileEvidence
    let left: ModelTransactionReservationLeft?
    let leftFile: ModelTransactionFileEvidence
    let origin: ModelTransactionOrigin
    let originFile: ModelTransactionFileEvidence
    let migrationSourceFile: ModelTransactionFileEvidence?
    let migrationProgressFile: ModelTransactionFileEvidence?

    var isPermanentlyNonreusable: Bool { left != nil }

    func validateFiles() throws {
        try classFile.validate()
        try leftFile.validate()
        try originFile.validate()
        try migrationSourceFile?.validate()
        try migrationProgressFile?.validate()
    }
}

private final class ModelTransactionNoncreatingOwnerProbe {
    let directory: ModelTransactionDirectory
    let name: String
    let descriptor: Int32?
    let observed: stat?

    init(directory: ModelTransactionDirectory, id: String, budget: ModelTransactionWorkBudget) throws {
        name = ".owner-" + id
        self.directory = directory
        try budget.check()
        guard let metadata = try directory.metadata(name) else {
            descriptor = nil
            observed = nil
            return
        }
        let opened = try directory.openFile(name, flags: O_RDWR)
        do {
            var current = stat()
            guard fstat(opened, &current) == 0,
                  ModelTransactionFileEvidence.same(metadata, current),
                  flock(opened, LOCK_EX | LOCK_NB) == 0 else {
                throw ModelCatalogTransactionError.busy
            }
            descriptor = opened
            observed = current
        } catch {
            close(opened)
            throw error
        }
    }

    deinit {
        if let descriptor {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    func validate() throws {
        let current = try directory.metadata(name)
        guard let descriptor, let observed else {
            guard current == nil else { throw ModelCatalogRetentionError.changed }
            return
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, let current,
              ModelTransactionFileEvidence.same(observed, opened),
              ModelTransactionFileEvidence.same(observed, current) else {
            throw ModelCatalogRetentionError.changed
        }
    }
}

extension ModelCatalogTransactionStore {
    static let reservationClassLimit = 32_768
    static let reservationLeftLimit = 16_384
    static let reservationPublicationLimit = 131_072
    private static let reservationMigrationName = ".reservation-migration"

    private func reservationRoot(create: Bool = false) throws -> ModelTransactionDirectory {
        try ModelTransactionDirectory.current(root).child(Self.reservationMigrationName, create: create)
    }

    private func reservationChild(_ name: String, create: Bool = false) throws -> ModelTransactionDirectory {
        try reservationRoot(create: create).child(name, create: create)
    }

    private func reservationFile(_ directory: ModelTransactionDirectory, name: String, maxBytes: Int,
                                 budget: ModelTransactionWorkBudget) throws -> ModelTransactionFileEvidence {
        try ModelTransactionFileEvidence(directory: directory, name: name, maxBytes: maxBytes, budget: budget,
            observe: { try retentionBoundary("reservation_migration_bulk_read") })
    }

    func requireReservationDigest(_ value: String) throws {
        guard value.count == 64, value == value.lowercased(), value.allSatisfy({ $0.isHexDigit }) else {
            throw ModelCatalogRetentionError.unsafe
        }
    }

    private func reservationTupleBytes(_ allocation: ModelTransactionOrigin.Allocation) throws -> Data {
        struct Tuple: Encodable {
            let domain = "model_catalog_reservation_reuse_tuple.v1"
            let target: String
            let modelKey: String
            let revision: String
            let sha256: String
            let candidateDigest: String
            let artifactDigest: String
            let signerKeyID: String
        }
        return try canonicalData(Tuple(target: allocation.target, modelKey: allocation.modelKey,
            revision: allocation.revision, sha256: allocation.sha256, candidateDigest: allocation.candidateDigest,
            artifactDigest: allocation.artifactDigest, signerKeyID: allocation.signerKeyID))
    }

    func reservationClass(origin: ModelTransactionOrigin, originSHA256: String) throws -> ModelTransactionReservationClass {
        let provenance: ModelTransactionReservationClass.Provenance
        switch origin.provenance {
        case .allocated(let allocation):
            let value = ModelTransactionReservationClass.Allocated(operationGeneration: allocation.operationGeneration,
                kind: allocation.kind, createdAt: allocation.createdAt, target: allocation.target,
                modelKey: allocation.modelKey, revision: allocation.revision, sha256: allocation.sha256,
                candidateDigest: allocation.candidateDigest, artifactDigest: allocation.artifactDigest,
                signerKeyID: allocation.signerKeyID, reuseTupleSHA256: digest(try reservationTupleBytes(allocation)))
            provenance = .allocated(value)
        case .legacySnapshot: provenance = .legacySnapshot
        case .protectedSnapshot: provenance = .protectedSnapshot
        }
        return .init(schema: "model_catalog_reservation_class.v1", transactionID: origin.transactionID,
                     originSHA256: originSHA256, provenance: provenance)
    }

    private func reservationClassBytes(origin: ModelTransactionOrigin, originSHA256: String) throws -> Data {
        let bytes = try canonicalData(reservationClass(origin: origin, originSHA256: originSHA256))
        guard bytes.count <= Self.reservationClassLimit else { throw ModelCatalogRetentionError.unsafe }
        return bytes
    }

    private func validateReservationClass(_ value: ModelTransactionReservationClass, bytes: Data,
                                          id: String, origin: ModelTransactionOrigin,
                                          originSHA256: String) throws {
        guard value.schema == "model_catalog_reservation_class.v1", value.transactionID == id,
              value.originSHA256 == originSHA256,
              bytes == (try reservationClassBytes(origin: origin, originSHA256: originSHA256)) else {
            throw ModelCatalogRetentionError.unsafe
        }
    }

    func initialQueued(_ record: ModelCatalogTransactionRecord,
                       allocation: ModelTransactionOrigin.Allocation) -> Bool {
        record.operationGeneration == allocation.operationGeneration && record.kind == allocation.kind &&
        record.createdAt == allocation.createdAt && record.target == allocation.target &&
        record.modelKey == allocation.modelKey && record.revision == allocation.revision &&
        record.sha256 == allocation.sha256 && record.candidateDigest == allocation.candidateDigest &&
        record.artifactDigest == allocation.artifactDigest && record.signerKeyID == allocation.signerKeyID &&
        record.startedAt == nil && !record.committed && !record.cancelRequested && !record.cleanupRequired &&
        record.events.count == 1 && record.events.first?.state == "queued"
    }

    private func reservationLeftReason(_ record: ModelCatalogTransactionRecord) -> String {
        if record.startedAt != nil { return "started" }
        if record.events.last?.state == "cancelled" || record.cancelRequested { return "cancelled" }
        if record.committed { return "committed" }
        if record.cleanupRequired || record.kind == "cleanup_staging" { return "cleanup" }
        if record.terminal { return "terminal" }
        return "migrated_nonreusable"
    }

    private func reservationLeftBytes(record: ModelCatalogTransactionRecord, origin: ModelTransactionOrigin,
                                      originSHA256: String, classSHA256: String,
                                      primarySHA256: String) throws -> Data? {
        guard case .allocated(let allocation) = origin.provenance,
              !initialQueued(record, allocation: allocation) else { return nil }
        let value = ModelTransactionReservationLeft(schema: "model_catalog_reservation_left.v1",
            transactionID: record.transactionID, operationGeneration: allocation.operationGeneration,
            originSHA256: originSHA256, classSHA256: classSHA256,
            firstObservedNonreusablePrimarySHA256: primarySHA256, reason: reservationLeftReason(record))
        let bytes = try canonicalData(value)
        guard bytes.count <= Self.reservationLeftLimit else { throw ModelCatalogRetentionError.unsafe }
        return bytes
    }

    private func validateReservationLeft(_ value: ModelTransactionReservationLeft, bytes: Data,
                                         id: String, origin: ModelTransactionOrigin, originSHA256: String,
                                         classSHA256: String) throws {
        guard case .allocated(let allocation) = origin.provenance,
              value.schema == "model_catalog_reservation_left.v1", value.transactionID == id,
              value.operationGeneration == allocation.operationGeneration,
              value.originSHA256 == originSHA256, value.classSHA256 == classSHA256,
              ["started", "cancelled", "terminal", "committed", "cleanup", "migrated_nonreusable"].contains(value.reason),
              digest(bytes) == digest(try canonicalData(value)) else { throw ModelCatalogRetentionError.unsafe }
            try requireReservationDigest(value.firstObservedNonreusablePrimarySHA256)
    }

    func captureReservationAuthority(entry: ModelTransactionActiveIndex.Entry,
                                     budget: ModelTransactionWorkBudget,
                                     indexReceipt: ModelTransactionIndexReceipt? = nil) throws
        -> ModelTransactionReservationAuthorityReceipt {
        guard entry.phase == "active", let originHash = entry.originSHA256,
              let classHash = entry.classSHA256 else { throw ModelCatalogRetentionError.unsafe }
        let originFile = try evidence(entry.id + ".origin", budget: budget, maxBytes: 16_384)
        let classFile = try evidence(entry.id + ".reservation-class", budget: budget,
                                     maxBytes: Self.reservationClassLimit)
        let leftFile = try evidence(entry.id + ".reservation-left", budget: budget,
                                    maxBytes: Self.reservationLeftLimit)
        guard let originBytes = originFile.bytes, originFile.sha256 == originHash,
              let classBytes = classFile.bytes, classFile.sha256 == classHash else {
            throw ModelCatalogRetentionError.unsafe
        }
        let origin = try closedDecode(ModelTransactionOrigin.self, originBytes)
        let classification = try closedDecode(ModelTransactionReservationClass.self, classBytes)
        try validateReservationClass(classification, bytes: classBytes, id: entry.id,
                                     origin: origin, originSHA256: originHash)
        let left: ModelTransactionReservationLeft?
        if let expected = entry.leftSHA256 {
            guard let leftBytes = leftFile.bytes, leftFile.sha256 == expected else {
                throw ModelCatalogRetentionError.unsafe
            }
            let decoded = try closedDecode(ModelTransactionReservationLeft.self, leftBytes)
            try validateReservationLeft(decoded, bytes: leftBytes, id: entry.id, origin: origin,
                                        originSHA256: originHash, classSHA256: classHash)
            left = decoded
        } else {
            guard leftFile.bytes == nil else { throw ModelCatalogRetentionError.unsafe }
            left = nil
        }
        var migrationSourceFile: ModelTransactionFileEvidence?
        var migrationProgressFile: ModelTransactionFileEvidence?
        if let indexReceipt, indexReceipt.index.reservationPhase == "classifying" {
            let (source, sourceFile) = try sourceForReservationIndex(indexReceipt.index, budget: budget)
            let (progress, progressFile) = try progressForReservationIndex(indexReceipt.index, source: source,
                                                                           budget: budget)
            guard let sourceEntry = source.entries.first(where: { $0.id == entry.id }),
                  sourceEntry.originSHA256 == entry.originSHA256,
                  sourceEntry.provenance == entry.provenance,
                  let acknowledged = progress.entries.first(where: { $0.id == entry.id }),
                  acknowledged.classSHA256 == entry.classSHA256,
                  acknowledged.leftSHA256 == entry.leftSHA256 else {
                throw ModelCatalogRetentionError.migration
            }
            migrationSourceFile = sourceFile
            migrationProgressFile = progressFile
        }
        return .init(classification: classification, classFile: classFile, left: left,
                     leftFile: leftFile, origin: origin, originFile: originFile,
                     migrationSourceFile: migrationSourceFile, migrationProgressFile: migrationProgressFile)
    }

    func reservationClassMatches(_ classification: ModelTransactionReservationClass,
                                 authority: ModelCatalogTransactionAuthority, kind: String) -> Bool {
        guard case .allocated(let value) = classification.provenance else { return false }
        return value.kind == kind && value.target == authority.row.modelID && value.modelKey == authority.modelKey &&
            value.revision == authority.row.modelRevision && value.sha256 == authority.row.modelSHA256 &&
            value.candidateDigest == authority.candidateDigest && value.artifactDigest == authority.artifactDigest &&
            value.signerKeyID == authority.signerKeyID
    }

    func validateReservationIndexShape(_ index: ModelTransactionActiveIndex) throws {
        guard index.schema == "model_catalog_active_index.v4",
              let migrationID = index.reservationMigrationID,
              let source = index.reservationSourceSHA256,
              let progress = index.reservationProgressSHA256,
              let phase = index.reservationPhase,
              ["classifying", "finalizing", "complete"].contains(phase) else {
            throw ModelCatalogRetentionError.corruptIndex
        }
        try validateID(migrationID)
        try requireReservationDigest(source)
        try requireReservationDigest(progress)
        if phase == "finalizing" {
            guard index.reservationInstallID != nil, index.reservationInstallReceiptSHA256 != nil else {
                throw ModelCatalogRetentionError.corruptIndex
            }
        } else if phase == "classifying" {
            guard index.reservationInstallID == nil, index.reservationInstallReceiptSHA256 == nil,
                  index.entries.allSatisfy({ $0.phase == "active" }) else {
                throw ModelCatalogRetentionError.corruptIndex
            }
        } else {
            guard index.reservationInstallID != nil, index.reservationInstallReceiptSHA256 == nil else {
                throw ModelCatalogRetentionError.corruptIndex
            }
        }
        for entry in index.entries {
            if entry.phase == "allocating" {
                guard phase == "complete", entry.provenance == "allocated",
                      entry.originSHA256 != nil, entry.classSHA256 != nil,
                      entry.allocatedGeneration != nil, entry.initialPrimarySHA256 != nil,
                      entry.leftSHA256 == nil, entry.reservationPublication == nil else {
                    throw ModelCatalogRetentionError.corruptIndex
                }
                continue
            }
            guard entry.phase == "active", entry.originSHA256 != nil, entry.provenance != nil else {
                throw ModelCatalogRetentionError.corruptIndex
            }
            guard entry.allocatedGeneration == nil, entry.initialPrimarySHA256 == nil else {
                throw ModelCatalogRetentionError.corruptIndex
            }
            if phase == "classifying", entry.classSHA256 == nil {
                guard entry.leftSHA256 == nil else { throw ModelCatalogRetentionError.corruptIndex }
            } else if entry.classSHA256 == nil {
                throw ModelCatalogRetentionError.corruptIndex
            }
            if entry.provenance != "allocated", entry.leftSHA256 != nil {
                throw ModelCatalogRetentionError.corruptIndex
            }
            if phase == "finalizing", entry.reservationPublication != nil {
                throw ModelCatalogRetentionError.corruptIndex
            }
            if entry.leftSHA256 != nil, entry.reservationPublication != nil {
                // Pending metadata may add the first immutable left reference;
                // an already-left entry has no legal reservation publication.
                throw ModelCatalogRetentionError.corruptIndex
            }
        }
    }

    private func validateReservationSource(_ source: ModelTransactionReservationMigrationSource,
                                           hash: String) throws {
        guard source.schema == "model_catalog_reservation_migration_source.v1",
              source.entries.count <= Self.activeTransactionLimit,
              Set(source.entries.map(\.id)).count == source.entries.count,
              source.originalIndexGeneration > 0 else { throw ModelCatalogRetentionError.migration }
        try validateID(source.migrationID)
        for hash in [hash, source.originalFormatSHA256, source.originalIndexSHA256, source.bindingSourceSHA256] {
            try requireReservationDigest(hash)
        }
        try validateID(source.bindingMigrationID)
        for (position, entry) in source.entries.enumerated() {
            try validateID(entry.id); try requireReservationDigest(entry.originSHA256)
            guard ["allocated", "legacy_snapshot", "protected_snapshot"].contains(entry.provenance),
                  (entry.provenance == "allocated") == (entry.allocatedGeneration != nil),
                  position == 0 || source.entries[position - 1].id < entry.id else {
                throw ModelCatalogRetentionError.migration
            }
            if let generation = entry.allocatedGeneration { try validateID(generation) }
        }
    }

    private func validateReservationProgress(_ progress: ModelTransactionReservationMigrationProgress,
                                             source: ModelTransactionReservationMigrationSource,
                                             sourceHash: String) throws {
        guard progress.schema == "model_catalog_reservation_migration_progress.v1",
              progress.migrationID == source.migrationID, progress.sourceSHA256 == sourceHash,
              ["classifying", "complete"].contains(progress.phase),
              progress.entries.count <= source.entries.count,
              Set(progress.entries.map(\.id)).count == progress.entries.count else {
            throw ModelCatalogRetentionError.migration
        }
        var acknowledged: [String: ModelTransactionReservationMigrationProgress.Entry] = [:]
        for entry in progress.entries {
            guard source.entries.contains(where: { $0.id == entry.id }) else { throw ModelCatalogRetentionError.migration }
            try requireReservationDigest(entry.classSHA256)
            if let left = entry.leftSHA256 { try requireReservationDigest(left) }
            acknowledged[entry.id] = entry
        }
        var prefix = 0
        while prefix < source.entries.count, acknowledged[source.entries[prefix].id] != nil { prefix += 1 }
        guard progress.prefixLength == prefix,
              progress.generation >= UInt64(progress.entries.count),
              progress.entries.map(\.id) == progress.entries.map(\.id).sorted(),
              progress.phase != "complete" ||
                (prefix == source.entries.count && progress.generation > UInt64(progress.entries.count)) else {
            throw ModelCatalogRetentionError.migration
        }
    }

    private func reservationMigrationSource(indexReceipt: ModelTransactionIndexReceipt,
                                            migration: ModelTransactionMigrationCompletionReceipt) throws
        -> ModelTransactionReservationMigrationSource {
        let index = indexReceipt.index
        return try ModelTransactionReservationMigrationSource(schema: "model_catalog_reservation_migration_source.v1",
            migrationID: UUID().uuidString.lowercased(), originalFormatSHA256: indexReceipt.format.sha256!,
            originalIndexSHA256: indexReceipt.file.sha256!, originalIndexGeneration: index.generation,
            bindingMigrationID: migration.migrationID, bindingSourceSHA256: migration.sourceSHA256,
            entries: index.entries.sorted { $0.id < $1.id }.map { entry in
                guard entry.phase == "active", let origin = entry.originSHA256, let provenance = entry.provenance else {
                    throw ModelCatalogRetentionError.migration
                }
                var generation: String?
                if provenance == "allocated" {
                    let originFile = try evidence(entry.id + ".origin", budget: indexReceipt.budget, maxBytes: 16_384)
                    guard let bytes = originFile.bytes else { throw ModelCatalogRetentionError.unsafe }
                    let decoded = try closedDecode(ModelTransactionOrigin.self, bytes)
                    guard case .allocated(let allocation) = decoded.provenance,
                          originFile.sha256 == origin else { throw ModelCatalogRetentionError.unsafe }
                    generation = allocation.operationGeneration
                }
                return .init(id: entry.id, originSHA256: origin, provenance: provenance,
                             allocatedGeneration: generation)
            })
    }

    private func publishExactImmutable(_ bytes: Data, directory: ModelTransactionDirectory, name: String,
                                       limit: Int, budget: ModelTransactionWorkBudget) throws {
        let evidence = try reservationFile(directory, name: name, maxBytes: limit, budget: budget)
        if let existing = evidence.bytes {
            guard existing == bytes else { throw ModelCatalogRetentionError.unsafe }
            return
        }
        try directory.write(bytes, name: name, exclusive: true, maxBytes: limit)
    }
}

extension ModelCatalogTransactionStore {
    private func captureReservationCompletion(indexReceipt: ModelTransactionIndexReceipt) throws
        -> ModelTransactionReservationCompletionReceipt {
        let budget = indexReceipt.budget
        let index = indexReceipt.index
        try validateReservationIndexShape(index)
        guard index.reservationPhase == "complete", let migrationID = index.reservationMigrationID,
              let sourceHash = index.reservationSourceSHA256,
              let progressHash = index.reservationProgressSHA256,
              let installID = index.reservationInstallID else { throw ModelCatalogRetentionError.migration }
        let sources = try reservationChild("sources")
        let installs = try reservationChild("installs")
        let sourceFile = try reservationFile(sources, name: migrationID + ".json", maxBytes: Self.indexLimit, budget: budget)
        let progressFile = try reservationFile(reservationRoot(), name: "progress.json", maxBytes: Self.indexLimit, budget: budget)
        let installFile = try reservationFile(installs, name: installID + ".json", maxBytes: 16_384, budget: budget)
        let completedFile = try reservationFile(installs, name: installID + ".active.json", maxBytes: Self.indexLimit, budget: budget)
        guard let sourceBytes = sourceFile.bytes, sourceFile.sha256 == sourceHash,
              let progressBytes = progressFile.bytes, progressFile.sha256 == progressHash,
              let installBytes = installFile.bytes, let completedBytes = completedFile.bytes else {
            throw ModelCatalogRetentionError.migration
        }
        let source = try closedDecode(ModelTransactionReservationMigrationSource.self, sourceBytes)
        let progress = try closedDecode(ModelTransactionReservationMigrationProgress.self, progressBytes)
        let install = try closedDecode(ModelTransactionReservationInstall.self, installBytes)
        let completed = try decodeActiveIndex(completedBytes, format: indexReceipt.format.bytes!)
        try validateReservationSource(source, hash: sourceHash)
        try validateReservationProgress(progress, source: source, sourceHash: sourceHash)
        guard progress.phase == "complete", install.schema == "model_catalog_reservation_install.v1",
              install.installID == installID, install.migrationID == migrationID,
              install.sourceSHA256 == sourceHash, install.progressSHA256 == progressHash,
              install.completedIndexSHA256 == completedFile.sha256,
              completed.schema == "model_catalog_active_index.v4", completed.reservationPhase == "complete",
              completed.reservationInstallID == installID,
              completed.reservationInstallReceiptSHA256 == nil,
              completed.generation == install.finalizingGeneration + 1,
              install.preparedIndexGeneration + 1 == install.finalizingGeneration else {
            throw ModelCatalogRetentionError.migration
        }
        return .init(sourceFile: sourceFile, progressFile: progressFile, installFile: installFile,
            completedIndexFile: completedFile, migrationID: migrationID, sourceSHA256: sourceHash,
            progressSHA256: progressHash, installID: installID, completedGeneration: completed.generation,
            budget: budget)
    }

    func captureReservationMigrationCompletion(indexReceipt: ModelTransactionIndexReceipt) throws
        -> ModelTransactionReservationCompletionReceipt {
        try captureReservationCompletion(indexReceipt: indexReceipt)
    }

    private func sourceForReservationIndex(_ index: ModelTransactionActiveIndex,
                                           budget: ModelTransactionWorkBudget) throws
        -> (ModelTransactionReservationMigrationSource, ModelTransactionFileEvidence) {
        guard let migrationID = index.reservationMigrationID,
              let sourceHash = index.reservationSourceSHA256 else { throw ModelCatalogRetentionError.migration }
        let file = try reservationFile(reservationChild("sources"), name: migrationID + ".json",
                                       maxBytes: Self.indexLimit, budget: budget)
        guard let bytes = file.bytes, file.sha256 == sourceHash else { throw ModelCatalogRetentionError.migration }
        let source = try closedDecode(ModelTransactionReservationMigrationSource.self, bytes)
        try validateReservationSource(source, hash: sourceHash)
        return (source, file)
    }

    private func progressForReservationIndex(_ index: ModelTransactionActiveIndex,
                                             source: ModelTransactionReservationMigrationSource,
                                             budget: ModelTransactionWorkBudget) throws
        -> (ModelTransactionReservationMigrationProgress, ModelTransactionFileEvidence) {
        guard let expected = index.reservationProgressSHA256,
              let sourceHash = index.reservationSourceSHA256 else { throw ModelCatalogRetentionError.migration }
        let file = try reservationFile(reservationRoot(), name: "progress.json", maxBytes: Self.indexLimit, budget: budget)
        guard let bytes = file.bytes else { throw ModelCatalogRetentionError.migration }
        let progress = try closedDecode(ModelTransactionReservationMigrationProgress.self, bytes)
        try validateReservationProgress(progress, source: source, sourceHash: sourceHash)
        if file.sha256 != expected {
            let pending = index.entries.contains { $0.reservationPublication != nil }
            let completedAhead = index.reservationPhase == "classifying" && progress.phase == "complete" &&
                index.entries.allSatisfy { $0.phase == "active" && $0.classSHA256 != nil && $0.reservationPublication == nil }
            guard pending || completedAhead else { throw ModelCatalogRetentionError.migration }
        }
        return (progress, file)
    }

    private func reservationCutover(binding: ModelTransactionMigrationCompletionReceipt,
                                    indexReceipt: ModelTransactionIndexReceipt) throws -> ModelTransactionIndexReceipt {
        let budget = indexReceipt.budget
        let current = indexReceipt.index
        guard current.schema == "model_catalog_active_index.v3",
              current.entries.allSatisfy({ $0.phase == "active" }),
              current.generation < UInt64.max else { throw ModelCatalogRetentionError.migration }
        let rootDirectory = try ModelTransactionDirectory.current(root)
        let reservation = try reservationRoot(create: true)
        let sources = try reservationChild("sources", create: true)
        _ = try reservationChild("installs", create: true)
        _ = try reservationChild("receipts", create: true)

        let formatValue = try closedDecode(ModelTransactionRetentionFormat.self, indexReceipt.format.bytes!)
        let source: ModelTransactionReservationMigrationSource
        let sourceBytes: Data
        let formatBytes: Data
        let sourceName: String
        let sourceAlreadyPublished: Bool
        if formatValue.schema == "model_catalog_retention.v3" {
            guard let migrationID = formatValue.reservationMigrationID,
                  let sourceHash = formatValue.reservationSourceSHA256 else { throw ModelCatalogRetentionError.migration }
            sourceName = migrationID + ".json"
            let file = try reservationFile(sources, name: sourceName, maxBytes: Self.indexLimit, budget: budget)
            guard let bytes = file.bytes, file.sha256 == sourceHash else { throw ModelCatalogRetentionError.migration }
            source = try closedDecode(ModelTransactionReservationMigrationSource.self, bytes)
            sourceBytes = bytes
            try validateReservationSource(source, hash: sourceHash)
            guard source.originalIndexSHA256 == indexReceipt.file.sha256,
                  source.originalIndexGeneration == current.generation else { throw ModelCatalogRetentionError.migration }
            formatBytes = indexReceipt.format.bytes!
            sourceAlreadyPublished = true
        } else {
            guard formatValue.schema == "model_catalog_retention.v2" else { throw ModelCatalogRetentionError.migration }
            source = try reservationMigrationSource(indexReceipt: indexReceipt, migration: binding)
            sourceBytes = try canonicalData(source)
            guard sourceBytes.count <= Self.indexLimit else { throw ModelCatalogRetentionError.capacity }
            sourceName = source.migrationID + ".json"
            formatBytes = try canonicalData(ModelTransactionRetentionFormat(schema: "model_catalog_retention.v3",
                reservationMigrationID: source.migrationID, reservationSourceSHA256: digest(sourceBytes)))
            sourceAlreadyPublished = false
        }
        let sourceHash = digest(sourceBytes)
        let progress = ModelTransactionReservationMigrationProgress(schema: "model_catalog_reservation_migration_progress.v1",
            migrationID: source.migrationID, sourceSHA256: sourceHash, generation: 0,
            phase: "classifying", prefixLength: 0, entries: [])
        let progressBytes = try canonicalData(progress)
        var next = current
        next.schema = "model_catalog_active_index.v4"
        next.reservationMigrationID = source.migrationID
        next.reservationSourceSHA256 = sourceHash
        next.reservationProgressSHA256 = digest(progressBytes)
        next.reservationPhase = "classifying"
        next.reservationInstallID = nil
        next.reservationInstallReceiptSHA256 = nil
        next.generation += 1
        for position in next.entries.indices {
            next.entries[position].classSHA256 = nil
            next.entries[position].leftSHA256 = nil
            next.entries[position].reservationPublication = nil
            next.entries[position].allocatedGeneration = nil
            next.entries[position].initialPrimarySHA256 = nil
        }
        try validateReservationIndexShape(next)
        let nextBytes = try canonicalData(next)
        guard nextBytes.count <= Self.indexLimit else { throw ModelCatalogRetentionError.capacity }

        var probes: [ModelTransactionNoncreatingOwnerProbe] = []
        for (position, entry) in current.entries.sorted(by: { $0.id < $1.id }).enumerated() {
            try budget.yield(after: position)
            probes.append(try ModelTransactionNoncreatingOwnerProbe(directory: rootDirectory, id: entry.id, budget: budget))
        }
        try locked(nonblocking: true) {
            try indexReceipt.validateLocked(store: self, requireCompleted: false)
            for probe in probes { try probe.validate() }
            try budget.check()
            if !sourceAlreadyPublished {
                guard try sources.metadata(sourceName) == nil else { throw ModelCatalogRetentionError.changed }
                try sources.write(sourceBytes, name: sourceName, exclusive: true, maxBytes: Self.indexLimit)
                try retentionBoundary("reservation_migration_source")
            }
            try budget.check()
            if formatValue.schema == "model_catalog_retention.v2" {
                try retentionDirectory().write(formatBytes, name: "format.json", maxBytes: 4_096)
                try retentionBoundary("reservation_migration_format")
            }
            try budget.check()
            if try reservation.metadata("progress.json") != nil {
                let existing = try reservation.read("progress.json", maxBytes: Self.indexLimit)
                guard existing == progressBytes else { throw ModelCatalogRetentionError.migration }
            } else {
                try reservation.write(progressBytes, name: "progress.json", exclusive: true, maxBytes: Self.indexLimit)
                try retentionBoundary("reservation_migration_progress")
            }
            try budget.check()
            try retentionDirectory().write(nextBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("reservation_migration_index")
        }
        return try captureIndexReceipt(budget: budget, migration: binding, requireCompleted: false)
    }

    private func reservationClassifyOne(indexReceipt: ModelTransactionIndexReceipt,
                                        source: ModelTransactionReservationMigrationSource,
                                        sourceFile: ModelTransactionFileEvidence,
                                        progress: ModelTransactionReservationMigrationProgress,
                                        progressFile: ModelTransactionFileEvidence,
                                        id: String,
                                        heldOwner: ModelCatalogFileLock? = nil) throws -> ModelTransactionIndexReceipt {
        let budget = indexReceipt.budget
        let acquiredOwner: ModelCatalogFileLock?
        if let heldOwner {
            guard heldOwner.resourceName == ".owner-" + id else { throw ModelCatalogRetentionError.unsafe }
            acquiredOwner = nil
        } else {
            acquiredOwner = try ownerLock(id)
        }
        defer { withExtendedLifetime(heldOwner) {}; withExtendedLifetime(acquiredOwner) {} }
        guard let entryPosition = indexReceipt.index.entries.firstIndex(where: { $0.id == id && $0.phase == "active" }),
              let sourceEntry = source.entries.first(where: { $0.id == id }) else {
            throw ModelCatalogRetentionError.migration
        }
        if indexReceipt.index.entries[entryPosition].reservationPublication != nil {
            return try recoverReservationPublication(indexReceipt: indexReceipt, source: source,
                                                      sourceFile: sourceFile, progress: progress,
                                                      progressFile: progressFile, id: id)
        }
        let primary = try evidence(id + ".json", budget: budget)
        let originFile = try evidence(id + ".origin", budget: budget, maxBytes: 16_384)
        let classFile = try evidence(id + ".reservation-class", budget: budget, maxBytes: Self.reservationClassLimit)
        let leftFile = try evidence(id + ".reservation-left", budget: budget, maxBytes: Self.reservationLeftLimit)
        guard let primaryBytes = primary.bytes, let originBytes = originFile.bytes,
              originFile.sha256 == sourceEntry.originSHA256 else { throw ModelCatalogRetentionError.unsafe }
        let record = try decodeRetentionRecord(primaryBytes, id: id)
        let origin = try closedDecode(ModelTransactionOrigin.self, originBytes)
        guard origin.transactionID == id, origin.provenance.name == sourceEntry.provenance else {
            throw ModelCatalogRetentionError.unsafe
        }
        let classBytes = try reservationClassBytes(origin: origin, originSHA256: sourceEntry.originSHA256)
        let classHash = digest(classBytes)
        let leftBytes = try reservationLeftBytes(record: record, origin: origin, originSHA256: sourceEntry.originSHA256,
                                                 classSHA256: classHash, primarySHA256: primary.sha256!)
        guard classFile.bytes == nil, leftFile.bytes == nil else { throw ModelCatalogRetentionError.unsafe }
        return try publishReservationMetadata(indexReceipt: indexReceipt, source: source, sourceFile: sourceFile,
                                              progress: progress, progressFile: progressFile, primary: primary,
                                              originFile: originFile, classBytes: classBytes, leftBytes: leftBytes,
                                              id: id)
    }

    private func receiptDirectory(id: String, create: Bool) throws -> ModelTransactionDirectory {
        try validateID(id)
        return try reservationChild("receipts", create: create).child(id, create: create)
    }

    func reservationReceiptDirectoryExists(_ id: String) throws -> Bool {
        try validateID(id)
        let root = try ModelTransactionDirectory.current(root)
        guard try root.metadata(Self.reservationMigrationName) != nil else { return false }
        let migration = try root.child(Self.reservationMigrationName)
        guard try migration.metadata("receipts") != nil else { return false }
        return try migration.child("receipts").metadata(id) != nil
    }

    private func publishReservationMetadata(indexReceipt: ModelTransactionIndexReceipt,
                                            source: ModelTransactionReservationMigrationSource,
                                            sourceFile: ModelTransactionFileEvidence,
                                            progress: ModelTransactionReservationMigrationProgress,
                                            progressFile: ModelTransactionFileEvidence,
                                            primary: ModelTransactionFileEvidence,
                                            originFile: ModelTransactionFileEvidence,
                                            classBytes: Data, leftBytes: Data?, id: String) throws
        -> ModelTransactionIndexReceipt {
        let budget = indexReceipt.budget
        guard let position = indexReceipt.index.entries.firstIndex(where: { $0.id == id }),
              let primaryHash = primary.sha256, let originHash = originFile.sha256,
              let oldIndexHash = indexReceipt.file.sha256,
              let previousProgressHash = indexReceipt.index.reservationProgressSHA256 else {
            throw ModelCatalogRetentionError.unsafe
        }
        let classHash = digest(classBytes), leftHash = leftBytes.map(digest)
        let oldEntry = indexReceipt.index.entries[position]
        let decodedClass = try closedDecode(ModelTransactionReservationClass.self, classBytes)
        let allocatedGeneration: String?
        if case .allocated(let allocated) = decodedClass.provenance { allocatedGeneration = allocated.operationGeneration }
        else { allocatedGeneration = nil }
        let publication = ModelTransactionReservationPublication(schema: "model_catalog_reservation_publication.v1",
            transactionID: id, allocatedGeneration: allocatedGeneration,
            migrationID: source.migrationID, sourceSHA256: sourceFile.sha256!, oldIndexGeneration: indexReceipt.index.generation,
            oldIndexSHA256: oldIndexHash, originalPrimarySHA256: primaryHash, originSHA256: originHash,
            previousClassSHA256: oldEntry.classSHA256, previousLeftSHA256: oldEntry.leftSHA256,
            previousProgressSHA256: previousProgressHash, classBytes: classBytes, leftBytes: leftBytes,
            nextEntry: .init(classSHA256: classHash, leftSHA256: leftHash ?? oldEntry.leftSHA256))
        let receiptBytes = try canonicalData(publication)
        guard receiptBytes.count <= Self.reservationPublicationLimit else { throw ModelCatalogRetentionError.capacity }
        let receiptHash = digest(receiptBytes), receiptName = receiptHash + ".json"
        var pendingIndex = indexReceipt.index
        pendingIndex.generation += 1
        pendingIndex.entries[position].reservationPublication = receiptHash
        let pendingBytes = try canonicalData(pendingIndex)
        guard pendingBytes.count <= Self.indexLimit else { throw ModelCatalogRetentionError.capacity }
        let receipts = try reservationChild("receipts", create: true)
        let existingDirectory = try receipts.metadata(id)
        let transactionReceipts: ModelTransactionDirectory
        if existingDirectory == nil { transactionReceipts = try receipts.child(id, create: true) }
        else { transactionReceipts = try receipts.child(id) }
        try locked(nonblocking: true) {
            try indexReceipt.validateLocked(store: self, requireCompleted: false)
            try sourceFile.validate(); try progressFile.validate(); try primary.validate(); try originFile.validate()
            try budget.check()
            let existing = try transactionReceipts.metadata(receiptName)
            if existing == nil {
                try transactionReceipts.write(receiptBytes, name: receiptName, exclusive: true,
                                              maxBytes: Self.reservationPublicationLimit)
            } else {
                guard try transactionReceipts.read(receiptName, maxBytes: Self.reservationPublicationLimit) == receiptBytes else {
                    throw ModelCatalogRetentionError.unsafe
                }
            }
            try retentionBoundary("reservation_publication_receipt")
            try budget.check()
            try retentionDirectory().write(pendingBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("reservation_publication_intent")
        }
        let pendingReceipt = try captureIndexReceipt(budget: budget, migration: indexReceipt.migration, requireCompleted: false)
        let (latestProgress, latestProgressFile) = try progressForReservationIndex(pendingReceipt.index, source: source, budget: budget)
        return try recoverReservationPublication(indexReceipt: pendingReceipt, source: source,
                                                  sourceFile: sourceFile, progress: latestProgress,
                                                  progressFile: latestProgressFile, id: id)
    }

    private func recoverReservationPublication(indexReceipt: ModelTransactionIndexReceipt,
                                               source: ModelTransactionReservationMigrationSource,
                                               sourceFile: ModelTransactionFileEvidence,
                                               progress: ModelTransactionReservationMigrationProgress,
                                               progressFile: ModelTransactionFileEvidence,
                                               id: String) throws -> ModelTransactionIndexReceipt {
        let budget = indexReceipt.budget
        guard let position = indexReceipt.index.entries.firstIndex(where: { $0.id == id }),
              let receiptHash = indexReceipt.index.entries[position].reservationPublication else {
            return indexReceipt
        }
        try requireReservationDigest(receiptHash)
        let receiptDirectory = try self.receiptDirectory(id: id, create: false)
        let receiptFile = try reservationFile(receiptDirectory, name: receiptHash + ".json",
                                              maxBytes: Self.reservationPublicationLimit, budget: budget)
        guard let bytes = receiptFile.bytes, receiptFile.sha256 == receiptHash else {
            throw ModelCatalogRetentionError.unsafe
        }
        let publication = try closedDecode(ModelTransactionReservationPublication.self, bytes)
        let entry = indexReceipt.index.entries[position]
        guard publication.schema == "model_catalog_reservation_publication.v1",
              publication.transactionID == id, publication.migrationID == source.migrationID,
              publication.sourceSHA256 == sourceFile.sha256,
              publication.oldIndexGeneration < indexReceipt.index.generation,
              publication.originSHA256 == entry.originSHA256,
              publication.previousClassSHA256 == entry.classSHA256,
              publication.previousLeftSHA256 == entry.leftSHA256,
              publication.nextEntry.classSHA256 == digest(publication.classBytes),
              publication.nextEntry.leftSHA256 == publication.leftBytes.map(digest) ?? entry.leftSHA256 else {
            throw ModelCatalogRetentionError.unsafe
        }
        let primary = try evidence(id + ".json", budget: budget)
        let originFile = try evidence(id + ".origin", budget: budget, maxBytes: 16_384)
        guard primary.sha256 == publication.originalPrimarySHA256,
              originFile.sha256 == publication.originSHA256,
              let originBytes = originFile.bytes else { throw ModelCatalogRetentionError.unsafe }
        let origin = try closedDecode(ModelTransactionOrigin.self, originBytes)
        let decodedClass = try closedDecode(ModelTransactionReservationClass.self, publication.classBytes)
        try validateReservationClass(decodedClass, bytes: publication.classBytes, id: id,
                                     origin: origin, originSHA256: publication.originSHA256)
        let decodedGeneration: String?
        if case .allocated(let allocated) = decodedClass.provenance {
            decodedGeneration = allocated.operationGeneration
        } else {
            decodedGeneration = nil
        }
        guard decodedGeneration == publication.allocatedGeneration else {
            throw ModelCatalogRetentionError.unsafe
        }
        if let leftBytes = publication.leftBytes {
            let decodedLeft = try closedDecode(ModelTransactionReservationLeft.self, leftBytes)
            try validateReservationLeft(decodedLeft, bytes: leftBytes, id: id, origin: origin,
                                        originSHA256: publication.originSHA256,
                                        classSHA256: publication.nextEntry.classSHA256)
        }
        let classFile = try evidence(id + ".reservation-class", budget: budget, maxBytes: Self.reservationClassLimit)
        let leftFile = try evidence(id + ".reservation-left", budget: budget, maxBytes: Self.reservationLeftLimit)
        if let existing = classFile.bytes { guard existing == publication.classBytes else { throw ModelCatalogRetentionError.unsafe } }
        if let existing = leftFile.bytes { guard existing == publication.leftBytes else { throw ModelCatalogRetentionError.unsafe } }
        var nextProgress = progress
        if indexReceipt.index.reservationPhase == "classifying" {
            if let acknowledged = nextProgress.entries.firstIndex(where: { $0.id == id }) {
                let previous = nextProgress.entries[acknowledged]
                guard previous.classSHA256 == publication.nextEntry.classSHA256 else {
                    throw ModelCatalogRetentionError.migration
                }
                if previous.leftSHA256 != publication.nextEntry.leftSHA256 {
                    guard previous.leftSHA256 == publication.previousLeftSHA256,
                          previous.leftSHA256 == nil else {
                        throw ModelCatalogRetentionError.migration
                    }
                    nextProgress.entries[acknowledged].leftSHA256 = publication.nextEntry.leftSHA256
                    nextProgress.generation += 1
                }
            } else {
                nextProgress.entries.append(.init(id: id, classSHA256: publication.nextEntry.classSHA256,
                                                  leftSHA256: publication.nextEntry.leftSHA256))
                nextProgress.entries.sort { $0.id < $1.id }
                let acknowledged = Set(nextProgress.entries.map(\.id))
                nextProgress.prefixLength = source.entries.prefix { acknowledged.contains($0.id) }.count
                nextProgress.generation += 1
            }
        }
        let progressBytes = try canonicalData(nextProgress)
        var nextIndex = indexReceipt.index
        nextIndex.generation += 1
        nextIndex.entries[position].classSHA256 = publication.nextEntry.classSHA256
        nextIndex.entries[position].leftSHA256 = publication.nextEntry.leftSHA256
        nextIndex.entries[position].reservationPublication = nil
        nextIndex.reservationProgressSHA256 = digest(progressBytes)
        let indexBytes = try canonicalData(nextIndex)
        guard progressBytes.count <= Self.indexLimit, indexBytes.count <= Self.indexLimit else {
            throw ModelCatalogRetentionError.capacity
        }
        try locked(nonblocking: true) {
            try indexReceipt.validateLocked(store: self, requireCompleted: false)
            try sourceFile.validate(); try progressFile.validate(); try receiptFile.validate()
            try primary.validate(); try originFile.validate(); try classFile.validate(); try leftFile.validate()
            let directory = try ModelTransactionDirectory.current(root)
            try budget.check()
            if classFile.bytes == nil {
                try directory.write(publication.classBytes, name: id + ".reservation-class", exclusive: true,
                                    maxBytes: Self.reservationClassLimit)
            }
            try retentionBoundary("reservation_class_published")
            if let leftBytes = publication.leftBytes, leftFile.bytes == nil {
                try directory.write(leftBytes, name: id + ".reservation-left", exclusive: true,
                                    maxBytes: Self.reservationLeftLimit)
            }
            try retentionBoundary("reservation_left_published")
            try budget.check()
            if indexReceipt.index.reservationPhase == "classifying", progressFile.bytes != progressBytes {
                try reservationRoot().write(progressBytes, name: "progress.json", maxBytes: Self.indexLimit)
                try retentionBoundary("reservation_progress_acknowledged")
            }
            try budget.check()
            try retentionDirectory().write(indexBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("reservation_publication_complete")
        }
        return try captureIndexReceipt(budget: budget, migration: indexReceipt.migration,
                                       requireCompleted: nextIndex.reservationPhase == "complete")
    }

    func recoverReservationPublicationIfNeeded(indexReceipt: ModelTransactionIndexReceipt,
                                               id: String, heldOwner: ModelCatalogFileLock? = nil) throws
        -> ModelTransactionIndexReceipt {
        guard indexReceipt.index.entries.first(where: { $0.id == id })?.reservationPublication != nil else {
            return indexReceipt
        }
        if let heldOwner, heldOwner.resourceName != ".owner-" + id {
            throw ModelCatalogRetentionError.unsafe
        }
        let acquiredOwner = heldOwner == nil ? try ownerLock(id) : nil
        defer { withExtendedLifetime(acquiredOwner) {} }
        let (source, sourceFile) = try sourceForReservationIndex(indexReceipt.index, budget: indexReceipt.budget)
        let (progress, progressFile) = try progressForReservationIndex(indexReceipt.index, source: source,
                                                                       budget: indexReceipt.budget)
        return try recoverReservationPublication(indexReceipt: indexReceipt, source: source,
                                                  sourceFile: sourceFile, progress: progress,
                                                  progressFile: progressFile, id: id)
    }

    @discardableResult
    func publishReservationDeparture(record: ModelCatalogTransactionRecord,
                                     primary: ModelTransactionFileEvidence,
                                     indexReceipt supplied: ModelTransactionIndexReceipt) throws
        -> ModelTransactionIndexReceipt {
        var indexReceipt = try recoverReservationPublicationIfNeeded(indexReceipt: supplied,
                                                                     id: record.transactionID)
        guard let entry = indexReceipt.index.entries.first(where: { $0.id == record.transactionID && $0.phase == "active" }) else {
            throw ModelCatalogRetentionError.changed
        }
        let authority = try captureReservationAuthority(entry: entry, budget: indexReceipt.budget,
                                                        indexReceipt: indexReceipt)
        if authority.left != nil { return indexReceipt }
        guard case .allocated(let allocation) = authority.origin.provenance else { return indexReceipt }
        if initialQueued(record, allocation: allocation) { return indexReceipt }
        guard let primaryHash = primary.sha256, let classHash = entry.classSHA256,
              let classBytes = authority.classFile.bytes else { throw ModelCatalogRetentionError.unsafe }
        let leftBytes = try reservationLeftBytes(record: record, origin: authority.origin,
                                                 originSHA256: authority.originFile.sha256!,
                                                 classSHA256: classHash, primarySHA256: primaryHash)
        guard leftBytes != nil else { throw ModelCatalogRetentionError.unsafe }
        let (source, sourceFile) = try sourceForReservationIndex(indexReceipt.index, budget: indexReceipt.budget)
        let (progress, progressFile) = try progressForReservationIndex(indexReceipt.index, source: source,
                                                                       budget: indexReceipt.budget)
        indexReceipt = try publishReservationMetadata(indexReceipt: indexReceipt, source: source,
            sourceFile: sourceFile, progress: progress, progressFile: progressFile, primary: primary,
            originFile: authority.originFile, classBytes: classBytes, leftBytes: leftBytes,
            id: record.transactionID)
        return indexReceipt
    }

    private func finalizeReservationMigration(indexReceipt: ModelTransactionIndexReceipt,
                                              source: ModelTransactionReservationMigrationSource,
                                              sourceFile: ModelTransactionFileEvidence,
                                              progress: ModelTransactionReservationMigrationProgress,
                                              progressFile: ModelTransactionFileEvidence) throws
        -> ModelTransactionIndexReceipt {
        let budget = indexReceipt.budget
        let index = indexReceipt.index
        guard index.reservationPhase == "classifying", index.generation < UInt64.max - 1,
              index.entries.allSatisfy({ $0.phase == "active" && $0.classSHA256 != nil && $0.reservationPublication == nil }),
              source.entries.count == index.entries.count else { throw ModelCatalogRetentionError.migration }
        var authorities: [ModelTransactionReservationAuthorityReceipt] = []
        for sourceEntry in source.entries {
            guard let entry = index.entries.first(where: { $0.id == sourceEntry.id }),
                  entry.originSHA256 == sourceEntry.originSHA256,
                  entry.provenance == sourceEntry.provenance,
                  let acknowledged = progress.entries.first(where: { $0.id == sourceEntry.id }),
                  acknowledged.classSHA256 == entry.classSHA256,
                  acknowledged.leftSHA256 == entry.leftSHA256 else { throw ModelCatalogRetentionError.migration }
            // Source/progress membership was checked immediately above and the
            // exact source/progress evidence is validated again at publication.
            // Avoid decoding both full migration documents once per UUID while
            // validating the immutable per-entry authority graph.
            authorities.append(try captureReservationAuthority(entry: entry, budget: budget))
        }
        var completedProgress = progress
        completedProgress.phase = "complete"
        completedProgress.generation += 1
        completedProgress.prefixLength = source.entries.count
        let completedProgressBytes = try canonicalData(completedProgress)
        let completedProgressHash = digest(completedProgressBytes)
        let installID = UUID().uuidString.lowercased()

        var completed = index
        completed.generation += 2
        completed.reservationPhase = "complete"
        completed.reservationProgressSHA256 = completedProgressHash
        completed.reservationInstallID = installID
        completed.reservationInstallReceiptSHA256 = nil
        let completedBytes = try canonicalData(completed)
        let completedHash = digest(completedBytes)
        let install = ModelTransactionReservationInstall(schema: "model_catalog_reservation_install.v1",
            installID: installID, migrationID: source.migrationID, sourceSHA256: sourceFile.sha256!,
            progressSHA256: completedProgressHash, preparedIndexSHA256: indexReceipt.file.sha256!,
            preparedIndexGeneration: index.generation, finalizingGeneration: index.generation + 1,
            completedIndexSHA256: completedHash)
        let installBytes = try canonicalData(install), installHash = digest(installBytes)
        var finalizing = completed
        finalizing.generation = index.generation + 1
        finalizing.reservationPhase = "finalizing"
        finalizing.reservationInstallReceiptSHA256 = installHash
        let finalizingBytes = try canonicalData(finalizing)
        guard completedProgressBytes.count <= Self.indexLimit, completedBytes.count <= Self.indexLimit,
              finalizingBytes.count <= Self.indexLimit, installBytes.count <= 16_384 else {
            throw ModelCatalogRetentionError.capacity
        }
        let installs = try reservationChild("installs", create: true)
        try locked(nonblocking: true) {
            try indexReceipt.validateLocked(store: self, requireCompleted: false)
            try sourceFile.validate(); try progressFile.validate()
            for authority in authorities { try authority.validateFiles() }
            try budget.check()
            try reservationRoot().write(completedProgressBytes, name: "progress.json", maxBytes: Self.indexLimit)
            try retentionBoundary("reservation_migration_progress_complete")
            try installs.write(completedBytes, name: installID + ".active.json", exclusive: true, maxBytes: Self.indexLimit)
            try installs.write(installBytes, name: installID + ".json", exclusive: true, maxBytes: 16_384)
            try retentionBoundary("reservation_migration_install_prepared")
            try budget.check()
            try retentionDirectory().write(finalizingBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("reservation_migration_finalizing")
            try budget.check()
            try retentionDirectory().write(completedBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("reservation_migration_complete")
        }
        return try captureIndexReceipt(budget: budget, migration: indexReceipt.migration, requireCompleted: true)
    }

    private func recoverReservationFinalizing(indexReceipt: ModelTransactionIndexReceipt) throws
        -> ModelTransactionIndexReceipt {
        let budget = indexReceipt.budget
        let index = indexReceipt.index
        try validateReservationIndexShape(index)
        guard index.reservationPhase == "finalizing", let installID = index.reservationInstallID,
              let expectedInstallHash = index.reservationInstallReceiptSHA256 else {
            throw ModelCatalogRetentionError.migration
        }
        let installs = try reservationChild("installs")
        let installFile = try reservationFile(installs, name: installID + ".json", maxBytes: 16_384, budget: budget)
        let completedFile = try reservationFile(installs, name: installID + ".active.json", maxBytes: Self.indexLimit, budget: budget)
        guard let installBytes = installFile.bytes, installFile.sha256 == expectedInstallHash,
              let completedBytes = completedFile.bytes else { throw ModelCatalogRetentionError.migration }
        let install = try closedDecode(ModelTransactionReservationInstall.self, installBytes)
        let completed = try decodeActiveIndex(completedBytes, format: indexReceipt.format.bytes!)
        guard install.schema == "model_catalog_reservation_install.v1", install.installID == installID,
              install.migrationID == index.reservationMigrationID,
              install.sourceSHA256 == index.reservationSourceSHA256,
              install.progressSHA256 == index.reservationProgressSHA256,
              install.finalizingGeneration == index.generation,
              install.completedIndexSHA256 == completedFile.sha256,
              completed.generation == index.generation + 1,
              completed.reservationPhase == "complete", completed.reservationInstallID == installID,
              completed.reservationInstallReceiptSHA256 == nil,
              completed.entries == index.entries else { throw ModelCatalogRetentionError.migration }
        try locked(nonblocking: true) {
            try indexReceipt.validateLocked(store: self, requireCompleted: false)
            try installFile.validate(); try completedFile.validate(); try budget.check()
            try retentionDirectory().write(completedBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("reservation_migration_complete")
        }
        return try captureIndexReceipt(budget: budget, migration: indexReceipt.migration, requireCompleted: true)
    }

    func initializeReservationMigration(binding: ModelTransactionMigrationCompletionReceipt,
                                        indexReceipt supplied: ModelTransactionIndexReceipt) throws
        -> ModelTransactionIndexReceipt {
        let budget = supplied.budget
        var receipt = supplied
        if receipt.index.schema == "model_catalog_active_index.v3" {
            receipt = try reservationCutover(binding: binding, indexReceipt: receipt)
        }
        while true {
            try budget.check()
            try validateReservationIndexShape(receipt.index)
            if receipt.index.reservationPhase == "complete" {
                let completion = try captureReservationCompletion(indexReceipt: receipt)
                let completed = receipt.completed(completion)
                try locked(nonblocking: true) { try completed.validateLocked(store: self) }
                return completed
            }
            if receipt.index.reservationPhase == "finalizing" {
                return try recoverReservationFinalizing(indexReceipt: receipt)
            }
            let (source, sourceFile) = try sourceForReservationIndex(receipt.index, budget: budget)
            var (progress, progressFile) = try progressForReservationIndex(receipt.index, source: source, budget: budget)
            if progress.phase == "complete" {
                // A crash after completing progress but before the finalizing
                // index leaves the exact current classifying index as the only
                // admissible prepared state.
                progress.phase = "classifying"
                progress.generation -= 1
            }
            var advanced = false
            for sourceEntry in source.entries {
                try budget.check()
                var entryAdvanced = false
                guard let currentEntry = receipt.index.entries.first(where: { $0.id == sourceEntry.id }) else {
                    throw ModelCatalogRetentionError.migration
                }
                if currentEntry.reservationPublication != nil {
                    do {
                        receipt = try reservationClassifyOne(indexReceipt: receipt, source: source,
                            sourceFile: sourceFile, progress: progress, progressFile: progressFile, id: sourceEntry.id)
                        advanced = true
                        entryAdvanced = true
                    } catch ModelCatalogTransactionError.busy { continue }
                } else if currentEntry.classSHA256 == nil {
                    do {
                        receipt = try reservationClassifyOne(indexReceipt: receipt, source: source,
                            sourceFile: sourceFile, progress: progress, progressFile: progressFile, id: sourceEntry.id)
                        advanced = true
                        entryAdvanced = true
                    } catch ModelCatalogTransactionError.busy { continue }
                }
                if entryAdvanced {
                    (progress, progressFile) = try progressForReservationIndex(receipt.index, source: source, budget: budget)
                }
            }
            if receipt.index.entries.allSatisfy({ $0.classSHA256 != nil && $0.reservationPublication == nil }) {
                return try finalizeReservationMigration(indexReceipt: receipt, source: source,
                    sourceFile: sourceFile, progress: progress, progressFile: progressFile)
            }
            if !advanced { throw ModelCatalogTransactionError.busy }
        }
    }

    /// Active writers need authority for their own UUID, not completion of an
    /// unrelated migration prefix. The returned receipt remains bound to the
    /// caller's original work budget and exact source/progress evidence.
    func initializeRetentionForActiveEntry(id: String, heldOwner: ModelCatalogFileLock? = nil,
                                           budget: ModelTransactionWorkBudget = .init()) throws
        -> ModelTransactionIndexReceipt {
        try initializeLegacyRetention(budget: budget)
        let initial = try captureIndexReceipt(budget: budget, requireCompleted: false)
        let migration = try initializeBindingMigration(budget: budget, initialIndex: initial)
        var receipt = ["model_catalog_active_index.v3", "model_catalog_active_index.v4"].contains(initial.index.schema)
            ? initial.completed(migration)
            : try captureIndexReceipt(budget: budget, migration: migration, requireCompleted: false)
        if receipt.index.schema == "model_catalog_active_index.v3" {
            if heldOwner != nil { throw ModelCatalogTransactionError.busy }
            try recoverAllocations(budget: budget, indexReceipt: &receipt)
            receipt = try reservationCutover(binding: migration, indexReceipt: receipt)
        }
        try validateReservationIndexShape(receipt.index)
        if receipt.index.reservationPhase == "finalizing" {
            receipt = try recoverReservationFinalizing(indexReceipt: receipt)
        }
        if receipt.index.reservationPhase == "complete" {
            let completion = try captureReservationCompletion(indexReceipt: receipt)
            let completed = receipt.completed(completion)
            try locked(nonblocking: true) { try completed.validateLocked(store: self) }
            return completed
        }
        guard receipt.index.reservationPhase == "classifying",
              var entry = receipt.index.entries.first(where: { $0.id == id && $0.phase == "active" }) else {
            throw ModelCatalogTransactionError.invalidTransaction
        }
        let (source, sourceFile) = try sourceForReservationIndex(receipt.index, budget: budget)
        let (progress, progressFile) = try progressForReservationIndex(receipt.index, source: source, budget: budget)
        if entry.reservationPublication != nil || entry.classSHA256 == nil {
            receipt = try reservationClassifyOne(indexReceipt: receipt, source: source, sourceFile: sourceFile,
                progress: progress, progressFile: progressFile, id: id, heldOwner: heldOwner)
            guard let refreshed = receipt.index.entries.first(where: { $0.id == id && $0.phase == "active" }) else {
                throw ModelCatalogTransactionError.invalidTransaction
            }
            entry = refreshed
        }
        _ = try captureReservationAuthority(entry: entry, budget: budget, indexReceipt: receipt)
        try locked(nonblocking: true) { try receipt.validateLocked(store: self, requireCompleted: false) }
        return receipt
    }
}
