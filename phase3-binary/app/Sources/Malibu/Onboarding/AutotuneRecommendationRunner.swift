import Foundation

enum AutotuneRecommendationRunner {
    /// Wall-clock budget for `macprovider-cli autotune --recommend --json`.
    ///
    /// Autotune runs Stage-1 probes against every non-blocked, RAM-eligible
    /// row in the catalog. Each probe spawns a subprocess of
    /// `macprovider-cli serve`, waits for MLX to load the model, then does a
    /// prewarm HTTP call followed by measured TTFT + tokens/sec replicates.
    ///
    /// Per-candidate strict worst case (see `Stage1Prober` in
    /// `Stage1Iterator.swift`):
    ///   * `readyTimeoutSec = 120s` — MLX model load
    ///   * prewarm `probeOnce` = `probeIdleTimeoutSec = 300s` (Track A3,
    ///     `Stage1Iterator.swift:474`)
    ///   * measured replicate `probeOnce` = `probeIdleTimeoutSec = 300s`
    ///     (default `stage1Replicates = 1`, `AutotuneCommand.swift:35-37`)
    /// = 720s per candidate.
    ///
    /// **The App-side cannot assume a fixed candidate count.** The recommend
    /// path in `AutotuneRecommend.benchmarks()` iterates every catalog row
    /// filtered only by `runtime_status == "blocked"` and RAM/tier gates.
    /// The set of admitted rows scales with `safetyMarginGB = 4` and the
    /// user's Mac tier, so a 36GB machine may probe 4 rows and larger
    /// machines can hit 5+. Compounded with 720s per candidate this
    /// exceeds any small App-side guess.
    ///
    /// **This timeout is the App-side authoritative ceiling.** The CLI's
    /// declared `AutotuneCommand.maxDuration = 7200s` at
    /// `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:47-48`
    /// is only enforced by the non-recommend path (deadline created at
    /// `AutotuneCommand.swift:157-161`). `runAutotuneRecommend()` at
    /// `AutotuneCommand.swift:131-139` returns before that deadline is
    /// installed and calls `AutotuneRecommendationBenchmarker().benchmarks()`
    /// with no deadline / cancellation input. So this cap is not "CLI cap +
    /// grace"; it IS the outer bound of autotune runtime, chosen by the
    /// App.
    ///
    /// Value: 7260s = 2h1m. Rationale:
    ///   1. Above any per-candidate math ceiling for reasonable N (up to
    ///      ~10 candidates × 720s = 7200s worst case).
    ///   2. Well above the empirical 2-5 min median so the UX is never
    ///      affected in the healthy case.
    ///   3. Aligned with the CLI's declared `maxDuration` constant so if
    ///      the recommend path is later fixed to enforce maxDuration
    ///      (see follow-up items in the PR body), the two ceilings
    ///      naturally coincide.
    ///   4. Below 2.5h so a truly wedged subprocess doesn't trap the user
    ///      in a multi-hour spinner.
    ///
    /// Median UX is unaffected because autotune completes in 2-5 min. Only
    /// a pathologically wedged run reaches this ceiling, at which point
    /// the user has almost certainly already quit the app.
    ///
    /// Prior wrong values in this file's history:
    ///   * 30s (v1.8.3): ~240× too short; every fresh install failed at
    ///     `.autotuning` — see 2026-07-05 smoke report at
    ///     `/private/tmp/claude-501/.../scratchpad/smoke-v183/`.
    ///   * 1800s / 2700s (R1/R2 audit rounds): under-counted candidate
    ///     cardinality and per-candidate steps.
    static let processTimeout: TimeInterval = 7260

    private final class ProcessOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func value(appending remaining: Data) -> Data {
            lock.lock()
            var copy = data
            lock.unlock()
            copy.append(remaining)
            return copy
        }
    }

    static func run(
        cliURL: URL,
        configPath: URL = ProviderPaths.current.configFile
    ) async throws -> AutotuneRecommendationResult {
        let data = try await runProcess(
            executableURL: cliURL,
            arguments: ["autotune", "--recommend", "--json", "--config", configPath.path]
        )
        return try AutotuneRecommendationResult.fromAutotuneJSON(data)
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = processTimeout,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                let output = ProcessOutputBuffer()

                process.executableURL = executableURL
                process.arguments = arguments
                do {
                    process.environment = try sanitizedProcessEnvironment(from: environment)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.standardOutput = stdout
                process.standardError = stderr

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    output.append(chunk)
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    _ = handle.availableData
                }

                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(max(1, timeout))
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                        throw AutotuneRecommendationError.timedOut
                    }
                    process.waitUntilExit()
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    let remainingOutput = stdout.fileHandleForReading.readDataToEndOfFile()
                    _ = stderr.fileHandleForReading.readDataToEndOfFile()
                    let data = output.value(appending: remainingOutput)
                    guard process.terminationStatus == 0 else {
                        throw AutotuneRecommendationError.nonZeroExit(process.terminationStatus)
                    }
                    continuation.resume(returning: data)
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func sanitizedProcessEnvironment(from environment: [String: String]) throws -> [String: String] {
        try ProcessEnvironmentSanitizer.sanitized(from: environment)
    }
}

enum AutotuneRecommendationError: Error {
    case invalidJSON
    case nonZeroExit(Int32)
    case timedOut
}

struct AutotuneRecommendationResult: Equatable {
    let plan: LaunchProviderController.ModelDownloadPlan
    let serveConfig: ProviderConfig.AutotuneServeConfig

    static func fromAutotuneJSON(_ data: Data) throws -> Self {
        let rootObject = try JSONSerialization.jsonObject(with: data)
        guard let root = rootObject as? [String: Any] else {
            throw AutotuneRecommendationError.invalidJSON
        }
        return AutotuneRecommendationResult(
            plan: try LaunchProviderController.ModelDownloadPlan.fromAutotuneRoot(root),
            serveConfig: try AutotuneServeConfigEnvelope.decode(from: data)
        )
    }
}

private struct AutotuneServeConfigEnvelope: Decodable {
    let serveConfig: AutotuneServeConfigPayload

    enum CodingKeys: String, CodingKey {
        case serveConfig = "serve_config"
    }

    static func decode(from data: Data) throws -> ProviderConfig.AutotuneServeConfig {
        do {
            let envelope = try JSONDecoder().decode(Self.self, from: data)
            return try envelope.serveConfig.providerConfig()
        } catch {
            throw AutotuneRecommendationError.invalidJSON
        }
    }
}

private struct AutotuneServeConfigPayload: Decodable {
    let model: String
    let modelArtifactPath: String
    let modelArtifactSHA256: String
    let modelCatalogKey: String
    let modelCatalogModelID: String
    let modelCatalogRevision: String
    let modelCatalogSHA256: String
    let modelCatalogVersion: String
    let modelCatalogHash: String
    let kvBits: Int?
    let maxContextOverride: Int
    let maxConcurrencyOverride: Int
    let donorMode: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case modelArtifactPath = "model_artifact_path"
        case modelArtifactSHA256 = "model_artifact_sha256"
        case modelCatalogKey = "model_catalog_key"
        case modelCatalogModelID = "model_catalog_model_id"
        case modelCatalogRevision = "model_catalog_revision"
        case modelCatalogSHA256 = "model_catalog_sha256"
        case modelCatalogVersion = "model_catalog_version"
        case modelCatalogHash = "model_catalog_hash"
        case kvBits = "kv_bits"
        case maxContextOverride = "max_context_override"
        case maxConcurrencyOverride = "max_concurrency_override"
        case donorMode = "donor_mode"
    }

    func providerConfig() throws -> ProviderConfig.AutotuneServeConfig {
        guard [
            model,
            modelArtifactPath,
            modelArtifactSHA256,
            modelCatalogKey,
            modelCatalogModelID,
            modelCatalogRevision,
            modelCatalogSHA256,
            modelCatalogVersion,
            modelCatalogHash,
        ].allSatisfy({ !$0.isEmpty }) else {
            throw AutotuneRecommendationError.invalidJSON
        }

        return ProviderConfig.AutotuneServeConfig(
            model: model,
            modelArtifactPath: modelArtifactPath,
            modelArtifactSHA256: modelArtifactSHA256,
            modelCatalogKey: modelCatalogKey,
            modelCatalogModelID: modelCatalogModelID,
            modelCatalogRevision: modelCatalogRevision,
            modelCatalogSHA256: modelCatalogSHA256,
            modelCatalogVersion: modelCatalogVersion,
            modelCatalogHash: modelCatalogHash,
            kvBits: kvBits,
            maxContextOverride: maxContextOverride,
            maxConcurrencyOverride: maxConcurrencyOverride,
            donorMode: donorMode ?? false
        )
    }
}

extension LaunchProviderController.ModelDownloadPlan {
    static func fromAutotuneJSON(_ data: Data) throws -> Self {
        let rootObject = try JSONSerialization.jsonObject(with: data)
        guard let root = rootObject as? [String: Any] else {
            throw AutotuneRecommendationError.invalidJSON
        }
        return try fromAutotuneRoot(root)
    }

    static func fromAutotuneRoot(_ root: [String: Any]) throws -> Self {
        let modelName = recommendedModel(in: root) ?? Self.recommended.modelName
        let range = earningsEstimate(modelName: modelName, root: root)
        return Self(modelName: modelName, state: nil, earningsEstimate: range)
    }

    private static func recommendedModel(in root: [String: Any]) -> String? {
        if let model = root["recommended_model"] as? String, !model.isEmpty {
            return model
        }
        if let recommendation = root["recommendation"] as? [String: Any],
           let model = recommendation["model"] as? String,
           !model.isEmpty {
            return model
        }
        return nil
    }

    private static func earningsEstimate(modelName: String, root: [String: Any]) -> EarningsEstimateRange? {
        if let explicit = explicitDailyRange(modelName: modelName, root: root) {
            return explicit
        }
        guard let candidate = candidate(modelName: modelName, root: root),
              let hourly = double(candidate["expected_net_usd_per_hour"]) else {
            return nil
        }
        let inputs = root["inputs"] as? [String: Any]
        let hours = double(inputs?["availability_hours_per_day"]) ?? 24
        let daily = max(0, hourly * hours)
        guard daily.isFinite else { return nil }
        return EarningsEstimateRange(lowDailyUSD: daily, highDailyUSD: daily)
    }

    private static func explicitDailyRange(modelName: String, root: [String: Any]) -> EarningsEstimateRange? {
        let candidate = candidate(modelName: modelName, root: root)
        let low = double(candidate?["expected_net_usd_per_day_low"])
            ?? double(root["expected_net_usd_per_day_low"])
            ?? double(root["estimated_daily_usd_low"])
        let high = double(candidate?["expected_net_usd_per_day_high"])
            ?? double(root["expected_net_usd_per_day_high"])
            ?? double(root["estimated_daily_usd_high"])
        guard let low, let high, low.isFinite, high.isFinite else { return nil }
        return EarningsEstimateRange(lowDailyUSD: max(0, min(low, high)), highDailyUSD: max(0, max(low, high)))
    }

    private static func candidate(modelName: String, root: [String: Any]) -> [String: Any]? {
        guard let candidates = root["candidates"] as? [[String: Any]] else { return nil }
        return candidates.first { ($0["model"] as? String) == modelName }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}
