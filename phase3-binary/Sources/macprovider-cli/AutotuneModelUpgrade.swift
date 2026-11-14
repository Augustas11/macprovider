import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore

/// SPEC-023-R029: a stale or missing recommendation re-tunes an existing
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

    /// R029 step 1: the incumbent plus every signed row that passes the
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

    /// R029 step 2 download order: the incumbent first, then every other row
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

    /// R029 step 2: keep every verified artifact, drop the rest, and fail when
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

    /// R029 step 5: the catalog bench gate is hard for an automatic switch.
    /// A measured TPS below `min_sustained_tps` or a 4k TTFT above
    /// `max_4k_ttft_ms` disqualifies the row; manual `--recommend` keeps the
    /// gate advisory.
    static func clearsHardBenchGate(_ benchmark: CandidateBenchmark?, row: CandidateCatalog.Row?) -> Bool {
        guard let benchmark, let row else { return false }
        return AutotuneRecommendEngine.advisoryBenchmarkWarnings(benchmark, candidate: row).isEmpty
    }

    /// R029 step 5, under the §4 / §4.1 selection rule. The challengers are
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

    /// R029 step 6: the row to write. A keep re-applies the incumbent's own
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

    /// R029 step 6 cleanup: remove the artifacts this run downloaded that
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

    /// R029 step 3: wait for zero in-flight and queued requests. An
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

    static func afterUpdateArguments(configPath: String?, unattended: Bool = false) -> [String] {
        var arguments = ["autotune", "--recommend", "--upgrade", "--apply"]
        if unattended {
            arguments.append("--unattended")
        }
        if let configPath {
            arguments += ["--config", configPath]
        }
        return arguments
    }

    // MARK: - Fleet bounds

    /// R029 step 2 cap: one run downloads at most twice this Mac's memory.
    /// Every planned challenger fits in memory, so the cap always admits the
    /// best-ordered challenger and bounds a run to about two models of
    /// bandwidth and disk, whatever the catalog lists.
    static func runDownloadCapBytes(memoryGB: Int) -> Int64 {
        Int64(max(memoryGB, 1)) * 2 * 1_073_741_824
    }

    /// Unattended runs spread one catalog release across this window, so a
    /// release never moves the whole fleet at once.
    static let staggerWindowSeconds: UInt64 = 48 * 3600

    /// A fixed per-provider offset into the stagger window. It is derived
    /// from the provider and the catalog digest, so each release reorders the
    /// fleet and no provider is always first.
    static func staggerOffsetSeconds(providerKey: String, catalogSHA256: String) -> TimeInterval {
        let digest = SHA256.hash(data: Data("\(providerKey)\n\(catalogSHA256)".utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return TimeInterval(value % staggerWindowSeconds)
    }

    /// The earliest time an unattended run may act on this catalog.
    static func staggerNotBefore(catalogGeneratedAt: Date, providerKey: String, catalogSHA256: String) -> Date {
        catalogGeneratedAt.addingTimeInterval(staggerOffsetSeconds(providerKey: providerKey, catalogSHA256: catalogSHA256))
    }

    /// Unattended runs retry the same catalog and binary at most once per
    /// this interval, so a failing prefetch is not repeated on every check.
    static let unattendedRetrySeconds: TimeInterval = 24 * 3600

    struct AttemptRecord: Codable, Equatable {
        var catalogSHA256: String
        var binaryVersion: String
        var attemptedAt: Date

        enum CodingKeys: String, CodingKey {
            case catalogSHA256 = "candidate_catalog_sha256"
            case binaryVersion = "binary_version"
            case attemptedAt = "attempted_at"
        }
    }

    static var attemptRecordURL: URL {
        RecommendationStateStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("model-upgrade-attempt.json")
    }

    static func readAttempt(from url: URL = attemptRecordURL) -> AttemptRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AttemptRecord.self, from: data)
    }

    static func writeAttempt(_ record: AttemptRecord, to url: URL = attemptRecordURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(record).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[warn] model_upgrade: could not record the attempt: \(error)\n".utf8))
        }
    }

    enum UnattendedGate: Equatable {
        case proceed
        case staggered(until: Date)
        case retryLater(until: Date)
    }

    /// The unattended gates, in order: the stagger offset, then the retry
    /// interval for the same catalog and binary.
    static func unattendedGate(
        now: Date,
        catalogGeneratedAt: Date,
        catalogSHA256: String,
        binaryVersion: String,
        providerKey: String,
        lastAttempt: AttemptRecord?
    ) -> UnattendedGate {
        let notBefore = staggerNotBefore(
            catalogGeneratedAt: catalogGeneratedAt,
            providerKey: providerKey,
            catalogSHA256: catalogSHA256
        )
        if now < notBefore {
            return .staggered(until: notBefore)
        }
        if let lastAttempt,
           lastAttempt.catalogSHA256 == catalogSHA256,
           lastAttempt.binaryVersion == binaryVersion {
            let retryAt = lastAttempt.attemptedAt.addingTimeInterval(unattendedRetrySeconds)
            if now < retryAt {
                return .retryLater(until: retryAt)
            }
        }
        return .proceed
    }

    // MARK: - Unattended trigger

    /// How often a serving provider starts an unattended check, and how long
    /// after start the first check waits so a restart settles first.
    static let unattendedCheckIntervalSeconds: UInt64 = 6 * 3600
    static let unattendedFirstCheckDelaySeconds: UInt64 = 15 * 60

    /// Why a serving provider must not start an unattended upgrade check.
    static func unattendedTriggerSuppression(
        donorMode: Bool,
        poolModelID: String?,
        autotuneCandidate: Bool,
        operatorPaused: Bool
    ) -> String? {
        if autotuneCandidate { return "autotune_candidate" }
        if donorMode { return "donor_mode" }
        if let poolModelID, !poolModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "pool_model_id"
        }
        if operatorPaused { return "operator_paused" }
        return nil
    }

    /// Starts `autotune --recommend --upgrade --apply --unattended` in its own
    /// session, so the R022 stop of this provider's launchd job does not take
    /// the child with it. stdin is /dev/null; stdout and stderr append to
    /// `logPath`. The child is not waited on: it outlives the serve process
    /// that started it, and it restarts the provider on every exit.
    @discardableResult
    static func spawnDetachedUnattendedUpgrade(executable: URL, configPath: String?, logPath: String) -> pid_t? {
        let arguments = [executable.path] + afterUpdateArguments(configPath: configPath, unattended: true)
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var cArguments = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &fileActions, &attributes, &cArguments, &environment)
        guard status == 0 else {
            FileHandle.standardError.write(Data("[warn] model_upgrade: could not start the unattended check: errno \(status)\n".utf8))
            return nil
        }
        // Reap the child whenever it exits so it never lingers as a zombie
        // while this provider keeps serving.
        let childPID = pid
        DispatchQueue.global(qos: .utility).async {
            var childStatus: Int32 = 0
            _ = waitpid(childPID, &childStatus, 0)
        }
        return pid
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
