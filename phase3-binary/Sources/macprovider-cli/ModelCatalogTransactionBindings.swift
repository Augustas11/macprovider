import CryptoKit
import Foundation

enum ModelTransactionBindingPublicationError: Error { case pending }

struct ModelTransactionOrigin: Codable {
    struct Allocation: Codable {
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
        let initialPrimarySHA256: String
    }
    enum Provenance: Codable {
        case allocated(Allocation)
        case legacySnapshot(primarySHA256: String)
        case protectedSnapshot(primarySHA256: String?)
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
    let provenance: Provenance

    static func allocated(_ record: ModelCatalogTransactionRecord, primarySHA256: String) throws -> Self {
        guard let generation = record.operationGeneration else { throw ModelCatalogRetentionError.unsafe }
        return .init(schema: "model_catalog_transaction_origin.v1", transactionID: record.transactionID,
            provenance: .allocated(.init(operationGeneration: generation, kind: record.kind, createdAt: record.createdAt,
                target: record.target, modelKey: record.modelKey, revision: record.revision, sha256: record.sha256,
                candidateDigest: record.candidateDigest, artifactDigest: record.artifactDigest,
                signerKeyID: record.signerKeyID, initialPrimarySHA256: primarySHA256)))
    }
    func validate(_ record: ModelCatalogTransactionRecord, primarySHA256: String?) throws {
        guard schema == "model_catalog_transaction_origin.v1", transactionID == record.transactionID else {
            throw ModelCatalogRetentionError.unsafe
        }
        switch provenance {
        case .allocated(let value):
            guard record.operationGeneration == value.operationGeneration, record.kind == value.kind,
                  record.createdAt == value.createdAt, record.target == value.target, record.modelKey == value.modelKey,
                  record.revision == value.revision, record.sha256 == value.sha256,
                  record.candidateDigest == value.candidateDigest, record.artifactDigest == value.artifactDigest,
                  record.signerKeyID == value.signerKeyID else { throw ModelCatalogRetentionError.unsafe }
        case .legacySnapshot(let hash):
            guard record.operationGeneration == nil, primarySHA256 == hash else { throw ModelCatalogRetentionError.unsafe }
        case .protectedSnapshot: throw ModelCatalogRetentionError.unsafe
        }
    }
}

struct ModelTransactionSuccessBinding: Codable {
    struct TerminalDelta: Codable { let cleanupRequired: Bool }
    let schema: String
    let transactionID: String
    let operationGeneration: String
    let originSHA256: String
    let contextSHA256: String
    let successCommitmentSHA256: String
    let resultSHA256: String
    let preterminalPrimarySHA256: String
    let terminalEvent: ModelCatalogTransactionEvent
    let terminalDelta: TerminalDelta
    let terminalPrimarySHA256: String
}

struct ModelTransactionRetirementCertificate: Codable {
    enum File: Codable { case absent; case present(sha256: String) }
    enum Cleanup: Codable {
        case absent
        case present(sha256: String, operationGeneration: String, terminalState: String)
        case legacyPresent(sha256: String, terminalState: String)
    }
    struct Snapshot: Codable {
        let primarySHA256: String
        let result: File
        let seal: File
        let cleanup: Cleanup
    }
    enum Outcome: Codable {
        case evaluationSuccess(operationGeneration: String, bindingSHA256: String, contextSHA256: String,
                               successCommitmentSHA256: String, resultSHA256: String, cleanup: Cleanup)
        case prepareSuccessSnapshot(operationGeneration: String, snapshot: Snapshot)
        case prepareNonSuccessSnapshot(operationGeneration: String, terminalState: String, snapshot: Snapshot)
        case evaluationNonSuccessSnapshot(operationGeneration: String, terminalState: String, snapshot: Snapshot)
        case legacyTerminalSnapshot(kind: String, terminalState: String, snapshot: Snapshot)
    }
    let schema: String
    let transactionID: String
    let originSHA256: String
    let outcome: Outcome
}

/// Captures provenance before mutable primary state can select a weaker branch.
struct ModelTransactionProvenanceReceipt {
    let origin: ModelTransactionOrigin
    let originFile: ModelTransactionFileEvidence
    let bindingFile: ModelTransactionFileEvidence
    let retiredFile: ModelTransactionFileEvidence
    let originalFile: ModelTransactionFileEvidence
    let binding: ModelTransactionSuccessBinding?
    let expectedBindingSHA256: String?
    let migration: ModelTransactionMigrationCompletionReceipt
    func validateFiles() throws {
        try migration.validateFiles()
        for item in [originFile, bindingFile, retiredFile, originalFile] { try item.validate() }
    }
    func validateProspective(_ record: ModelCatalogTransactionRecord) throws {
        try requireMutable()
        if record.kind == "cleanup_staging" {
            guard case .allocated(let allocation) = origin.provenance,
                  record.transactionID == origin.transactionID, record.target == allocation.target,
                  record.modelKey == allocation.modelKey, record.revision == allocation.revision,
                  record.sha256 == allocation.sha256, record.candidateDigest == allocation.candidateDigest,
                  record.artifactDigest == allocation.artifactDigest, record.signerKeyID == allocation.signerKeyID else { throw ModelCatalogRetentionError.unsafe }
        } else {
            try origin.validate(record, primarySHA256: nil)
            if let binding {
                let store = ModelCatalogTransactionStore(root: originalFile.directory.url)
                guard record.events.last?.state == "succeeded", try store.successDigest(record) == binding.successCommitmentSHA256 else { throw ModelCatalogRetentionError.unsafe }
            } else if record.kind == "evaluate_model", record.events.last?.state == "succeeded" {
                throw ModelCatalogRetentionError.unsafe
            }
        }
    }
    func requireMutable() throws {
        guard retiredFile.bytes == nil else { throw ModelCatalogRetentionError.unsafe }
        // A terminal success may undergo its existing cleanup bookkeeping. A
        // nonterminal pending success must be replayed before any ordinary write.
        if binding != nil {
            let original = try JSONDecoder().decode(ModelCatalogTransactionRecord.self, from: originalFile.bytes!)
            guard original.terminal else { throw ModelCatalogRetentionError.unsafe }
        }
    }
}

extension ModelCatalogTransactionStore {
    func bindingBytes<T: Encodable>(_ value: T) throws -> Data {
        let bytes = try canonicalData(value)
        guard bytes.count <= 16_384 else { throw ModelCatalogRetentionError.unsafe }
        return bytes
    }
    func captureProvenance(original: ModelCatalogTransactionRecord, primary: ModelTransactionFileEvidence,
                           entry: ModelTransactionActiveIndex.Entry?, budget: ModelTransactionWorkBudget,
                           migration: ModelTransactionMigrationCompletionReceipt? = nil) throws -> ModelTransactionProvenanceReceipt {
        let migration = try migration ?? captureMigrationCompletion(budget: budget)
        let id = original.transactionID
        let originFile = try evidence(id + ".origin", budget: budget, maxBytes: 16_384)
        let bindingFile = try evidence(id + ".success-binding", budget: budget, maxBytes: 16_384)
        let retiredFile = try evidence(id + ".retired", budget: budget, maxBytes: 16_384)
        guard let bytes = originFile.bytes else { throw ModelCatalogRetentionError.unsafe }
        let origin = try closedDecode(ModelTransactionOrigin.self, bytes)
        if let entry {
            guard entry.originSHA256 == originFile.sha256, entry.provenance == origin.provenance.name else {
                throw ModelCatalogRetentionError.unsafe
            }
        }
        try origin.validate(original, primarySHA256: primary.sha256)
        let binding = try bindingFile.bytes.map { try closedDecode(ModelTransactionSuccessBinding.self, $0) }
        if let expected = entry?.bindingSHA256 {
            guard bindingFile.sha256 == expected else { throw ModelCatalogRetentionError.unsafe }
        }
        if let binding {
            guard binding.schema == "model_catalog_evaluation_success_binding.v2", binding.transactionID == id,
                  binding.operationGeneration == original.operationGeneration, binding.originSHA256 == originFile.sha256,
                  original.kind == "evaluate_model" else { throw ModelCatalogRetentionError.unsafe }
            if original.terminal {
                guard original.events.last?.state == "succeeded", entry == nil || entry?.bindingSHA256 == bindingFile.sha256,
                      try successDigest(original) == binding.successCommitmentSHA256 else { throw ModelCatalogRetentionError.unsafe }
            } else {
                guard primary.sha256 == binding.preterminalPrimarySHA256 else { throw ModelCatalogRetentionError.unsafe }
            }
        } else if original.operationGeneration != nil, original.kind == "evaluate_model", original.events.last?.state == "succeeded" {
            throw ModelCatalogRetentionError.unsafe
        }
        if entry == nil, retiredFile.bytes == nil { throw ModelCatalogRetentionError.unsafe }
        return .init(origin: origin, originFile: originFile, bindingFile: bindingFile, retiredFile: retiredFile,
                     originalFile: primary, binding: binding, expectedBindingSHA256: entry?.bindingSHA256, migration: migration)
    }
}

extension ModelCatalogTransactionStore {
    /// Caller keeps the original UUID owner. A partially published binding is
    /// recovered explicitly, never retried as an ordinary terminal mutation.
    func commitEvaluationSuccess(preterminal: ModelTransactionActiveReceipt, terminal: ModelCatalogTransactionRecord,
                                 result: ModelTransactionFileEvidence,
                                 budget: ModelTransactionWorkBudget = .init(),
                                 check: () throws -> Void = {}) throws -> ModelCatalogTransactionRecord {
        let index = try snapshotIndex(budget: budget, indexReceipt: preterminal.indexReceipt)
        guard index.generation == preterminal.indexGeneration else { throw ModelCatalogRetentionError.changed }
        guard index.generation < UInt64.max,
              let position = index.entries.firstIndex(where: { $0.id == terminal.transactionID && $0.phase == "active" }),
              let event = terminal.events.last, let generation = terminal.operationGeneration,
              let provenance = preterminal.provenance, provenance.bindingFile.bytes == nil,
              provenance.retiredFile.bytes == nil, let originHash = provenance.originFile.sha256,
              let data = result.bytes, let preterminalHash = preterminal.primary.sha256 else { throw ModelCatalogRetentionError.unsafe }
        let rebuilt = try evaluationSuccessTerminal(preterminal: preterminal.record, cleanupRequired: terminal.cleanupRequired, event: event)
        let terminalBytes = try canonicalData(terminal)
        guard try canonicalData(rebuilt) == terminalBytes else { throw ModelCatalogRetentionError.unsafe }
        _ = try validatedCommittedResult(terminal, data: data)
        let parsed = try ModelsAdoptRecommendationCommand.parseRecommendation(data: data, enforceFreshness: false)
        let binding = ModelTransactionSuccessBinding(schema: "model_catalog_evaluation_success_binding.v2",
            transactionID: terminal.transactionID, operationGeneration: generation, originSHA256: originHash,
            contextSHA256: digest(try canonicalData(recommendationContext(terminal, parsed))),
            successCommitmentSHA256: try successDigest(terminal), resultSHA256: digest(data),
            preterminalPrimarySHA256: preterminalHash, terminalEvent: event,
            terminalDelta: .init(cleanupRequired: terminal.cleanupRequired), terminalPrimarySHA256: digest(terminalBytes))
        let bytes = try bindingBytes(binding)
        var next = index; next.generation += 1; next.entries[position].bindingSHA256 = digest(bytes)
        let indexBytes = try canonicalData(next)
        try budget.check()
        try locked(nonblocking: true) {
            try preterminal.validateLocked(store: self); try result.validate()
            let directory = try ModelTransactionDirectory.current(root)
            try budget.check(); try check()
            do {
            try directory.write(bytes, name: terminal.transactionID + ".success-binding", exclusive: true, maxBytes: 16_384)
            try retentionBoundary("success_binding_published")
            try budget.check(); try check()
            try retentionDirectory().write(indexBytes, name: "active.json", maxBytes: Self.indexLimit)
            try retentionBoundary("success_binding_referenced")
            try budget.check(); try check()
            try directory.write(terminalBytes, name: terminal.transactionID + ".json")
            try retentionBoundary("success_terminal_published")
            } catch { throw ModelTransactionBindingPublicationError.pending }
        }
        return terminal
    }
    /// Requires caller-held current owner. Missing proof returns nil only when
    /// no binding or expected binding exists; malformed pending proof throws.
    func recoverBoundEvaluationSuccess(selector: ModelCatalogTransactionSelector,
                                       budget: ModelTransactionWorkBudget = .init(),
                                       heldOwner: ModelCatalogFileLock? = nil,
                                       check: () throws -> Void = {}) throws -> ModelCatalogTransactionRecord? {
        let receipt = try captureActiveReceipt(selector: selector, budget: budget, allowPendingSuccess: true,
                                               heldOwner: heldOwner)
        guard let provenance = receipt.provenance else { throw ModelCatalogRetentionError.unsafe }
        guard let binding = provenance.binding else { return nil }
        let result = try evidence(selector.transactionID + ".result", budget: budget)
        guard let data = result.bytes, result.sha256 == binding.resultSHA256 else { throw ModelCatalogRetentionError.unsafe }
        _ = try validatedCommittedResult(receipt.record, data: data)
        if receipt.record.terminal {
            try locked(nonblocking: true) {
                try receipt.validateLocked(store: self, allowImmutable: true); try result.validate(); try budget.check(); try check()
            }
            return receipt.record
        }
        let terminal = try evaluationSuccessTerminal(preterminal: receipt.record, cleanupRequired: binding.terminalDelta.cleanupRequired, event: binding.terminalEvent)
        let terminalBytes = try canonicalData(terminal)
        let parsed = try ModelsAdoptRecommendationCommand.parseRecommendation(data: data, enforceFreshness: false)
        guard digest(terminalBytes) == binding.terminalPrimarySHA256,
              try successDigest(terminal) == binding.successCommitmentSHA256,
              digest(try canonicalData(recommendationContext(terminal, parsed))) == binding.contextSHA256 else {
            throw ModelCatalogRetentionError.unsafe
        }
        var index = try snapshotIndex(budget: budget, indexReceipt: receipt.indexReceipt)
        guard index.generation == receipt.indexGeneration, index.generation < UInt64.max,
              let position = index.entries.firstIndex(where: { $0.id == selector.transactionID && $0.phase == "active" }) else {
            throw ModelCatalogRetentionError.changed
        }
        let needsReference = index.entries[position].bindingSHA256 == nil
        if needsReference { index.entries[position].bindingSHA256 = provenance.bindingFile.sha256; index.generation += 1 }
        let indexBytes = try canonicalData(index)
        try budget.check()
        try locked(nonblocking: true) {
            try receipt.validateLocked(store: self, allowImmutable: true); try result.validate()
            guard provenance.retiredFile.bytes == nil else { throw ModelCatalogRetentionError.unsafe }
            if needsReference {
                try budget.check(); try check()
                try retentionDirectory().write(indexBytes, name: "active.json", maxBytes: Self.indexLimit)
                try retentionBoundary("success_binding_referenced")
            }
            try budget.check(); try check()
            try ModelTransactionDirectory.current(root).write(terminalBytes, name: selector.transactionID + ".json")
            try retentionBoundary("success_terminal_published")
        }
        return terminal
    }
}
