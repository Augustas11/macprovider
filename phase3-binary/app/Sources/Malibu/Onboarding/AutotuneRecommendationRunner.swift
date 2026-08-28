import Foundation

enum AutotuneRecommendationRunner {
    /// Wall-clock budget for `malibu-cli autotune --recommend --json`.
    ///
    /// Autotune runs Stage-1 probes against every non-blocked, RAM-eligible
    /// row in the catalog. Rows that fail artifact verification (e.g. stale
    /// HuggingFace cache hash mismatch on an unrelated model) are skipped with
    /// a diagnostic instead of aborting the whole run. Optional
    /// `--candidate-models` scopes probes to matching catalog `model_id`s. Each probe spawns a subprocess of
    /// `malibu-cli serve`, waits for MLX to load the model, then does a
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
    /// `phase3-binary/Sources/malibu-cli/AutotuneCommand.swift:47-48`
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

    /// Pending-trust path: resubmit stored evidence without rebenchmarking.
    static func pendingEvidenceResubmitArguments(configPath: URL) -> [String] {
        [
            "autotune",
            "--recommend",
            "--freshness-check",
            "--require-hardware-evidence",
            "--json",
            "--config", configPath.path,
        ]
    }

    /// Corrective #582 recovery transaction owned by the CLI.
    static func hardwareAdmissionRecoveryArguments(configPath: URL) -> [String] {
        [
            "autotune",
            "--recommend",
            "--recover-hardware-admission",
            "--json",
            "--config", configPath.path,
        ]
    }

    static func runPendingEvidenceResubmit(
        cliURL: URL,
        configPath: URL = ProviderPaths.current.configFile
    ) async throws {
        _ = try await runProcess(
            executableURL: cliURL,
            arguments: pendingEvidenceResubmitArguments(configPath: configPath),
            timeout: 120
        )
    }

    /// Cooperative cancel grace for corrective recovery. Must outlive
    /// `drainGrace` plus CLI SIGTERM cascade so restore can run before the
    /// App gives up; do not escalate to SIGKILL on this path.
    static let recoveryCancelGraceSeconds: TimeInterval = 120

    /// Runs the CLI corrective recovery transaction. Drain/restore and evidence
    /// requirements are owned by malibu-cli; Malibu only launches and
    /// cooperatively cancels (no SIGKILL) so restore can complete.
    static func runHardwareAdmissionRecovery(
        cliURL: URL,
        configPath: URL = ProviderPaths.current.configFile
    ) async throws {
        _ = try await runProcess(
            executableURL: cliURL,
            arguments: hardwareAdmissionRecoveryArguments(configPath: configPath),
            cancelGraceSeconds: recoveryCancelGraceSeconds,
            escalateToSIGKILL: false
        )
    }

    /// Whether Malibu should attempt a best-effort launchd bootstrap after a
    /// hardware-recovery attempt. Only corrective recovery drains/bootouts;
    /// pending freshness never owns that obligation.
    static func shouldBestEffortBootstrapLaunchd(
        attemptedCorrectiveRecovery: Bool
    ) -> Bool {
        attemptedCorrectiveRecovery
    }

    /// Best-effort launchd bootstrap after cancelled/failed corrective recovery.
    /// Safe if the job is already loaded; ignores nonzero exit.
    static func bestEffortBootstrapLaunchdProvider(
        uid: uid_t = getuid(),
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/live.malibu.provider.plist")
    ) {
        let process = Process()
        process.executableURL = launchctlURL
        process.arguments = ["bootstrap", "gui/\(uid)", plistURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private final class ProcessHold: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private let cancelGraceSeconds: TimeInterval
        private let escalateToSIGKILL: Bool

        init(cancelGraceSeconds: TimeInterval, escalateToSIGKILL: Bool) {
            self.cancelGraceSeconds = cancelGraceSeconds
            self.escalateToSIGKILL = escalateToSIGKILL
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func register(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldTerminate = cancelled
            lock.unlock()
            if shouldTerminate {
                terminate(process)
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process {
                terminate(process)
            }
        }

        private func terminate(_ process: Process) {
            guard process.isRunning else { return }
            AutotuneRecommendationRunner.terminateAutotuneSubtree(
                process: process,
                graceSeconds: cancelGraceSeconds,
                escalateToSIGKILL: escalateToSIGKILL
            )
        }
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = processTimeout,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cancelGraceSeconds: TimeInterval = subtreeGraceSeconds,
        escalateToSIGKILL: Bool = true
    ) async throws -> Data {
        try Task.checkCancellation()
        let hold = ProcessHold(
            cancelGraceSeconds: cancelGraceSeconds,
            escalateToSIGKILL: escalateToSIGKILL
        )
        let result: Result<(Data, String), Error> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    let stdout = Pipe()
                    let stderr = Pipe()
                    let output = ProcessOutputBuffer()
                    let errOutput = ProcessOutputBuffer()

                    process.executableURL = executableURL
                    process.arguments = arguments
                    do {
                        process.environment = try sanitizedProcessEnvironment(from: environment)
                    } catch {
                        continuation.resume(returning: .failure(error))
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
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        errOutput.append(chunk)
                    }

                    do {
                        try process.run()
                        hold.register(process)
                        let deadline = Date().addingTimeInterval(max(1, timeout))
                        while process.isRunning && Date() < deadline && !hold.isCancelled {
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                        if hold.isCancelled {
                            if process.isRunning {
                                Self.terminateAutotuneSubtree(
                                    process: process,
                                    graceSeconds: cancelGraceSeconds,
                                    escalateToSIGKILL: escalateToSIGKILL
                                )
                                if escalateToSIGKILL {
                                    process.waitUntilExit()
                                } else {
                                    let waitDeadline = Date().addingTimeInterval(1)
                                    while process.isRunning && Date() < waitDeadline {
                                        Thread.sleep(forTimeInterval: 0.05)
                                    }
                                }
                            }
                            stdout.fileHandleForReading.readabilityHandler = nil
                            stderr.fileHandleForReading.readabilityHandler = nil
                            continuation.resume(returning: .failure(CancellationError()))
                            return
                        }
                        if process.isRunning {
                            // Recovery must keep cooperative-only teardown here
                            // too: escalating to SIGKILL before the CLI can
                            // restore would strand a post-bootout provider.
                            let timeoutGrace = escalateToSIGKILL
                                ? subtreeGraceSeconds
                                : cancelGraceSeconds
                            Self.terminateAutotuneSubtree(
                                process: process,
                                graceSeconds: timeoutGrace,
                                escalateToSIGKILL: escalateToSIGKILL
                            )
                            if escalateToSIGKILL {
                                process.waitUntilExit()
                            }
                            throw AutotuneRecommendationError.timedOut
                        }
                        process.waitUntilExit()
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        let remainingOutput = stdout.fileHandleForReading.readDataToEndOfFile()
                        let remainingErr = stderr.fileHandleForReading.readDataToEndOfFile()
                        let data = output.value(appending: remainingOutput)
                        let errText = String(decoding: errOutput.value(appending: remainingErr), as: UTF8.self)
                        guard process.terminationStatus == 0 else {
                            throw AutotuneRecommendationError.nonZeroExit(
                                process.terminationStatus,
                                stderrTail: String(errText.suffix(512))
                            )
                        }
                        continuation.resume(returning: .success((data, errText)))
                    } catch {
                        if process.isRunning {
                            let failureGrace = escalateToSIGKILL
                                ? subtreeGraceSeconds
                                : cancelGraceSeconds
                            Self.terminateAutotuneSubtree(
                                process: process,
                                graceSeconds: failureGrace,
                                escalateToSIGKILL: escalateToSIGKILL
                            )
                            if escalateToSIGKILL {
                                process.waitUntilExit()
                            }
                        }
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } onCancel: {
            hold.cancel()
        }
        try Task.checkCancellation()
        switch result {
        case .success(let pair):
            return pair.0
        case .failure(let error):
            throw error
        }
    }

    static func sanitizedProcessEnvironment(from environment: [String: String]) throws -> [String: String] {
        try ProcessEnvironmentSanitizer.sanitized(from: environment)
    }

    /// Wall-clock grace between SIGTERM (via `process.terminate()`) and the
    /// SIGKILL group escalation. Long enough for the CLI's cascading signal
    /// handler to fire and every `serve --no-join` grandchild to unwind
    /// cleanly, short enough that a truly wedged CLI does not delay App
    /// shutdown by a visible amount.
    static let subtreeGraceSeconds: TimeInterval = 5

    /// Send SIGTERM to the CLI (Foundation's `process.terminate()` does
    /// `kill(pid, SIGTERM)`), then poll for grace. If still alive, escalate
    /// to `killpg(cliPid, SIGKILL)` which reaches every grandchild that
    /// inherited the CLI's process-group id (the CLI's `--recommend` path
    /// calls `setpgid(0, 0)` early, making `cliPid == pgid`). Follow up
    /// with a direct `SIGKILL` to the CLI pid in case `killpg` returned
    /// ESRCH before `setpgid` ran (race window between fork/exec and the
    /// CLI installing its group).
    static func terminateAutotuneSubtree(
        process: Process,
        graceSeconds: TimeInterval,
        escalateToSIGKILL: Bool = true
    ) {
        process.terminate()
        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else { return }
        guard escalateToSIGKILL else { return }
        let cliPid = process.processIdentifier
        _ = Darwin.killpg(cliPid, SIGKILL)
        _ = Darwin.kill(cliPid, SIGKILL)
        // Poll briefly so callers observing `process.isRunning` immediately
        // after termination don't race the kernel's reap of the SIGKILLed
        // child. Bounded — SIGKILL is uncatchable, so 1s is generous.
        let killDeadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

enum AutotuneRecommendationError: Error, LocalizedError {
    case invalidJSON
    case nonZeroExit(Int32, stderrTail: String = "")
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Provider setup returned invalid data."
        case .nonZeroExit(let code, let stderrTail):
            let detail = stderrTail
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty })
            if let detail, detail.count <= 180 {
                return "Provider setup failed (exit \(code)): \(detail)"
            }
            return "Provider setup failed (exit \(code))."
        case .timedOut:
            return "Provider setup timed out."
        }
    }
}

struct ModelDownloadPlan: Equatable {
    let modelName: String
    let earningsEstimate: EarningsEstimateRange?

    static let recommended = ModelDownloadPlan(modelName: "recommended", earningsEstimate: nil)
}

struct AutotuneRecommendationResult: Equatable {
    let plan: ModelDownloadPlan
    let serveConfig: ProviderConfig.AutotuneServeConfig

    static func fromAutotuneJSON(_ data: Data) throws -> Self {
        let rootObject = try JSONSerialization.jsonObject(with: data)
        guard let root = rootObject as? [String: Any] else {
            throw AutotuneRecommendationError.invalidJSON
        }
        return AutotuneRecommendationResult(
            plan: try ModelDownloadPlan.fromAutotuneRoot(root),
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

extension ModelDownloadPlan {
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
        return Self(modelName: modelName, earningsEstimate: range)
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
