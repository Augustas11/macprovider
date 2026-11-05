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
    /// A row whose cached probe on this Mac already fails its hard bench gate
    /// (step 5) can never be switched to, so it is not downloaded.
    static func candidateModelIDs(
        catalog: CandidateCatalog,
        demandRank: DemandRank,
        rateCard: RateCardProjection,
        hardware: AutotuneRecommendHardware,
        incumbentKey: String,
        cachedBenchmarks: [String: CandidateBenchmark] = [:]
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
            if let cached = cachedBenchmarks[key], !clearsHardBenchGate(cached, row: row) { continue }
            modelIDs.insert(row.modelID)
        }
        return modelIDs
    }

    /// R028 step 2 download order: the incumbent first, then every other row
    /// by its estimated expected-earnings score, so the likely winners are
    /// fetched before the disk reserve runs out. The estimate is the engine's
    /// own score with each row's cached probe TPS on this Mac, or its catalog
    /// `min_sustained_tps` when no probe is cached.
    static func prefetchOrder(
        request: AutotuneRecommendRequest,
        incumbentKey: String,
        cachedBenchmarks: [String: CandidateBenchmark]
    ) -> [String] {
        var estimate = request
        estimate.benchmarks = Dictionary(uniqueKeysWithValues: request.candidateCatalog.rows.map { key, row in
            (key, cachedBenchmarks[key] ?? CandidateBenchmark(
                modelKey: key,
                sustainedTPS: row.benchGate.minSustainedTPS,
                ttftMS: row.benchGate.max4KTTFTMS,
                swapDetected: false,
                thermalThrottleDetected: false,
                artifactSHA256: row.modelSHA256 ?? "",
                modelArtifactPath: "",
                benchmarkID: nil,
                generatedAt: request.generatedAt,
                candidateCatalogSHA256: "",
                binaryVersion: "",
                modelID: row.modelID,
                hardwareIdentityHash: ""
            ))
        })
        let scores = Dictionary(
            uniqueKeysWithValues: AutotuneRecommendEngine().recommend(estimate).allCandidates.map { ($0.catalogKey, $0.orderingScore) }
        )
        let others = request.candidateCatalog.rows.keys.filter { $0 != incumbentKey }.sorted { lhs, rhs in
            let left = scores[lhs] ?? 0
            let right = scores[rhs] ?? 0
            return left == right ? lhs < rhs : left > right
        }
        return (request.candidateCatalog.rows[incumbentKey] == nil ? [] : [incumbentKey]) + others
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

    /// R028 step 5: the catalog bench gate is hard for an automatic switch.
    /// A measured TPS below `min_sustained_tps` or a 4k TTFT above
    /// `max_4k_ttft_ms` disqualifies the row; manual `--recommend` keeps the
    /// gate advisory.
    static func clearsHardBenchGate(_ benchmark: CandidateBenchmark?, row: CandidateCatalog.Row?) -> Bool {
        guard let benchmark, let row else { return false }
        return AutotuneRecommendEngine.advisoryBenchmarkWarnings(benchmark, candidate: row).isEmpty
    }

    /// R028 step 5, under the §4 / §4.1 selection rule. The challengers are
    /// the eligible rows the engine orders ahead of the incumbent (every
    /// eligible row when the incumbent is not eligible), in that order; the
    /// first one that clears the hard bench gate and beats the incumbent wins.
    static func decide(
        result: AutotuneRecommendResult,
        incumbentKey: String,
        benchmarks: [String: CandidateBenchmark],
        catalog: CandidateCatalog
    ) -> Decision {
        guard let selected = result.selectedCandidate else {
            return .keep(reason: "no_eligible_candidate")
        }
        if selected.catalogKey == incumbentKey {
            return .keep(reason: "incumbent_selected")
        }
        let incumbent = result.allCandidates.first { $0.catalogKey == incumbentKey }
        var belowGate = false
        for challenger in result.allCandidates where challenger.eligible {
            if challenger.catalogKey == incumbentKey { break }
            guard clearsHardBenchGate(benchmarks[challenger.catalogKey], row: catalog.rows[challenger.catalogKey]) else {
                belowGate = true
                continue
            }
            let to = challenger.catalogKey
            guard let incumbent else {
                return .switchModel(from: incumbentKey, to: to, reason: "incumbent_not_in_signed_catalog")
            }
            if !incumbent.eligible {
                return .switchModel(from: incumbentKey, to: to, reason: "incumbent_not_eligible")
            }
            if policyDemotionReasons.contains(incumbent.explanation.lostReason),
               !policyDemotionReasons.contains(challenger.explanation.lostReason) {
                return .switchModel(from: incumbentKey, to: to, reason: "incumbent_policy_demoted")
            }
            if challenger.orderingScore > incumbent.orderingScore {
                return .switchModel(from: incumbentKey, to: to, reason: "strictly_higher_expected_earnings")
            }
        }
        return .keep(reason: belowGate ? "candidate_below_bench_gate" : "not_strictly_better")
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
        case let .switchModel(_, to, _):
            return result.allCandidates.first { $0.catalogKey == to }
        case .keep:
            guard let incumbent = result.allCandidates.first(where: { $0.catalogKey == incumbentKey }),
                  incumbent.eligible,
                  benchmarks[incumbentKey] != nil
            else { return nil }
            return incumbent
        }
    }

    /// R028 step 6 cleanup: remove the artifacts this run downloaded that
    /// are not kept. Only a receipt row marked `downloaded_by_run` whose path
    /// is exactly the durable content-addressed path of its current signed row
    /// is removed, and never a path a kept row also uses, so the incumbent's
    /// artifact and any copy that existed before the run are never touched.
    @discardableResult
    static func removeUnselectedRunDownloads(
        _ artifacts: [PrefetchedModelArtifact],
        keepModelKeys: Set<String>,
        catalog: CandidateCatalog,
        resolver: CachedModelArtifactResolver,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> [String] {
        let keptPaths = Set(artifacts.filter { keepModelKeys.contains($0.modelKey) }.map(\.path))
        var removed: [String] = []
        for artifact in artifacts where artifact.downloadedByRun == true
            && !keepModelKeys.contains(artifact.modelKey)
            && !keptPaths.contains(artifact.path) {
            guard let row = catalog.rows[artifact.modelKey],
                  row.modelID == artifact.modelID,
                  row.modelRevision == artifact.modelRevision,
                  let sha256 = row.modelSHA256,
                  sha256 == artifact.sha256,
                  let expected = try? resolver.durableStore.artifactURL(
                      modelID: row.modelID,
                      revision: artifact.modelRevision,
                      sha256: sha256
                  ).standardizedFileURL,
                  expected.path == artifact.path
            else { continue }
            do {
                try removeItem(expected)
                removed.append(artifact.path)
                FileHandle.standardError.write(Data("model_upgrade: removed unselected download \(artifact.modelID)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("[warn] model_upgrade: could not remove \(artifact.path): \(error)\n".utf8))
            }
        }
        return removed
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
