#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MLX
import MacProviderCore

/// `multi-model-bench --check`: the single check command of the #2338 swarm
/// run (scratchpad/swarm-brief-2338-gpu-sharing.md).
///
/// A lane is one row of one model: it serves that model's fixed prompts one
/// after another, starting at its own offset, until the phase deadline, then
/// finishes its in-flight request. Phases: an unmeasured `warmup` (one
/// request per model, alone), `solo-a`, `solo-b`, a `reference`
/// pre-pass that serves once, alone, every prompt index the solo phases did
/// not reach, `contended` (both models), and an optional `soak`.
///
/// Each runtime is constructed the way `serve` builds one: paged KV on with
/// the family defaults, the continuous-batching mode explicitly configured
/// (`--cb-x`, as `serve --continuous-batching` does) and max batch = rows,
/// bound to the catalog serving id (`--model-id-x`) and loaded from the
/// snapshot (`--model-x`). Mixed-cache models (GLM-5.3-Flash, Qwen3.6/3.8)
/// attach paged KV, and so batch, only under their exact serving id.
/// A model asked for rows > 1 whose runtime reports a serialized engine, or
/// whose scheduler never batched two rows, is a `CHECK error`, never a GOAL.
/// Native MTP is not offered: the production load admits it only through a
/// signed admission sidecar, and this harness has no lab path around that.
///
/// One interval rule for every measured phase: tokens arriving between ramp
/// end (`rampSeconds`) and the phase deadline, over that wall time. In
/// `contended` and `soak` both models must have a request in flight for at
/// least `minimumOverlap` of the interval, else `CHECK error not_overlapped`.
/// Tokens are placed on chunk arrival times in order: exact when chunks
/// equal completion tokens, proportional otherwise (recorded per phase).
///
/// stdout ends with `GATE pass|fail ...` then `GOAL share=...`. Exit codes:
/// 0 pass, 2 gate fail, 3 hang, 1 when the check cannot run.
enum MultiModelCheck {
    static let rampSeconds: Double = 10
    static let minimumOverlap = 0.95
    /// Upper bound on waiting for serve's CB self-check decision at load.
    static let selfCheckBoundSeconds: Double = 1800
    static let promptsPerModel = 8
    static let schema = "macprovider.multi-model-bench.check.v1"

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func seconds(_ nanos: UInt64, since start: UInt64) -> Double {
        nanos >= start ? Double(nanos - start) / 1e9 : -Double(start - nanos) / 1e9
    }

    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
        MultiModelBenchCommand.log(line)
    }
}

extension MultiModelBenchCommand {
    func runCheck() async throws {
        let nonce = String(UUID().uuidString.prefix(8).lowercased())
        let capturePath = Self.prepareTokenCapture(nonce: nonce)
        let firstFamily = ModelRuntime.localModelFamily(modelA)
        let appliedBudgetMB = firstFamily.flatMap { ModelRuntime.applyMLXCommandBufferBudget(modelFamily: $0) }
        let basePrompt = Self.promptText(promptTokens: promptTokens)
        // SPEC-001-R018: the lab selects the GPU turn policy both runtimes
        // share; an invalid flag or env value fails the check before any load.
        let gpuTurnSelection: (policy: any GPUTurnPolicy, source: String)
        do {
            gpuTurnSelection = try GPUTurnPolicyRegistry.labSelection(
                flag: gpuTurnPolicy, environment: ProcessInfo.processInfo.environment
            ) ?? (GPUTurnPolicyRegistry.compiledDefault, "default")
        } catch {
            MultiModelCheck.emit("CHECK error reason=gpu_turn_policy_invalid detail=\"\(error)\"")
            throw ExitCode(1)
        }
        GPUTurnArbiter.shared.setPolicy(gpuTurnSelection.policy)
        MultiModelBenchCommand.log("gpu_turn_policy name=\(gpuTurnSelection.policy.name) parameters=\(gpuTurnSelection.policy.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")) source=\(gpuTurnSelection.source)")
        let config = MultiModelCheckConfig(
            modelA: modelA,
            modelB: modelB,
            modelIDA: modelIDA ?? modelA,
            modelIDB: modelIDB ?? modelB,
            rowsA: rowsA,
            rowsB: rowsB,
            continuousBatchingA: cbA,
            continuousBatchingB: cbB,
            maxTokensA: maxTokensA,
            maxTokensB: maxTokensB,
            promptTokensTarget: promptTokens,
            promptsPerModel: MultiModelCheck.promptsPerModel,
            phaseSeconds: phaseSeconds,
            soakSeconds: soakSeconds,
            rampSeconds: MultiModelCheck.rampSeconds,
            watchdogSeconds: watchdogSeconds,
            loadOrder: ["a", "b"],
            temperature: 0,
            topP: 1,
            stream: true,
            tokenCapturePath: capturePath,
            gpuTurnPolicy: MultiModelCheckGPUTurnPolicy(
                name: gpuTurnSelection.policy.name,
                parameters: gpuTurnSelection.policy.parameters,
                source: gpuTurnSelection.source
            )
        )
        let report = MultiModelCheckReport(
            schema: MultiModelCheck.schema,
            generatedAtUnixSeconds: Date().timeIntervalSince1970,
            host: MultiModelBenchHost.current(),
            binaryVersion: CoordinatorClient.binaryVersion,
            config: config,
            processEnvironment: MultiModelBenchProcessEnvironment(
                firstLoadedModelFamily: firstFamily,
                commandBufferBudgetAppliedMb: appliedBudgetMB,
                mlxMaxMbPerBuffer: ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
            )
        )
        let box = MultiModelCheckReportBox(report: report, outPath: out)
        box.write()
        let monitor = MultiModelBenchMonitor(outPath: nil, watchdogSeconds: watchdogSeconds) { phase, idle, footprint in
            box.hang(phase: phase, secondsSinceLastChunk: idle, footprintMax: footprint)
        }
        monitor.start()
        defer { monitor.stop() }
        do {
            let serve = try MultiModelCheckServeSettings.resolve(configPath: configPath)
            let runner = MultiModelCheckRunner(config: config, serve: serve, basePrompt: basePrompt, nonce: nonce, box: box, monitor: monitor)
            try await runner.run()
        } catch let failure as MultiModelCheckFailure {
            box.update { $0.error = failure.reason }
            box.write()
            MultiModelCheck.emit("CHECK error reason=\(failure.reason)")
            throw ExitCode(1)
        } catch let exit as ExitCode {
            throw exit
        } catch {
            let reason = "error detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))"
            box.update { $0.error = reason }
            box.write()
            MultiModelCheck.emit("CHECK error reason=\(reason)")
            throw ExitCode(1)
        }
    }
}

struct MultiModelCheckFailure: Error {
    let reason: String
}

// MARK: - Runner

struct MultiModelCheckRunner: Sendable {
    let config: MultiModelCheckConfig
    let serve: MultiModelCheckServeSettings
    let basePrompt: String
    let nonce: String
    let box: MultiModelCheckReportBox
    let monitor: MultiModelBenchMonitor
    /// SPEC-001-R018: arbiter statistics per phase, by slot.
    let gpuTurns = MultiModelCheckGPUTurnWindow()
    /// SPEC-001-R017: shared memory budget per phase, by slot.
    let memoryBudget = MultiModelCheckMemoryBudgetWindow()

    func run() async throws {
        for (slot, path) in [(MultiModelBenchSlot.a, config.modelA), (.b, config.modelB)] {
            try Self.requireModelDirectory(slot: slot, value: path)
        }
        var runtimes: [MultiModelBenchSlot: ModelRuntime] = [:]
        for slot in MultiModelBenchSlot.allCases {
            runtimes[slot] = try await load(slot)
            gpuTurns.bind(slot: slot, participantID: runtimes[slot]!.gpuTurnParticipant.id)
            memoryBudget.bind(slot: slot, memberID: runtimes[slot]!.memoryBudgetMemberID)
        }
        var requests: [MultiModelBenchSlot: [ChatCompletionRequest]] = [:]
        for slot in MultiModelBenchSlot.allCases {
            let modelID = slot == .a ? config.modelIDA : config.modelIDB
            let maxTokens = slot == .a ? config.maxTokensA : config.maxTokensB
            requests[slot] = try (0..<config.promptsPerModel).map { index in
                try MultiModelBenchCommand.request(
                    modelID: modelID,
                    prompt: "Request \(index + 1) of \(config.promptsPerModel). " + basePrompt,
                    maxTokens: maxTokens
                )
            }
        }
        let lanes = MultiModelCheckLanes(runtimes: runtimes, requests: requests, nonce: nonce, capturePath: config.tokenCapturePath, monitor: monitor, box: box)

        // A runtime's first request can take far longer than the ramp
        // (observed 34 s to first token on a cold second runtime), so each
        // model serves one unmeasured request alone before solo-a.
        _ = try await runSequential(.warmup, MultiModelBenchSlot.allCases.map { ($0, 0) }, lanes: lanes)
        let soloA = try await runPhase(.soloA, seconds: config.phaseSeconds, lanes: lanes)
        let soloB = try await runPhase(.soloB, seconds: config.phaseSeconds, lanes: lanes)
        var references: [MultiModelBenchSlot: [Int: MultiModelCheckRequestRecord]] = [.a: [:], .b: [:]]
        // References come from the solo phases and the pre-pass, which both
        // run the model's own row count; the warmup (one row) never does.
        for record in soloA.requests + soloB.requests {
            let slot = MultiModelBenchSlot(rawValue: record.model)!
            if references[slot]![record.promptIndex] == nil { references[slot]![record.promptIndex] = record }
        }
        var missing: [MultiModelBenchSlot: [Int]] = [:]
        for slot in MultiModelBenchSlot.allCases {
            missing[slot] = (0..<config.promptsPerModel).filter { references[slot]![$0] == nil }
        }
        let referencePass = try await runReferencePass(missing, lanes: lanes)
        for record in referencePass.requests where !record.filler {
            references[MultiModelBenchSlot(rawValue: record.model)!]![record.promptIndex] = record
        }
        box.update { report in
            report.references = MultiModelBenchSlot.allCases.flatMap { slot in
                references[slot]!.keys.sorted().map { MultiModelCheckReference(slot: slot, record: references[slot]![$0]!) }
            }
        }
        box.write()

        let contended = try await runPhase(.contended, seconds: config.phaseSeconds, lanes: lanes)
        var checked = [contended]
        if config.soakSeconds > 0 {
            checked.append(try await runPhase(.soak, seconds: config.soakSeconds, lanes: lanes))
        }

        for slot in MultiModelBenchSlot.allCases {
            let snapshot = await runtimes[slot]!.currentSnapshot()
            box.update { report in
                guard let index = report.runtimes.firstIndex(where: { $0.model == slot.rawValue }) else { return }
                report.runtimes[index].recordEnd(snapshot)
            }
        }

        let gate = Self.gate(checked: checked, references: references, report: box.snapshot())
        let goal = try Self.goal(soloA: soloA, soloB: soloB, contended: contended)
        box.update { report in
            report.parityChecked = gate.checked
            report.parityMismatches = gate.mismatches
            report.outputComparison = gate.outputComparison
            report.gate = MultiModelCheckGate(pass: gate.reasons.isEmpty, reasons: gate.reasons, line: gate.line)
            report.goal = goal
            report.complete = true
        }
        box.write()
        MultiModelCheck.emit(gate.line)
        MultiModelCheck.emit(goal.line)
        if !gate.reasons.isEmpty { throw ExitCode(2) }
    }

    /// A value that names a local path must exist as a directory; anything
    /// else is treated as a model id and left to the runtime.
    static func isLocalPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix(".") || value.hasPrefix("~")
    }

    static func requireModelDirectory(slot: MultiModelBenchSlot, value: String) throws {
        guard isLocalPath(value) else { return }
        let path = (value as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MultiModelCheckFailure(reason: "missing_model_dir model=\(slot.rawValue) path=\(path)")
        }
    }

    private func load(_ slot: MultiModelBenchSlot) async throws -> ModelRuntime {
        let loadValue = slot == .a ? config.modelA : config.modelB
        // As serve: the runtime is bound to the catalog serving id and loads
        // from the snapshot path. The SPEC-039 FR-PKV12 mixed-layout allowlist
        // (ModelRuntime.pagedKVModelCapabilities) keys on that serving id, so
        // a path-bound GLM-5.3-Flash or Qwen3.8 runtime falls back with
        // `paged_fallback_cache_class` and never batches.
        let modelID = slot == .a ? config.modelIDA : config.modelIDB
        let modelLoadPath: String? = modelID == loadValue ? nil : loadValue
        MultiModelBenchCommand.log("load start model=\(slot.rawValue) id=\(modelID) load_path=\(modelLoadPath ?? "nil")")
        let started = Date()
        let rows = rows(slot)
        let mode = ContinuousBatchingMode(rawValue: slot == .a ? config.continuousBatchingA : config.continuousBatchingB) ?? .on
        // As serve: paged KV attaches by default with the family block size,
        // sized to the advertised context (MacProviderCLI.swift serve path).
        let pagedKV = serve.pagedKV
            .withFamilyDefaults(modelFamily: ModelRuntime.localModelFamily(loadValue) ?? "")
            .sizedToCover(contextTokens: ProviderCapacity(maxContextOverride: serve.maxContextOverride, maxConcurrencyOverride: nil).maxContextTokens)
        // Serve passes the catalog-verified snapshot-manifest hash; paged KV
        // (and so CB) attaches only with an artifact identity. A local
        // snapshot gets the same canonical hash the catalog records.
        let artifactSHA256: String?
        if Self.isLocalPath(loadValue) {
            do {
                artifactSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(
                    directory: URL(fileURLWithPath: (loadValue as NSString).expandingTildeInPath))
            } catch {
                throw MultiModelCheckFailure(reason: "artifact_hash_failed model=\(slot.rawValue) detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))")
            }
        } else {
            artifactSHA256 = nil
        }
        // SPEC-001-R017 *Load*: the shared budget decides before any weights
        // are read, from the snapshot's safetensors sizes.
        let loadDecision = Self.loadDecision(slot: slot, loadValue: loadValue, maxContextOverride: serve.maxContextOverride)
        box.update { $0.loadDecisions.append(loadDecision) }
        box.write()
        MultiModelBenchCommand.log("load_decision model=\(slot.rawValue) admitted=\(loadDecision.decision.admitted) reason=\(loadDecision.decision.reason) required_bytes=\(loadDecision.decision.requiredBytes) limit_bytes=\(loadDecision.decision.limitBytes.map(String.init) ?? "nil")")
        guard loadDecision.decision.admitted else {
            throw MultiModelCheckFailure(reason: "insufficient_memory model=\(slot.rawValue) required_bytes=\(loadDecision.decision.requiredBytes) limit_bytes=\(loadDecision.decision.limitBytes.map(String.init) ?? "nil")")
        }
        let runtime: ModelRuntime
        do {
            runtime = try await ModelRuntime(
                modelID: modelID,
                modelLoadPath: modelLoadPath,
                mlxCacheLimitMB: serve.mlxCacheLimitMB,
                maxContextTokensOverride: serve.maxContextOverride,
                kvBitsOverride: serve.kvBitsOverride,
                familyKVQuantDefault: true,
                pagedKVConfig: pagedKV,
                prefillStepSize: serve.prefillStepSize,
                prefillStepSizeExplicitlyConfigured: serve.prefillStepSizeExplicitlyConfigured,
                maxBatch: rows,
                continuousBatchingMode: mode,
                continuousBatchQueueLimit: serve.continuousBatchQueueLimit,
                continuousBatchQueueWaitTimeoutMS: serve.continuousBatchQueueWaitTimeoutMS,
                continuousBatchPrefillTokensPerIteration: serve.continuousBatchPrefillTokensPerIteration,
                continuousBatchingCachedTurns: serve.continuousBatchingCachedTurns,
                // Serve's coverage for every non-autotune runtime.
                continuousBatchingAcceptanceCoverage: .defaultOn(revocations: []),
                continuousBatchingModeExplicitlyConfigured: true,
                nativeMTPMode: serve.nativeMTPMode,
                verifiedModelArtifactSHA256: artifactSHA256
            )
        } catch {
            throw MultiModelCheckFailure(reason: "load_failed model=\(slot.rawValue) detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))")
        }
        guard await runtime.isLoaded else {
            throw MultiModelCheckFailure(reason: "load_failed model=\(slot.rawValue) detail=not_loaded")
        }
        let selfCheck = try await runSelfCheck(slot: slot, runtime: runtime, modelID: modelID, rows: rows, mode: mode, artifactSHA256: artifactSHA256)
        let load = MultiModelBenchLoad(
            model: slot.rawValue,
            modelID: modelID,
            modelFamily: ModelRuntime.localModelFamily(loadValue),
            loadSeconds: Date().timeIntervalSince(started),
            mlxActiveBytes: Memory.activeMemory,
            mlxPeakBytes: Memory.peakMemory,
            mlxCacheBytes: Memory.cacheMemory,
            mlxCacheLimitBytes: Memory.cacheLimit,
            mlxMemoryLimitBytes: Memory.memoryLimit,
            physFootprintBytes: MultiModelBenchMonitor.physFootprintBytes(),
            mlxMaxMbPerBuffer: ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
        )
        let state = MultiModelCheckRuntimeState(
            slot: slot,
            requestedMode: mode,
            rows: rows,
            snapshot: await runtime.currentSnapshot(),
            servedSlots: await runtime.servedSlotLimitForTest(),
            selfCheck: selfCheck
        )
        box.update { report in
            report.loads.append(load)
            report.runtimes.append(state)
            report.modelArtifactSha256[slot.rawValue] = artifactSHA256
        }
        box.write()
        MultiModelBenchCommand.log("load done model=\(slot.rawValue) seconds=\(String(format: "%.1f", load.loadSeconds)) engine=\(state.engine) cb_mode=\(state.continuousBatchingMode ?? "nil") cb_active=\(state.continuousBatchingActive) paged_kv=\(state.pagedKvDecision ?? "nil") served_slots=\(state.servedSlots) native_mtp=\(state.nativeMTPModeAtLoad) memory_limit=\(load.mlxMemoryLimitBytes)")
        if rows > 1, state.engine != "continuous_batching" || state.servedSlots < rows {
            throw MultiModelCheckFailure(reason: "engine_mismatch model=\(slot.rawValue) rows=\(rows) engine=\(state.engine) served_slots=\(state.servedSlots) cb_mode=\(state.continuousBatchingMode ?? "nil") cb_unsupported=\(state.continuousBatchingUnsupportedReason ?? "nil") paged_kv=\(state.pagedKvDecision ?? "nil")")
        }
        return runtime
    }

    static func loadDecision(slot: MultiModelBenchSlot, loadValue: String, maxContextOverride: Int?) -> MultiModelCheckLoadDecision {
        let directory = try? ModelRuntime.localModelDirectory(for: loadValue)
        let estimated = directory.map { SharedModelMemoryRules.estimatedResidentBytes(modelDirectory: $0) } ?? 0
        let perToken = MLXMemoryLimit.kvBytesPerToken(modelDirectory: directory) ?? 0
        let rowKV = MLXMemoryBudget.kvBytes(tokens: SharedModelMemoryRules.minimumRowTokens, bytesPerToken: perToken)
        return MultiModelCheckLoadDecision(
            model: slot.rawValue,
            decision: SharedModelMemoryBudget.shared.canLoad(estimatedResidentBytes: estimated, minimumRowKVBytes: rowKV))
    }

    /// Serve's default-on path: under default-on coverage the runtime serves
    /// serially until this Mac's CB self-check decides. Runs serve's own
    /// `ContinuousBatchingSelfCheckDriver` against a private ProviderStatus and
    /// a private, empty decision store (no prior grant carries over), and
    /// waits for its decision. Nil when CB is off or nothing can be checked.
    private func runSelfCheck(
        slot: MultiModelBenchSlot,
        runtime: ModelRuntime,
        modelID: String,
        rows: Int,
        mode: ContinuousBatchingMode,
        artifactSHA256: String?
    ) async throws -> MultiModelCheckSelfCheck? {
        guard mode != .off, await runtime.continuousBatchingSelfCheckTarget() != nil else { return nil }
        let status = ProviderStatus(
            modelID: modelID,
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: rows),
            modelHash: artifactSHA256
        )
        await runtime.setProviderStatus(status)
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macprovider-multi-model-check-\(nonce)-\(slot.rawValue)")
            .appendingPathComponent(ContinuousBatchingSelfCheckStore.fileName)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let driver = ContinuousBatchingSelfCheckDriver(
            runtime: runtime,
            providerStatus: status,
            store: ContinuousBatchingSelfCheckStore(url: storeURL),
            ownerPinnedSlots: nil,
            idleSeconds: 1,
            pollSeconds: 0.5,
            log: { MultiModelBenchCommand.log("cb_self_check model=\(slot.rawValue) \($0)") }
        )
        MultiModelBenchCommand.log("cb_self_check start model=\(slot.rawValue) max_rows=\(rows)")
        let started = Date()
        let task = Task { await driver.run() }
        var state = await runtime.continuousBatchingSelfCheckState()
        while state == .pending, Date().timeIntervalSince(started) < MultiModelCheck.selfCheckBoundSeconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            state = await runtime.continuousBatchingSelfCheckState()
        }
        task.cancel()
        await task.value
        let seconds = Date().timeIntervalSince(started)
        guard state != .pending else {
            throw MultiModelCheckFailure(reason: "self_check_timeout model=\(slot.rawValue) seconds=\(Int(seconds))")
        }
        let outcome: String
        switch state {
        case .granted(let slots): outcome = "granted slots=\(slots)"
        case .refused(let reason): outcome = "refused reason=\(reason)"
        case .pending: outcome = "pending"
        }
        MultiModelBenchCommand.log("cb_self_check done model=\(slot.rawValue) \(outcome) seconds=\(Int(seconds))")
        return MultiModelCheckSelfCheck(outcome: outcome, seconds: seconds, storePath: storeURL.path)
    }

    // MARK: Phases

    private func rows(_ slot: MultiModelBenchSlot) -> Int { slot == .a ? config.rowsA : config.rowsB }

    private func runPhase(_ phase: MultiModelCheckPhase, seconds: Double, lanes: MultiModelCheckLanes) async throws -> MultiModelCheckPhaseResult {
        let started = beginPhase(phase, seconds: seconds)
        let deadline = started + UInt64(seconds * 1e9)
        let rowCounts = Dictionary(uniqueKeysWithValues: phase.slots.map { ($0, rows($0)) })
        var records: [MultiModelCheckRequestRecord] = []
        do {
            records = try await withThrowingTaskGroup(of: [MultiModelCheckRequestRecord].self) { group in
                for slot in phase.slots {
                    let count = rowCounts[slot]!
                    for lane in 0..<count {
                        let offset = (lane * lanes.promptCount) / count
                        group.addTask {
                            try await lanes.runLane(phase: phase, slot: slot, lane: lane, offset: offset, phaseStart: started, deadline: deadline)
                        }
                    }
                }
                var all: [MultiModelCheckRequestRecord] = []
                for try await laneRecords in group { all.append(contentsOf: laneRecords) }
                return all
            }
        } catch {
            endPhase(phase, failedWith: error)
            throw error
        }
        lanes.attachOutputs(&records)
        records.sort { ($0.startSeconds, $0.model, $0.lane) < ($1.startSeconds, $1.model, $1.lane) }
        var result = finishPhase(phase, seconds: seconds, records: records, started: started)
        let window = (MultiModelCheck.rampSeconds, seconds)
        let intervalSeconds = window.1 - window.0
        result.measurementSegments = [[window.0, window.1]]
        result.measurementIntervalSeconds = intervalSeconds
        if phase.slots.count == 2 {
            var overlap = [window]
            for slot in phase.slots {
                overlap = MultiModelCheckIntervals.intersect(overlap, MultiModelCheckIntervals.union(records.filter { $0.model == slot.rawValue }.map(\.inFlightSpan)))
            }
            result.overlapFraction = overlap.reduce(0) { $0 + ($1.1 - $1.0) } / intervalSeconds
        }
        for slot in phase.slots {
            let modelRecords = records.filter { $0.model == slot.rawValue }
            var stats = MultiModelCheckModelPhaseStats(rows: rowCounts[slot]!, records: modelRecords, segments: [window], intervalSeconds: intervalSeconds)
            let scheduler = await lanes.runtimes[slot]!.currentSnapshot().continuousBatching?.scheduler
            stats.schedulerMaxObservedBatchDepth = scheduler?.maxObservedBatchDepth
            stats.schedulerSharedForwardCalls = scheduler?.sharedForwardCalls
            if slot == .a { result.a = stats } else { result.b = stats }
        }
        let snapshot = result
        box.update { $0.phases[$0.phases.count - 1] = snapshot }
        box.write()
        for slot in phase.slots {
            guard let stats = slot == .a ? result.a : result.b else { continue }
            MultiModelBenchCommand.log("  \(phase.rawValue) model=\(slot.rawValue) rows=\(stats.rows) batch_depth_max=\(stats.schedulerMaxObservedBatchDepth.map(String.init) ?? "n/a") completed=\(stats.requestsCompleted) tokens_in_interval=\(stats.tokensInInterval) decode_tps=\(stats.decodeTokensPerSecond.map { String(format: "%.2f", $0) } ?? "n/a") ttft_ms_median=\(stats.ttftMsMedian.map { String(format: "%.0f", $0) } ?? "n/a") interval_s=\(String(format: "%.1f", intervalSeconds))")
            guard stats.requestsCompleted > 0 else {
                throw MultiModelCheckFailure(reason: "no_completed_requests phase=\(phase.rawValue) model=\(slot.rawValue)")
            }
        }
        guard intervalSeconds > 0 else {
            throw MultiModelCheckFailure(reason: "empty_measurement_interval phase=\(phase.rawValue)")
        }
        if let overlap = result.overlapFraction {
            MultiModelBenchCommand.log("  \(phase.rawValue) overlap_fraction=\(String(format: "%.3f", overlap))")
            guard overlap >= MultiModelCheck.minimumOverlap else {
                throw MultiModelCheckFailure(reason: "not_overlapped phase=\(phase.rawValue) overlap_fraction=\(String(format: "%.3f", overlap)) required=\(MultiModelCheck.minimumOverlap)")
            }
        }
        // A rows > 1 model whose scheduler never put two rows in one forward
        // ran serialized, whatever the load-time snapshot said.
        for slot in phase.slots where rowCounts[slot]! > 1 {
            let depth = (slot == .a ? result.a : result.b)?.schedulerMaxObservedBatchDepth ?? 0
            guard depth >= 2 else {
                throw MultiModelCheckFailure(reason: "engine_mismatch phase=\(phase.rawValue) model=\(slot.rawValue) rows=\(rowCounts[slot]!) scheduler_max_observed_batch_depth=\(depth)")
            }
        }
        return result
    }

    /// Serves each missing prompt index once per model, that model alone, on
    /// the model's own row count: `rows` lanes take indices from a shared
    /// queue, and a lane with no index left serves filler requests (excluded
    /// from references) while real ones are still decoding, so the batch the
    /// reference decoded in has the same row count as the solo phase.
    private func runReferencePass(_ missing: [MultiModelBenchSlot: [Int]], lanes: MultiModelCheckLanes) async throws -> MultiModelCheckPhaseResult {
        let started = beginPhase(.reference, seconds: 0)
        var records: [MultiModelCheckRequestRecord] = []
        do {
            for slot in MultiModelBenchSlot.allCases {
                guard let indices = missing[slot], !indices.isEmpty else { continue }
                let queue = MultiModelCheckReferenceQueue(indices)
                let count = rows(slot)
                let modelRecords = try await withThrowingTaskGroup(of: [MultiModelCheckRequestRecord].self) { group in
                    for lane in 0..<count {
                        group.addTask {
                            var laneRecords: [MultiModelCheckRequestRecord] = []
                            var sequence = 0
                            while true {
                                let promptIndex: Int
                                let filler: Bool
                                if let next = await queue.take() {
                                    promptIndex = next
                                    filler = false
                                } else if await queue.realInFlight > 0 {
                                    promptIndex = (lane + sequence) % lanes.promptCount
                                    filler = true
                                } else {
                                    break
                                }
                                var record = try await lanes.serve(phase: .reference, slot: slot, lane: lane, sequence: sequence, promptIndex: promptIndex, phaseStart: started)
                                if filler { record.filler = true } else { await queue.finished() }
                                laneRecords.append(record)
                                sequence += 1
                            }
                            return laneRecords
                        }
                    }
                    var all: [MultiModelCheckRequestRecord] = []
                    for try await laneRecords in group { all.append(contentsOf: laneRecords) }
                    return all
                }
                records.append(contentsOf: modelRecords)
            }
        } catch {
            endPhase(.reference, failedWith: error)
            throw error
        }
        lanes.attachOutputs(&records)
        let result = finishPhase(.reference, seconds: 0, records: records, started: started)
        box.update { $0.phases[$0.phases.count - 1] = result }
        box.write()
        MultiModelBenchCommand.log("  reference served=\(records.filter { !$0.filler }.count) filler=\(records.filter(\.filler).count)")
        return result
    }

    /// Serves each (model, prompt index) once, alone, one after another (the
    /// unmeasured warmup).
    private func runSequential(_ phase: MultiModelCheckPhase, _ items: [(MultiModelBenchSlot, Int)], lanes: MultiModelCheckLanes) async throws -> MultiModelCheckPhaseResult {
        let started = beginPhase(phase, seconds: 0)
        var records: [MultiModelCheckRequestRecord] = []
        do {
            for (sequence, item) in items.enumerated() {
                records.append(try await lanes.serve(phase: phase, slot: item.0, lane: 0, sequence: sequence, promptIndex: item.1, phaseStart: started))
            }
        } catch {
            endPhase(phase, failedWith: error)
            throw error
        }
        lanes.attachOutputs(&records)
        let result = finishPhase(phase, seconds: 0, records: records, started: started)
        box.update { $0.phases[$0.phases.count - 1] = result }
        box.write()
        MultiModelBenchCommand.log("  \(phase.rawValue) served=\(records.count)")
        return result
    }

    private func beginPhase(_ phase: MultiModelCheckPhase, seconds: Double) -> UInt64 {
        Memory.peakMemory = 0 // setter resets MLX's peak counter
        gpuTurns.begin()
        memoryBudget.begin()
        monitor.phaseBegan(phase.rawValue)
        box.update { $0.phases.append(MultiModelCheckPhaseResult(phase: phase.rawValue, durationSeconds: seconds)) }
        box.write()
        MultiModelBenchCommand.log("phase start \(phase.rawValue) seconds=\(seconds)")
        return MultiModelCheck.now()
    }

    private func endPhase(_ phase: MultiModelCheckPhase, failedWith error: Error) {
        let footprint = monitor.phaseEnded()
        let peak = Memory.peakMemory
        box.update { report in
            let index = report.phases.count - 1
            report.phases[index].error = String(describing: error)
            report.phases[index].physFootprintMaxBytes = footprint
            report.phases[index].mlxPeakBytes = peak
            report.phases[index].gpuTurns = gpuTurns.finish()
            report.phases[index].memoryBudget = memoryBudget.finish()
        }
        box.write()
        MultiModelBenchCommand.log("phase \(phase.rawValue) failed: \(error)")
    }

    private func finishPhase(_ phase: MultiModelCheckPhase, seconds: Double, records: [MultiModelCheckRequestRecord], started: UInt64) -> MultiModelCheckPhaseResult {
        var result = MultiModelCheckPhaseResult(phase: phase.rawValue, durationSeconds: seconds)
        result.wallSeconds = MultiModelCheck.seconds(MultiModelCheck.now(), since: started)
        result.physFootprintMaxBytes = monitor.phaseEnded()
        result.mlxPeakBytes = Memory.peakMemory
        result.gpuTurns = gpuTurns.finish()
        result.memoryBudget = memoryBudget.finish()
        if let budget = result.memoryBudget {
            MultiModelBenchCommand.log("  \(phase.rawValue) memory_budget limit_bytes=\(budget.limitBytes.map(String.init) ?? "nil") wired_limit_bytes=\(budget.wiredLimitBytes.map(String.init) ?? "nil") cache_limit_bytes=\(budget.cacheLimitBytes) headroom_min_bytes=\(budget.headroomMinBytes.map(String.init) ?? "nil") refusals=\(budget.admissionRefusals) admitted_past_budget=\(budget.rowsAdmittedPastBudget) cache_clears_performed=\(budget.cacheClearsPerformed) cache_clears_skipped=\(budget.cacheClearsSkipped) \(budget.runtimes.map { "\($0.model ?? "unbound"):resident=\($0.residentBytes),committed_kv_peak=\($0.committedKVPeakBytes)" }.joined(separator: " "))")
        }
        if let stats = result.gpuTurns {
            for participant in stats.participants {
                MultiModelBenchCommand.log("  \(phase.rawValue) gpu_turns model=\(participant.model ?? "unbound") participant=\(participant.arbiter.id) turns=\(participant.arbiter.turns) decode_steps=\(participant.arbiter.decodeSteps) prefill_chunks=\(participant.arbiter.prefillChunks) busy_s=\(String(format: "%.3f", participant.arbiter.busySeconds)) wait_s=\(String(format: "%.3f", participant.arbiter.waitSeconds)) max_wait_s=\(String(format: "%.4f", participant.arbiter.maxWaitSeconds))")
            }
        }
        result.requests = records
        result.completed = true
        return result
    }

    // MARK: Gate and goal

    struct GateOutcome {
        var checked = 0
        var mismatches: [MultiModelCheckMismatch] = []
        var outputComparison: [MultiModelCheckOutputComparison] = []
        var reasons: [String] = []
        var line = "GATE pass"
    }

    static func gate(
        checked phases: [MultiModelCheckPhaseResult],
        references: [MultiModelBenchSlot: [Int: MultiModelCheckRequestRecord]],
        report: MultiModelCheckReport
    ) -> GateOutcome {
        var outcome = GateOutcome()
        for slot in MultiModelBenchSlot.allCases {
            let all = (references[slot]!.values.map { $0 }) + phases.flatMap(\.requests).filter { $0.model == slot.rawValue }
            let ids = all.filter { $0.outputTokenIDs != nil }.count
            let kind = ids == all.count ? "token_ids" : (ids == 0 ? "text" : "mixed_token_ids_where_both_captured_else_text")
            outcome.outputComparison.append(MultiModelCheckOutputComparison(model: slot.rawValue, kind: kind))
        }
        for phase in phases {
            for record in phase.requests {
                let slot = MultiModelBenchSlot(rawValue: record.model)!
                guard let reference = references[slot]![record.promptIndex] else {
                    outcome.reasons.append("no_reference phase=\(phase.phase) model=\(record.model) prompt=\(record.promptIndex)")
                    continue
                }
                outcome.checked += 1
                let compared: String
                let position: Int?
                if let left = record.outputTokenIDs, let right = reference.outputTokenIDs {
                    compared = "token_ids"
                    position = left == right ? nil : MultiModelBenchCommand.firstDifference(left, right)
                } else {
                    compared = "text"
                    let left = Array(record.outputText.unicodeScalars)
                    let right = Array(reference.outputText.unicodeScalars)
                    position = left == right ? nil : MultiModelBenchCommand.firstDifference(left, right)
                }
                let countEqual = record.completionTokens == reference.completionTokens
                let finishEqual = record.finishReason == reference.finishReason
                guard position != nil || !countEqual || !finishEqual else { continue }
                let mismatch = MultiModelCheckMismatch(
                    model: record.model,
                    phase: phase.phase,
                    promptIndex: record.promptIndex,
                    requestID: record.requestID,
                    referenceRequestID: reference.requestID,
                    compared: compared,
                    firstDivergingPosition: position,
                    completionTokens: record.completionTokens,
                    referenceCompletionTokens: reference.completionTokens,
                    finishReason: record.finishReason,
                    referenceFinishReason: reference.finishReason
                )
                outcome.mismatches.append(mismatch)
                let kind = position != nil ? "output_mismatch" : (!countEqual ? "token_count_mismatch" : "finish_reason_mismatch")
                outcome.reasons.append("\(kind) phase=\(phase.phase) model=\(record.model) prompt=\(record.promptIndex) compared=\(compared) position=\(position.map(String.init) ?? "-") tokens=\(record.completionTokens)/\(reference.completionTokens) finish=\(record.finishReason)/\(reference.finishReason)")
            }
        }
        let memoryLimit = report.loads.last?.mlxMemoryLimitBytes ?? 0
        for phase in report.phases {
            guard let footprint = phase.physFootprintMaxBytes, memoryLimit > 0, footprint > UInt64(memoryLimit) else { continue }
            outcome.reasons.append("memory_over_limit phase=\(phase.phase) footprint_max_bytes=\(footprint) mlx_memory_limit_bytes=\(memoryLimit)")
        }
        // SPEC-001-R017: the process stays under the one shared limit and no
        // row is admitted past the shared budget.
        for phase in report.phases {
            guard let budget = phase.memoryBudget else { continue }
            if let limit = budget.limitBytes, limit > 0, let footprint = phase.physFootprintMaxBytes, footprint > UInt64(limit) {
                outcome.reasons.append("memory_over_shared_limit phase=\(phase.phase) footprint_max_bytes=\(footprint) shared_limit_bytes=\(limit)")
            }
            if budget.rowsAdmittedPastBudget > 0 {
                outcome.reasons.append("row_admitted_past_shared_budget phase=\(phase.phase) rows=\(budget.rowsAdmittedPastBudget)")
            }
        }
        if let first = outcome.reasons.first {
            let more = outcome.reasons.count > 1 ? " (+\(outcome.reasons.count - 1) more in JSON)" : ""
            outcome.line = "GATE fail reason=\(first)\(more)"
        }
        return outcome
    }

    static func goal(soloA: MultiModelCheckPhaseResult, soloB: MultiModelCheckPhaseResult, contended: MultiModelCheckPhaseResult) throws -> MultiModelCheckGoal {
        guard let soloATPS = soloA.a?.decodeTokensPerSecond, soloATPS > 0 else {
            throw MultiModelCheckFailure(reason: "no_tokens_in_interval phase=solo-a model=a")
        }
        guard let soloBTPS = soloB.b?.decodeTokensPerSecond, soloBTPS > 0 else {
            throw MultiModelCheckFailure(reason: "no_tokens_in_interval phase=solo-b model=b")
        }
        let contendedA = contended.a?.decodeTokensPerSecond ?? 0
        let contendedB = contended.b?.decodeTokensPerSecond ?? 0
        guard let ttftSolo = soloA.a?.ttftMsMedian, let ttftContended = contended.a?.ttftMsMedian else {
            throw MultiModelCheckFailure(reason: "no_main_ttft")
        }
        let share = (contendedA + contendedB) / (soloATPS + soloBTPS)
        let aFrac = contendedA / soloATPS
        let bFrac = contendedB / soloBTPS
        let line = String(
            format: "GOAL share=%.4f a_frac=%.4f b_frac=%.4f main_ttft_ms_solo=%.0f main_ttft_ms_contended=%.0f",
            share, aFrac, bFrac, ttftSolo, ttftContended
        )
        return MultiModelCheckGoal(
            share: share,
            aFrac: aFrac,
            bFrac: bFrac,
            soloADecodeTokensPerSecond: soloATPS,
            soloBDecodeTokensPerSecond: soloBTPS,
            contendedADecodeTokensPerSecond: contendedA,
            contendedBDecodeTokensPerSecond: contendedB,
            mainTtftMsSolo: ttftSolo,
            mainTtftMsContended: ttftContended,
            line: line
        )
    }
}

enum MultiModelCheckPhase: String, Sendable {
    case soloA = "solo-a"
    case soloB = "solo-b"
    case warmup
    case reference
    case contended
    case soak

    var slots: [MultiModelBenchSlot] {
        switch self {
        case .soloA: return [.a]
        case .soloB: return [.b]
        case .warmup, .reference, .contended, .soak: return [.a, .b]
        }
    }
}

// MARK: - Lanes

struct MultiModelCheckLanes: Sendable {
    let runtimes: [MultiModelBenchSlot: ModelRuntime]
    let requests: [MultiModelBenchSlot: [ChatCompletionRequest]]
    let nonce: String
    let capturePath: String
    let monitor: MultiModelBenchMonitor
    let box: MultiModelCheckReportBox

    var promptCount: Int { requests[.a]!.count }

    func runLane(phase: MultiModelCheckPhase, slot: MultiModelBenchSlot, lane: Int, offset: Int, phaseStart: UInt64, deadline: UInt64) async throws -> [MultiModelCheckRequestRecord] {
        var records: [MultiModelCheckRequestRecord] = []
        var sequence = 0
        while MultiModelCheck.now() < deadline {
            let promptIndex = (offset + sequence) % promptCount
            records.append(try await serve(phase: phase, slot: slot, lane: lane, sequence: sequence, promptIndex: promptIndex, phaseStart: phaseStart))
            sequence += 1
        }
        return records
    }

    func serve(phase: MultiModelCheckPhase, slot: MultiModelBenchSlot, lane: Int, sequence: Int, promptIndex: Int, phaseStart: UInt64) async throws -> MultiModelCheckRequestRecord {
        let runtime = runtimes[slot]!
        let request = requests[slot]![promptIndex].withRequestID("mmc-\(nonce)-\(phase.rawValue)-\(slot.rawValue)-l\(lane)-r\(sequence)")
        let chunks = MultiModelCheckChunkLog()
        let monitor = monitor
        monitor.chunkArrived()
        let started = MultiModelCheck.now()
        let requestKey = request.requestID ?? UUID().uuidString
        box.beginRequest(requestKey, MultiModelCheckInFlight(
            model: slot.rawValue, phase: phase.rawValue, lane: lane, promptIndex: promptIndex,
            requestID: request.requestID, phaseStart: phaseStart, started: started, chunks: chunks
        ))
        defer { box.endRequest(requestKey) }
        let handle = try await runtime.acquireRequestHandle(request)
        let completion: CompletionResult
        do {
            try await runtime.preflight(request, with: handle)
            completion = try await runtime.stream(request, with: handle) { _ in
                chunks.record()
                monitor.chunkArrived()
            }
            await runtime.unregisterInFlight(handle.registrationID)
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        let arrivals = chunks.snapshot().map { MultiModelCheck.seconds($0, since: phaseStart) }
        let startSeconds = MultiModelCheck.seconds(started, since: phaseStart)
        return MultiModelCheckRequestRecord(
            model: slot.rawValue,
            lane: lane,
            promptIndex: promptIndex,
            requestID: request.requestID,
            startSeconds: startSeconds,
            endSeconds: MultiModelCheck.seconds(MultiModelCheck.now(), since: phaseStart),
            chunkOffsetsSeconds: arrivals,
            promptTokens: completion.promptTokens,
            completionTokens: completion.completionTokens,
            finishReason: completion.finishReason,
            ttftMilliseconds: arrivals.first.map { ($0 - startSeconds) * 1000 },
            outputKind: "text",
            outputSha256: "",
            outputTokenIDs: nil,
            outputText: (completion.reasoningContent ?? "") + "\u{1}" + completion.content
        )
    }

    /// Reads the token-capture file once per phase, after it ends, so the
    /// lookup never runs on the measured path; text hash otherwise, as in the
    /// default phases.
    func attachOutputs(_ records: inout [MultiModelCheckRequestRecord]) {
        var captured: [String: [Int]] = [:]
        if let data = FileManager.default.contents(atPath: capturePath) {
            for line in data.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let requestID = object["request_id"] as? String,
                      let ids = object["output_token_ids"] as? [Int]
                else { continue }
                captured[requestID] = ids
            }
        }
        for index in records.indices {
            let ids = records[index].requestID.flatMap { captured[$0] }
            let hashInput = ids.map { $0.map(String.init).joined(separator: ",") } ?? records[index].outputText
            records[index].outputTokenIDs = ids
            records[index].outputKind = ids == nil ? "text" : "token_ids"
            records[index].outputSha256 = SHA256.hash(data: Data(hashInput.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Prompt indices still to serve in a reference pre-pass, and how many
/// real (non-filler) requests are still decoding.
actor MultiModelCheckReferenceQueue {
    private var pending: [Int]
    private(set) var realInFlight = 0

    init(_ indices: [Int]) {
        pending = indices
    }

    func take() -> Int? {
        guard !pending.isEmpty else { return nil }
        realInFlight += 1
        return pending.removeFirst()
    }

    func finished() {
        realInFlight -= 1
    }
}

/// Monotonic chunk arrival times for one request.
final class MultiModelCheckChunkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals: [UInt64] = []

    func record() {
        let now = MultiModelCheck.now()
        lock.lock()
        arrivals.append(now)
        lock.unlock()
    }

    func snapshot() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return arrivals
    }
}

enum MultiModelCheckIntervals {
    /// Merged, sorted union of closed intervals.
    static func union(_ spans: [(Double, Double)]) -> [(Double, Double)] {
        var merged: [(Double, Double)] = []
        for span in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Intersection of two merged, sorted interval lists.
    static func intersect(_ lhs: [(Double, Double)], _ rhs: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            let low = max(lhs[i].0, rhs[j].0)
            let high = min(lhs[i].1, rhs[j].1)
            if low < high { result.append((low, high)) }
            if lhs[i].1 < rhs[j].1 { i += 1 } else { j += 1 }
        }
        return result
    }

    static func contains(_ segments: [(Double, Double)], _ time: Double) -> Bool {
        segments.contains { time >= $0.0 && time <= $0.1 }
    }
}

// MARK: - Report box

/// The check report, readable from the watchdog thread on a hang.
final class MultiModelCheckReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: MultiModelCheckReport
    private let outPath: String?
    private var inFlight: [String: MultiModelCheckInFlight] = [:]

    init(report: MultiModelCheckReport, outPath: String?) {
        self.report = report
        self.outPath = outPath
    }

    func update(_ body: (inout MultiModelCheckReport) -> Void) {
        lock.lock()
        body(&report)
        lock.unlock()
    }

    func beginRequest(_ key: String, _ request: MultiModelCheckInFlight) {
        lock.lock()
        inFlight[key] = request
        lock.unlock()
    }

    func endRequest(_ key: String) {
        lock.lock()
        inFlight[key] = nil
        lock.unlock()
    }

    func snapshot() -> MultiModelCheckReport {
        lock.lock()
        defer { lock.unlock() }
        return report
    }

    func write() {
        guard let outPath, let data = try? Self.encode(snapshot()) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        } catch {
            MultiModelBenchCommand.log("cannot write \(outPath): \(error)")
        }
    }

    /// Runs on the watchdog thread; the monitor exits 3 after it returns.
    func hang(phase: String, secondsSinceLastChunk: Double, footprintMax: UInt64) {
        let line = "GATE fail reason=hang phase=\(phase) seconds_since_last_chunk=\(Int(secondsSinceLastChunk))"
        let now = MultiModelCheck.now()
        update { report in
            report.hang = MultiModelBenchHang(phase: phase, secondsSinceLastChunk: secondsSinceLastChunk)
            report.inFlightAtHang = inFlight.values
                .sorted { ($0.model, $0.lane) < ($1.model, $1.lane) }
                .map { $0.state(now: now) }
            if let index = report.phases.lastIndex(where: { $0.phase == phase }) {
                report.phases[index].physFootprintMaxBytes = footprintMax
            }
            report.gate = MultiModelCheckGate(pass: false, reasons: [String(line.dropFirst("GATE fail reason=".count))], line: line)
        }
        write()
        MultiModelCheck.emit(line)
    }

    static func encode(_ report: MultiModelCheckReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(report)
    }
}

// MARK: - Report schema

struct MultiModelCheckReport: Encodable, Sendable {
    let schema: String
    let generatedAtUnixSeconds: Double
    let host: MultiModelBenchHost
    let binaryVersion: String
    let config: MultiModelCheckConfig
    let processEnvironment: MultiModelBenchProcessEnvironment
    var loads: [MultiModelBenchLoad] = []
    /// SPEC-001-R017: the shared budget's load decision before each load.
    var loadDecisions: [MultiModelCheckLoadDecision] = []
    var runtimes: [MultiModelCheckRuntimeState] = []
    /// Canonical snapshot-manifest hash passed as the verified artifact identity.
    var modelArtifactSha256: [String: String] = [:]
    var phases: [MultiModelCheckPhaseResult] = []
    var references: [MultiModelCheckReference] = []
    var outputComparison: [MultiModelCheckOutputComparison] = []
    var parityChecked = 0
    var parityMismatches: [MultiModelCheckMismatch] = []
    var gate: MultiModelCheckGate?
    var goal: MultiModelCheckGoal?
    var hang: MultiModelBenchHang?
    /// Requests in flight when the watchdog fired.
    var inFlightAtHang: [MultiModelCheckInFlightState] = []
    var error: String?
    var complete = false
}

struct MultiModelCheckInFlight: Sendable {
    let model: String
    let phase: String
    let lane: Int
    let promptIndex: Int
    let requestID: String?
    let phaseStart: UInt64
    let started: UInt64
    let chunks: MultiModelCheckChunkLog

    func state(now: UInt64) -> MultiModelCheckInFlightState {
        let arrivals = chunks.snapshot()
        return MultiModelCheckInFlightState(
            model: model,
            phase: phase,
            lane: lane,
            promptIndex: promptIndex,
            requestID: requestID,
            startSeconds: MultiModelCheck.seconds(started, since: phaseStart),
            chunksReceived: arrivals.count,
            secondsSinceStart: MultiModelCheck.seconds(now, since: started),
            secondsSinceLastChunk: arrivals.last.map { MultiModelCheck.seconds(now, since: $0) }
        )
    }
}

struct MultiModelCheckInFlightState: Encodable, Sendable {
    let model: String
    let phase: String
    let lane: Int
    let promptIndex: Int
    let requestID: String?
    let startSeconds: Double
    let chunksReceived: Int
    let secondsSinceStart: Double
    let secondsSinceLastChunk: Double?
}

/// The serve tunables both runtimes are built with. Without `--config`:
/// serve's defaults. With it: the file resolved by serve's own
/// `ConfigLoader` (YAML, then environment), applied as serve applies it.
/// `continuous_batching_accepted_tuples` is not read: serve ignores manual
/// tuples outside `--no-join` (MacProviderCLI.swift, `continuous_batching_
/// manual_tuple action=ignored`); under default-on coverage CB admission is
/// the on-device self-check's decision, and accepted tuples only carry the
/// signed AC-26 cached-turn grant.
struct MultiModelCheckServeSettings: Sendable {
    var configPath: String?
    var pagedKV = PagedKVConfig(enabled: true)
    var maxContextOverride: Int?
    var kvBitsOverride: Int?
    var mlxCacheLimitMB: Int?
    var prefillStepSize = 512
    var prefillStepSizeExplicitlyConfigured = false
    var continuousBatchQueueLimit: Int?
    var continuousBatchQueueWaitTimeoutMS: Int?
    var continuousBatchPrefillTokensPerIteration: Int?
    var continuousBatchingCachedTurns = true
    var nativeMTPMode: NativeMTPMode = .off

    static func resolve(configPath: String?) throws -> MultiModelCheckServeSettings {
        var settings = MultiModelCheckServeSettings()
        if let configPath {
            let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: configPath), resolveCredentials: false)
            settings.configPath = resolved.configPath
            settings.pagedKV = resolved.pagedKV
            // As serve: paged KV attaches by default unless paged_kv.enabled
            // is set explicitly (SPEC-039 FR-PKV14).
            if !resolved.pagedKVEnabledExplicitlyConfigured, resolved.pagedKV.errors.isEmpty {
                settings.pagedKV.enabled = true
            }
            settings.maxContextOverride = resolved.maxContextOverride
            settings.kvBitsOverride = resolved.kvBitsOverride
            settings.mlxCacheLimitMB = resolved.mlxCacheLimitMB
            settings.prefillStepSize = resolved.prefillStepSize
            settings.prefillStepSizeExplicitlyConfigured = resolved.prefillStepSizeExplicitlyConfigured
            settings.continuousBatchQueueLimit = resolved.continuousBatchQueueLimit
            settings.continuousBatchQueueWaitTimeoutMS = resolved.continuousBatchQueueWaitTimeoutMS
            settings.continuousBatchPrefillTokensPerIteration = resolved.continuousBatchPrefillTokensPerIteration
            settings.continuousBatchingCachedTurns = resolved.continuousBatchingCachedTurns
            settings.nativeMTPMode = resolved.nativeMTPMode
        }
        MultiModelBenchCommand.log("serve_settings config=\(settings.configPath ?? "nil") paged_kv_enabled=\(settings.pagedKV.enabled) paged_kv_errors=\(settings.pagedKV.errors.count) block_size=\(settings.pagedKV.blockSizeTokens) max_physical_blocks=\(settings.pagedKV.maxPhysicalBlocks) max_context=\(settings.maxContextOverride.map(String.init) ?? "nil") kv_bits=\(settings.kvBitsOverride.map(String.init) ?? "nil") mlx_cache_limit_mb=\(settings.mlxCacheLimitMB.map(String.init) ?? "nil") prefill_step=\(settings.prefillStepSize) queue_limit=\(settings.continuousBatchQueueLimit.map(String.init) ?? "nil") cached_turns=\(settings.continuousBatchingCachedTurns) native_mtp_mode=\(settings.nativeMTPMode.rawValue)")
        return settings
    }
}

struct MultiModelCheckConfig: Encodable, Sendable {
    /// Load path (or id) per model.
    let modelA: String
    let modelB: String
    /// Serving identity bound into the runtime and sent as `request.model`,
    /// as serve binds the catalog id (`--model-id-x`, default the load value).
    let modelIDA: String
    let modelIDB: String
    let rowsA: Int
    let rowsB: Int
    /// Explicitly configured continuous-batching mode per model (`--cb-x`).
    let continuousBatchingA: String
    let continuousBatchingB: String
    let maxTokensA: Int
    let maxTokensB: Int
    let promptTokensTarget: Int
    let promptsPerModel: Int
    let phaseSeconds: Double
    let soakSeconds: Double
    let rampSeconds: Double
    let watchdogSeconds: Double
    let loadOrder: [String]
    let temperature: Double
    let topP: Double
    let stream: Bool
    let tokenCapturePath: String
    /// SPEC-001-R018: the GPU turn policy both runtimes ran under.
    let gpuTurnPolicy: MultiModelCheckGPUTurnPolicy
}

struct MultiModelCheckGPUTurnPolicy: Encodable, Sendable {
    let name: String
    let parameters: [String: String]
    /// `flag`, `env` or `default`.
    let source: String
}

/// One phase's arbiter statistics: counters accumulated during the phase and
/// the longest single wait inside it, per participant, labelled by slot.
struct MultiModelCheckGPUTurnStats: Encodable, Sendable {
    let policy: String
    let policyParameters: [String: String]
    let participants: [MultiModelCheckGPUTurnParticipant]
}

struct MultiModelCheckGPUTurnParticipant: Encodable, Sendable {
    /// `a` or `b`; nil for a participant that is not one of the two runtimes.
    let model: String?
    let arbiter: GPUTurnParticipantSnapshot
}

final class MultiModelCheckGPUTurnWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Int: MultiModelBenchSlot] = [:]
    private var baseline: GPUTurnArbiterSnapshot?

    func bind(slot: MultiModelBenchSlot, participantID: Int) {
        lock.lock(); defer { lock.unlock() }
        slots[participantID] = slot
    }

    func begin() {
        let snapshot = GPUTurnArbiter.shared.snapshot(resettingMaxWait: true)
        lock.lock(); defer { lock.unlock() }
        baseline = snapshot
    }

    func finish() -> MultiModelCheckGPUTurnStats? {
        let current = GPUTurnArbiter.shared.snapshot(resettingMaxWait: true)
        lock.lock(); defer { lock.unlock() }
        guard let baseline else { return nil }
        self.baseline = nil
        let delta = current.delta(since: baseline)
        return MultiModelCheckGPUTurnStats(
            policy: delta.policy,
            policyParameters: delta.policyParameters,
            participants: delta.participants.map {
                MultiModelCheckGPUTurnParticipant(model: slots[$0.id]?.rawValue, arbiter: $0)
            }
        )
    }
}

struct MultiModelCheckLoadDecision: Encodable, Sendable {
    let model: String
    let decision: SharedModelMemoryRules.LoadDecision
}

struct MultiModelCheckMemoryBudgetRuntime: Encodable, Sendable {
    /// `a` or `b`; nil for a member that is not one of the two runtimes.
    let model: String?
    let memberID: Int
    let residentBytes: Int
    let kvBytesPerToken: Int
    /// Highest worst-case KV committed to this runtime's admitted rows.
    let committedKVPeakBytes: Int
    let rowsAdmitted: Int
    let rowsRefused: Int
    let rowsAdmittedPastBudget: Int
}

/// One phase of the shared budget: the limits at phase end, counters
/// accumulated during the phase, and the lowest headroom (limit less every
/// runtime's weights, peak committed row KV and margin).
struct MultiModelCheckMemoryBudgetStats: Encodable, Sendable {
    let limitBytes: Int?
    let wiredLimitBytes: Int?
    let cacheLimitBytes: Int
    let headroomMinBytes: Int?
    let admissionRefusals: Int
    let rowsAdmittedPastBudget: Int
    let cacheClearsPerformed: Int
    let cacheClearsSkipped: Int
    let commandBufferBudgetSetBy: String?
    let commandBufferBudgetMb: Int?
    let commandBufferConflicts: [String]
    let runtimes: [MultiModelCheckMemoryBudgetRuntime]
}

final class MultiModelCheckMemoryBudgetWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Int: MultiModelBenchSlot] = [:]
    private var baseline: SharedModelMemoryBudget.Snapshot?

    func bind(slot: MultiModelBenchSlot, memberID: Int) {
        lock.lock(); defer { lock.unlock() }
        slots[memberID] = slot
    }

    func begin() {
        SharedModelMemoryBudget.shared.resetPeaks()
        let snapshot = SharedModelMemoryBudget.shared.snapshot()
        lock.lock(); defer { lock.unlock() }
        baseline = snapshot
    }

    func finish() -> MultiModelCheckMemoryBudgetStats? {
        let end = SharedModelMemoryBudget.shared.snapshot()
        lock.lock(); defer { lock.unlock() }
        guard let start = baseline else { return nil }
        baseline = nil
        let before = Dictionary(uniqueKeysWithValues: start.members.map { ($0.memberID, $0) })
        let runtimes = end.members.map { member in
            let earlier = before[member.memberID]
            return MultiModelCheckMemoryBudgetRuntime(
                model: slots[member.memberID]?.rawValue,
                memberID: member.memberID,
                residentBytes: member.residentBytes,
                kvBytesPerToken: member.kvBytesPerToken,
                committedKVPeakBytes: member.peakCommittedKVBytes,
                rowsAdmitted: member.rowsAdmitted - (earlier?.rowsAdmitted ?? 0),
                rowsRefused: member.rowsRefused - (earlier?.rowsRefused ?? 0),
                rowsAdmittedPastBudget: member.rowsAdmittedPastBudget - (earlier?.rowsAdmittedPastBudget ?? 0)
            )
        }
        return MultiModelCheckMemoryBudgetStats(
            limitBytes: end.limitBytes,
            wiredLimitBytes: end.wiredLimitBytes,
            cacheLimitBytes: end.cacheLimitBytes,
            headroomMinBytes: end.limitBytes.map { $0 - end.peakChargedBytes },
            admissionRefusals: runtimes.reduce(0) { $0 + $1.rowsRefused },
            rowsAdmittedPastBudget: runtimes.reduce(0) { $0 + $1.rowsAdmittedPastBudget },
            cacheClearsPerformed: end.cacheClearsPerformed - start.cacheClearsPerformed,
            cacheClearsSkipped: end.cacheClearsSkipped - start.cacheClearsSkipped,
            commandBufferBudgetSetBy: end.commandBufferBudgetSetBy,
            commandBufferBudgetMb: end.commandBufferBudgetMb,
            commandBufferConflicts: end.commandBufferConflicts,
            runtimes: runtimes
        )
    }
}

/// What the runtime actually does with concurrent requests, as reported by
/// its own snapshot after the serve-shaped construction in `load`.
struct MultiModelCheckRuntimeState: Encodable, Sendable {
    let model: String
    let constructedWith: String
    /// `continuous_batching` when the CB scheduler is active, else
    /// `serial_inference_gate` (lanes queue on the runtime's inference gate).
    let engine: String
    let servedSlots: Int
    let continuousBatchingMode: String?
    let continuousBatchingActive: Bool
    let continuousBatchingUnsupportedReason: String?
    let pagedKvDecision: String?
    let continuousBatchingPolicyLoadStatus: String?
    let continuousBatchingPolicyAuthorized: Bool?
    let continuousBatchingPolicyDecisionReason: String?
    let nativeMTPSupported: Bool
    let nativeMTPEnabled: Bool
    let nativeMTPModeAtLoad: String
    let nativeMTPReasonAtLoad: String
    var nativeMTPModeAtEnd: String?
    var nativeMTPForwardsAtEnd: UInt64?
    /// True only when the runtime ran MTP forwards during the check.
    var nativeMTPActive: Bool?
    var continuousBatchingActiveAtEnd: Bool?
    var schedulerMaxObservedBatchDepthAtEnd: Int?
    var schedulerSharedForwardCallsAtEnd: Int?
    /// Serve's CB self-check run at load; nil when CB is off or uncheckable.
    let selfCheck: MultiModelCheckSelfCheck?

    init(slot: MultiModelBenchSlot, requestedMode: ContinuousBatchingMode, rows: Int, snapshot: RuntimeSnapshot, servedSlots: Int, selfCheck: MultiModelCheckSelfCheck?) {
        self.selfCheck = selfCheck
        let cb = snapshot.continuousBatching
        model = slot.rawValue
        constructedWith = "serve shape: paged_kv=on (family defaults) max_batch=\(rows) continuous_batching_mode=\(requestedMode.rawValue) explicitly_configured=true cached_turns=true verified_artifact_sha256=canonical snapshot-manifest hash, default-on CB coverage decided by serve's self-check driver, native_mtp_mode=off (no signed admission sidecar), no signed CB policy"
        engine = cb?.active == true ? "continuous_batching" : "serial_inference_gate"
        self.servedSlots = servedSlots
        continuousBatchingMode = cb?.mode.rawValue
        continuousBatchingActive = cb?.active ?? false
        continuousBatchingUnsupportedReason = cb?.unsupportedReason
        pagedKvDecision = cb?.pagedKVDecision
        continuousBatchingPolicyLoadStatus = cb?.policy.loadStatus
        continuousBatchingPolicyAuthorized = cb?.policy.authorized
        continuousBatchingPolicyDecisionReason = cb?.policy.decisionReason
        nativeMTPSupported = snapshot.nativeMTPStatus.supported
        nativeMTPEnabled = snapshot.nativeMTPStatus.enabled
        nativeMTPModeAtLoad = snapshot.nativeMTPStatus.mode.rawValue
        nativeMTPReasonAtLoad = snapshot.nativeMTPStatus.lastReason.rawValue
    }

    mutating func recordEnd(_ snapshot: RuntimeSnapshot) {
        let status = snapshot.nativeMTPStatus
        continuousBatchingActiveAtEnd = snapshot.continuousBatching?.active
        schedulerMaxObservedBatchDepthAtEnd = snapshot.continuousBatching?.scheduler?.maxObservedBatchDepth
        schedulerSharedForwardCallsAtEnd = snapshot.continuousBatching?.scheduler?.sharedForwardCalls
        nativeMTPModeAtEnd = status.mode.rawValue
        nativeMTPForwardsAtEnd = status.mtpForwards
        nativeMTPActive = status.mtpForwards > 0
    }
}

struct MultiModelCheckSelfCheck: Encodable, Sendable {
    let outcome: String
    let seconds: Double
    let storePath: String
}

struct MultiModelCheckRequestRecord: Encodable, Sendable {
    let model: String
    let lane: Int
    let promptIndex: Int
    let requestID: String?
    /// Seconds since the phase start (monotonic clock).
    let startSeconds: Double
    let endSeconds: Double
    let chunkOffsetsSeconds: [Double]
    let promptTokens: Int
    let completionTokens: Int
    let finishReason: String
    let ttftMilliseconds: Double?
    var outputKind: String
    var outputSha256: String
    var outputTokenIDs: [Int]?
    var outputText: String
    /// Reference pre-pass only: served to keep the row count, not a reference.
    var filler = false

    enum CodingKeys: String, CodingKey {
        case model, lane, promptIndex, requestID, startSeconds, endSeconds, chunkOffsetsSeconds
        case promptTokens, completionTokens, finishReason, ttftMilliseconds, outputKind, outputSha256, filler
    }

    /// Submission to completion: the time this request is in flight.
    var inFlightSpan: (Double, Double) { (startSeconds, endSeconds) }

    /// Arrival time of each completion token: chunk `j * chunks / tokens`.
    var tokenArrivals: [Double] {
        let chunks = chunkOffsetsSeconds.count
        guard chunks > 0, completionTokens > 0 else { return [] }
        return (0..<completionTokens).map { chunkOffsetsSeconds[min(chunks - 1, $0 * chunks / completionTokens)] }
    }
}

struct MultiModelCheckModelPhaseStats: Encodable, Sendable {
    let rows: Int
    let requestsCompleted: Int
    let tokensInInterval: Int
    /// tokens_in_interval ÷ measurement_interval_seconds.
    let decodeTokensPerSecond: Double?
    let ttftMsMedian: Double?
    let ttftMsP95: Double?
    /// `exact` when every request's chunk count equals its completion tokens.
    let tokenChunkMapping: String
    /// Cumulative CB scheduler counters at phase end (nil when no scheduler).
    var schedulerMaxObservedBatchDepth: Int?
    var schedulerSharedForwardCalls: Int?

    init(rows: Int, records: [MultiModelCheckRequestRecord], segments: [(Double, Double)], intervalSeconds: Double) {
        self.rows = rows
        requestsCompleted = records.count
        tokensInInterval = records.reduce(0) { total, record in
            total + record.tokenArrivals.filter { MultiModelCheckIntervals.contains(segments, $0) }.count
        }
        decodeTokensPerSecond = intervalSeconds > 0 ? Double(tokensInInterval) / intervalSeconds : nil
        let ttfts = records.compactMap(\.ttftMilliseconds).sorted()
        ttftMsMedian = MultiModelBenchModelStats.median(ttfts)
        ttftMsP95 = ttfts.isEmpty ? nil : ttfts[max(0, Int((0.95 * Double(ttfts.count)).rounded(.up)) - 1)]
        tokenChunkMapping = records.allSatisfy { $0.chunkOffsetsSeconds.count == $0.completionTokens } ? "exact" : "proportional"
    }
}

struct MultiModelCheckPhaseResult: Encodable, Sendable {
    let phase: String
    let durationSeconds: Double
    var wallSeconds: Double?
    var completed = false
    var mlxPeakBytes: Int?
    var physFootprintMaxBytes: UInt64?
    var measurementIntervalSeconds: Double?
    var measurementSegments: [[Double]] = []
    /// Contended/soak: share of the interval with a request of each model in flight.
    var overlapFraction: Double?
    /// SPEC-001-R018: GPU turn arbiter statistics for this phase.
    var gpuTurns: MultiModelCheckGPUTurnStats?
    /// SPEC-001-R017: the shared memory budget over this phase.
    var memoryBudget: MultiModelCheckMemoryBudgetStats?
    var a: MultiModelCheckModelPhaseStats?
    var b: MultiModelCheckModelPhaseStats?
    var requests: [MultiModelCheckRequestRecord] = []
    var error: String?

    init(phase: String, durationSeconds: Double) {
        self.phase = phase
        self.durationSeconds = durationSeconds
    }
}

struct MultiModelCheckReference: Encodable, Sendable {
    let model: String
    let promptIndex: Int
    let requestID: String?
    let completionTokens: Int
    let finishReason: String
    let outputKind: String
    let outputSha256: String
    let outputTokenIDs: [Int]?

    init(slot: MultiModelBenchSlot, record: MultiModelCheckRequestRecord) {
        model = slot.rawValue
        promptIndex = record.promptIndex
        requestID = record.requestID
        completionTokens = record.completionTokens
        finishReason = record.finishReason
        outputKind = record.outputKind
        outputSha256 = record.outputSha256
        outputTokenIDs = record.outputTokenIDs
    }
}

struct MultiModelCheckOutputComparison: Encodable, Sendable {
    let model: String
    /// `token_ids` (lab token capture) or `text` (completion text fallback).
    let kind: String
}

struct MultiModelCheckMismatch: Encodable, Sendable {
    let model: String
    let phase: String
    let promptIndex: Int
    let requestID: String?
    let referenceRequestID: String?
    let compared: String
    let firstDivergingPosition: Int?
    let completionTokens: Int
    let referenceCompletionTokens: Int
    let finishReason: String
    let referenceFinishReason: String
}

struct MultiModelCheckGate: Encodable, Sendable {
    let pass: Bool
    let reasons: [String]
    let line: String
}

struct MultiModelCheckGoal: Encodable, Sendable {
    let share: Double
    let aFrac: Double
    let bFrac: Double
    let soloADecodeTokensPerSecond: Double
    let soloBDecodeTokensPerSecond: Double
    let contendedADecodeTokensPerSecond: Double
    let contendedBDecodeTokensPerSecond: Double
    let mainTtftMsSolo: Double
    let mainTtftMsContended: Double
    let line: String
}
#endif
