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
    /// When either acceleration admission set could not be verified, no
    /// switch is made (`acceleration_admission_unverified`).
    static func decide(
        result: AutotuneRecommendResult,
        incumbentKey: String,
        benchmarks: [String: CandidateBenchmark],
        catalog: CandidateCatalog,
        acceleration: AccelerationAdmissions
    ) -> Decision {
        guard let selected = result.selectedCandidate else {
            return .keep(reason: "no_eligible_candidate")
        }
        if selected.catalogKey == incumbentKey {
            return .keep(reason: "incumbent_selected")
        }
        let incumbent = result.allCandidates.first { $0.catalogKey == incumbentKey }
        var belowGate = false
        var tradesAcceleration = false
        for challenger in result.allCandidates where challenger.eligible {
            if challenger.catalogKey == incumbentKey { break }
            guard clearsHardBenchGate(benchmarks[challenger.catalogKey], row: catalog.rows[challenger.catalogKey]) else {
                belowGate = true
                continue
            }
            let to = challenger.catalogKey
            // Operator rule: an automatic switch never gives up a signed CB
            // or native-MTP admission the incumbent holds. Unknown admission
            // sets fail closed: the incumbent is kept.
            if !acceleration.unverified.isEmpty {
                return .keep(reason: "acceleration_admission_unverified")
            }
            if acceleration.trades(from: incumbentKey, to: to) {
                tradesAcceleration = true
                continue
            }
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
        if tradesAcceleration { return .keep(reason: "challenger_lacks_incumbent_acceleration") }
        return .keep(reason: belowGate ? "candidate_below_bench_gate" : "not_strictly_better")
    }

    /// The catalog keys holding a signed acceleration admission an automatic
    /// switch must keep: a positive, unrevoked continuous-batching policy
    /// entry, or an entry in the release's signed native-MTP admission set.
    /// `unverified` names each set that could not be established (a CB policy
    /// that is not live-verified, or no signed native-MTP set from the feed or
    /// this Mac's copy); any entry blocks every switch.
    struct AccelerationAdmissions: Equatable {
        var continuousBatching: Set<String> = []
        var nativeMTP: Set<String> = []
        var unverified: Set<String> = []

        func trades(from incumbent: String, to challenger: String) -> Bool {
            (continuousBatching.contains(incumbent) && !continuousBatching.contains(challenger))
                || (nativeMTP.contains(incumbent) && !nativeMTP.contains(challenger))
        }
    }

    /// Rows with a positive (`rollout` canary or on) signed CB policy entry
    /// that no revocation names for the row's artifact. Only a live-verified
    /// policy admits anything.
    static func continuousBatchingAdmittedKeys(
        _ policy: ContinuousBatchingPolicyLoadResult,
        catalog: CandidateCatalog
    ) -> Set<String> {
        guard policy.status == .liveVerified else { return [] }
        let selection = policy.selection
        return Set(catalog.rows.compactMap { key, row -> String? in
            guard selection.entries.contains(where: { $0.modelKey == key && $0.rollout != .off }) else { return nil }
            let revoked = selection.revocations.contains {
                $0.modelKey == key && (row.modelSHA256 == nil || $0.modelSHA256 == row.modelSHA256)
            }
            return revoked ? nil : key
        })
    }

    /// Rows the signed native-MTP admission sidecar names, matched as the
    /// loader matches (`model_key` and `artifact_hash`; an entry without both
    /// strings counts as a match). `model_key` is the served model name, so a
    /// row matches by its catalog key, `model_id` or rate-card served key.
    static func nativeMTPAdmittedKeys(
        sidecar: Data,
        catalog: CandidateCatalog,
        servedModelNames: [String: String] = [:]
    ) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: sidecar) as? [String: Any],
              let entries = root["entries"] as? [Any]
        else { return [] }
        return Set(catalog.rows.compactMap { key, row -> String? in
            guard let sha256 = row.modelSHA256 else { return nil }
            let names = Set([key, row.modelID] + (servedModelNames[key].map { [$0] } ?? []))
            let named = entries.contains { entry in
                guard let object = entry as? [String: Any],
                      let modelKey = object["model_key"] as? String,
                      let artifactHash = object["artifact_hash"] as? String
                else { return true }
                return names.contains(modelKey) && artifactHash == sha256
            }
            return named ? key : nil
        })
    }

    /// Loads both admission sets for the current signed release. The
    /// native-MTP set is fetched from the static feed and signature-checked;
    /// when the feed cannot be read, the set this Mac's provider materialized
    /// for the same release is used, else none.
    static func loadAccelerationAdmissions(
        catalog: AutotuneStaticSelection<CandidateCatalog>,
        rateCard: RateCardProjection,
        staticInputs: AutotuneStaticInputs = AutotuneStaticInputs(),
        loadCBPolicy: ((AutotuneStaticSelection<CandidateCatalog>) async -> ContinuousBatchingPolicyLoadResult)? = nil,
        fetchNativeMTPMembers: () async throws -> NativeMTPAdmissionFeed.Members = {
            try await NativeMTPAdmissionFeed.fetchMembers(baseURL: NativeMTPAdmissionFeed.productionBaseURL)
        },
        nativeMTPRoot: URL = NativeMTPAdmissionFeed.defaultRoot()
    ) async -> AccelerationAdmissions {
        let policy: ContinuousBatchingPolicyLoadResult
        if let loadCBPolicy {
            policy = await loadCBPolicy(catalog)
        } else {
            policy = await staticInputs.loadContinuousBatchingPolicy(candidateCatalog: catalog)
        }
        var servedNames: [String: String] = [:]
        for key in catalog.value.rows.keys {
            if let match = rateCard.rowForRecommendation(modelKey: key) {
                servedNames[key] = rateCard.servedModelKey(modelKey: key, rateCardKey: match.key)
            }
        }
        let releaseID = catalog.value.version
        var sidecar: Data?
        if let members = try? await fetchNativeMTPMembers(),
           (try? NativeMTPAdmissionFeed.precheck(
               members,
               releaseID: releaseID,
               signerKeyID: AutotuneStaticInputs.keyID,
               trustedPublicKeys: staticInputs.trustedPublicKeys
           )) != nil {
            sidecar = members.sidecar
        } else {
            let directory = NativeMTPAdmissionFeed.releaseDirectory(root: nativeMTPRoot, releaseID: releaseID)
            if let local = try? Data(contentsOf: directory.appendingPathComponent(NativeMTPAdmissionFeed.sidecarFileName)),
               let signature = try? Data(contentsOf: directory.appendingPathComponent(NativeMTPAdmissionFeed.signatureFileName)),
               (try? NativeMTPAdmissionFeed.precheck(
                   NativeMTPAdmissionFeed.Members(sidecar: local, signature: signature, manifest: Data(), bank: Data(), bankSignature: Data()),
                   releaseID: releaseID,
                   signerKeyID: AutotuneStaticInputs.keyID,
                   trustedPublicKeys: staticInputs.trustedPublicKeys
               )) != nil {
                sidecar = local
            } else {
                FileHandle.standardError.write(Data("model_upgrade: no signed native-MTP admission set for this release; no switch is made\n".utf8))
            }
        }
        var unverified = Set<String>()
        if policy.status != .liveVerified {
            FileHandle.standardError.write(Data("model_upgrade: CB policy is \(policy.status.rawValue); no switch is made\n".utf8))
            unverified.insert("continuous_batching")
        }
        if sidecar == nil {
            unverified.insert("native_mtp")
        }
        return AccelerationAdmissions(
            continuousBatching: continuousBatchingAdmittedKeys(policy, catalog: catalog.value),
            nativeMTP: sidecar.map { nativeMTPAdmittedKeys(sidecar: $0, catalog: catalog.value, servedModelNames: servedNames) } ?? [],
            unverified: unverified
        )
    }

    /// The result as served after the decision, so recommendation state and
    /// hardware evidence name the row this provider actually serves: the
    /// switch target, or the kept incumbent when it passed admission in this
    /// run. A kept row that did not pass admission is named nowhere, so the
    /// state stays stale and the run is retried.
    static func servedResult(
        _ result: AutotuneRecommendResult,
        servedKey: String?,
        benchmarks: [String: CandidateBenchmark]
    ) -> AutotuneRecommendResult {
        var served = result
        let candidate = servedKey.flatMap { key in
            result.allCandidates.first { $0.catalogKey == key && $0.eligible && benchmarks[key] != nil }
        }
        let benchmark = candidate.flatMap { benchmarks[$0.catalogKey] }
        served.selectedCandidate = candidate
        served.recommendedModel = candidate?.model
        served.promptRatePerMillionTokens = candidate?.promptRateUSDPerMillionTokens
        served.completionRatePerMillionTokens = candidate?.completionRateUSDPerMillionTokens
        served.benchmarkID = benchmark?.benchmarkID
        served.benchmarkGeneratedAt = benchmark?.generatedAt
        return served
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
    /// The row's hash-qualified prefetch snapshot in the Hugging Face cache
    /// (`<revision>.macprovider-prefetch.<sha256>`, created by this same
    /// download) goes too, with every blob it links that no other snapshot
    /// of the repo links (#2485). Nothing at, inside or above a served path
    /// is removed, nor a blob a served path links. Already-removed paths are
    /// skipped, so a second call is a no-op.
    @discardableResult
    static func removeUnselectedRunDownloads(
        _ artifacts: [PrefetchedModelArtifact],
        keepModelKeys: Set<String>,
        catalog: CandidateCatalog,
        resolver: CachedModelArtifactResolver,
        servedPaths: Set<String> = [],
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> [String] {
        let keptPaths = Set(artifacts.filter { keepModelKeys.contains($0.modelKey) }.map(\.path))
        let served = Set(servedPaths.flatMap { path -> [String] in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return [url.path, url.resolvingSymlinksInPath().path]
        })
        func overlapsServed(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return served.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
        }
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
            let staging = resolver.prefetchSnapshotURL(
                modelID: row.modelID,
                revision: artifact.modelRevision,
                sha256: sha256
            ).standardizedFileURL
            var removedAny = false
            for target in [expected, staging] {
                var info = stat()
                guard lstat(target.path, &info) == 0 else { continue }
                if overlapsServed(target) || keptPaths.contains(target.path) {
                    FileHandle.standardError.write(Data("model_upgrade: kept \(target.path): a served or kept model uses it\n".utf8))
                    continue
                }
                let blobs = target == staging ? linkedBlobs(in: staging) : []
                do {
                    try removeItem(target)
                    removedAny = true
                } catch {
                    FileHandle.standardError.write(Data("[warn] model_upgrade: could not remove \(target.path): \(error)\n".utf8))
                    continue
                }
                if target == staging {
                    removeUnreferencedBlobs(blobs, snapshot: staging, servedPaths: served, removeItem: removeItem)
                }
            }
            if removedAny {
                removed.append(artifact.path)
                FileHandle.standardError.write(Data("model_upgrade: removed unselected download \(artifact.modelID)\n".utf8))
            }
        }
        return removed
    }

    /// The `blobs/` files of `snapshot`'s Hugging Face repo that symlinks
    /// under `snapshot` point at.
    static func linkedBlobs(in snapshot: URL) -> Set<String> {
        let blobsRoot = snapshot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("blobs", isDirectory: true).standardizedFileURL.path
        var blobs = Set<String>()
        for target in symlinkTargets(under: snapshot) where target.hasPrefix(blobsRoot + "/") {
            blobs.insert(target)
        }
        return blobs
    }

    /// Standardized targets of every symlink under `root` (not followed).
    static func symlinkTargets(under root: URL) -> Set<String> {
        var targets = Set<String>()
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { return targets }
        if (rootInfo.st_mode & S_IFMT) == S_IFLNK {
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: root.path) {
                targets.insert(linkTarget(destination, from: root))
            }
            return targets
        }
        // Relative names keep `root`'s own spelling of the path (no
        // `/private` resolution), so targets compare with paths built the same way.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            return targets
        }
        for case let relative as String in enumerator {
            let url = root.appendingPathComponent(relative)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            else { continue }
            targets.insert(linkTarget(destination, from: url))
        }
        return targets
    }

    /// The standardized path a link at `link` with `destination` names.
    private static func linkTarget(_ destination: String, from link: URL) -> String {
        let target = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : link.deletingLastPathComponent().appendingPathComponent(destination)
        return target.standardizedFileURL.path
    }

    /// Removes the blobs a removed snapshot linked that no remaining snapshot
    /// of the repo and no served path links, then the repo's `snapshots/`,
    /// `blobs/` and repo directories when they are left empty.
    static func removeUnreferencedBlobs(
        _ blobs: Set<String>,
        snapshot: URL,
        servedPaths: Set<String>,
        removeItem: (URL) throws -> Void
    ) {
        let snapshots = snapshot.deletingLastPathComponent()
        let repo = snapshots.deletingLastPathComponent()
        if !blobs.isEmpty {
            var referenced = Set<String>()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [] {
                referenced.formUnion(symlinkTargets(under: snapshots.appendingPathComponent(name)))
            }
            for path in servedPaths {
                referenced.formUnion(symlinkTargets(under: URL(fileURLWithPath: path)))
                referenced.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
            for blob in blobs.subtracting(referenced).sorted() {
                var info = stat()
                guard lstat(blob, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                do {
                    try removeItem(URL(fileURLWithPath: blob))
                } catch {
                    FileHandle.standardError.write(Data("[warn] model_upgrade: could not remove \(blob): \(error)\n".utf8))
                }
            }
        }
        // rmdir removes only an empty directory.
        for directory in [snapshots, repo.appendingPathComponent("blobs", isDirectory: true), repo] {
            _ = rmdir(directory.path)
        }
    }

    /// The paths the configured model is served from: `model_artifact_path`
    /// and an absolute `model`, as the config file names them now.
    static func servedArtifactPaths(configPath: String?) -> Set<String> {
        guard let config = try? ConfigLoader.load(cli: CLIOverrides(configPath: configPath)) else { return [] }
        return Set([config.modelArtifactPath, config.model].compactMap { path in
            guard let path, path.hasPrefix("/") else { return nil }
            return path
        })
    }

    /// The model keys a run keeps on disk: the incumbent, plus a target once
    /// its config was applied.
    final class RunKeep: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Set<String>

        init(_ keys: Set<String>) {
            storage = keys
        }

        var keys: Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func insert(_ key: String) {
            lock.lock()
            storage.insert(key)
            lock.unlock()
        }
    }

    /// R029 step 6: runs `body` and then, on every exit (success, a thrown
    /// error, exit 75 or an interrupt), removes this run's downloads except
    /// the incumbent, an applied target and the row the config file names
    /// at cleanup time (`configuredKey`, re-read then), so a config changed
    /// during the run never loses its served model. `servedPaths` (also
    /// re-read then) names the paths the config serves from.
    static func withRunDownloadCleanup<T>(
        _ artifacts: [PrefetchedModelArtifact],
        incumbentKey: String,
        catalog: CandidateCatalog,
        resolver: CachedModelArtifactResolver,
        configuredKey: () -> String?,
        servedPaths: () -> Set<String> = { [] },
        body: (RunKeep) async throws -> T
    ) async rethrows -> T {
        let keep = RunKeep([incumbentKey])
        defer {
            removeUnselectedRunDownloads(
                artifacts,
                keepModelKeys: keep.keys.union(configuredKey().map { [$0] } ?? []),
                catalog: catalog,
                resolver: resolver,
                servedPaths: servedPaths()
            )
        }
        return try await body(keep)
    }

    /// The signed row the config file names right now, re-read from disk.
    static func configuredCatalogKey(configPath: String?, catalog: CandidateCatalog) -> String? {
        incumbentCatalogKey(config: try? ConfigLoader.load(cli: CLIOverrides(configPath: configPath)), catalog: catalog)
    }

    /// R029 step 3: wait for zero in-flight and queued requests. A status
    /// error is not idle; a provider never confirmed idle by the ceiling is
    /// not stopped.
    static func waitForLocalProviderIdle(
        port: Int,
        timeoutSeconds: Int = idleWaitCeilingSeconds,
        fetchStatus: (Int) async throws -> [String: Any] = { try await LocalStatusClient.fetch(port: $0) },
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        now: () -> Date = Date.init
    ) async -> Bool {
        let deadline = now().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            if let status = try? await fetchStatus(port),
               let inFlight = (status["requests_in_flight"] as? NSNumber)?.intValue,
               let queued = (status["requests_queued"] as? NSNumber)?.intValue,
               inFlight == 0, queued == 0 {
                return true
            }
            if now() >= deadline { return false }
            await sleep(1_000_000_000)
        }
    }

    static func afterUpdateArguments(configPath: String?, unattended: Bool = false, parentPID: Int32? = nil) -> [String] {
        var arguments = ["autotune", "--recommend", "--upgrade", "--apply"]
        if unattended {
            arguments.append("--unattended")
            if let parentPID {
                arguments += ["--upgrade-parent-pid", String(parentPID)]
            }
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

    /// #2485: the free space an upgrade run leaves on the disk. Each
    /// download must leave its advertised size plus this floor free, and the
    /// first row that would not stops the run's downloads. It is one
    /// memory's worth (half the run cap), at least 16 GiB: after any run the
    /// disk still has room for one more model of the largest size this Mac
    /// serves, with the probe's swap and OS updates beside it, where the
    /// 5 GiB download reserve left a 32 GB Mac at 6.8 GB free. The run cap
    /// bounds one run; the floor bounds the disk.
    static func upgradeFreeSpaceFloorBytes(memoryGB: Int) -> Int64 {
        Int64(max(memoryGB, 16)) * 1_073_741_824
    }

    /// Unattended runs spread one release of the recommendation inputs
    /// across this window, so a release never moves the whole fleet at once.
    static let staggerWindowSeconds: UInt64 = 48 * 3600

    /// One digest over every input whose change makes the recommendation
    /// stale: the signed catalog, rate card and demand rank content, the CB
    /// and native-MTP admission sets the decision reads, and the binary
    /// version. It keys the stagger offset, the retry record and the
    /// recorded keep.
    static func inputsKey(inputDigests: [String], binaryVersion: String) -> String {
        let text = (inputDigests + ["binary=\(binaryVersion)"]).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Top-level feed fields a re-publish restamps without changing what the
    /// decision reads (`renew-autotune-static-feed.sh` restamps both).
    static let restampFields: Set<String> = ["generated_at", "version"]

    /// SHA-256 of a feed's content: its JSON with the restamp fields removed,
    /// re-serialized with sorted keys, so a pure re-stamp keeps the digest.
    /// Bytes that are not a JSON object hash as they are.
    static func contentDigest(_ bytes: Data) -> String {
        var canonical = bytes
        if var object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
            for field in restampFields { object.removeValue(forKey: field) }
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                canonical = data
            }
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    /// The gate before prefetch and the keep recorded after the decision
    /// both call this with the same loaded `acceleration`, so they compute
    /// one key. The admission sets enter as the sorted admitted keys and
    /// unverified set names the decision reads, so re-signing the same sets
    /// keeps the key and any admission change is a new key.
    static func upgradeInputDigests(
        catalog: Data,
        rateCard: Data,
        demandRank: Data,
        acceleration: AccelerationAdmissions
    ) -> [String] {
        func setDigest(_ set: Set<String>) -> String {
            SHA256.hash(data: Data(set.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return [
            "candidate_catalog=" + contentDigest(catalog),
            "rate_card=" + contentDigest(rateCard),
            "demand_rank=" + contentDigest(demandRank),
            "cb_admissions=" + setDigest(acceleration.continuousBatching),
            "native_mtp_admissions=" + setDigest(acceleration.nativeMTP),
            "acceleration_unverified=" + setDigest(acceleration.unverified),
        ]
    }

    /// Whether a keep is recorded so the unattended check skips these inputs:
    /// a keep that wrote no benchmarked row (so the state stays stale), but
    /// not one caused by an admission set that could not be read, which a
    /// later check may resolve.
    static func recordsKeep(_ decision: Decision, wroteRow: Bool) -> Bool {
        guard case let .keep(reason) = decision else { return false }
        return !wroteRow && reason != "acceleration_admission_unverified"
    }

    /// Adds a keep for `inputsKey` to the record at `url`.
    static func recordKeep(inputsKey: String, at date: Date, url: URL = attemptRecordURL) throws {
        var record = readAttempt(from: url) ?? AttemptRecord()
        record.recordKeep(inputsKey: inputsKey, at: date)
        try writeAttempt(record, to: url)
    }

    /// A fixed per-provider offset into the stagger window. It is derived
    /// from the provider and the inputs key, so each input release reorders
    /// the fleet and no provider is always first.
    static func staggerOffsetSeconds(providerKey: String, inputsKey: String) -> TimeInterval {
        let digest = SHA256.hash(data: Data("\(providerKey)\n\(inputsKey)".utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return TimeInterval(value % staggerWindowSeconds)
    }

    /// The stagger anchor: the newest input release, which is the newest
    /// feed `generated_at` or the time this binary version was first seen.
    static func staggerAnchor(feedGeneratedAt: [Date], binaryFirstSeenAt: Date?) -> Date {
        (feedGeneratedAt + (binaryFirstSeenAt.map { [$0] } ?? [])).max() ?? .distantPast
    }

    /// Unattended runs retry the same inputs at most once per this interval,
    /// so a failing prefetch is not repeated on every check.
    static let unattendedRetrySeconds: TimeInterval = 24 * 3600

    /// Attempts kept in the record, so a selection that flips between a few
    /// input sets is still retried at most daily per set.
    static let attemptHistoryLimit = 8

    struct AttemptRecord: Codable, Equatable {
        struct Attempt: Codable, Equatable {
            var inputsKey: String
            var attemptedAt: Date

            enum CodingKeys: String, CodingKey {
                case inputsKey = "inputs_key"
                case attemptedAt = "attempted_at"
            }
        }

        var binaryVersion: String?
        var binaryFirstSeenAt: Date?
        var attempts: [Attempt] = []
        /// Inputs a completed run kept the incumbent for without writing a
        /// benchmarked row; the unattended check skips them until they change.
        var keeps: [Attempt] = []

        enum CodingKeys: String, CodingKey {
            case binaryVersion = "binary_version"
            case binaryFirstSeenAt = "binary_first_seen_at"
            case attempts
            case keeps
        }

        init(binaryVersion: String? = nil, binaryFirstSeenAt: Date? = nil, attempts: [Attempt] = [], keeps: [Attempt] = []) {
            self.binaryVersion = binaryVersion
            self.binaryFirstSeenAt = binaryFirstSeenAt
            self.attempts = attempts
            self.keeps = keeps
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            binaryVersion = try c.decodeIfPresent(String.self, forKey: .binaryVersion)
            binaryFirstSeenAt = try c.decodeIfPresent(Date.self, forKey: .binaryFirstSeenAt)
            attempts = try c.decodeIfPresent([Attempt].self, forKey: .attempts) ?? []
            keeps = try c.decodeIfPresent([Attempt].self, forKey: .keeps) ?? []
        }

        mutating func recordKeep(inputsKey: String, at date: Date) {
            keeps.removeAll { $0.inputsKey == inputsKey }
            keeps.append(Attempt(inputsKey: inputsKey, attemptedAt: date))
            if keeps.count > AutotuneModelUpgrade.attemptHistoryLimit {
                keeps.removeFirst(keeps.count - AutotuneModelUpgrade.attemptHistoryLimit)
            }
        }

        mutating func recordAttempt(inputsKey: String, at date: Date) {
            attempts.removeAll { $0.inputsKey == inputsKey }
            attempts.append(Attempt(inputsKey: inputsKey, attemptedAt: date))
            if attempts.count > AutotuneModelUpgrade.attemptHistoryLimit {
                attempts.removeFirst(attempts.count - AutotuneModelUpgrade.attemptHistoryLimit)
            }
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

    static func writeAttempt(_ record: AttemptRecord, to url: URL = attemptRecordURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    enum UnattendedGate: Equatable {
        case proceed
        /// A completed run already kept the incumbent for these inputs.
        case kept(since: Date)
        case staggered(until: Date)
        case retryLater(until: Date)
        /// The record could not be written, so the run cannot bound its
        /// retries; it stops before anything is downloaded or stopped.
        case recordUnwritable(String)
    }

    /// The unattended gates, in order: the stagger offset after the newest
    /// input release, then the retry interval for the same inputs. The time
    /// a binary version is first seen is persisted before the stagger is
    /// evaluated, and an attempt is recorded before the run proceeds; a
    /// failed write stops the run.
    static func unattendedGate(
        now: Date,
        feedGeneratedAt: [Date],
        inputDigests: [String],
        binaryVersion: String,
        providerKey: String,
        readRecord: () -> AttemptRecord?,
        writeRecord: (AttemptRecord) throws -> Void
    ) -> UnattendedGate {
        var record = readRecord() ?? AttemptRecord()
        if record.binaryVersion != binaryVersion || record.binaryFirstSeenAt == nil {
            record.binaryVersion = binaryVersion
            record.binaryFirstSeenAt = now
            do {
                try writeRecord(record)
            } catch {
                return .recordUnwritable(String(describing: error))
            }
        }
        let key = inputsKey(inputDigests: inputDigests, binaryVersion: binaryVersion)
        if let kept = record.keeps.last(where: { $0.inputsKey == key }) {
            return .kept(since: kept.attemptedAt)
        }
        let notBefore = staggerAnchor(feedGeneratedAt: feedGeneratedAt, binaryFirstSeenAt: record.binaryFirstSeenAt)
            .addingTimeInterval(staggerOffsetSeconds(providerKey: providerKey, inputsKey: key))
        if now < notBefore {
            return .staggered(until: notBefore)
        }
        if let last = record.attempts.last(where: { $0.inputsKey == key }) {
            let retryAt = last.attemptedAt.addingTimeInterval(unattendedRetrySeconds)
            if now < retryAt {
                return .retryLater(until: retryAt)
            }
        }
        record.recordAttempt(inputsKey: key, at: now)
        do {
            try writeRecord(record)
        } catch {
            return .recordUnwritable(String(describing: error))
        }
        return .proceed
    }

    // MARK: - Single run, lifecycle lease and operator pause

    /// Held for the whole run by every `--upgrade` mode (the in-process run,
    /// the installer's `--prefetch` and `--apply --prefetch-receipt` steps),
    /// so two upgrade runs never download or stop the provider at once.
    /// Attended runs wait for it; the unattended check never waits.
    final class RunLock {
        private var fd: Int32

        fileprivate init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            guard fd >= 0 else { return }
            _ = flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    static var runLockURL: URL {
        attemptRecordURL.deletingLastPathComponent().appendingPathComponent("model-upgrade.lock")
    }

    enum RunLockAcquisition {
        case acquired(RunLock)
        /// Another run holds the lock (non-blocking acquisition only).
        case busy
        /// The lock file could not be opened or locked.
        case failed(String)
    }

    static func acquireRunLock(at url: URL = runLockURL, blocking: Bool = false) -> RunLockAcquisition {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .failed("open \(url.path): \(String(cString: strerror(errno)))")
        }
        var announcedWait = false
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK, blocking {
                if !announcedWait {
                    FileHandle.standardError.write(Data("model_upgrade: waiting for another model upgrade run to finish (\(url.path))\n".utf8))
                    announcedWait = true
                }
                usleep(1_000_000)
                continue
            }
            close(fd)
            if code == EWOULDBLOCK { return .busy }
            return .failed("flock \(url.path): \(String(cString: strerror(code)))")
        }
        return .acquired(RunLock(fd: fd))
    }

    /// The SPEC-020 lifecycle lease the upgrade holds from the stop through
    /// the benchmark and apply, like an autoupdate, up to the restart. It is
    /// renewed while held, since a benchmark can outlast one lease window.
    /// A failed renewal marks the lease lost for good; a run whose lease was
    /// lost does not apply config (`confirmHeld`).
    final class MaintenanceLease: @unchecked Sendable {
        let store: ProviderLifecycleLeaseStore
        let record: ProviderLifecycleLeaseRecord
        private var renewal: Task<Void, Never>?

        init(store: ProviderLifecycleLeaseStore, record: ProviderLifecycleLeaseRecord) {
            self.store = store
            self.record = record
            renewal = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: AutotuneModelUpgrade.maintenanceLeaseRenewSeconds * 1_000_000_000)
                    if Task.isCancelled { return }
                    guard let self else { return }
                    _ = self.renewNow()
                }
            }
        }

        private let lock = NSLock()
        private var released = false
        private var lost_ = false

        var lost: Bool {
            lock.lock()
            defer { lock.unlock() }
            return lost_
        }

        /// Renews once; false (and lost from then on) when the renewal fails.
        @discardableResult
        func renewNow() -> Bool {
            do {
                _ = try store.renew(leaseID: record.leaseID, duration: AutotuneModelUpgrade.maintenanceLeaseSeconds)
                return !lost
            } catch {
                lock.lock()
                let first = !lost_
                lost_ = true
                lock.unlock()
                if first {
                    FileHandle.standardError.write(Data("[warn] model_upgrade: lost the lifecycle lease: \(error)\n".utf8))
                }
                return false
            }
        }

        /// The pre-apply check: renews now and reports whether the lease was
        /// held without a gap for the whole run.
        func confirmHeld() -> Bool {
            renewNow()
        }

        /// Idempotent.
        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard !released else { return }
            released = true
            renewal?.cancel()
            renewal = nil
            _ = try? store.clear(ifLeaseID: record.leaseID)
        }
    }

    /// The lease an in-process run took, for the pre-apply check.
    final class LeaseSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var lease_: MaintenanceLease?

        var lease: MaintenanceLease? {
            get { lock.lock(); defer { lock.unlock() }; return lease_ }
            set { lock.lock(); lease_ = newValue; lock.unlock() }
        }
    }

    static let maintenanceLeaseSeconds: TimeInterval = 20 * 60
    static let maintenanceLeaseRenewSeconds: UInt64 = 5 * 60

    enum LeaseAcquisition {
        case acquired(MaintenanceLease)
        case held(String)
    }

    static func acquireMaintenanceLease(
        store: ProviderLifecycleLeaseStore = ProviderLifecycleLeaseStore()
    ) -> LeaseAcquisition {
        do {
            let record = try store.acquire(
                kind: .maintenance,
                operationID: "model-upgrade-\(UUID().uuidString.lowercased())",
                duration: maintenanceLeaseSeconds
            )
            return .acquired(MaintenanceLease(store: store, record: record))
        } catch {
            return .held(String(describing: error))
        }
    }

    /// The persisted operator pause, which the serving provider writes and
    /// keeps across restarts. A state file that exists but cannot be read
    /// counts as paused.
    static func operatorPausePersisted(store: ProviderLifecycleStateStore = ProviderLifecycleStateStore()) -> Bool {
        switch store.inspect() {
        case .missing:
            return false
        case .valid(let record):
            return record.operatorPauseRequested
        case .invalid:
            return true
        }
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
        noJoin: Bool,
        isolateLifecycle: Bool,
        operatorPaused: Bool
    ) -> String? {
        if autotuneCandidate { return "autotune_candidate" }
        // A lab `serve --no-join` or `--isolate-lifecycle` serve must never
        // stop this Mac's launchd provider.
        if noJoin { return "no_join" }
        if isolateLifecycle { return "isolate_lifecycle" }
        if donorMode { return "donor_mode" }
        if let poolModelID, !poolModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "pool_model_id"
        }
        if operatorPaused { return "operator_paused" }
        return nil
    }

    /// Why the provider the R022 isolation would stop (`ProviderConflictDetector`)
    /// is not the process `expectedPID`: the serve that starts the check
    /// passes its own pid, and the unattended child refuses any other
    /// provider. A provider whose pid is unknown never matches.
    static func providerMismatch(
        _ conflict: ProviderConflict,
        expectedPID: Int32?,
        systemLaunchDaemonInstalled: Bool
    ) -> String? {
        guard let expectedPID else { return "no_parent_pid" }
        switch conflict {
        case .none:
            return "no_detected_provider"
        case let .launchdManaged(pid):
            return pid == expectedPID ? nil : "detected_provider_is_not_the_parent"
        case let .foreground(pid, _):
            // A headless provider runs as a system LaunchDaemon that the
            // provider user's `launchctl list` does not show; it looks
            // foreground, but a SIGTERM only makes launchd relaunch it.
            if systemLaunchDaemonInstalled { return "system_launch_daemon_provider" }
            return pid == expectedPID ? nil : "detected_provider_is_not_the_parent"
        }
    }

    static let systemLaunchDaemonPlistPaths = [
        "/Library/LaunchDaemons/live.malibu.provider.plist",
        "/Library/LaunchDaemons/live.streamvc.macprovider.plist",
    ]

    /// The serve-side per-tick decision: nil spawns the unattended check,
    /// any reason skips it. A trigger suppression wins; otherwise only the
    /// provider the child would stop (this serve's pid, not a system
    /// LaunchDaemon) starts a check, and a failed detection never does.
    static func unattendedTickSuppression(
        triggerSuppression: String?,
        detected: ProviderConflict?,
        servePID: Int32,
        systemLaunchDaemonInstalled: Bool
    ) -> String? {
        if let triggerSuppression { return triggerSuppression }
        guard let detected else { return "provider_detection_failed" }
        return providerMismatch(detected, expectedPID: servePID, systemLaunchDaemonInstalled: systemLaunchDaemonInstalled)
    }

    static func systemLaunchDaemonInstalled(
        paths: [String] = systemLaunchDaemonPlistPaths,
        fileManager: FileManager = .default
    ) -> Bool {
        paths.contains { fileManager.fileExists(atPath: $0) }
    }

    /// Starts `autotune --recommend --upgrade --apply --unattended` in its own
    /// session, so the R022 stop of this provider's launchd job does not take
    /// the child with it. stdin is /dev/null; stdout and stderr append to
    /// `logPath`. The child is not waited on: it outlives the serve process
    /// that started it, and it restarts the provider on every exit.
    @discardableResult
    static func spawnDetachedUnattendedUpgrade(
        executable: URL,
        configPath: String?,
        logPath: String,
        parentPID: Int32 = getpid()
    ) -> pid_t? {
        let arguments = [executable.path] + afterUpdateArguments(configPath: configPath, unattended: true, parentPID: parentPID)
        rotateUnattendedLog(atPath: logPath)
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT: only fds 0-2 reach the child. Without it the child
        // inherits the serve listener and buyer sockets (NIO does not set
        // close-on-exec on Darwin) and holds the port across the restart.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
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

    static let unattendedLogRotateBytes: UInt64 = 10 * 1024 * 1024

    /// Keeps one previous log beside the current one, so the unattended log
    /// stays under twice the rotate size however long the provider serves.
    static func rotateUnattendedLog(atPath logPath: String, limitBytes: UInt64 = unattendedLogRotateBytes) {
        var info = stat()
        guard lstat(logPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              UInt64(info.st_size) > limitBytes else { return }
        let previous = logPath + ".1"
        _ = unlink(previous)
        _ = rename(logPath, previous)
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
