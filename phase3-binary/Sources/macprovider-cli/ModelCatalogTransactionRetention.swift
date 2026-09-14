import CryptoKit
import Darwin
import Foundation
import MacProviderCore

struct ModelTransactionActiveIndex: Codable {
    struct Entry: Codable, Equatable {
        let id: String
        var phase: String
        var originSHA256: String?
        var provenance: String?
        var bindingSHA256: String?
        var classSHA256: String? = nil
        var leftSHA256: String? = nil
        var reservationPublication: String? = nil
        var allocatedGeneration: String? = nil
        var initialPrimarySHA256: String? = nil
    }
    var schema: String
    var migrationID: String?
    var migrationSourceSHA256: String?
    var reservationMigrationID: String? = nil
    var reservationSourceSHA256: String? = nil
    var reservationProgressSHA256: String? = nil
    var reservationPhase: String? = nil
    var reservationInstallID: String? = nil
    var reservationInstallReceiptSHA256: String? = nil
    var generation: UInt64
    var entries: [Entry]
}
private struct ModelTransactionMaintenanceCursor: Codable {
    let schema: String
    let lastID: String
}
struct ModelTransactionRetentionFormat: Codable {
    let schema: String
    var reservationMigrationID: String? = nil
    var reservationSourceSHA256: String? = nil
}
struct ModelTransactionRecommendationContext: Encodable, Equatable {
    let target: String
    let modelKey: String
    let revision: String
    let artifactSHA256: String
    let candidateDigest: String
    let artifactDigest: String
    let signerKeyID: String
    let rateVersion: String
    let demandVersion: String
    let candidateVersion: String
    let chip: String
    let memoryGB: Int
    let binaryVersion: String
    let schema = "model_catalog_recommendation_context.v1"
}
struct ModelTransactionRecommendationPointer: Codable {
    let schema: String
    let contextDigest: String
    let transactionID: String
    let successCommitmentSHA256: String
    let resultSHA256: String
    let originSHA256: String
    let bindingSHA256: String
}

struct ModelCatalogCleanupInventory {
    let records: [ModelCatalogTransactionRecord]
    private let indexReceipt: ModelTransactionIndexReceipt
    private let witnesses: [ModelTransactionFileWitness]

    fileprivate init(records: [ModelCatalogTransactionRecord], indexReceipt: ModelTransactionIndexReceipt,
                     witnesses: [ModelTransactionFileWitness]) {
        self.records = records
        self.indexReceipt = indexReceipt
        self.witnesses = witnesses
    }

    func validate(store: ModelCatalogTransactionStore, budget: ModelTransactionWorkBudget) throws {
        try budget.check()
        // The index receipt freezes exact active membership. Per-file witnesses
        // additionally catch primary/provenance replacement that does not alter
        // the active-index generation.
        try store.locked(nonblocking: true) {
            try indexReceipt.validateLocked(store: store)
            for witness in witnesses { try witness.validate(budget: budget) }
            try budget.check()
        }
    }
}
private struct ModelTransactionSuccessCommitment: Encodable {
    let schema = "model_catalog_evaluation_success_commitment.v1"
    let transactionID: String
    let operationGeneration: String
    let kind: String
    let createdAt: Date
    let startedAt: Date
    let target: String
    let modelKey: String
    let revision: String
    let sha256: String
    let candidateDigest: String
    let artifactDigest: String
    let signerKeyID: String
    let committed: Bool
    let resultSHA256: String
    let successfulTerminalEvent: ModelCatalogTransactionEvent
}

extension ModelCatalogTransactionStore {
    static let activeTransactionLimit = 1_024
    private static let retentionName = ".retention-v2"
    static let indexLimit = 1_048_576

    func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    func closedDecode<T: Codable>(_ type: T.Type, _ bytes: Data) throws -> T {
        try AutotuneStrictJSON.rejectDuplicateKeys(bytes)
        let decoded = try JSONDecoder().decode(type, from: bytes)
        guard try JSONSerialization.jsonObject(with: bytes) as? NSDictionary ==
                JSONSerialization.jsonObject(with: canonicalData(decoded)) as? NSDictionary else {
            throw ModelCatalogRetentionError.corruptIndex
        }
        return decoded
    }
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func retentionDirectory() throws -> ModelTransactionDirectory {
        try ModelTransactionDirectory.current(root).child(Self.retentionName)
    }
    @discardableResult
    func initializeRetention(budget: ModelTransactionWorkBudget = .init()) throws -> ModelTransactionIndexReceipt {
        try initializeLegacyRetention(budget: budget)
        let initial = try captureIndexReceipt(budget: budget, requireCompleted: false)
        let migration = try initializeBindingMigration(budget: budget, initialIndex: initial)
        var result = ["model_catalog_active_index.v3", "model_catalog_active_index.v4"].contains(initial.index.schema)
            ? initial.completed(migration)
            : try captureIndexReceipt(budget: budget, migration: migration, requireCompleted: false)
        if result.index.schema == "model_catalog_active_index.v3" {
            try recoverAllocations(budget: budget, indexReceipt: &result)
        }
        result = try initializeReservationMigration(binding: migration, indexReceipt: result)
        try locked(nonblocking: true) { try result.validateLocked(store: self) }
        return result
    }
    func initializeLegacyRetention(budget: ModelTransactionWorkBudget) throws {
        try budget.check(); try secure()
        let directory = try ModelTransactionDirectory.current(root)
        if try directory.metadata(Self.retentionName) != nil { return }
        let bootstrap = try ModelCatalogFileLock(root.appendingPathComponent(".retention-bootstrap"), nonblocking: true)
        defer { withExtendedLifetime(bootstrap) {} }
        if try directory.metadata(Self.retentionName) != nil { return }
        // Ensure the stable journal lock inode exists before observing the root.
        try locked(nonblocking: true) {}
        let observed = try directory.info()
        try retentionBoundary("migration_scan")
        let names = try directory.entries(limit: 8_192, check: budget.check)
        let records = names.filter { $0.hasSuffix(".json") }
        guard records.count <= Self.activeTransactionLimit else { throw ModelCatalogRetentionError.migration }
        for name in records { try validateID(String(name.dropLast(5))) }
        let index = ModelTransactionActiveIndex(schema: "model_catalog_active_index.v2", generation: 1,
            entries: records.sorted().map { .init(id: String($0.dropLast(5)), phase: "active") })
        let temporaryName = Self.retentionName + ".init"
        if try directory.metadata(temporaryName) != nil {
            let previous = try directory.child(temporaryName)
            let pending = try previous.entries(limit: 2, check: budget.check)
            guard pending.allSatisfy({ ["format.json", "active.json"].contains($0) }) else { throw ModelCatalogRetentionError.migration }
            for name in pending {
                let evidence = try ModelTransactionFileEvidence(directory: previous, name: name,
                    maxBytes: Self.indexLimit, budget: budget)
                try evidence.validate()
                guard unlinkat(previous.fd, name, 0) == 0 else { throw ModelCatalogRetentionError.storage }
            }
            guard fsync(previous.fd) == 0 else { throw ModelCatalogRetentionError.storage }
        }
        let data = try canonicalData(index)
        let format = try canonicalData(ModelTransactionRetentionFormat(schema: "model_catalog_retention.v2"))
        try locked(nonblocking: true) {
            try directory.validateCurrent()
            guard ModelTransactionFileEvidence.same(observed, try directory.info()),
                  try directory.metadata(Self.retentionName) == nil else { throw ModelCatalogRetentionError.changed }
            try budget.check()
            let temporary = try directory.child(temporaryName, create: true)
            try temporary.write(data, name: "active.json", exclusive: true, maxBytes: Self.indexLimit)
            try temporary.write(format, name: "format.json", exclusive: true)
            guard fsync(temporary.fd) == 0,
                  renameat(directory.fd, temporaryName, directory.fd, Self.retentionName) == 0,
                  fsync(directory.fd) == 0 else { throw ModelCatalogRetentionError.storage }
        }
    }
    func decodeActiveIndex(_ bytes: Data, format formatBytes: Data) throws -> ModelTransactionActiveIndex {
        try retentionBoundary("index_decode")
        let format = try closedDecode(ModelTransactionRetentionFormat.self, formatBytes)
        let index = try closedDecode(ModelTransactionActiveIndex.self, bytes)
        guard ["model_catalog_retention.v2", "model_catalog_retention.v3"].contains(format.schema),
              ["model_catalog_active_index.v2", "model_catalog_active_index.v3", "model_catalog_active_index.v4"].contains(index.schema), index.generation > 0,
              index.entries.count <= Self.activeTransactionLimit,
              Set(index.entries.map(\.id)).count == index.entries.count else { throw ModelCatalogRetentionError.corruptIndex }
        for entry in index.entries {
            try validateID(entry.id)
            guard ["active", "allocating"].contains(entry.phase) else { throw ModelCatalogRetentionError.corruptIndex }
        }
        if index.schema == "model_catalog_active_index.v3" {
            guard index.migrationID != nil, index.migrationSourceSHA256 != nil,
                  index.entries.allSatisfy({ $0.originSHA256 != nil && ["allocated", "legacy_snapshot", "protected_snapshot"].contains($0.provenance ?? "") }) else { throw ModelCatalogRetentionError.corruptIndex }
        }
        if format.schema == "model_catalog_retention.v2" {
            guard index.schema != "model_catalog_active_index.v4", format.reservationMigrationID == nil,
                  format.reservationSourceSHA256 == nil else { throw ModelCatalogRetentionError.corruptIndex }
        } else {
            guard ["model_catalog_active_index.v3", "model_catalog_active_index.v4"].contains(index.schema),
                  let migrationID = format.reservationMigrationID,
                  let sourceHash = format.reservationSourceSHA256 else { throw ModelCatalogRetentionError.corruptIndex }
            try validateID(migrationID)
            try requireReservationDigest(sourceHash)
            if index.schema == "model_catalog_active_index.v4" {
                try validateReservationIndexShape(index)
                guard index.reservationMigrationID == migrationID,
                      index.reservationSourceSHA256 == sourceHash else { throw ModelCatalogRetentionError.corruptIndex }
            }
        }
        return index
    }
    func captureIndexReceipt(budget: ModelTransactionWorkBudget = .init(),
                             migration supplied: ModelTransactionMigrationCompletionReceipt? = nil,
                             requireCompleted: Bool = true) throws -> ModelTransactionIndexReceipt {
        let directory = try retentionDirectory()
        let format = try ModelTransactionFileEvidence(directory: directory, name: "format.json", maxBytes: 4_096,
            budget: budget, observe: { try retentionBoundary("index_bulk_read") })
        let file = try ModelTransactionFileEvidence(directory: directory, name: "active.json", maxBytes: Self.indexLimit,
            budget: budget, observe: { try retentionBoundary("index_bulk_read") })
        guard let bytes = file.bytes, let formatBytes = format.bytes else { throw ModelCatalogRetentionError.corruptIndex }
        let index = try decodeActiveIndex(bytes, format: formatBytes)
        let migration = try supplied ?? (requireCompleted ? captureMigrationCompletion(budget: budget) : nil)
        var receipt = ModelTransactionIndexReceipt(index: index, file: file, format: format, migration: migration, budget: budget)
        if requireCompleted, index.schema == "model_catalog_active_index.v4" {
            receipt = receipt.completed(try captureReservationMigrationCompletion(indexReceipt: receipt))
        }
        try budget.check()
        return receipt
    }
    func recaptureIndexReceipt(_ previous: ModelTransactionIndexReceipt, next: ModelTransactionActiveIndex,
                               bytes: Data) throws -> ModelTransactionIndexReceipt {
        try retentionBoundary("index_before_recapture")
        let file = try ModelTransactionFileEvidence(directory: previous.file.directory, name: "active.json",
            maxBytes: Self.indexLimit, budget: previous.budget, observe: { try retentionBoundary("index_bulk_read") })
        guard file.bytes == bytes else { throw ModelCatalogRetentionError.changed }
        let receipt = ModelTransactionIndexReceipt(index: next, file: file, format: previous.format,
            migration: previous.migration, reservationMigration: previous.reservationMigration, budget: previous.budget)
        try receipt.validateLocked(store: self)
        try retentionBoundary("index_recaptured")
        return receipt
    }
    func decodeRetentionRecord(_ data: Data, id: String) throws -> ModelCatalogTransactionRecord {
        guard !ModelTransactionDirectory.hasScopedDirectory else { throw ModelCatalogTransactionError.busy }
        try validateID(id)
        try AutotuneStrictJSON.rejectDuplicateKeys(data)
        let object = try JSONSerialization.jsonObject(with: data)
        let known: Set<String> = ["schema", "transactionID", "operationGeneration", "target", "modelKey", "kind", "revision", "sha256",
            "candidateDigest", "artifactDigest", "signerKeyID", "createdAt", "startedAt", "resultSHA256", "artifactSealSHA256",
            "committed", "cancelRequested", "cleanupRequired", "events", "attemptStartSequence"]
        let eventKeys: Set<String> = ["schema", "transaction_id", "transaction_kind", "operation_generation", "model_key",
            "event_sequence", "emitted_at", "state", "progress", "error_code", "warning_code"]
        guard let fields = object as? [String: Any], Set(fields.keys).isSubset(of: known),
              let events = fields["events"] as? [[String: Any]],
              events.allSatisfy({ event in
                  guard Set(event.keys).isSubset(of: eventKeys) else { return false }
                  if let progress = event["progress"] as? [String: Any] {
                      return Set(progress.keys).isSubset(of: ["stage_label_key", "heartbeat"])
                  }
                  return true
              }) else { throw ModelCatalogRetentionError.unsafe }
        let record = try JSONDecoder().decode(ModelCatalogTransactionRecord.self, from: data)
        guard record.transactionID == id else { throw ModelCatalogRetentionError.unsafe }
        try validate(record); return record
    }
    private func untouchedSidecarsAbsentLocked(_ id: String, includeOwner: Bool = false) throws -> Bool {
        var names = [id + ".result", id + ".cleanup", id + ".seal", id + ".success-binding", id + ".retired", "staging-" + id]
        if includeOwner { names.append(".owner-" + id) }
        let directory = try ModelTransactionDirectory.current(root)
        return try names.allSatisfy { try directory.metadata($0) == nil }
    }
    func snapshotIndex(budget: ModelTransactionWorkBudget = .init(),
                       migration: ModelTransactionMigrationCompletionReceipt? = nil,
                       indexReceipt supplied: ModelTransactionIndexReceipt? = nil) throws -> ModelTransactionActiveIndex {
        let receipt = try supplied ?? captureIndexReceipt(budget: budget, migration: migration)
        return try locked(nonblocking: true) {
            try receipt.validateLocked(store: self); return receipt.index
        }
    }
    func activeReceiptGeneration(_ id: String) throws -> UInt64 {
        let index = try snapshotIndex()
        guard index.entries.contains(where: { $0.id == id && $0.phase == "active" }) else { throw ModelCatalogTransactionError.invalidTransaction }
        return index.generation
    }
    func validateActiveReceiptMembership(_ id: String, generation: UInt64,
                                         provenance: ModelTransactionProvenanceReceipt,
                                         indexReceipt: ModelTransactionIndexReceipt) throws {
        let current = indexReceipt.index
        let reservationInProgress = current.schema == "model_catalog_active_index.v4" &&
            current.reservationPhase == "classifying"
        try indexReceipt.validateLocked(store: self, requireCompleted: !reservationInProgress)
        try provenance.migration.validateLocked(current)
        guard current.generation == generation,
              let entry = current.entries.first(where: { $0.id == id && $0.phase == "active" }) else {
            throw ModelCatalogRetentionError.changed
        }
        guard entry.originSHA256 == provenance.originFile.sha256,
              entry.provenance == provenance.origin.provenance.name,
              entry.bindingSHA256 == provenance.expectedBindingSHA256 else {
            throw ModelCatalogRetentionError.unsafe
        }
    }
    private func absent(_ id: String, includeOwner: Bool) throws -> Bool {
        try untouchedSidecarsAbsentLocked(id, includeOwner: includeOwner)
    }
    func recoverAllocations(budget: ModelTransactionWorkBudget, indexReceipt: inout ModelTransactionIndexReceipt) throws {
        let snapshot = indexReceipt.index
        for (position, entry) in snapshot.entries.enumerated() where entry.phase == "allocating" {
            try budget.yield(after: position)
            do {
                let observed = indexReceipt
                let index = observed.index
                guard entry.provenance == "allocated", let expectedOrigin = entry.originSHA256,
                      index.generation < UInt64.max,
                      let offset = index.entries.firstIndex(where: { $0.id == entry.id && $0.phase == "allocating" }),
                      index.entries[offset].originSHA256 == expectedOrigin else { continue }
                let primary = try evidence(entry.id + ".json", budget: budget)
                let origin = try evidence(entry.id + ".origin", budget: budget, maxBytes: 16_384)
                let classEvidence = try evidence(entry.id + ".reservation-class", budget: budget,
                                                    maxBytes: Self.reservationClassLimit)
                let reservationLeft = try evidence(entry.id + ".reservation-left", budget: budget,
                                                   maxBytes: Self.reservationLeftLimit)
                var originToPublish: Data?
                var classToPublish: Data?
                var next = index
                if let data = primary.bytes {
                    if index.schema == "model_catalog_active_index.v4" {
                        guard primary.sha256 == entry.initialPrimarySHA256,
                              reservationLeft.bytes == nil, try !reservationReceiptDirectoryExists(entry.id),
                              let generation = entry.allocatedGeneration,
                              entry.classSHA256 != nil else { continue }
                        try validateID(generation)
                    }
                    let record = try decodeRetentionRecord(data, id: entry.id)
                    guard record.events.count == 1, record.events.first?.state == "queued", record.startedAt == nil,
                          !record.committed, !record.cancelRequested, !record.cleanupRequired else { continue }
                    let expected = try bindingBytes(ModelTransactionOrigin.allocated(record, primarySHA256: digest(data)))
                    guard digest(expected) == expectedOrigin, origin.bytes == nil || origin.bytes == expected else { continue }
                    if origin.bytes == nil { originToPublish = expected }
                    if index.schema == "model_catalog_active_index.v4" {
                        let decodedOrigin = try closedDecode(ModelTransactionOrigin.self, expected)
                        let expectedClass = try canonicalData(reservationClass(origin: decodedOrigin, originSHA256: expectedOrigin))
                        guard digest(expectedClass) == entry.classSHA256,
                              classEvidence.bytes == nil || classEvidence.bytes == expectedClass else { continue }
                        if classEvidence.bytes == nil { classToPublish = expectedClass }
                    } else if classEvidence.bytes != nil || reservationLeft.bytes != nil { continue }
                    next.entries[offset].phase = "active"
                    next.entries[offset].allocatedGeneration = nil
                    next.entries[offset].initialPrimarySHA256 = nil
                } else {
                    guard origin.bytes == nil, classEvidence.bytes == nil, reservationLeft.bytes == nil,
                          try !reservationReceiptDirectoryExists(entry.id) else { continue }
                    next.entries.remove(at: offset)
                }
                // No owner acquisition: absent-intent recovery cannot create its
                // own contradictory owner evidence.
                guard try absent(entry.id, includeOwner: true) else { continue }
                next.generation += 1
                let bytes = try canonicalData(next)
                try locked(nonblocking: true) {
                    try observed.validateLocked(store: self)
                    guard observed.index.generation == index.generation,
                          try absent(entry.id, includeOwner: true) else { throw ModelCatalogRetentionError.changed }
                    try primary.validate(); try origin.validate(); try classEvidence.validate(); try reservationLeft.validate(); try budget.check()
                    do {
                    if let originToPublish {
                        try ModelTransactionDirectory.current(root).write(originToPublish, name: entry.id + ".origin", exclusive: true, maxBytes: 16_384)
                        try retentionBoundary("allocation_origin")
                    }
                    try budget.check()
                    if let classToPublish {
                        try ModelTransactionDirectory.current(root).write(classToPublish, name: entry.id + ".reservation-class",
                                                                         exclusive: true, maxBytes: Self.reservationClassLimit)
                        try retentionBoundary("allocation_class")
                    }
                    try budget.check()
                    try retentionDirectory().write(bytes, name: "active.json", maxBytes: Self.indexLimit)
                    } catch { throw ModelTransactionIndexPublicationError.interrupted }
                }
                do { indexReceipt = try recaptureIndexReceipt(observed, next: next, bytes: bytes) }
                catch { throw ModelTransactionIndexPublicationError.interrupted }
            } catch {
                if error is ModelTransactionIndexPublicationError { throw error }
                if case ModelCatalogRetentionError.changed = error { throw error }
                try indexReceipt.validateLocked(store: self); try budget.check()
            }
        }
    }
    func reserveOperation(authority: ModelCatalogTransactionAuthority, kind: String, now: Date = Date(), budget: ModelTransactionWorkBudget = .init()) throws -> ModelCatalogTransactionReservation {
        guard ["prepare_model", "evaluate_model"].contains(kind) else { throw ModelCatalogTransactionError.invalidTransaction }
        var indexReceipt = try initializeRetention(budget: budget)
        try recoverAllocations(budget: budget, indexReceipt: &indexReceipt)
        guard let migration = indexReceipt.migration else { throw ModelCatalogRetentionError.migration }
        try retentionBoundary("reservation_scan_started")
        for (position, entry) in indexReceipt.index.entries.enumerated() where entry.phase == "active" {
            try budget.yield(after: position)
            let reservation = try captureReservationAuthority(entry: entry, budget: budget,
                                                               indexReceipt: indexReceipt)
            if reservation.isPermanentlyNonreusable ||
                !reservationClassMatches(reservation.classification, authority: authority, kind: kind) { continue }
            let primary = try evidence(entry.id + ".json", budget: budget)
            guard let data = primary.bytes else { throw ModelCatalogRetentionError.unsafe }
            let record = try decodeRetentionRecord(data, id: entry.id)
            try reservation.origin.validate(record, primarySHA256: nil)
            guard case .allocated(let allocation) = reservation.origin.provenance else {
                throw ModelCatalogRetentionError.unsafe
            }
            if !initialQueued(record, allocation: allocation) {
                // A matching origin that has durably left its initial queued
                // state cannot be skipped as a negative until the immutable
                // left anchor is committed. Exact owner custody prevents a live
                // writer from being rebaselined by reservation search.
                let owner = try ownerLock(entry.id)
                indexReceipt = try publishReservationDeparture(record: record, primary: primary,
                                                                indexReceipt: indexReceipt)
                withExtendedLifetime(owner) {}
                continue
            }
            guard try absent(entry.id, includeOwner: false) else {
                throw ModelCatalogRetentionError.unsafe
            }
            let age = now.timeIntervalSince(record.createdAt)
            guard age >= 0 else { throw ModelCatalogTransactionError.busy }
            guard age < 1_800 else { continue }
            guard let selector = record.selector else { throw ModelCatalogRetentionError.unsafe }
            let owner = try ownerLock(entry.id); defer { withExtendedLifetime(owner) {} }
            let generation = indexReceipt.index.generation
            let receipt = ModelTransactionActiveReceipt(record: record, selector: selector, indexGeneration: generation,
                primary: primary, provenance: try captureProvenance(original: record, primary: primary, entry: entry,
                budget: budget, migration: migration), reservation: reservation, indexReceipt: indexReceipt)
            try locked(nonblocking: true) {
                try receipt.validateLocked(store: self)
                try reservation.validateFiles()
                guard try absent(entry.id, includeOwner: false) else { throw ModelCatalogRetentionError.changed }
            }
            return .init(transactionID: entry.id, operationGeneration: selector.operationGeneration)
        }
        try retentionBoundary("reservation_scan_complete")
        try maintainRetention(now: now, budget: budget, stopWhenSpaceAvailable: true, indexReceipt: &indexReceipt)
        let index = indexReceipt.index
        guard index.entries.count < Self.activeTransactionLimit, index.generation < UInt64.max - 1 else { throw ModelCatalogRetentionError.capacity }
        let id = UUID().uuidString.lowercased(), generation = UUID().uuidString.lowercased()
        var record = ModelCatalogTransactionRecord(transactionID: id, target: authority.row.modelID,
            modelKey: authority.modelKey, kind: kind, revision: authority.row.modelRevision!, sha256: authority.row.modelSHA256!,
            candidateDigest: authority.candidateDigest, artifactDigest: authority.artifactDigest,
            signerKeyID: authority.signerKeyID, createdAt: now)
        record.operationGeneration = generation; append(&record, state: "queued", stage: "queued")
        let recordBytes = try JSONEncoder().encode(record)
        let origin = try ModelTransactionOrigin.allocated(record, primarySHA256: digest(recordBytes))
        let originBytes = try bindingBytes(origin)
        let classBytes = try canonicalData(reservationClass(origin: origin, originSHA256: digest(originBytes)))
        guard classBytes.count <= Self.reservationClassLimit else { throw ModelCatalogRetentionError.capacity }
        var allocating = index
        allocating.generation += 1
        allocating.entries.append(.init(id: id, phase: "allocating", originSHA256: digest(originBytes),
            provenance: "allocated", classSHA256: digest(classBytes), allocatedGeneration: generation,
            initialPrimarySHA256: digest(recordBytes)))
        allocating.entries.sort { $0.id < $1.id }
        var active = allocating; active.generation += 1
        let activePosition = active.entries.firstIndex(where: { $0.id == id })!
        active.entries[activePosition].phase = "active"
        active.entries[activePosition].allocatedGeneration = nil
        active.entries[activePosition].initialPrimarySHA256 = nil
        let allocatingBytes = try canonicalData(allocating), activeBytes = try canonicalData(active)
        try budget.check()
        try locked(nonblocking: true) {
            try indexReceipt.validateLocked(store: self)
            let current = indexReceipt.index
            guard current.generation == index.generation, current.entries.count < Self.activeTransactionLimit else { throw ModelCatalogRetentionError.changed }
            let directory = try ModelTransactionDirectory.current(root)
            guard try directory.metadata(id + ".json") == nil, try directory.metadata(id + ".origin") == nil,
                  try directory.metadata(id + ".reservation-class") == nil,
                  try directory.metadata(id + ".reservation-left") == nil,
                  try !reservationReceiptDirectoryExists(id),
                  try absent(id, includeOwner: true) else { throw ModelCatalogRetentionError.changed }
            let retention = try retentionDirectory()
            try budget.check()
            try retention.write(allocatingBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("allocation_intent")
            try directory.write(recordBytes, name: id + ".json", exclusive: true)
            try retentionBoundary("allocation_record")
            try budget.check()
            try directory.write(originBytes, name: id + ".origin", exclusive: true, maxBytes: 16_384)
            try retentionBoundary("allocation_origin")
            try budget.check()
            try directory.write(classBytes, name: id + ".reservation-class", exclusive: true,
                                maxBytes: Self.reservationClassLimit)
            try retentionBoundary("allocation_class")
            try budget.check()
            try retention.write(activeBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("allocation_active")
        }
        return .init(transactionID: id, operationGeneration: generation)
    }
    private enum RetirementReceipt {
        case generated(ModelTransactionActiveReceipt)
        case legacy(id: String, generation: UInt64, primary: ModelTransactionFileEvidence, provenance: ModelTransactionProvenanceReceipt, indexReceipt: ModelTransactionIndexReceipt)
        func validateLocked(_ store: ModelCatalogTransactionStore) throws {
            switch self {
            case .generated(let receipt): try receipt.validateLocked(store: store, allowImmutable: true)
            case .legacy(let id, let generation, let primary, let provenance, let indexReceipt):
                try store.validateActiveReceiptMembership(id, generation: generation, provenance: provenance, indexReceipt: indexReceipt); try primary.validate()
            }
        }
    }
    func maintainRetention(now: Date = Date()) throws {
        let budget = ModelTransactionWorkBudget()
        var indexReceipt = try initializeRetention(budget: budget)
        try recoverAllocations(budget: budget, indexReceipt: &indexReceipt)
        try maintainRetention(now: now, budget: budget, stopWhenSpaceAvailable: false, indexReceipt: &indexReceipt)
    }
    private func maintainRetention(now: Date, budget: ModelTransactionWorkBudget, stopWhenSpaceAvailable: Bool,
                                  indexReceipt: inout ModelTransactionIndexReceipt) throws {
        let snapshot = indexReceipt.index
        let directory = try retentionDirectory()
        let cursor = try ModelTransactionFileEvidence(directory: directory, name: "maintenance.json", maxBytes: 4_096, budget: budget)
        var lastID = ""
        if let data = cursor.bytes {
            let value = try closedDecode(ModelTransactionMaintenanceCursor.self, data)
            guard value.schema == "model_catalog_maintenance_cursor.v1" else { throw ModelCatalogRetentionError.corruptIndex }
            try validateID(value.lastID); lastID = value.lastID
        }
        let ids = snapshot.entries.filter { $0.phase == "active" }.map(\.id).sorted()
        let ordered = ids.filter { $0 > lastID } + ids.filter { $0 <= lastID }
        for (position, id) in ordered.enumerated() {
            try budget.yield(after: position)
            do { try retireOne(id: id, now: now, budget: budget, indexReceipt: &indexReceipt) }
            catch {
                if error is ModelTransactionIndexPublicationError { throw error }
                if case ModelCatalogRetentionError.changed = error { throw error }
                try indexReceipt.validateLocked(store: self); try budget.check()
            }
            let cursorObservation = try ModelTransactionFileEvidence(directory: directory, name: "maintenance.json", maxBytes: 4_096, budget: budget)
            if let data = cursorObservation.bytes {
                let currentCursor = try closedDecode(ModelTransactionMaintenanceCursor.self, data)
                guard currentCursor.schema == "model_catalog_maintenance_cursor.v1" else { throw ModelCatalogRetentionError.corruptIndex }
                try validateID(currentCursor.lastID)
            }
            let cursorBytes = try canonicalData(ModelTransactionMaintenanceCursor(schema: "model_catalog_maintenance_cursor.v1", lastID: id))
            try retentionBoundary("retention_cursor_captured")
            try budget.check()
            try locked(nonblocking: true) {
                try indexReceipt.validateLocked(store: self); try cursorObservation.validate(); try budget.check()
                try retentionDirectory().write(cursorBytes, name: "maintenance.json", maxBytes: 4_096)
                try retentionBoundary("retention_cursor_published")
            }
            if stopWhenSpaceAvailable, indexReceipt.index.entries.count < Self.activeTransactionLimit { break }
        }
    }
    private func retireOne(id: String, now: Date, budget: ModelTransactionWorkBudget,
                           indexReceipt: inout ModelTransactionIndexReceipt) throws {
        let owner = try ownerLock(id); defer { withExtendedLifetime(owner) {} }
        var observed = indexReceipt, index = observed.index
        guard let migration = observed.migration else { throw ModelCatalogRetentionError.migration }
        guard index.entries.contains(where: { $0.id == id && $0.phase == "active" }) else { return }
        var primary = try evidence(id + ".json", budget: budget)
        guard let data = primary.bytes else { return }
        var record = try decodeRetentionRecord(data, id: id)
        var provenance = try captureProvenance(original: record, primary: primary,
            entry: index.entries.first { $0.id == id }, budget: budget, migration: migration)
        if record.events.count == 1, record.events.first?.state == "queued", record.startedAt == nil,
           !record.committed, !record.cancelRequested, !record.cleanupRequired,
           now.timeIntervalSince(record.createdAt) >= 1_800, let selector = record.selector,
           try absent(id, includeOwner: false) {
            let receipt = ModelTransactionActiveReceipt(record: record, selector: selector, indexGeneration: index.generation,
                primary: primary, provenance: provenance,
                reservation: try captureReservationAuthority(entry: index.entries.first { $0.id == id }!,
                                                             budget: budget, indexReceipt: observed),
                indexReceipt: observed)
            append(&record, state: "timed_out", error: "reservation_expired")
            let bytes = try JSONEncoder().encode(record)
            try locked(nonblocking: true) {
                try receipt.validateLocked(store: self)
                guard try absent(id, includeOwner: false) else { throw ModelCatalogRetentionError.changed }
                try budget.check()
                try ModelTransactionDirectory.current(root).write(bytes, name: id + ".json")
            }
            primary = try evidence(id + ".json", budget: budget)
            do {
                indexReceipt = try publishReservationDeparture(record: record, primary: primary, indexReceipt: observed)
            } catch { throw ModelTransactionIndexPublicationError.interrupted }
            observed = indexReceipt; index = observed.index
            provenance = try captureProvenance(original: record, primary: primary, entry: index.entries.first { $0.id == id }, budget: budget, migration: migration)
        }
        guard record.terminal, !record.cleanupRequired else { return }
        let rootDirectory = try ModelTransactionDirectory.current(root)
        guard try rootDirectory.metadata("staging-" + id) == nil else { return }
        let proof = try captureRetirementProof(record: record, primary: primary, provenance: provenance, budget: budget)
        if record.kind == "evaluate_model", record.events.last?.state == "succeeded", record.operationGeneration != nil {
            try indexCompletedEvaluation(record, budget: budget, indexReceipt: observed)
        }
        let receipt: RetirementReceipt
        if let selector = record.selector {
            let entry = index.entries.first { $0.id == id && $0.phase == "active" }
            receipt = .generated(.init(record: record, selector: selector, indexGeneration: index.generation,
                primary: primary, provenance: provenance,
                reservation: try entry.map { try captureReservationAuthority(entry: $0, budget: budget,
                                                                             indexReceipt: observed) },
                indexReceipt: observed))
        } else { receipt = .legacy(id: id, generation: index.generation, primary: primary, provenance: provenance, indexReceipt: observed) }
        guard index.generation < UInt64.max else { throw ModelCatalogRetentionError.capacity }
        var next = index; next.entries.removeAll { $0.id == id }; next.generation += 1
        try retentionBoundary("index_encode")
        let bytes = try canonicalData(next)
        try budget.check()
        try retentionBoundary("retirement_captured")
        try locked(nonblocking: true) {
            try receipt.validateLocked(self)
            try proof.validate(self)
            try budget.check()
            do {
            if provenance.retiredFile.bytes == nil {
                try rootDirectory.write(proof.bytes, name: id + ".retired", exclusive: true, maxBytes: 16_384)
                try retentionBoundary("retirement_certificate")
            }
            try budget.check()
            try retentionBoundary("retirement_before_commit")
            try retentionDirectory().write(bytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("retirement_committed")
            } catch { throw ModelTransactionIndexPublicationError.interrupted }
        }
        do { indexReceipt = try recaptureIndexReceipt(observed, next: next, bytes: bytes) }
        catch { throw ModelTransactionIndexPublicationError.interrupted }
    }
    func reserveCleanup(id: String, target: String, budget: ModelTransactionWorkBudget = .init()) throws -> ModelCatalogTransactionReservation {
        let indexReceipt = try initializeRetention(budget: budget)
        let owner = try ownerLock(id)
        defer { withExtendedLifetime(owner) {} }
        guard let migration = indexReceipt.migration else { throw ModelCatalogRetentionError.migration }
        let index = indexReceipt.index
        let generation = index.generation
        let primary = try evidence(id + ".json", budget: budget)
        guard let bytes = primary.bytes else { throw ModelCatalogRetentionError.unsafe }
        let original = try decodeRetentionRecord(bytes, id: id)
        guard original.target == target, original.terminal, original.cleanupRequired, let selector = original.selector else { throw ModelCatalogTransactionError.invalidTransaction }
        let entry = index.entries.first { $0.id == id }
        let receipt = ModelTransactionActiveReceipt(record: original, selector: selector, indexGeneration: generation,
            primary: primary, provenance: try captureProvenance(original: original, primary: primary, entry: entry,
            budget: budget, migration: migration),
            reservation: try entry.map { try captureReservationAuthority(entry: $0, budget: budget,
                                                                         indexReceipt: indexReceipt) },
            indexReceipt: indexReceipt)
        let prior = try evidence(id + ".cleanup", budget: budget)
        var history: ModelTransactionFileEvidence?
        if let data = prior.bytes {
            let stream = try decodeRetentionRecord(data, id: id)
            guard stream.target == target, stream.kind == "cleanup_staging", let oldGeneration = stream.operationGeneration else { throw ModelCatalogRetentionError.unsafe }
            if !stream.terminal {
                try locked(nonblocking: true) { try receipt.validateLocked(store: self); try prior.validate() }
                return .init(transactionID: id, operationGeneration: oldGeneration)
            }
            history = try evidence(id + ".cleanup-" + oldGeneration, budget: budget)
            if let existing = history?.bytes { guard existing == data else { throw ModelCatalogRetentionError.changed } }
        }
        var record = ModelCatalogTransactionRecord(transactionID: id, target: target, modelKey: original.modelKey,
            kind: "cleanup_staging", revision: original.revision, sha256: original.sha256,
            candidateDigest: original.candidateDigest, artifactDigest: original.artifactDigest,
            signerKeyID: original.signerKeyID, createdAt: Date())
        let nextGeneration = UUID().uuidString.lowercased(); record.operationGeneration = nextGeneration
        append(&record, state: "queued", stage: "cleanup")
        let data = try JSONEncoder().encode(record)
        try locked(nonblocking: true) {
            try receipt.validateLocked(store: self); try prior.validate(); try history?.validate()
            let directory = try ModelTransactionDirectory.current(root)
            try budget.check()
            if let history, history.bytes == nil, let priorBytes = prior.bytes { try directory.write(priorBytes, name: history.name, exclusive: true) }
            try directory.write(data, name: id + ".cleanup")
        }
        return .init(transactionID: id, operationGeneration: nextGeneration)
    }
    func cleanupRecordsFromIndex(budget: ModelTransactionWorkBudget = .init(), requireComplete: Bool = false) throws -> [ModelCatalogTransactionRecord] {
        if requireComplete { return try captureCompleteCleanupInventory(budget: budget).records }
        let indexReceipt = try initializeRetention(budget: budget)
        var records: [ModelCatalogTransactionRecord] = []
        for (position, entry) in indexReceipt.index.entries.enumerated() where entry.phase == "active" {
            try budget.yield(after: position)
            do {
                let primary = try evidence(entry.id + ".json", budget: budget)
                guard let bytes = primary.bytes else { continue }
                let record = try decodeRetentionRecord(bytes, id: entry.id)
                guard record.cleanupRequired, record.terminal, record.operationGeneration != nil else { continue }
                let provenance = try captureProvenance(original: record, primary: primary, entry: entry, budget: budget, migration: indexReceipt.migration)
                try indexReceipt.validateLocked(store: self)
                try provenance.requireMutable()
                records.append(record)
            } catch {
                if requireComplete { throw error }
                try indexReceipt.validateLocked(store: self); try budget.check()
            }
        }
        try locked(nonblocking: true) { try indexReceipt.validateLocked(store: self) }
        return records.sorted { ($0.createdAt, $0.transactionID) < ($1.createdAt, $1.transactionID) }
    }

    /// Every active entry is decoded and provenance-validated. Large primary
    /// bodies are released after each entry; the returned compact witnesses are
    /// sufficient to reject later membership, placement or metadata changes.
    func captureCompleteCleanupInventory(budget: ModelTransactionWorkBudget) throws -> ModelCatalogCleanupInventory {
        let indexReceipt = try initializeRetention(budget: budget)
        guard let migration = indexReceipt.migration else { throw ModelCatalogRetentionError.migration }
        var records: [ModelCatalogTransactionRecord] = []
        var witnesses: [ModelTransactionFileWitness] = []
        for (position, entry) in indexReceipt.index.entries.enumerated() {
            try budget.yield(after: position)
            guard entry.phase == "active" else { throw ModelCatalogRetentionError.changed }
            let primary = try evidence(entry.id + ".json", budget: budget)
            guard let bytes = primary.bytes else { throw ModelCatalogRetentionError.unsafe }
            let record = try decodeRetentionRecord(bytes, id: entry.id)
            let provenance = try captureProvenance(original: record, primary: primary, entry: entry,
                                                   budget: budget, migration: migration)
            try locked(nonblocking: true) {
                try indexReceipt.validateLocked(store: self)
                try primary.validate()
                try provenance.validateFiles()
                try budget.check()
            }
            witnesses.append(primary.compactWitness())
            witnesses.append(contentsOf: [provenance.originFile, provenance.bindingFile,
                                           provenance.retiredFile, provenance.originalFile].map { $0.compactWitness() })
            if record.cleanupRequired && record.terminal {
                guard record.operationGeneration != nil else { throw ModelCatalogRetentionError.unsafe }
                try provenance.requireMutable()
                records.append(record)
            }
        }
        let inventory = ModelCatalogCleanupInventory(
            records: records.sorted { ($0.createdAt, $0.transactionID) < ($1.createdAt, $1.transactionID) },
            indexReceipt: indexReceipt,
            witnesses: witnesses)
        try inventory.validate(store: self, budget: budget)
        return inventory
    }

    func recommendationContext(_ record: ModelCatalogTransactionRecord, _ parsed: ParsedRecommendationAdoption) -> ModelTransactionRecommendationContext {
        .init(target: record.target, modelKey: record.modelKey, revision: record.revision, artifactSHA256: record.sha256,
              candidateDigest: record.candidateDigest, artifactDigest: record.artifactDigest, signerKeyID: record.signerKeyID,
              rateVersion: parsed.rateCardVersion, demandVersion: parsed.demandRankVersion, candidateVersion: parsed.candidateCatalogVersion,
              chip: parsed.hardwareChip, memoryGB: parsed.hardwareMemoryGB, binaryVersion: parsed.hardwareBinaryVersion)
    }
    func successDigest(_ record: ModelCatalogTransactionRecord) throws -> String {
        try validate(record)
        guard record.kind == "evaluate_model", record.committed, let result = record.resultSHA256,
              let generation = record.operationGeneration, let started = record.startedAt,
              let terminal = record.events.last, terminal.state == "succeeded",
              record.events.filter({ $0.state == "succeeded" }).count == 1,
              terminal.operationGeneration == generation else { throw ModelCatalogRetentionError.unsafe }
        try validateID(generation)
        return digest(try canonicalData(ModelTransactionSuccessCommitment(transactionID: record.transactionID,
            operationGeneration: generation, kind: record.kind, createdAt: record.createdAt, startedAt: started,
            target: record.target, modelKey: record.modelKey, revision: record.revision, sha256: record.sha256,
            candidateDigest: record.candidateDigest, artifactDigest: record.artifactDigest, signerKeyID: record.signerKeyID,
            committed: true, resultSHA256: result, successfulTerminalEvent: terminal)))
    }
    private func pointerDirectory(_ contextHash: String, create: Bool) throws -> ModelTransactionDirectory {
        try retentionDirectory().child("recommendations", create: create).child(String(contextHash.prefix(2)), create: create)
    }
    private struct OriginalPointerEvidence {
        let record: ModelCatalogTransactionRecord
        let primary: ModelTransactionFileEvidence
        let result: ModelTransactionFileEvidence
        let provenance: ModelTransactionProvenanceReceipt
        let retirement: ModelTransactionRetirementProof?
        let indexReceipt: ModelTransactionIndexReceipt
        func validate(_ store: ModelCatalogTransactionStore) throws {
            try indexReceipt.validateLocked(store: store)
            try primary.validate(); try result.validate(); try provenance.validateFiles(); try retirement?.validate(store)
        }
    }
    private func validatePointer(_ pointer: ModelTransactionRecommendationPointer, contextHash: String,
                                 budget: ModelTransactionWorkBudget,
                                 indexReceipt supplied: ModelTransactionIndexReceipt? = nil) throws -> OriginalPointerEvidence {
        let budget = supplied?.budget ?? budget
        guard pointer.schema == "model_catalog_recommendation_pointer.v2", pointer.contextDigest == contextHash else { throw ModelCatalogRetentionError.unsafe }
        let primary = try evidence(pointer.transactionID + ".json", budget: budget)
        guard let bytes = primary.bytes else { throw ModelCatalogRetentionError.unsafe }
        let record = try decodeRetentionRecord(bytes, id: pointer.transactionID)
        let result = try evidence(record.transactionID + ".result", budget: budget)
        guard let resultBytes = result.bytes else { throw ModelCatalogRetentionError.unsafe }
        _ = try validatedCommittedResult(record, data: resultBytes)
        let indexReceipt = try supplied ?? captureIndexReceipt(budget: budget)
        guard let migration = indexReceipt.migration else { throw ModelCatalogRetentionError.migration }
        let entry = indexReceipt.index.entries.first { $0.id == record.transactionID && $0.phase == "active" }
        let provenance = try captureProvenance(original: record, primary: primary, entry: entry, budget: budget, migration: migration)
        guard provenance.originFile.sha256 == pointer.originSHA256, provenance.bindingFile.sha256 == pointer.bindingSHA256,
              provenance.binding?.contextSHA256 == contextHash else { throw ModelCatalogRetentionError.unsafe }
        let retirement = provenance.retiredFile.bytes == nil ? nil : try captureRetirementProof(record: record, primary: primary, provenance: provenance, budget: budget)
        let parsed = try ModelsAdoptRecommendationCommand.parseRecommendation(data: resultBytes, enforceFreshness: false)
        guard digest(try canonicalData(recommendationContext(record, parsed))) == contextHash,
              try successDigest(record) == pointer.successCommitmentSHA256, result.sha256 == pointer.resultSHA256 else {
            throw ModelCatalogRetentionError.unsafe
        }
        return .init(record: record, primary: primary, result: result, provenance: provenance, retirement: retirement, indexReceipt: indexReceipt)
    }
    /// Caller retains this UUID's existing owner; bulk verification never holds
    /// the journal lock and previous-pointer targets remain strictly read-only.
    @discardableResult
    func indexCompletedEvaluation(_ record: ModelCatalogTransactionRecord,
                                  budget: ModelTransactionWorkBudget = .init(), check: () throws -> Void = {},
                                  indexReceipt supplied: ModelTransactionIndexReceipt? = nil) throws
        -> ModelRecommendationPointerPublicationOutcome {
        var exactPointerMayBeDurable = false
        do {
            let budget = supplied?.budget ?? budget
            guard let selector = record.selector else { throw ModelCatalogRetentionError.unsafe }
            let receipt = try captureActiveReceipt(selector: selector, budget: budget,
                                                   allowPendingSuccess: true, indexReceipt: supplied)
            guard try successDigest(receipt.record) == successDigest(record) else { throw ModelCatalogRetentionError.changed }
            let result = try evidence(record.transactionID + ".result", budget: budget)
            guard let data = result.bytes else { throw ModelCatalogRetentionError.unsafe }
            _ = try validatedCommittedResult(receipt.record, data: data)
            let parsed = try ModelsAdoptRecommendationCommand.parseRecommendation(data: data, enforceFreshness: false)
            let contextHash = digest(try canonicalData(recommendationContext(receipt.record, parsed)))
            let pointer = ModelTransactionRecommendationPointer(schema: "model_catalog_recommendation_pointer.v2",
                contextDigest: contextHash, transactionID: record.transactionID,
                successCommitmentSHA256: try successDigest(receipt.record), resultSHA256: digest(data),
                originSHA256: receipt.provenance!.originFile.sha256!, bindingSHA256: receipt.provenance!.bindingFile.sha256!)
            let bytes = try canonicalData(pointer)
            let directory = try pointerDirectory(contextHash, create: true), name = contextHash + ".json"
            let previous = try ModelTransactionFileEvidence(directory: directory, name: name, maxBytes: 4_096,
                budget: budget, observe: { try retentionBoundary("bulk_read") })
            var original: OriginalPointerEvidence?
            if let previousBytes = previous.bytes {
                let old = try closedDecode(ModelTransactionRecommendationPointer.self, previousBytes)
                original = try validatePointer(old, contextHash: contextHash, budget: budget,
                                               indexReceipt: receipt.indexReceipt)
            }
            if receipt.provenance?.retiredFile.bytes != nil, previous.bytes == nil {
                throw ModelCatalogRetentionError.unsafe
            }
            let shouldWrite = original.map {
                ($0.record.createdAt, $0.record.transactionID) < (record.createdAt, record.transactionID)
            } ?? true
            try retentionBoundary("pointer_before_publish")
            try budget.check()
            if shouldWrite {
                do {
                    try locked(nonblocking: true) {
                        try receipt.validateLocked(store: self, allowImmutable: true)
                        try result.validate(); try previous.validate(); try original?.validate(self)
                        try budget.check(); try check()
                        _ = try directory.writeWithPublicationOutcome(bytes, name: name, maxBytes: 4_096) { stage in
                            if stage == .renamed { try retentionBoundary("pointer_renamed") }
                            if stage == .durable { try retentionBoundary("pointer_durable") }
                        }
                    }
                    exactPointerMayBeDurable = true
                } catch let failure as ModelTransactionAtomicPublicationError {
                    exactPointerMayBeDurable = failure.truth == .mayOrDidPublish
                    throw failure.underlying
                }
                // A durable rename is not acknowledged until the exact bytes and
                // all source evidence pass an ordinary bounded readback.
                try retentionBoundary("pointer_published")
                try budget.check(); try check()
                let published = try ModelTransactionFileEvidence(directory: directory, name: name,
                    maxBytes: 4_096, budget: budget, observe: { try retentionBoundary("bulk_read") })
                guard published.bytes == bytes else { throw ModelCatalogRetentionError.changed }
                let decoded = try closedDecode(ModelTransactionRecommendationPointer.self, bytes)
                let acknowledged = try validatePointer(decoded, contextHash: contextHash, budget: budget,
                                                       indexReceipt: receipt.indexReceipt)
                try locked(nonblocking: true) {
                    try receipt.validateLocked(store: self, allowImmutable: true)
                    try result.validate(); try published.validate(); try acknowledged.validate(self)
                    try budget.check(); try check()
                    try retentionBoundary("pointer_acknowledged")
                }
                return .exactPointerPublishedAndValidated
            }
            try locked(nonblocking: true) {
                try receipt.validateLocked(store: self, allowImmutable: true)
                try result.validate(); try previous.validate(); try original?.validate(self)
                try budget.check(); try check()
            }
            return .existingPointerValidated
        } catch let failure as ModelRecommendationPointerPublicationError {
            throw failure
        } catch {
            throw ModelRecommendationPointerPublicationError(
                truth: exactPointerMayBeDurable ? .mayOrDidPublish : .notPublished,
                underlying: error)
        }
    }
    /// No projection can treat an interrupted/incomplete recovery pass as valid.
    @discardableResult
    func prepareRecommendationIndex(target: String) throws -> ModelTransactionIndexReceipt {
        try prepareRecommendationIndex(target: target, budget: .init())
    }
    func prepareRecommendationIndex(target: String, budget: ModelTransactionWorkBudget,
                                    readBudget: ModelCatalogReadBudget? = nil,
                                    requireComplete: Bool = false) throws -> ModelTransactionIndexReceipt {
        var indexReceipt = try initializeRetention(budget: budget)
        let snapshot = indexReceipt.index
        for (position, entry) in snapshot.entries.enumerated() where entry.phase == "active" {
            try budget.yield(after: position)
            var record: ModelCatalogTransactionRecord
            do {
                let primary = try evidence(entry.id + ".json", budget: budget)
                guard let bytes = primary.bytes else {
                    if requireComplete { throw ModelCatalogRetentionError.unsafe }
                    continue
                }
                record = try decodeRetentionRecord(bytes, id: entry.id)
            } catch {
                if requireComplete { throw error }
                try budget.check(); continue
            }
            guard record.kind == "evaluate_model", record.target == target, let selector = record.selector else { continue }
            if !record.terminal {
                record = try reconcile(selector, readBudget: readBudget, workBudget: budget,
                                       requireRecommendationPublication: requireComplete)
                if !record.terminal { continue }
                indexReceipt = try initializeRetention(budget: budget)
            }
            guard record.events.last?.state == "succeeded" else { continue }
            let owner: ModelCatalogFileLock
            do { owner = try ownerLock(entry.id) }
            catch ModelCatalogTransactionError.busy {
                if requireComplete { throw ModelCatalogTransactionError.busy }
                continue
            }
            defer { withExtendedLifetime(owner) {} }
            indexReceipt = try initializeRetention(budget: budget)
            let current = try captureActiveReceipt(selector: selector, budget: budget, indexReceipt: indexReceipt,
                                                   heldOwner: owner)
            if current.record.events.last?.state == "succeeded" {
                try indexCompletedEvaluation(current.record, budget: budget, indexReceipt: indexReceipt)
            }
        }
        indexReceipt = try initializeRetention(budget: budget)
        try locked(nonblocking: true) { try indexReceipt.validateLocked(store: self) }
        return indexReceipt
    }
    func indexedRecommendation(authority: ModelCatalogTransactionAuthority, inputs: ModelCatalogRecommendationInputs,
                               chip: String, memoryGB: Int, binaryVersion: String,
                               budget: ModelTransactionWorkBudget = .init(),
                               readBudget: ModelCatalogReadBudget? = nil,
                               requireComplete: Bool = false) throws -> ModelCatalogTransactionRecord? {
        let indexReceipt = try prepareRecommendationIndex(target: authority.row.modelID, budget: budget,
                                                          readBudget: readBudget,
                                                          requireComplete: requireComplete)
        let context = ModelTransactionRecommendationContext(target: authority.row.modelID, modelKey: authority.modelKey,
            revision: authority.row.modelRevision!, artifactSHA256: authority.row.modelSHA256!,
            candidateDigest: authority.candidateDigest, artifactDigest: authority.artifactDigest, signerKeyID: authority.signerKeyID,
            rateVersion: inputs.rateCard.value.version, demandVersion: inputs.demand.value.version,
            candidateVersion: inputs.candidate.value.version, chip: chip, memoryGB: memoryGB, binaryVersion: binaryVersion)
        let hash = digest(try canonicalData(context))
        let retention = try retentionDirectory()
        guard try retention.metadata("recommendations") != nil else { return nil }
        let recommendations = try retention.child("recommendations")
        guard try recommendations.metadata(String(hash.prefix(2))) != nil else { return nil }
        let directory = try recommendations.child(String(hash.prefix(2)))
        let pointerBytes = try ModelTransactionFileEvidence(directory: directory, name: hash + ".json", maxBytes: 4_096, budget: budget)
        guard let bytes = pointerBytes.bytes else { return nil }
        let pointer = try closedDecode(ModelTransactionRecommendationPointer.self, bytes)
        let original = try validatePointer(pointer, contextHash: hash, budget: budget, indexReceipt: indexReceipt)
        let parsed = try ModelsAdoptRecommendationCommand.parseRecommendation(data: original.result.bytes!)
        try ModelsAdoptRecommendationCommand.validateSignedCatalogBinding(recommendation: parsed, catalogKey: authority.modelKey, row: authority.row)
        try budget.check()
        try locked(nonblocking: true) { try pointerBytes.validate(); try original.validate(self); try budget.check() }
        return original.record
    }

}

/// Historical cleanup evidence never becomes a current model row or authority.
func makeModelCatalogRecoveries(store: ModelCatalogTransactionStore) -> [ModelCatalogEconomicsWire.Recovery] {
    guard let records = try? store.cleanupRecords() else { return [] }
    var targets: Set<String> = []
    return records.compactMap { record in
        guard targets.insert(record.target).inserted,
              let reservation = try? store.reserveCleanup(id: record.transactionID, target: record.target) else { return nil }
        return .init(targetModelID: record.target, modelKey: record.modelKey,
            action: .init(available: true, requiresConfirmation: true, transactionKind: "cleanup_staging",
                          transactionID: reservation.transactionID, actionTimeoutSeconds: 1800,
                          estimatedBytes: nil, unavailableReason: nil, operationGeneration: reservation.operationGeneration))
    }
}

/// App reads publish a complete inventory or fail; interrupted collection is not
/// evidence that cleanup obligations are absent.
func makeCompleteModelCatalogRecoveries(store: ModelCatalogTransactionStore, budget: ModelCatalogReadBudget, reserve: Bool = true) throws -> [ModelCatalogEconomicsWire.Recovery] {
    let workBudget = try budget.transactionBudget()
    let inventory = try store.captureCompleteCleanupInventory(budget: workBudget)
    return try makeCompleteModelCatalogRecoveries(store: store, inventory: inventory,
                                                  budget: budget, workBudget: workBudget, reserve: reserve)
}

func makeCompleteModelCatalogRecoveries(store: ModelCatalogTransactionStore,
    inventory: ModelCatalogCleanupInventory, budget: ModelCatalogReadBudget,
    workBudget: ModelTransactionWorkBudget, reserve: Bool = true) throws -> [ModelCatalogEconomicsWire.Recovery] {
    try inventory.validate(store: store, budget: workBudget)
    let records = inventory.records
    var targets = Set<String>()
    var result: [ModelCatalogEconomicsWire.Recovery] = []
    for record in records {
        try budget.check()
        guard targets.insert(record.target).inserted else { continue }
        let reservation: ModelCatalogTransactionReservation
        if reserve { reservation = try store.reserveCleanup(id: record.transactionID, target: record.target, budget: workBudget) }
        else { reservation = .init(transactionID: record.transactionID, operationGeneration: "00000000-0000-4000-8000-000000000000") }
        result.append(.init(targetModelID: record.target, modelKey: record.modelKey,
            action: .init(available: true, requiresConfirmation: true, transactionKind: "cleanup_staging",
                          transactionID: reservation.transactionID, actionTimeoutSeconds: 1800,
                          estimatedBytes: nil, unavailableReason: nil, operationGeneration: reservation.operationGeneration)))
    }
    try budget.check()
    return result
}
