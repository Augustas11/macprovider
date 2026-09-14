import CryptoKit
import Darwin
import Foundation

struct ModelTransactionWorkBudget {
    private let deadline: UInt64
    private let sharedCheck: (() throws -> Void)?
    init(seconds: Double = 8, sharedCheck: (() throws -> Void)? = nil) {
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
        self.sharedCheck = sharedCheck
    }
    private init(deadline: UInt64, sharedCheck: (() throws -> Void)?) {
        self.deadline = deadline
        self.sharedCheck = sharedCheck
    }
    /// Applies a narrower helper ceiling without renewing the deadline carried
    /// by the caller. The shared request/phase check remains part of the view.
    func limiting(seconds: Double) -> Self {
        let now = DispatchTime.now().uptimeNanoseconds
        let delta = UInt64(max(0, seconds) * 1_000_000_000)
        let candidate = now.addingReportingOverflow(delta)
        let helperDeadline = candidate.overflow ? UInt64.max : candidate.partialValue
        return .init(deadline: min(deadline, helperDeadline), sharedCheck: sharedCheck)
    }
    func check() throws {
        try sharedCheck?()
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ModelCatalogTransactionError.busy }
    }
    func yield(after index: Int) throws {
        try check()
        if index > 0 && index % 16 == 0 { sched_yield() }
    }
}

/// Exact bytes from a stable open descriptor; final CAS checks placement and all
/// mutable metadata, without reading or hashing the body under the journal lock.
final class ModelTransactionFileEvidence {
    let directory: ModelTransactionDirectory
    let name: String
    let bytes: Data?
    let sha256: String?
    private let descriptor: Int32?
    private let metadata: stat?

    init(directory: ModelTransactionDirectory, name: String, maxBytes: Int = 4_194_304,
         budget: ModelTransactionWorkBudget, observe: () throws -> Void = {}) throws {
        guard !ModelTransactionDirectory.hasScopedDirectory else { throw ModelCatalogTransactionError.busy }
        try budget.check(); try directory.validateCurrent()
        self.directory = directory; self.name = name
        guard try directory.metadata(name) != nil else {
            bytes = nil; sha256 = nil; descriptor = nil; metadata = nil; return
        }
        let fd = try directory.openFile(name, flags: O_RDONLY)
        do {
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_size > 0, before.st_size <= maxBytes else { throw ModelCatalogRetentionError.unsafe }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            repeat {
                try budget.check(); try observe()
                let count = Darwin.read(fd, &buffer, buffer.count)
                try budget.check()
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw ModelCatalogRetentionError.storage }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maxBytes else { throw ModelCatalogRetentionError.unsafe }
            } while true
            var after = stat()
            guard fstat(fd, &after) == 0, Self.same(before, after), data.count == after.st_size,
                  let placed = try directory.metadata(name), Self.same(after, placed) else { throw ModelCatalogRetentionError.changed }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try budget.check()
            bytes = data; sha256 = hash; descriptor = fd; metadata = after
        } catch { close(fd); throw error }
    }
    deinit { if let descriptor { close(descriptor) } }
    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    func validate() throws {
        try directory.validateCurrent()
        let placed = try directory.metadata(name)
        guard let metadata, let descriptor else {
            guard placed == nil else { throw ModelCatalogRetentionError.changed }; return
        }
        var current = stat()
        guard fstat(descriptor, &current) == 0, let placed,
              Self.same(metadata, current), Self.same(metadata, placed) else { throw ModelCatalogRetentionError.changed }
    }
    func compactWitness() -> ModelTransactionFileWitness {
        .init(directoryURL: directory.url, name: name, metadata: metadata, sha256: sha256)
    }
}

/// Request-local evidence for a final coherent inventory. It retains only file
/// identity and digest metadata, allowing large decoded primaries to be released
/// between entries while still detecting replacement or in-place mutation.
struct ModelTransactionFileWitness {
    let directoryURL: URL
    let name: String
    private let metadata: stat?
    let sha256: String?

    fileprivate init(directoryURL: URL, name: String, metadata: stat?, sha256: String?) {
        self.directoryURL = directoryURL
        self.name = name
        self.metadata = metadata
        self.sha256 = sha256
    }

    func validate(budget: ModelTransactionWorkBudget) throws {
        try budget.check()
        let directory = try ModelTransactionDirectory(directoryURL)
        let placed = try directory.metadata(name)
        switch (metadata, placed) {
        case (nil, nil): break
        case let (expected?, current?) where ModelTransactionFileEvidence.same(expected, current): break
        default: throw ModelCatalogRetentionError.changed
        }
        try budget.check()
    }
}

enum ModelTransactionIndexPublicationError: Error { case interrupted }

enum ModelRecommendationPointerPublicationOutcome: Equatable {
    case existingPointerValidated
    case exactPointerPublishedAndValidated
}

struct ModelRecommendationPointerPublicationError: Error {
    let truth: ModelTransactionAtomicPublicationTruth
    let underlying: Error
}

/// Fully decoded once outside the lock; every use proves the same file still
/// occupies its captured slot. Replacement after our write requires exact bytes.
struct ModelTransactionIndexReceipt {
    let index: ModelTransactionActiveIndex
    let file: ModelTransactionFileEvidence
    let format: ModelTransactionFileEvidence
    let migration: ModelTransactionMigrationCompletionReceipt?
    var reservationMigration: ModelTransactionReservationCompletionReceipt? = nil
    let budget: ModelTransactionWorkBudget

    func validateLocked(store: ModelCatalogTransactionStore, requireCompleted: Bool = true) throws {
        try store.validatePinnedDirectory(ModelTransactionDirectory.current(store.root))
        try format.validate(); try file.validate()
        if let migration { try migration.validateLocked(index) }
        else if requireCompleted { throw ModelCatalogRetentionError.migration }
        if index.schema == "model_catalog_active_index.v4" {
            if let reservationMigration { try reservationMigration.validateLocked(index) }
            else if requireCompleted { throw ModelCatalogRetentionError.migration }
        } else if reservationMigration != nil {
            throw ModelCatalogRetentionError.migration
        }
        try budget.check()
    }
    func completed(_ migration: ModelTransactionMigrationCompletionReceipt) -> Self {
        .init(index: index, file: file, format: format, migration: migration,
              reservationMigration: reservationMigration, budget: budget)
    }
    func completed(_ reservation: ModelTransactionReservationCompletionReceipt) -> Self {
        .init(index: index, file: file, format: format, migration: migration,
              reservationMigration: reservation, budget: budget)
    }
}

struct ModelTransactionActiveReceipt {
    let record: ModelCatalogTransactionRecord
    let selector: ModelCatalogTransactionSelector
    let indexGeneration: UInt64
    let primary: ModelTransactionFileEvidence
    var provenance: ModelTransactionProvenanceReceipt? = nil
    var reservation: ModelTransactionReservationAuthorityReceipt? = nil
    var indexReceipt: ModelTransactionIndexReceipt? = nil
    func validateProspective(record: ModelCatalogTransactionRecord) throws {
        guard let provenance else { throw ModelCatalogRetentionError.unsafe }
        try provenance.validateProspective(record)
    }
    func validateLocked(store: ModelCatalogTransactionStore, allowImmutable: Bool = false) throws {
        try store.validatePinnedDirectory(ModelTransactionDirectory.current(store.root))
        guard let provenance, let indexReceipt else { throw ModelCatalogRetentionError.unsafe }
        try store.validateActiveReceiptMembership(selector.transactionID, generation: indexGeneration,
                                                 provenance: provenance, indexReceipt: indexReceipt)
        try primary.validate()
        try provenance.validateFiles()
        if indexReceipt.index.schema == "model_catalog_active_index.v4" {
            guard let reservation else { throw ModelCatalogRetentionError.unsafe }
            try reservation.validateFiles()
            if indexReceipt.index.reservationPhase == "classifying" {
                guard reservation.migrationSourceFile != nil,
                      reservation.migrationProgressFile != nil else {
                    throw ModelCatalogRetentionError.migration
                }
            } else if indexReceipt.index.reservationPhase != "complete" {
                throw ModelCatalogRetentionError.migration
            }
            guard let entry = indexReceipt.index.entries.first(where: { $0.id == selector.transactionID }),
                  entry.classSHA256 == reservation.classFile.sha256,
                  entry.leftSHA256 == reservation.leftFile.sha256 else {
                throw ModelCatalogRetentionError.unsafe
            }
        }
        if !allowImmutable { try provenance.requireMutable() }
        // selector was decoded from these exact unchanged primary bytes.
        guard record.selector == selector else { throw ModelCatalogTransactionError.invalidTransaction }
    }
}

extension ModelCatalogTransactionStore {
    func captureActiveReceipt(selector: ModelCatalogTransactionSelector,
                              budget: ModelTransactionWorkBudget = .init(), allowPendingSuccess: Bool = false,
                              indexReceipt supplied: ModelTransactionIndexReceipt? = nil,
                              heldOwner: ModelCatalogFileLock? = nil) throws -> ModelTransactionActiveReceipt {
        let budget = supplied?.budget ?? budget
        if let heldOwner, heldOwner.resourceName != ".owner-" + selector.transactionID {
            throw ModelCatalogRetentionError.unsafe
        }
        var indexReceipt = try supplied ?? initializeRetentionForActiveEntry(id: selector.transactionID,
                                                                              heldOwner: heldOwner, budget: budget)
        indexReceipt = try recoverReservationPublicationIfNeeded(indexReceipt: indexReceipt,
                                                                 id: selector.transactionID,
                                                                 heldOwner: heldOwner)
        let index = try snapshotIndex(budget: budget, indexReceipt: indexReceipt)
        guard let migration = indexReceipt.migration else { throw ModelCatalogRetentionError.migration }
        guard let entry = index.entries.first(where: { $0.id == selector.transactionID && $0.phase == "active" }) else { throw ModelCatalogTransactionError.invalidTransaction }
        var generation = index.generation
        let primary = try evidence(selector.transactionID + (selector.kind == "cleanup_staging" ? ".cleanup" : ".json"), budget: budget)
        guard let data = primary.bytes else { throw ModelCatalogTransactionError.invalidTransaction }
        let record = try decodeRetentionRecord(data, id: selector.transactionID)
        guard record.selector == selector else { throw ModelCatalogTransactionError.invalidTransaction }
        let originalFile = selector.kind == "cleanup_staging" ? try evidence(selector.transactionID + ".json", budget: budget) : primary
        guard let originalBytes = originalFile.bytes else { throw ModelCatalogRetentionError.unsafe }
        let original = selector.kind == "cleanup_staging" ? try decodeRetentionRecord(originalBytes, id: selector.transactionID) : record
        let provenance = try captureProvenance(original: original, primary: originalFile, entry: entry, budget: budget, migration: migration)
        var reservation = index.schema == "model_catalog_active_index.v4"
            ? try captureReservationAuthority(entry: entry, budget: budget, indexReceipt: indexReceipt)
            : nil
        if let currentReservation = reservation,
           !currentReservation.isPermanentlyNonreusable,
           case .allocated(let allocation) = currentReservation.origin.provenance,
           !initialQueued(original, allocation: allocation) {
            // A crash may leave the truthful first nonreusable primary durable
            // before its immutable exclusion. Take exact UUID custody, recapture
            // the current graph, and complete only that departure before any
            // caller can observe or mutate the record as ordinary active state.
            let acquiredOwner = heldOwner == nil ? try ownerLock(selector.transactionID) : nil
            let owner = heldOwner ?? acquiredOwner!
            defer { withExtendedLifetime(acquiredOwner) {} }
            indexReceipt = try initializeRetentionForActiveEntry(id: selector.transactionID,
                                                                 heldOwner: owner, budget: budget)
            indexReceipt = try recoverReservationPublicationIfNeeded(indexReceipt: indexReceipt,
                                                                     id: selector.transactionID)
            guard indexReceipt.index.entries.contains(where: {
                $0.id == selector.transactionID && $0.phase == "active"
            }) else { throw ModelCatalogTransactionError.invalidTransaction }
            let refreshedPrimary = try evidence(selector.transactionID + ".json", budget: budget)
            guard let refreshedBytes = refreshedPrimary.bytes else {
                throw ModelCatalogTransactionError.invalidTransaction
            }
            let refreshedRecord = try decodeRetentionRecord(refreshedBytes, id: selector.transactionID)
            guard refreshedRecord.selector == selector else {
                throw ModelCatalogTransactionError.invalidTransaction
            }
            indexReceipt = try publishReservationDeparture(record: refreshedRecord,
                                                            primary: refreshedPrimary,
                                                            indexReceipt: indexReceipt)
            guard let anchoredEntry = indexReceipt.index.entries.first(where: {
                $0.id == selector.transactionID && $0.phase == "active"
            }) else { throw ModelCatalogTransactionError.invalidTransaction }
            reservation = try captureReservationAuthority(entry: anchoredEntry, budget: budget,
                                                           indexReceipt: indexReceipt)
            guard reservation?.isPermanentlyNonreusable == true else {
                throw ModelCatalogRetentionError.unsafe
            }
            generation = indexReceipt.index.generation
        }
        if !allowPendingSuccess { try provenance.requireMutable() }
        try retentionBoundary("receipt_captured")
        return .init(record: record, selector: selector, indexGeneration: generation, primary: primary,
                     provenance: provenance, reservation: reservation, indexReceipt: indexReceipt)
    }
    func commit(record: ModelCatalogTransactionRecord, receipt: ModelTransactionActiveReceipt, check: () throws -> Void = {}) throws {
        try validate(record)
        try receipt.validateProspective(record: record)
        guard record.selector == receipt.selector else { throw ModelCatalogTransactionError.invalidTransaction }
        let data = try JSONEncoder().encode(record)
        try locked(nonblocking: true) {
            try receipt.validateLocked(store: self)
            try check()
            try ModelTransactionDirectory.current(root).write(data, name: receipt.primary.name)
        }
        if record.kind != "cleanup_staging" {
            do {
                let written = try evidence(record.transactionID + ".json", budget: receipt.indexReceipt!.budget)
                guard written.bytes == data else { throw ModelCatalogRetentionError.changed }
                _ = try publishReservationDeparture(record: record, primary: written,
                                                     indexReceipt: receipt.indexReceipt!)
            } catch {
                throw ModelTransactionIndexPublicationError.interrupted
            }
        }
    }
    func evidence(_ name: String, budget: ModelTransactionWorkBudget, maxBytes: Int = 4_194_304) throws -> ModelTransactionFileEvidence {
        let directory = try ModelTransactionDirectory.current(root)
        try validatePinnedDirectory(directory)
        return try ModelTransactionFileEvidence(directory: directory, name: name, maxBytes: maxBytes,
            budget: budget, observe: { try retentionBoundary("bulk_read") })
    }
}
