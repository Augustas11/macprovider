import ArgumentParser
import Foundation
import MacProviderCore

extension ModelsCatalogEconomicsCommand {
    func runLocalRead(context: ModelCommandExecutionContext) async throws {
        guard localActivation, model == nil, supportedModels == nil, ctlSocketPath == nil,
              coordinatorURL == nil, providerID == nil else { throw ModelCatalogReadError.contextChanged }
        try readOptions.validate(mode: [.quick, .verify], target: verifyLocalModel)
        guard readOptions.isPresent || verifyLocalModel == nil else { throw ModelCatalogReadError.contextChanged }
        if readOptions.isPresent {
            guard localDiscoveryNamespacePath == nil, mlxCacheDir == nil, ollamaOrigin == nil,
                  openaiCompatibleOrigin == nil, !skipOllama, !skipOpenaiCompatible,
                  !skipCoordinatorStatus else { throw ModelCatalogReadError.contextChanged }
        }
        let mode = readOptions.appReadMode ?? .quick
        let budget = ModelCatalogReadBudget(mode: mode)
        let lease = try ModelCatalogReadLease.start(options: readOptions, budget: budget,
            homeDirectory: { try context.projectionHome ?? ModelTransactionContextLoader.kernelHomeDirectory() })
        defer { withExtendedLifetime(lease) {} }
        let namespace = try ModelTransactionContextLoader.projectionEnvironment(context.projectionEnvironment)
        let home = try context.projectionHome ?? ModelTransactionContextLoader.kernelHomeDirectory()
        let prepared = try ModelTransactionContextLoader.prepareProjection(configPath: config,
            environment: namespace, homeDirectory: home)
        try budget.check()
        let store: ModelCatalogTransactionStore
        let initialBound: BoundModelTransactionContext
        if mode == .verify {
            initialBound = try ModelTransactionContextLoader.existingProjection(prepared,
                expectedDigest: readOptions.expectedContextSHA256!)
            store = .forContext(initialBound)
        } else {
            let setup = try ModelCatalogTransactionStore.prepareProjectionStore(prepared)
            initialBound = try ModelTransactionContextLoader.finalizeProjection(context: prepared, storeIdentity: setup.identity)
            store = .forContext(initialBound)
        }
        try budget.check()
        let initialInputs = await context.inputs().loadRecommendationInputs()
        try budget.check()
        let initialSignedBinding = ModelCatalogSignedInputBinding(initialInputs)
        let inspection = ModelCatalogLocalInspection(root: prepared.durableRoot, budget: budget)
        try inspectCatalogKeys(initialInputs, inspection: inspection, budget: budget)
        let selected: ModelCatalogTransactionAuthority?
        let events: ModelCatalogReadEvents?
        if mode == .verify {
            let authority = try ModelCatalogTransactionAuthority.resolve(target: verifyLocalModel!, inputs: initialInputs)
            guard authority.row.modelID == verifyLocalModel,
                  (try? SupportedModels.validate(model: authority.modelKey, supportedModels: prepared.config.supportedModels)) != nil else {
                throw ModelCatalogReadError.authorityChanged
            }
            selected = authority
            let stream = ModelCatalogReadEvents(requestID: readOptions.appReadRequest!, target: authority.row.modelID,
                key: authority.modelKey, budget: budget)
            try stream.start(); events = stream
        } else { selected = nil; events = nil }
        do {
            var preparedEnvelope: ModelCatalogReadOutput.PreparedEnvelope?
            if let selected {
                let previewWorkBudget = try budget.transactionBudget()
                let previewDiscovery = try await catalogDiscovery(inputs: initialInputs, prepared: prepared,
                    context: context, inspection: inspection, budget: budget)
                let previewCurrentModelID = await readCurrentModelID(config: prepared.config)
                try budget.check()
                let previewAdmissions = try await readOwnedAdmissionStatuses(discovery: previewDiscovery,
                    frozenConfig: prepared.config, context: context, budget: budget)
                try prepareCompleteModelCatalogRecommendationIndexes(inputs: initialInputs, config: prepared.config,
                    store: store, budget: budget, workBudget: previewWorkBudget)
                let previewInventory = try store.captureCompleteCleanupInventory(budget: previewWorkBudget)
                let previewRecoveries = try makeCompleteModelCatalogRecoveries(store: store,
                    inventory: previewInventory, budget: budget, workBudget: previewWorkBudget, reserve: false)
                let previewActions = try makeCompleteModelCatalogLocalActions(inputs: initialInputs,
                    config: prepared.config, store: store, inspection: inspection, budget: budget,
                    workBudget: previewWorkBudget, reserve: false)
                try previewInventory.validate(store: store, budget: previewWorkBudget)
                let preview = ModelCatalogEconomicsBuilder.makeProjection(currentModelID: previewCurrentModelID,
                    discovery: previewDiscovery, admissionStatuses: previewAdmissions, demand: initialInputs.demand,
                    candidateCatalog: initialInputs.candidate, rateCard: initialInputs.rateCard,
                    localActivation: true, localActions: previewActions, localInspection: inspection,
                    transactionContextSHA256: initialBound.projectionDigest, recoveries: previewRecoveries)
                preparedEnvelope = try ModelCatalogReadOutput.preflight(preview,
                    requestID: readOptions.appReadRequest!, targetModelID: selected.row.modelID,
                    modelKey: selected.modelKey, budget: budget)
                try previewInventory.validate(store: store, budget: previewWorkBudget)
                try budget.beginHashing()
                let entry = try inspection.inspect(key: .init(modelKey: selected.modelKey, modelID: selected.row.modelID,
                    revision: selected.row.modelRevision!, sha256: selected.row.modelSHA256!), verify: true,
                    measuredBytes: { try context.catalogReadHashProgress?($0) })
                guard entry.state == .verified else { throw ModelCatalogReadError.artifactInvalid }
                try budget.beginFinalization()
            }
            // The same consumed config is retained while current feed/status
            // observations are refreshed after a long hash.
            let inputs: ModelCatalogRecommendationInputs
            if selected != nil { inputs = await context.inputs().loadRecommendationInputs() }
            else { inputs = initialInputs }
            try budget.check()
            if let selected {
                guard initialSignedBinding == ModelCatalogSignedInputBinding(inputs) else {
                    throw ModelCatalogReadError.authorityChanged
                }
                let current = try ModelCatalogTransactionAuthority.resolve(target: selected.row.modelID, inputs: inputs)
                guard selected.matches(current) else { throw ModelCatalogReadError.authorityChanged }
            }
            try inspectCatalogKeys(inputs, inspection: inspection, budget: budget)
            let discovery = try await catalogDiscovery(inputs: inputs, prepared: prepared, context: context,
                inspection: inspection, budget: budget)
            let currentModelID = await readCurrentModelID(config: prepared.config)
            try budget.check()
            let admissions = try await readOwnedAdmissionStatuses(discovery: discovery,
                frozenConfig: prepared.config, context: context, budget: budget)
            let workBudget = try budget.transactionBudget()
            try prepareCompleteModelCatalogRecommendationIndexes(inputs: inputs, config: prepared.config,
                store: store, budget: budget, workBudget: workBudget)
            let initialInventory = try store.captureCompleteCleanupInventory(budget: workBudget)
            _ = try makeCompleteModelCatalogRecoveries(store: store, inventory: initialInventory,
                budget: budget, workBudget: workBudget)
            let actions = try makeCompleteModelCatalogLocalActions(inputs: inputs, config: prepared.config,
                store: store, inspection: inspection, budget: budget, workBudget: workBudget)
            let finalInventory = try store.captureCompleteCleanupInventory(budget: workBudget)
            let recoveries = try makeCompleteModelCatalogRecoveries(store: store, inventory: finalInventory,
                budget: budget, workBudget: workBudget)
            let sealedInventory = try store.captureCompleteCleanupInventory(budget: workBudget)
            guard sameRecoveryObligations(finalInventory.records, sealedInventory.records) else {
                throw ModelCatalogReadError.verificationIncomplete
            }
            try inspection.validateVerifiedPlacements()
            let bound = try ModelTransactionContextLoader.existingProjection(prepared, expectedDigest: initialBound.projectionDigest)
            try budget.check()
            let document = ModelCatalogEconomicsBuilder.makeProjection(currentModelID: currentModelID,
                discovery: discovery, admissionStatuses: admissions, demand: inputs.demand,
                candidateCatalog: inputs.candidate, rateCard: inputs.rateCard, localActivation: true,
                localActions: actions, localInspection: inspection, transactionContextSHA256: bound.projectionDigest,
                recoveries: recoveries)
            if let selected {
                guard document.rows.contains(where: { $0.modelKey == selected.modelKey &&
                    $0.servedModelID == selected.row.modelID && $0.localVerification?.state == .verified }) else {
                    throw ModelCatalogReadError.verificationIncomplete
                }
            }
            try sealedInventory.validate(store: store, budget: workBudget)
            try budget.check()
            if let events {
                guard let preparedEnvelope else { throw ModelCatalogReadError.verificationIncomplete }
                try events.complete(document, maximumLineBytes: preparedEnvelope.maximumFinalLineBytes)
            }
            else { try ModelCatalogReadOutput.printQuick(document, budget: budget) }
        } catch {
            let classified = (error as? ModelCatalogReadError) ?? .verificationIncomplete
            events?.fail(classified)
            throw classified
        }
    }

    private func readOwnedAdmissionStatuses(discovery: BYOMDiscoveryWire, frozenConfig: AppConfig?,
        context: ModelCommandExecutionContext, budget: ModelCatalogReadBudget) async throws
        -> [String: BYOMAdmissionStatusWire] {
        try budget.check()
        let statuses = await readAdmissionStatuses(discovery: discovery, frozenConfig: frozenConfig,
                                                   context: context)
        try budget.check()
        return statuses
    }

    private func sameRecoveryObligations(_ lhs: [ModelCatalogTransactionRecord],
                                         _ rhs: [ModelCatalogTransactionRecord]) -> Bool {
        func identities(_ records: [ModelCatalogTransactionRecord]) -> [String] {
            records.map {
                [$0.transactionID, $0.operationGeneration ?? "", $0.target, $0.modelKey,
                 $0.events.last?.state ?? "", String($0.cleanupRequired)].joined(separator: "\u{1f}")
            }.sorted()
        }
        return identities(lhs) == identities(rhs)
    }

    private func inspectCatalogKeys(_ inputs: ModelCatalogRecommendationInputs,
        inspection: ModelCatalogLocalInspection, budget: ModelCatalogReadBudget) throws {
        for key in inputs.candidate.value.rows.keys.sorted() {
            try budget.check()
            guard let authority = try? ModelCatalogTransactionAuthority.resolve(target: key, inputs: inputs) else { continue }
            try inspection.inspect(key: .init(modelKey: key, modelID: authority.row.modelID,
                revision: authority.row.modelRevision!, sha256: authority.row.modelSHA256!))
        }
    }

    private func catalogDiscovery(inputs: ModelCatalogRecommendationInputs, prepared: PreparedModelTransactionContext,
        context: ModelCommandExecutionContext, inspection: ModelCatalogLocalInspection,
        budget: ModelCatalogReadBudget) async throws -> BYOMDiscoveryWire {
        try budget.check()
        let environment = context.discoveryEnvironment(BYOMDiscoveryEnvironment.production(
            namespacePath: localDiscoveryNamespacePath, mlxCacheDir: mlxCacheDir,
            ollamaOrigin: skipOllama ? nil : (ollamaOrigin ?? "http://127.0.0.1:11434"),
            openAICompatibleOrigin: skipOpenaiCompatible ? nil : openaiCompatibleOrigin,
            config: prepared.config, catalogMatcher: modelCatalogDiscoveryMatcher(inputs: inputs)))
        let discovery = try await BYOMDiscoveryRunner(environment: environment,
            localInspection: inspection).discoverCatalog()
        try budget.check()
        return discovery
    }
}

enum ModelCatalogReadOutput {
    struct PreparedEnvelope {
        let completedLineBytes: Int
        let maximumFinalLineBytes: Int
    }
    static let rawLineLimit = 1_048_576
    static let preflightReserve = 2_048
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return value
    }
    static func printQuick(_ document: ModelCatalogEconomicsWire, budget: ModelCatalogReadBudget) throws {
        let bytes = try encoder().encode(document)
        try budget.check()
        guard bytes.count < 8_388_608 else { throw ModelCatalogReadError.readLimitExceeded }
        try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
    }
    static func preflight(_ document: ModelCatalogEconomicsWire, requestID: String,
                          targetModelID: String, modelKey: String,
                          budget: ModelCatalogReadBudget) throws -> PreparedEnvelope {
        try budget.check()
        var object = try JSONSerialization.jsonObject(with: encoder().encode(document)) as! [String: Any]
        var rows = object["rows"] as! [[String: Any]]
        let uuid = "00000000-0000-4000-8000-000000000000"
        for index in rows.indices {
            try budget.check()
            rows[index]["action_model_id"] = rows[index]["served_model_id"]
            for (field, kind) in [("prepare", "prepare_model"), ("evaluate", "evaluate_model"),
                                  ("adopt_recommendation", "adopt_recommendation"), ("cleanup_staging", "cleanup_staging")] {
                let action: [String: Any] = ["available": true, "requires_confirmation": true,
                    "transaction_kind": kind, "transaction_id": uuid, "operation_generation": uuid,
                    "action_timeout_seconds": 1800, "estimated_bytes": Int64.max, "unavailable_reason": NSNull()]
                let old = rows[index][field] as? [String: Any] ?? [:]
                let oldSize = try JSONSerialization.data(withJSONObject: old).count
                if try JSONSerialization.data(withJSONObject: action).count > oldSize { rows[index][field] = action }
            }
        }
        object["rows"] = rows
        let inflatedBytes = try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let sizingProjection = try JSONDecoder().decode(ModelCatalogEconomicsWire.self, from: inflatedBytes)
        let line = try ModelCatalogReadEvents.encodedLine(
            requestID: requestID, eventSequence: 4_096, targetModelID: targetModelID,
            modelKey: modelKey, kind: "completed", bytesCompleted: UInt64.max,
            errorCode: nil, projection: sizingProjection)
        try budget.check()
        let ceiling = rawLineLimit.subtractingReportingOverflow(preflightReserve)
        guard !ceiling.overflow, line.count <= ceiling.partialValue else {
            throw ModelCatalogReadError.readLimitExceeded
        }
        let maximum = line.count.addingReportingOverflow(preflightReserve)
        guard !maximum.overflow, maximum.partialValue <= rawLineLimit else {
            throw ModelCatalogReadError.readLimitExceeded
        }
        return .init(completedLineBytes: line.count, maximumFinalLineBytes: maximum.partialValue)
    }
}
