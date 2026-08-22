import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore

struct ModelsCatalogEconomicsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog-economics",
        abstract: "Emit the model catalog economics projection for provider UX."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths). Overrides MACPROVIDER_SUPPORTED_MODELS and config supported_models.")
    var supportedModels: String?

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock.")
    var ctlSocketPath: String?

    @Flag(name: .customLong("json"), help: "Emit the strict model_catalog_economics.v1 JSON contract.")
    var emitJSON = false

    func run() async throws {
        guard emitJSON else {
            throw ValidationError("catalog-economics requires --json")
        }

        let startedAt = Date()
        let launchID = UUID().uuidString.lowercased()
        let resolved = try loadModelsConfig(
            config: config,
            model: model,
            supportedModels: supportedModels,
            ctlSocketPath: ctlSocketPath
        )
        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)

        let currentModelID: String?
        let supported: [String]
        let authorizedKeys: Set<String>?
        do {
            let (connection, status) = try await connectAndReadStatus(socketPath: socketPath)
            try await connection.send(.modelsRequest)
            let modelsFrame = try await connection.receive(timeout: 2.0)
            guard case let .modelsResponse(authorizedModelIDs, supportedModelIDs) = modelsFrame else {
                await connection.close()
                throw ControlSocketConnectError.handshakeTimeout(path: socketPath.path)
            }
            await connection.close()
            currentModelID = status.currentModelID
            supported = Self.mergeModelCatalog(
                configured: resolved.supportedModels,
                runtimeSupported: supportedModelIDs,
                authorized: authorizedModelIDs,
                current: status.currentModelID
            )
            authorizedKeys = Set(authorizedModelIDs.map(modelIDKey))
        } catch ControlSocketConnectError.socketAbsent {
            currentModelID = nil
            supported = idleCatalog(from: resolved)
            authorizedKeys = nil
        } catch ControlSocketConnectError.connectionRefused(let path) {
            writeStderr("stale control socket at \(path) (no listener); remove the file and restart serve")
            throw ExitCode(4)
        } catch ControlSocketConnectError.handshakeTimeout {
            writeStderr("serve is running but model catalog economics cannot read runtime models; restart serve with --enable-warm-swap")
            throw ExitCode(4)
        }

        let wire = try ModelCatalogEconomicsProjectionBuilder.build(
            currentModelID: currentModelID,
            supportedModels: supported,
            authorizedModelKeys: authorizedKeys,
            processLaunchID: launchID,
            processStartedAt: startedAt
        )
        try ModelSwitchingWireCodec.printJSON(wire)
    }

    private static func mergeModelCatalog(
        configured: [String]?,
        runtimeSupported: [String],
        authorized: [String],
        current: String
    ) -> [String] {
        var models = runtimeSupported.isEmpty ? (configured ?? []) : runtimeSupported
        for authorizedModelID in authorized where !models.contains(where: { modelIDKey($0) == modelIDKey(authorizedModelID) }) {
            models.append(authorizedModelID)
        }
        if !models.contains(where: { modelIDKey($0) == modelIDKey(current) }) {
            models.insert(current, at: 0)
        }
        return models
    }
}

enum ModelCatalogEconomicsProjectionBuilder {
    static let projectionProtocolVersion = "spec-044-cli-v1"
    static let staticFallbackMaxAgeSeconds = 604_800

    static func build(
        currentModelID: String?,
        supportedModels: [String],
        authorizedModelKeys: Set<String>?,
        processLaunchID: String,
        processStartedAt: Date
    ) throws -> ModelCatalogEconomicsWire {
        let demandBytes = Data(AutotuneStaticInputs.bakedDemandRankJSON.utf8)
        let candidateBytes = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        let rateBytes = Data(AutotuneStaticInputs.bakedRateCardJSON.utf8)
        let demand = try AutotuneStaticInputs.decodeDemandRank(demandBytes)
        let candidate = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
        let rateCard = try AutotuneStaticInputs.decodeRateCard(rateBytes)
        return try build(
            currentModelID: currentModelID,
            supportedModels: supportedModels,
            authorizedModelKeys: authorizedModelKeys,
            processLaunchID: processLaunchID,
            processStartedAt: processStartedAt,
            demand: demand,
            candidate: candidate,
            rateCard: rateCard,
            demandBytes: demandBytes,
            candidateBytes: candidateBytes,
            rateBytes: rateBytes
        )
    }

    static func build(
        currentModelID: String?,
        supportedModels: [String],
        authorizedModelKeys: Set<String>?,
        processLaunchID: String,
        processStartedAt: Date,
        demand: DemandRank,
        candidate: CandidateCatalog,
        rateCard: RateCardProjection,
        demandBytes: Data,
        candidateBytes: Data,
        rateBytes: Data
    ) throws -> ModelCatalogEconomicsWire {
        let generatedAt = Date()
        let rateCardIsStale = generatedAt.timeIntervalSince(rateCard.generatedAt) > Double(staticFallbackMaxAgeSeconds)
        var projectionWarnings = ["feed_fallback"]
        if rateCardIsStale {
            projectionWarnings.append("feed_stale")
        }
        let source = ModelCatalogEconomicsWire.Source(
            cliVersion: CoordinatorClient.binaryVersion,
            cliBuildCommit: sanitizedBuildCommit(ProcessInfo.processInfo.environment["MACPROVIDER_BUILD_COMMIT"]),
            processLaunchID: processLaunchID,
            processStartedAt: ModelSwitchingWireCodec.timestamp(processStartedAt),
            projectionProtocolVersion: projectionProtocolVersion,
            rateCardSource: "static_signed",
            rateCardDigest: sha256Hex(rateBytes),
            rateCardSignatureDigest: nil,
            demandFeedDigest: sha256Hex(demandBytes),
            candidateFeedDigest: sha256Hex(candidateBytes),
            rateCardMaxAgeSeconds: staticFallbackMaxAgeSeconds
        )

        let supportedKeys = Set(supportedModels.map(modelIDKey))
        let currentKey = currentModelID.map(modelIDKey)
        let rows = try candidate.rows.keys.sorted().compactMap { modelKey -> ModelCatalogEconomicsWire.Row? in
            guard let catalogRow = candidate.rows[modelKey] else { return nil }
            guard ModelSwitchingWireCodec.safeID(modelKey),
                  ModelSwitchingWireCodec.safeID(catalogRow.modelID) else {
                throw ValidationError("catalog economics contains an invalid model identifier")
            }

            let rate = rateCard.rowForRecommendation(modelKey: modelKey)
            let demandRow = demand.rows[modelKey]
            let fit = fitLabel(ModelFit.evaluate(modelID: catalogRow.modelID, ramGB: ModelFit.detectRAMGB()))
            let isCurrent = currentKey == modelIDKey(catalogRow.modelID) || currentKey == modelIDKey(modelKey)
            let weightsPresent = isCurrent
                || (authorizedModelKeys?.contains(modelIDKey(catalogRow.modelID)) == true)
                || (authorizedModelKeys?.contains(modelIDKey(modelKey)) == true)
                || (authorizedModelKeys == nil && supportedKeys.contains(modelIDKey(catalogRow.modelID)) && exactLocalArtifactPresent(modelID: catalogRow.modelID))
            let runtimeState = runtimeState(
                catalogRow: catalogRow,
                isCurrent: isCurrent,
                weightsPresent: weightsPresent,
                fit: fit
            )
            let disabledReason = disabledReason(
                catalogRow: catalogRow,
                runtimeState: runtimeState,
                fit: fit
            )
            let blockedEconomics = economicsBlocked(runtimeStatus: catalogRow.runtimeStatus, fit: fit)
            let actions = unavailableActions(
                reason: rate == nil ? "economics_unavailable" : "static_fallback_not_trusted"
            )
            let economics = economicsFields(rate: blockedEconomics ? nil : rate?.row, rateCard: rateCard)
            var warnings = ["feed_fallback"]
            if rateCardIsStale {
                warnings.append("feed_stale")
            }
            if rate == nil {
                warnings.append("projection_unavailable")
            }
            if catalogRow.runtimeStatus == "blocked" {
                warnings.append("model_not_supported")
            }
            if fit == "does_not_fit" {
                warnings.append("hardware_does_not_fit")
            }
            if fit == "unknown" {
                warnings.append("hardware_fit_unknown")
            }
            if !weightsPresent {
                warnings.append("model_not_local")
            }

            return ModelCatalogEconomicsWire.Row(
                modelKey: modelKey,
                servedModelID: rate.map { rateCard.servedModelKey(modelKey: modelKey, rateCardKey: $0.key) } ?? catalogRow.modelID,
                displayModelID: catalogRow.modelID,
                actionModelID: catalogRow.runtimeStatus == "blocked" ? nil : catalogRow.modelID,
                isCurrent: isCurrent,
                weightsPresentLocally: weightsPresent,
                runtimeState: runtimeState,
                estimatedGB: ModelFit.estimateWeightSizeGB(modelID: catalogRow.modelID).map(Double.init),
                fit: fit,
                disabledReason: disabledReason,
                warningCodes: warnings.sorted(),
                rateCardVersion: blockedEconomics || rate == nil ? nil : rateCard.version,
                rateCardGeneratedAt: blockedEconomics || rate == nil ? nil : ModelSwitchingWireCodec.timestamp(rateCard.generatedAt),
                rateCardKey: blockedEconomics ? nil : rate?.key,
                rateSource: blockedEconomics || rate == nil ? "none" : "static_signed",
                promptRateUSDPerMillionTokens: economics.prompt,
                completionRateUSDPerMillionTokens: economics.completion,
                providerShareBPS: blockedEconomics ? nil : rate?.row.providerShareBPS,
                providerPromptPayoutUSDPerMillionTokens: economics.providerPrompt,
                providerCompletionPayoutUSDPerMillionTokens: economics.providerCompletion,
                economicsState: economicsState(blocked: blockedEconomics, hasRate: rate != nil, stale: rateCardIsStale),
                demandRank: demandRow?.rank,
                demandWeight: demandRow?.demandWeight,
                readyProviderCount: demandRow?.readyProviderCount,
                supplyDeficitScore: demandRow?.effectiveSupplyDeficitMultiplier,
                actions: actions
            )
        }

        return ModelCatalogEconomicsWire(
            generatedAt: ModelSwitchingWireCodec.timestamp(generatedAt),
            projectionSequence: 1,
            source: source,
            warnings: projectionWarnings.sorted(),
            rows: rows
        )
    }

    private static func runtimeState(
        catalogRow: CandidateCatalog.Row,
        isCurrent: Bool,
        weightsPresent: Bool,
        fit: String
    ) -> String {
        if isCurrent { return "current" }
        if catalogRow.runtimeStatus == "blocked" || fit == "does_not_fit" {
            return "blocked"
        }
        if weightsPresent { return "ready" }
        if catalogRow.runtimeStatus == "candidate" || catalogRow.runtimeStatus == "listed" || catalogRow.runtimeStatus == "recommendable" {
            return "needs_preparation"
        }
        return "catalog"
    }

    private static func disabledReason(
        catalogRow: CandidateCatalog.Row,
        runtimeState: String,
        fit: String
    ) -> String? {
        if catalogRow.runtimeStatus == "blocked" {
            return "catalog_blocked"
        }
        if fit == "does_not_fit" {
            return "hardware_does_not_fit"
        }
        if runtimeState == "needs_preparation" {
            return "weights_not_prepared"
        }
        return nil
    }

    private static func fitLabel(_ verdict: ModelFit.Verdict) -> String {
        switch verdict {
        case .fits, .tight:
            return "fits"
        case .wontFit:
            return "does_not_fit"
        case .unknown:
            return "unknown"
        }
    }

    private static func economicsFields(
        rate: RateCardProjection.Row?,
        rateCard: RateCardProjection
    ) -> (prompt: Double?, completion: Double?, providerPrompt: Double?, providerCompletion: Double?) {
        guard let rate else {
            return (nil, nil, nil, nil)
        }
        let prompt = rate.usdPerMillionPromptTokens(creditsPerMillion: rateCard.usdPerMillionCredits)
        let completion = rate.usdPerMillionCompletionTokens(creditsPerMillion: rateCard.usdPerMillionCredits)
        let providerShare = Double(rate.providerShareBPS) / 10_000.0
        return (prompt, completion, prompt * providerShare, completion * providerShare)
    }

    private static func economicsState(blocked: Bool, hasRate: Bool, stale: Bool) -> String {
        if blocked { return "blocked" }
        if !hasRate { return "unavailable" }
        if stale { return "stale" }
        return "fallback"
    }

    static func economicsBlocked(runtimeStatus: String, fit: String) -> Bool {
        runtimeStatus == "blocked" || fit == "does_not_fit"
    }

    private static func unavailableActions(reason: String) -> ModelCatalogEconomicsWire.ActionSet {
        let action = ModelCatalogEconomicsWire.Action(
            available: false,
            requiresConfirmation: false,
            transactionKind: nil,
            transactionID: nil,
            actionTimeoutSeconds: nil,
            estimatedBytes: nil,
            unavailableReason: reason
        )
        return ModelCatalogEconomicsWire.ActionSet(
            switchAction: action,
            prepare: action,
            evaluate: action,
            adoptRecommendation: action,
            cleanupStaging: action
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedBuildCommit(_ raw: String?) -> String {
        guard let raw else { return "unknown" }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lengthOK = (7...40).contains(normalized.count)
        let hexOnly = normalized.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        return lengthOK && hexOnly ? normalized : "unknown"
    }
}

private func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
