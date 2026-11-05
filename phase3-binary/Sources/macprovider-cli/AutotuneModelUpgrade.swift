import ArgumentParser
import Foundation
import MacProviderCore

/// SPEC-023-R028: a stale or missing recommendation re-tunes an existing
/// provider over every signed row that fits this Mac and switches only to a
/// strictly better admitted model. `autotune --recommend --upgrade` is the one
/// entry point; the installer and `malibu-cli update` both call it.
enum AutotuneModelUpgrade {
    /// Upper bound on the idle wait before the SPEC-023-R022 stop. It is the
    /// ceiling of `swap_drain_timeout_seconds` (5...600), the bound the warm
    /// switch already uses to drain in-flight work.
    static let idleWaitCeilingSeconds = 600

    /// §4.1 policy demotions. A demoted incumbent loses to an undemoted
    /// selected row by policy, not by score.
    static let policyDemotionReasons: Set<String> = [
        "deprioritized_ram_class_onboarding_sku",
        "deprioritized_8gb_model_tier_preference",
    ]

    enum Decision: Equatable {
        case switchModel(from: String, to: String, reason: String)
        case keep(reason: String)
    }

    /// The config states that make the served model an explicit operator
    /// choice. The CLI has no other model pin.
    static func pinReason(config: AppConfig?) -> String? {
        guard let config else { return "config_unreadable" }
        if config.donorMode { return "donor_mode" }
        if let pool = config.poolModelID, !pool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "pool_model_id"
        }
        let key = config.modelCatalogKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelID = config.modelCatalogModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty, modelID.isEmpty { return "no_signed_catalog_identity" }
        return nil
    }

    /// The signed catalog key of the configured model, by catalog key first
    /// and then by an unambiguous `model_catalog_model_id` match.
    static func incumbentCatalogKey(config: AppConfig?, catalog: CandidateCatalog) -> String? {
        guard let config else { return nil }
        if let key = config.modelCatalogKey, catalog.rows[key] != nil { return key }
        guard let modelID = config.modelCatalogModelID, !modelID.isEmpty else { return nil }
        let keys = catalog.rows.filter { $0.value.modelID == modelID }.map(\.key)
        return keys.count == 1 ? keys[0] : nil
    }

    /// R028 step 1: the incumbent plus every signed row that passes the
    /// pre-benchmark §5 gates on this Mac. Prefetch needs an exact row match,
    /// so a `model_id` shared by several rows is planned only for the incumbent.
    static func candidateModelIDs(
        catalog: CandidateCatalog,
        demandRank: DemandRank,
        rateCard: RateCardProjection,
        hardware: AutotuneRecommendHardware,
        incumbentKey: String
    ) -> Set<String> {
        var rowsPerModelID: [String: Int] = [:]
        for row in catalog.rows.values {
            rowsPerModelID[row.modelID, default: 0] += 1
        }
        var modelIDs = Set<String>()
        if let incumbent = catalog.rows[incumbentKey] {
            modelIDs.insert(incumbent.modelID)
        }
        for (key, row) in catalog.rows {
            guard rowsPerModelID[row.modelID] == 1,
                  let demand = demandRank.rows[key],
                  AutotuneRecommendEngine.passesPreBenchmarkGates(
                      candidate: row,
                      demand: demand,
                      rateCardRow: rateCard.rowForRecommendation(modelKey: key)?.row,
                      hardware: hardware
                  )
            else { continue }
            modelIDs.insert(row.modelID)
        }
        return modelIDs
    }

    /// R028 step 2: keep every verified artifact, drop the rest, and fail when
    /// the incumbent's own artifact did not verify.
    static func verifiedUpgradeArtifacts(
        _ outcome: ArtifactPrefetchOutcomes,
        incumbentModelID: String
    ) throws -> [PrefetchedModelArtifact] {
        guard outcome.prefetchedModelIDs.contains(incumbentModelID) else {
            let reason = outcome.diagnostics.first { $0.modelID == incumbentModelID }?.reason ?? "not prefetched"
            throw ValidationError("model upgrade: the incumbent artifact \(incumbentModelID) did not verify: \(reason)")
        }
        return outcome.artifacts.sorted { $0.modelKey < $1.modelKey }
    }

    /// R028 step 5, under the §4 / §4.1 selection rule.
    static func decide(result: AutotuneRecommendResult, incumbentKey: String) -> Decision {
        guard let selected = result.selectedCandidate else {
            return .keep(reason: "no_eligible_candidate")
        }
        if selected.catalogKey == incumbentKey {
            return .keep(reason: "incumbent_selected")
        }
        guard let incumbent = result.allCandidates.first(where: { $0.catalogKey == incumbentKey }) else {
            return .switchModel(from: incumbentKey, to: selected.catalogKey, reason: "incumbent_not_in_signed_catalog")
        }
        if !incumbent.eligible {
            return .switchModel(from: incumbentKey, to: selected.catalogKey, reason: "incumbent_not_eligible")
        }
        if policyDemotionReasons.contains(incumbent.explanation.lostReason),
           !policyDemotionReasons.contains(selected.explanation.lostReason) {
            return .switchModel(from: incumbentKey, to: selected.catalogKey, reason: "incumbent_policy_demoted")
        }
        if selected.orderingScore > incumbent.orderingScore {
            return .switchModel(from: incumbentKey, to: selected.catalogKey, reason: "strictly_higher_expected_earnings")
        }
        return .keep(reason: "not_strictly_better")
    }

    /// R028 step 6: the row to write. A keep re-applies the incumbent's own
    /// row only when it passed admission in this run; otherwise nothing is
    /// written.
    static func configTarget(
        for decision: Decision,
        result: AutotuneRecommendResult,
        incumbentKey: String,
        benchmarks: [String: CandidateBenchmark]
    ) -> AutotuneCandidateScore? {
        switch decision {
        case .switchModel:
            return result.selectedCandidate
        case .keep:
            guard let incumbent = result.allCandidates.first(where: { $0.catalogKey == incumbentKey }),
                  incumbent.eligible,
                  benchmarks[incumbentKey] != nil
            else { return nil }
            return incumbent
        }
    }

    /// R028 step 3: wait for zero in-flight and queued requests. An
    /// unreachable status endpoint has no in-flight work to protect.
    static func waitForLocalProviderIdle(
        port: Int,
        timeoutSeconds: Int = idleWaitCeilingSeconds,
        fetchStatus: (Int) async throws -> [String: Any] = { try await LocalStatusClient.fetch(port: $0) },
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        now: () -> Date = Date.init
    ) async -> Bool {
        let deadline = now().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            guard let status = try? await fetchStatus(port) else { return true }
            let inFlight = (status["requests_in_flight"] as? NSNumber)?.intValue ?? 0
            let queued = (status["requests_queued"] as? NSNumber)?.intValue ?? 0
            if inFlight == 0, queued == 0 { return true }
            if now() >= deadline { return false }
            await sleep(1_000_000_000)
        }
    }

    static func afterUpdateArguments(configPath: String?) -> [String] {
        var arguments = ["autotune", "--recommend", "--upgrade", "--apply"]
        if let configPath {
            arguments += ["--config", configPath]
        }
        return arguments
    }

    /// Runs the upgrade with the installed binary, which an update has just
    /// replaced, so the new binary's freshness check, catalog and runtime
    /// decide. The child exits 0 without a re-tune when freshness is fresh.
    static func runAfterUpdate(executable: URL, configPath: String?) -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = afterUpdateArguments(configPath: configPath)
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("model_upgrade: could not start the re-tune: \(error)\n".utf8))
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
