import Foundation

struct ModelTransactionRetirementProof {
    let certificate: ModelTransactionRetirementCertificate
    let bytes: Data
    let provenance: ModelTransactionProvenanceReceipt
    let result: ModelTransactionFileEvidence
    let seal: ModelTransactionFileEvidence
    let cleanup: ModelTransactionFileEvidence
    func validate(_ store: ModelCatalogTransactionStore) throws {
        try provenance.validateFiles()
        for file in [result, seal, cleanup] { try file.validate() }
        guard try ModelTransactionDirectory.current(store.root).metadata("staging-" + certificate.transactionID) == nil else {
            throw ModelCatalogRetentionError.changed
        }
    }
}

extension ModelCatalogTransactionStore {
    func captureRetirementProof(record: ModelCatalogTransactionRecord, primary: ModelTransactionFileEvidence,
                                provenance: ModelTransactionProvenanceReceipt,
                                budget: ModelTransactionWorkBudget) throws -> ModelTransactionRetirementProof {
        guard record.terminal, !record.cleanupRequired, let primaryHash = primary.sha256,
              let originHash = provenance.originFile.sha256,
              try ModelTransactionDirectory.current(root).metadata("staging-" + record.transactionID) == nil else {
            throw ModelCatalogRetentionError.unsafe
        }
        let id = record.transactionID
        let result = try evidence(id + ".result", budget: budget)
        let seal = try evidence(id + ".seal", budget: budget)
        let cleanup = try evidence(id + ".cleanup", budget: budget)
        let resultValue: ModelTransactionRetirementCertificate.File
        let sealValue: ModelTransactionRetirementCertificate.File
        if let data = result.bytes {
            _ = try validatedCommittedResult(record, data: data)
            resultValue = .present(sha256: result.sha256!)
        } else {
            guard record.resultSHA256 == nil else { throw ModelCatalogRetentionError.unsafe }
            resultValue = .absent
        }
        if let data = seal.bytes {
            _ = try validatedPreparationSeal(record, data: data)
            sealValue = .present(sha256: seal.sha256!)
        } else {
            guard record.artifactSealSHA256 == nil else { throw ModelCatalogRetentionError.unsafe }
            sealValue = .absent
        }
        let cleanupValue: ModelTransactionRetirementCertificate.Cleanup
        if let data = cleanup.bytes {
            let stream = try decodeRetentionRecord(data, id: id)
            guard stream.kind == "cleanup_staging", stream.terminal, stream.target == record.target,
                  stream.modelKey == record.modelKey, stream.revision == record.revision, stream.sha256 == record.sha256,
                  stream.candidateDigest == record.candidateDigest, stream.artifactDigest == record.artifactDigest,
                  stream.signerKeyID == record.signerKeyID, let state = stream.events.last?.state else { throw ModelCatalogRetentionError.unsafe }
            if let generation = stream.operationGeneration {
                cleanupValue = .present(sha256: cleanup.sha256!, operationGeneration: generation, terminalState: state)
            } else {
                guard record.operationGeneration == nil else { throw ModelCatalogRetentionError.unsafe }
                cleanupValue = .legacyPresent(sha256: cleanup.sha256!, terminalState: state)
            }
        } else { cleanupValue = .absent }
        let snapshot = ModelTransactionRetirementCertificate.Snapshot(primarySHA256: primaryHash,
            result: resultValue, seal: sealValue, cleanup: cleanupValue)
        let outcome: ModelTransactionRetirementCertificate.Outcome
        guard let state = record.events.last?.state else { throw ModelCatalogRetentionError.unsafe }
        switch provenance.origin.provenance {
        case .protectedSnapshot: throw ModelCatalogRetentionError.unsafe
        case .legacySnapshot:
            guard record.operationGeneration == nil, ["prepare_model", "evaluate_model"].contains(record.kind),
                  !(record.kind == "evaluate_model" && state == "succeeded" && result.bytes == nil) else { throw ModelCatalogRetentionError.unsafe }
            outcome = .legacyTerminalSnapshot(kind: record.kind, terminalState: state, snapshot: snapshot)
        case .allocated:
            guard let generation = record.operationGeneration else { throw ModelCatalogRetentionError.unsafe }
            switch (record.kind, state) {
            case ("evaluate_model", "succeeded"):
                guard record.committed, let binding = provenance.binding, let bindingHash = provenance.bindingFile.sha256,
                      let resultHash = result.sha256, resultHash == binding.resultSHA256, seal.bytes == nil else { throw ModelCatalogRetentionError.unsafe }
                outcome = .evaluationSuccess(operationGeneration: generation, bindingSHA256: bindingHash,
                    contextSHA256: binding.contextSHA256, successCommitmentSHA256: try successDigest(record),
                    resultSHA256: resultHash, cleanup: cleanupValue)
            case ("prepare_model", "succeeded"):
                guard record.committed, record.startedAt != nil, seal.bytes != nil, result.bytes == nil else { throw ModelCatalogRetentionError.unsafe }
                outcome = .prepareSuccessSnapshot(operationGeneration: generation, snapshot: snapshot)
            case ("prepare_model", "failed"), ("prepare_model", "cancelled"), ("prepare_model", "timed_out"):
                guard result.bytes == nil, record.committed == (seal.bytes != nil) else { throw ModelCatalogRetentionError.unsafe }
                outcome = .prepareNonSuccessSnapshot(operationGeneration: generation, terminalState: state, snapshot: snapshot)
            case ("evaluate_model", "failed"), ("evaluate_model", "cancelled"), ("evaluate_model", "timed_out"):
                guard provenance.binding == nil, seal.bytes == nil, record.committed == (result.bytes != nil) else { throw ModelCatalogRetentionError.unsafe }
                outcome = .evaluationNonSuccessSnapshot(operationGeneration: generation, terminalState: state, snapshot: snapshot)
            default: throw ModelCatalogRetentionError.unsafe
            }
        }
        let certificate = ModelTransactionRetirementCertificate(schema: "model_catalog_transaction_retirement.v1",
            transactionID: id, originSHA256: originHash, outcome: outcome)
        let bytes = try bindingBytes(certificate)
        if let previous = provenance.retiredFile.bytes {
            _ = try closedDecode(ModelTransactionRetirementCertificate.self, previous)
            guard previous == bytes else { throw ModelCatalogRetentionError.unsafe }
        }
        return .init(certificate: certificate, bytes: bytes, provenance: provenance, result: result, seal: seal, cleanup: cleanup)
    }
    /// Validation for a direct historical original never creates an owner or
    /// active entry. Archived generated eligibility requires its certificate.
    func validateOriginalBindingEvidence(_ record: ModelCatalogTransactionRecord,
                                         budget: ModelTransactionWorkBudget = .init()) throws {
        let primary = try evidence(record.transactionID + ".json", budget: budget)
        guard let bytes = primary.bytes else { throw ModelCatalogRetentionError.unsafe }
        let current = try decodeRetentionRecord(bytes, id: record.transactionID)
        guard try canonicalData(current) == canonicalData(record) else { throw ModelCatalogRetentionError.changed }
        let indexReceipt = try captureIndexReceipt(budget: budget)
        guard let migration = indexReceipt.migration else { throw ModelCatalogRetentionError.migration }
        let entry = indexReceipt.index.entries.first { $0.id == record.transactionID && $0.phase == "active" }
        let provenance = try captureProvenance(original: current, primary: primary, entry: entry, budget: budget, migration: migration)
        var proof: ModelTransactionRetirementProof?
        if provenance.retiredFile.bytes != nil {
            proof = try captureRetirementProof(record: current, primary: primary, provenance: provenance, budget: budget)
        } else if entry == nil { throw ModelCatalogRetentionError.unsafe }
        var result: ModelTransactionFileEvidence?
        if current.operationGeneration != nil, current.kind == "evaluate_model", current.events.last?.state == "succeeded" {
            let file = try evidence(current.transactionID + ".result", budget: budget)
            guard let data = file.bytes, file.sha256 == provenance.binding?.resultSHA256 else { throw ModelCatalogRetentionError.unsafe }
            _ = try validatedCommittedResult(current, data: data)
            let parsed = try ModelsAdoptRecommendationCommand.parseRecommendation(data: data, enforceFreshness: false)
            guard digest(try canonicalData(recommendationContext(current, parsed))) == provenance.binding?.contextSHA256 else { throw ModelCatalogRetentionError.unsafe }
            result = file
        }
        try locked(nonblocking: true) {
            try indexReceipt.validateLocked(store: self)
            try provenance.validateFiles(); try proof?.validate(self); try result?.validate(); try budget.check()
        }
    }
}
