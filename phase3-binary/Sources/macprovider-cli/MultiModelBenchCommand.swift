#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MLX
import MacProviderCore

/// `multi-model-bench` — lab measurement for issue #2338: two `ModelRuntime`
/// instances resident in one process, decoding alone and at the same time.
///
/// Both runtimes load once, in `--load-order`, and stay resident for the whole
/// run, so the solo phases already pay for both sets of weights. Phases:
///   * `solo-a` / `solo-b`: one request on one runtime, the other idle.
///   * `concurrent-shared`: one request on each runtime at once, both on the
///     process default MLX stream.
///   * `concurrent-streams`: the same, each child task inside
///     `Stream.withNewDefaultStream`, so each runtime encodes on its own GPU
///     stream (own Metal command queue). This can hang the GPU, so the default
///     phase list runs it last.
///
/// The harness does not hide the process-global MLX state the two runtimes
/// share (cache limit, wired limit, `MLX_MAX_MB_PER_BUFFER`, `clearCache`);
/// it records what it observed after each load.
///
/// A plain `Thread` watchdog (not a Swift task, so it survives a blocked
/// cooperative pool) samples phys_footprint every 250 ms and, when no chunk
/// arrived for `--watchdog-seconds` during a phase, writes the partial report
/// with a `hang` object to `--out` and stderr, then exits 3.
///
/// Output identity: in a `MACPROVIDER_LAB_HARNESS` build the runtime records
/// the generated token ids through `LabOutputTokenCapture`; the harness points
/// `MACPROVIDER_LAB_TOKEN_CAPTURE` at a private file (unless already set) and
/// hashes those ids. Otherwise it hashes the completion text.
struct MultiModelBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "multi-model-bench",
        abstract: "Lab: hold two model runtimes in one process and measure decode alone and concurrently (#2338).",
        shouldDisplay: false
    )

    @Option(name: .customLong("model-a"), help: "Model A: local snapshot directory or model id.")
    var modelA: String

    @Option(name: .customLong("model-b"), help: "Model B: local snapshot directory or model id.")
    var modelB: String

    @Option(name: .customLong("max-tokens"), help: "max_tokens per request. Default 256.")
    var maxTokens: Int = 256

    @Option(name: .customLong("prompt-tokens"), help: "Approximate prompt length in tokens (about 4 characters per token). Default 1024.")
    var promptTokens: Int = 1024

    @Option(help: "Runs per phase; the first run of each phase is reported as warmup. Default 3.")
    var runs: Int = 3

    @Option(help: "Comma-separated phases, run in this order: solo-a,solo-b,concurrent-shared,concurrent-streams.")
    var phases: String = MultiModelBenchPhase.allCases.map(\.rawValue).joined(separator: ",")

    @Option(name: .customLong("load-order"), help: "Load order: a,b or b,a. Default a,b.")
    var loadOrder: String = "a,b"

    @Option(name: .customLong("watchdog-seconds"), help: "Seconds without a chunk during a phase before the run is declared hung (exit 3). With --check, per model: each model with a request in flight must produce a chunk within this time. Default 120.")
    var watchdogSeconds: Double = 120

    @Option(help: "JSON output path. Partial results are written here after every phase and on a hang.")
    var out: String?

    @Flag(help: """
        Swarm check mode (#2338): fixed-duration solo-a, solo-b, then per GPU turn policy a contended and optional soak phase; \
        prints POLICY, SOAK, GATE and GOAL lines. GOAL share = sum of contended decode tok/s over sum of solo decode tok/s \
        (decode tokens only). GOAL work_share credits prefill too: for each model, solo-equivalent seconds = \
        decode_tokens/solo_decode_rate + prefill_tokens/solo_prefill_rate, where in the solo phase prefill time is the \
        part of the interval with a prompt prefilling (request start to first chunk), decode time the rest, \
        solo_prefill_rate = solo prefilled prompt tokens / prefill time and solo_decode_rate = solo decode tokens / decode time \
        (so a solo phase scores exactly 1.0 against itself). work_share = (solo-equivalent seconds of A + of B) / interval \
        seconds: 1.0 means no loss from sharing one GPU, 2.0 perfect parallelism. See MultiModelBenchCheck.swift.
        """)
    var check = false

    @Option(name: .customLong("rows-a"), help: "--check: concurrent lanes on model A. Default 1.")
    var rowsA: Int = 1

    @Option(name: .customLong("rows-b"), help: "--check: concurrent lanes on model B. Default 4.")
    var rowsB: Int = 4

    @Flag(name: .customLong("rows-exact"), help: "--check: require each model to serve its requested rows (--rows-a/--rows-b) on the continuous-batching engine, else CHECK error engine_mismatch. Without it the check drives the rows serve's CB self-check granted and records requested_rows, granted_rows and the self-check reason.")
    var rowsExact = false

    @Option(name: .customLong("max-tokens-a"), help: "--check: max_tokens per model A request. Default 1024.")
    var maxTokensA: Int = 1024

    @Option(name: .customLong("max-tokens-b"), help: "--check: max_tokens per model B request. Default 256.")
    var maxTokensB: Int = 256

    @Option(name: .customLong("phase-seconds"), help: "--check: duration of solo-a, solo-b and contended. Must exceed the 10 s ramp and be at least 120 unless --allow-short-phases (60 s phases read about 7% high and cannot complete a 1024-token main request). Default 120.")
    var phaseSeconds: Double = 120

    @Flag(name: .customLong("allow-short-phases"), help: "--check: accept --phase-seconds below 120 (smoke runs only; the numbers are not comparable).")
    var allowShortPhases = false

    @Option(name: .customLong("soak-seconds"), help: "--check: contended soak after each policy's contended phase, printed as a SOAK line; when it runs, GOAL uses the soak numbers. 0 skips it. Default 0.")
    var soakSeconds: Double = 0

    @Option(name: .customLong("prompt-tokens-a"), help: "--check: approximate prompt length for model A. Default --prompt-tokens.")
    var promptTokensA: Int?

    @Option(name: .customLong("prompt-tokens-b"), help: "--check: approximate prompt length for model B. Default --prompt-tokens.")
    var promptTokensB: Int?

    @Option(name: .customLong("cb-a"), help: "--check: continuous-batching mode for model A, explicitly configured as `serve --continuous-batching` does: off, canary or on. Default on.")
    var cbA: String = ContinuousBatchingMode.on.rawValue

    @Option(name: .customLong("cb-b"), help: "--check: continuous-batching mode for model B (off, canary, on). Default on.")
    var cbB: String = ContinuousBatchingMode.on.rawValue

    @Option(name: .customLong("model-id-a"), help: "--check: catalog serving id for model A (e.g. zai-org/glm-5.3-flash), bound as serve binds it; --model-a stays the load path. Default: --model-a.")
    var modelIDA: String?

    @Option(name: .customLong("model-id-b"), help: "--check: catalog serving id for model B (e.g. qwen/qwen3.8-27b). Default: --model-b.")
    var modelIDB: String?

    @Option(name: .customLong("config"), help: "--check: provider config.yaml (a lab copy), resolved by serve's ConfigLoader; its paged_kv, queue, prefill, cache-limit, context, cached-turns and native_mtp_mode settings build both runtimes. CB mode stays --cb-x.")
    var configPath: String?

    @Option(name: .customLong("gpu-turn-policy"), help: "--check: GPU turn policy between the two runtimes, name[:k=v,...] (SPEC-001-R018, #2338). Default: env \(GPUTurnPolicyRegistry.labEnvironmentKey), else the compiled-in default (alternate:drain=never). Recorded in the check JSON.")
    var gpuTurnPolicy: String?

    @Option(name: .customLong("gpu-turn-policies"), help: "--check: several GPU turn policies measured in one load, name[:k=v,...] separated by ';'. Load, warmup, solo and reference phases run once under passthrough; then each policy runs one contended phase and, with --soak-seconds, its own soak. Prints one POLICY (and SOAK) line per policy; the final GATE line fails if any policy failed and GOAL is the first policy's.")
    var gpuTurnPolicies: String?

    /// `--gpu-turn-policies` split into trimmed, validated specs.
    static func parsePolicyList(_ value: String) throws -> [String] {
        let specs = value.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !specs.isEmpty, !specs.contains(where: \.isEmpty) else {
            throw ValidationError("--gpu-turn-policies must list policies separated by ';' with no empty entry")
        }
        for spec in specs {
            do {
                _ = try GPUTurnPolicyRegistry.make(spec)
            } catch {
                throw ValidationError("--gpu-turn-policies '\(spec)': \(error)")
            }
        }
        return specs
    }

    mutating func validate() throws {
        if let gpuTurnPolicy {
            do {
                _ = try GPUTurnPolicyRegistry.make(gpuTurnPolicy)
            } catch {
                throw ValidationError("--gpu-turn-policy: \(error)")
            }
        }
        if let gpuTurnPolicies {
            guard check else { throw ValidationError("--gpu-turn-policies requires --check") }
            guard gpuTurnPolicy == nil else { throw ValidationError("--gpu-turn-policies and --gpu-turn-policy are exclusive") }
            _ = try Self.parsePolicyList(gpuTurnPolicies)
        }
        if check {
            guard rowsA > 0, rowsB > 0 else { throw ValidationError("--rows-a and --rows-b must be > 0") }
            guard maxTokensA > 0, maxTokensB > 0 else { throw ValidationError("--max-tokens-a and --max-tokens-b must be > 0") }
            guard phaseSeconds > MultiModelCheck.rampSeconds else {
                throw ValidationError("--phase-seconds must exceed the \(Int(MultiModelCheck.rampSeconds)) s ramp")
            }
            guard allowShortPhases || phaseSeconds >= MultiModelCheck.minimumPhaseSeconds else {
                throw ValidationError("--phase-seconds must be at least \(Int(MultiModelCheck.minimumPhaseSeconds)) (pass --allow-short-phases for a smoke run)")
            }
            for (flag, value) in [("--cb-a", cbA), ("--cb-b", cbB)] where ContinuousBatchingMode(rawValue: value) == nil {
                throw ValidationError("\(flag) must be off, canary or on")
            }
            guard soakSeconds == 0 || soakSeconds > MultiModelCheck.rampSeconds else {
                throw ValidationError("--soak-seconds must be 0 or exceed the \(Int(MultiModelCheck.rampSeconds)) s ramp")
            }
        }
        for (flag, value) in [("--prompt-tokens-a", promptTokensA), ("--prompt-tokens-b", promptTokensB)] {
            guard let value else { continue }
            guard check else { throw ValidationError("\(flag) requires --check") }
            guard value > 0 else { throw ValidationError("\(flag) must be > 0") }
        }
        guard maxTokens > 0 else { throw ValidationError("--max-tokens must be > 0") }
        guard promptTokens > 0 else { throw ValidationError("--prompt-tokens must be > 0") }
        guard runs > 0 else { throw ValidationError("--runs must be > 0") }
        guard watchdogSeconds > 0 else { throw ValidationError("--watchdog-seconds must be > 0") }
        _ = try Self.parsePhases(phases)
        _ = try Self.parseLoadOrder(loadOrder)
    }

    static func parsePhases(_ value: String) throws -> [MultiModelBenchPhase] {
        let parsed = try value.split(separator: ",").map { raw -> MultiModelBenchPhase in
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard let phase = MultiModelBenchPhase(rawValue: name) else {
                throw ValidationError("unknown phase '\(name)'; expected one of \(MultiModelBenchPhase.allCases.map(\.rawValue).joined(separator: ","))")
            }
            return phase
        }
        guard !parsed.isEmpty else { throw ValidationError("--phases must name at least one phase") }
        guard Set(parsed).count == parsed.count else { throw ValidationError("--phases must not repeat a phase") }
        return parsed
    }

    static func parseLoadOrder(_ value: String) throws -> [MultiModelBenchSlot] {
        let order = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        switch order {
        case ["a", "b"]: return [.a, .b]
        case ["b", "a"]: return [.b, .a]
        default: throw ValidationError("--load-order must be a,b or b,a")
        }
    }

    mutating func run() async throws {
        if check {
            try await runCheck()
            return
        }
        let phaseList = try Self.parsePhases(phases)
        let order = try Self.parseLoadOrder(loadOrder)
        let ids: [MultiModelBenchSlot: String] = [.a: modelA, .b: modelB]

        // Token-id capture: the runtime appends one record per completion to
        // this file in lab-harness builds. Set before any runtime exists.
        let captureNonce = UUID().uuidString.prefix(8).lowercased()
        let capturePath = Self.prepareTokenCapture(nonce: String(captureNonce))

        // Serve applies the command-buffer budget for its one model before
        // any MLX device use; MLX reads it once. Two runtimes cannot each have
        // their own, so the first-loaded model's family decides it.
        let firstFamily = ModelRuntime.localModelFamily(ids[order[0]]!)
        let appliedBudgetMB = firstFamily.flatMap { ModelRuntime.applyMLXCommandBufferBudget(modelFamily: $0) }

        let promptText = Self.promptText(promptTokens: promptTokens)
        var report = MultiModelBenchReport(
            schema: "macprovider.multi-model-bench.v1",
            generatedAtUnixSeconds: Date().timeIntervalSince1970,
            host: MultiModelBenchHost.current(),
            binaryVersion: CoordinatorClient.binaryVersion,
            config: MultiModelBenchConfig(
                modelA: modelA,
                modelB: modelB,
                maxTokens: maxTokens,
                promptTokensTarget: promptTokens,
                promptCharacters: promptText.count,
                runs: runs,
                phases: phaseList.map(\.rawValue),
                loadOrder: order.map(\.rawValue),
                watchdogSeconds: watchdogSeconds,
                temperature: 0,
                topP: 1,
                stream: true,
                reasoningEffort: nil,
                ignoreEosSupported: false,
                tokenCapturePath: capturePath
            ),
            processEnvironment: MultiModelBenchProcessEnvironment(
                firstLoadedModelFamily: firstFamily,
                commandBufferBudgetAppliedMb: appliedBudgetMB,
                mlxMaxMbPerBuffer: ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
            ),
            loads: [],
            phases: [],
            slowdown: [],
            parity: [],
            hang: nil,
            complete: false
        )

        let monitor = MultiModelBenchMonitor(outPath: out, watchdogSeconds: watchdogSeconds)
        monitor.publish(report, writeFile: true)
        monitor.start()

        var runtimes: [MultiModelBenchSlot: ModelRuntime] = [:]
        for slot in order {
            let modelID = ids[slot]!
            Self.log("load start model=\(slot.rawValue) id=\(modelID)")
            let started = Date()
            let runtime = try await ModelRuntime(modelID: modelID)
            guard await runtime.isLoaded else {
                Self.log("failed to load \(modelID)")
                throw ExitCode(1)
            }
            let seconds = Date().timeIntervalSince(started)
            runtimes[slot] = runtime
            let load = MultiModelBenchLoad(
                model: slot.rawValue,
                modelID: modelID,
                modelFamily: ModelRuntime.localModelFamily(modelID),
                loadSeconds: seconds,
                mlxActiveBytes: Memory.activeMemory,
                mlxPeakBytes: Memory.peakMemory,
                mlxCacheBytes: Memory.cacheMemory,
                mlxCacheLimitBytes: Memory.cacheLimit,
                mlxMemoryLimitBytes: Memory.memoryLimit,
                physFootprintBytes: MultiModelBenchMonitor.physFootprintBytes(),
                mlxMaxMbPerBuffer: ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
            )
            report.loads.append(load)
            monitor.publish(report, writeFile: true)
            Self.log("load done model=\(slot.rawValue) seconds=\(String(format: "%.1f", seconds)) mlx_active_bytes=\(load.mlxActiveBytes) cache_limit=\(load.mlxCacheLimitBytes) memory_limit=\(load.mlxMemoryLimitBytes)")
        }

        let requests: [MultiModelBenchSlot: ChatCompletionRequest] = try [
            .a: Self.request(modelID: modelA, prompt: promptText, maxTokens: maxTokens),
            .b: Self.request(modelID: modelB, prompt: promptText, maxTokens: maxTokens),
        ]

        for phase in phaseList {
            Memory.peakMemory = 0 // setter resets MLX's peak counter
            monitor.phaseBegan(phase.rawValue)
            let phaseStarted = Date()
            report.phases.append(MultiModelBenchPhaseResult(
                phase: phase.rawValue,
                startedAtUnixSeconds: phaseStarted.timeIntervalSince1970,
                endedAtUnixSeconds: nil,
                completed: false,
                mlxPeakBytes: nil,
                physFootprintMaxBytes: nil,
                a: phase.slots.contains(.a) ? MultiModelBenchModelStats() : nil,
                b: phase.slots.contains(.b) ? MultiModelBenchModelStats() : nil,
                error: nil
            ))
            let index = report.phases.count - 1
            monitor.publish(report, writeFile: false)
            Self.log("phase start \(phase.rawValue)")
            do {
                for runIndex in 0..<runs {
                    let samples = try await Self.runOnce(
                        phase: phase,
                        runIndex: runIndex,
                        nonce: String(captureNonce),
                        runtimes: runtimes,
                        requests: requests,
                        capturePath: capturePath,
                        monitor: monitor
                    )
                    for (slot, sample) in samples {
                        report.phases[index].append(sample, slot: slot, isWarmup: runIndex == 0)
                        Self.log("  \(phase.rawValue) run=\(runIndex) model=\(slot.rawValue) tokens=\(sample.completionTokens) decode_tps=\(sample.decodeTokensPerSecond.map { String(format: "%.2f", $0) } ?? "n/a") ttft_ms=\(sample.clientTtftMilliseconds.map { String(format: "%.0f", $0) } ?? "n/a") finish=\(sample.finishReason)")
                    }
                    monitor.publish(report, writeFile: false)
                }
            } catch {
                report.phases[index].error = String(describing: error)
                report.phases[index].endedAtUnixSeconds = Date().timeIntervalSince1970
                report.phases[index].physFootprintMaxBytes = monitor.phaseEnded()
                report.phases[index].mlxPeakBytes = Memory.peakMemory
                monitor.publish(report, writeFile: true)
                Self.log("phase \(phase.rawValue) failed: \(error)")
                throw error
            }
            report.phases[index].endedAtUnixSeconds = Date().timeIntervalSince1970
            report.phases[index].completed = true
            report.phases[index].physFootprintMaxBytes = monitor.phaseEnded()
            report.phases[index].mlxPeakBytes = Memory.peakMemory
            report.phases[index].finalizeMedians()
            monitor.publish(report, writeFile: true)
        }

        report.parity = Self.parity(report.phases)
        report.slowdown = Self.slowdown(report.phases)
        report.complete = true
        monitor.publish(report, writeFile: true)
        monitor.stop()

        let data = try MultiModelBenchMonitor.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        Self.log(Self.table(report))
    }

    // MARK: - One run of a phase

    private static func runOnce(
        phase: MultiModelBenchPhase,
        runIndex: Int,
        nonce: String,
        runtimes: [MultiModelBenchSlot: ModelRuntime],
        requests: [MultiModelBenchSlot: ChatCompletionRequest],
        capturePath: String,
        monitor: MultiModelBenchMonitor
    ) async throws -> [(MultiModelBenchSlot, MultiModelBenchSample)] {
        func job(_ slot: MultiModelBenchSlot) -> MultiModelBenchJob {
            MultiModelBenchJob(
                slot: slot,
                runtime: runtimes[slot]!,
                request: requests[slot]!.withRequestID("mmb-\(nonce)-\(phase.rawValue)-\(slot.rawValue)-\(runIndex)"),
                runIndex: runIndex,
                capturePath: capturePath,
                monitor: monitor
            )
        }
        switch phase {
        case .soloA:
            return [(.a, try await measure(job(.a)))]
        case .soloB:
            return [(.b, try await measure(job(.b)))]
        case .concurrentShared, .concurrentStreams:
            let ownStreams = phase == .concurrentStreams
            let jobs = [job(.a), job(.b)]
            return try await withThrowingTaskGroup(of: (MultiModelBenchSlot, MultiModelBenchSample).self) { group in
                for job in jobs {
                    group.addTask {
                        if ownStreams {
                            return try await MLX.Stream.withNewDefaultStream {
                                (job.slot, try await measure(job))
                            }
                        }
                        return (job.slot, try await measure(job))
                    }
                }
                var results: [(MultiModelBenchSlot, MultiModelBenchSample)] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0.rawValue < $1.0.rawValue }
            }
        }
    }

    private static func measure(_ job: MultiModelBenchJob) async throws -> MultiModelBenchSample {
        let collector = MultiModelBenchChunkCollector()
        let monitor = job.monitor
        monitor.chunkArrived()
        let started = Date()
        let handle = try await job.runtime.acquireRequestHandle(job.request)
        let completion: CompletionResult
        do {
            try await job.runtime.preflight(job.request, with: handle)
            completion = try await job.runtime.stream(job.request, with: handle) { _ in
                collector.record()
                monitor.chunkArrived()
            }
            await job.runtime.unregisterInFlight(handle.registrationID)
        } catch {
            await job.runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        let ended = Date()
        let timing = collector.snapshot()

        var decodeTPS: Double?
        if let first = timing.first, let last = timing.last, completion.completionTokens > 1 {
            let span = last.timeIntervalSince(first)
            if span > 0 { decodeTPS = Double(completion.completionTokens - 1) / span }
        }

        let tokenIDs = job.request.requestID.flatMap { capturedTokenIDs(path: job.capturePath, requestID: $0) }
        let outputText: String? = tokenIDs == nil
            ? (completion.reasoningContent ?? "") + "\u{1}" + completion.content
            : nil
        let hashInput = tokenIDs.map { $0.map(String.init).joined(separator: ",") } ?? outputText ?? ""
        let digest = SHA256.hash(data: Data(hashInput.utf8)).map { String(format: "%02x", $0) }.joined()

        return MultiModelBenchSample(
            run: job.runIndex,
            requestID: job.request.requestID,
            promptTokens: completion.promptTokens,
            completionTokens: completion.completionTokens,
            finishReason: completion.finishReason,
            runtimeTtftMilliseconds: completion.ttftMilliseconds,
            clientTtftMilliseconds: timing.first.map { $0.timeIntervalSince(started) * 1000 },
            decodeSeconds: timing.first.flatMap { first in timing.last.map { $0.timeIntervalSince(first) } },
            decodeTokensPerSecond: decodeTPS,
            wallSeconds: ended.timeIntervalSince(started),
            chunkCount: timing.count,
            outputKind: tokenIDs == nil ? "text" : "token_ids",
            outputTokenIDs: tokenIDs,
            outputText: outputText,
            outputSha256: digest
        )
    }

    /// Points `MACPROVIDER_LAB_TOKEN_CAPTURE` at a private file unless already
    /// set; must run before any runtime exists.
    static func prepareTokenCapture(nonce: String) -> String {
        if let existing = ProcessInfo.processInfo.environment["MACPROVIDER_LAB_TOKEN_CAPTURE"], !existing.isEmpty {
            return existing
        }
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("macprovider-multi-model-bench-\(getpid())-\(nonce).jsonl")
        setenv("MACPROVIDER_LAB_TOKEN_CAPTURE", path, 1)
        return path
    }

    /// The record `LabOutputTokenCapture` wrote for `requestID`, if any.
    static func capturedTokenIDs(path: String, requestID: String) -> [Int]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["request_id"] as? String == requestID,
                  let ids = object["output_token_ids"] as? [Int]
            else { continue }
            return ids
        }
        return nil
    }

    // MARK: - Request

    static func promptText(promptTokens: Int) -> String {
        let instruction = "Summarize the following document in detail, section by section.\n\n"
        let body = MSBThroughputCommand.buildPromptText(index: 0, targetTokens: promptTokens)
        let budget = max(0, promptTokens * 4 - instruction.count)
        var cut = String(body.prefix(budget))
        if cut.count < body.count, let space = cut.lastIndex(of: " ") {
            cut = String(cut[..<space])
        }
        return instruction + cut
    }

    static func request(modelID: String, prompt: String, maxTokens: Int) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens,
            "temperature": 0,
            "top_p": 1,
            "stream": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try ChatCompletionRequest.parse(data: data)
    }

    // MARK: - Analysis

    static func parity(_ phases: [MultiModelBenchPhaseResult]) -> [MultiModelBenchParity] {
        var results: [MultiModelBenchParity] = []
        for slot in MultiModelBenchSlot.allCases {
            let ordered = phases.compactMap { phase in phase.stats(slot).map { (phase.phase, $0) } }
            let soloName = slot == .a ? MultiModelBenchPhase.soloA.rawValue : MultiModelBenchPhase.soloB.rawValue
            guard let referencePhase = ordered.first(where: { $0.0 == soloName }) ?? ordered.first,
                  let reference = referencePhase.1.warmup
            else { continue }
            for (phaseName, stats) in ordered {
                for sample in stats.allSamples {
                    let equal = sample.outputSha256 == reference.outputSha256
                    results.append(MultiModelBenchParity(
                        model: slot.rawValue,
                        phase: phaseName,
                        run: sample.run,
                        referencePhase: referencePhase.0,
                        parity: equal,
                        firstDivergingIndex: equal ? nil : firstDivergence(sample, reference)
                    ))
                }
            }
        }
        return results
    }

    static func firstDivergence(_ lhs: MultiModelBenchSample, _ rhs: MultiModelBenchSample) -> Int {
        if let left = lhs.outputTokenIDs, let right = rhs.outputTokenIDs {
            return firstDifference(left, right)
        }
        let left = Array((lhs.outputText ?? "").unicodeScalars)
        let right = Array((rhs.outputText ?? "").unicodeScalars)
        return firstDifference(left, right)
    }

    static func firstDifference<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        let shared = min(lhs.count, rhs.count)
        for index in 0..<shared where lhs[index] != rhs[index] { return index }
        return shared
    }

    static func slowdown(_ phases: [MultiModelBenchPhaseResult]) -> [MultiModelBenchSlowdown] {
        var results: [MultiModelBenchSlowdown] = []
        for slot in MultiModelBenchSlot.allCases {
            let soloName = slot == .a ? MultiModelBenchPhase.soloA.rawValue : MultiModelBenchPhase.soloB.rawValue
            let solo = phases.first { $0.phase == soloName }?.stats(slot)?.medianDecodeTokensPerSecond
            for concurrent in [MultiModelBenchPhase.concurrentShared, .concurrentStreams] {
                guard let stats = phases.first(where: { $0.phase == concurrent.rawValue })?.stats(slot) else { continue }
                let value = stats.medianDecodeTokensPerSecond
                results.append(MultiModelBenchSlowdown(
                    model: slot.rawValue,
                    phase: concurrent.rawValue,
                    soloMedianDecodeTokensPerSecond: solo,
                    concurrentMedianDecodeTokensPerSecond: value,
                    ratio: solo.flatMap { solo in value.flatMap { solo > 0 ? $0 / solo : nil } }
                ))
            }
        }
        return results
    }

    static func table(_ report: MultiModelBenchReport) -> String {
        func fmt(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "n/a" }
        var lines = ["", "phase               model  median_decode_tps  median_ttft_ms  vs_solo  parity"]
        for phase in report.phases {
            for slot in MultiModelBenchSlot.allCases {
                guard let stats = phase.stats(slot) else { continue }
                let ratio = report.slowdown.first { $0.model == slot.rawValue && $0.phase == phase.phase }?.ratio
                let rows = report.parity.filter { $0.model == slot.rawValue && $0.phase == phase.phase }
                let parity = rows.isEmpty ? "n/a" : (rows.allSatisfy(\.parity) ? "ok" : "DIFF")
                lines.append(
                    phase.phase.padding(toLength: 20, withPad: " ", startingAt: 0)
                        + slot.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)
                        + fmt(stats.medianDecodeTokensPerSecond, "%.2f").padding(toLength: 19, withPad: " ", startingAt: 0)
                        + fmt(stats.medianClientTtftMilliseconds, "%.0f").padding(toLength: 16, withPad: " ", startingAt: 0)
                        + fmt(ratio, "%.3f").padding(toLength: 9, withPad: " ", startingAt: 0)
                        + parity
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("multi-model-bench: \(message)\n".utf8))
    }
}

// MARK: - Phases and jobs

enum MultiModelBenchSlot: String, CaseIterable, Sendable {
    case a
    case b
}

enum MultiModelBenchPhase: String, CaseIterable, Sendable {
    case soloA = "solo-a"
    case soloB = "solo-b"
    case concurrentShared = "concurrent-shared"
    case concurrentStreams = "concurrent-streams"

    var slots: [MultiModelBenchSlot] {
        switch self {
        case .soloA: return [.a]
        case .soloB: return [.b]
        case .concurrentShared, .concurrentStreams: return [.a, .b]
        }
    }
}

struct MultiModelBenchJob: Sendable {
    let slot: MultiModelBenchSlot
    let runtime: ModelRuntime
    let request: ChatCompletionRequest
    let runIndex: Int
    let capturePath: String
    let monitor: MultiModelBenchMonitor
}

/// Chunk arrival times for one request; written from the runtime's stream callback.
final class MultiModelBenchChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Date?
    private var last: Date?
    private var count = 0

    func record() {
        let now = Date()
        lock.lock()
        if first == nil { first = now }
        last = now
        count += 1
        lock.unlock()
    }

    func snapshot() -> (first: Date?, last: Date?, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (first, last, count)
    }
}

// MARK: - Watchdog

/// Liveness, footprint sampling and partial-result persistence on a plain
/// thread, independent of the Swift cooperative pool.
final class MultiModelBenchMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let outPath: String?
    private let watchdogSeconds: Double
    private var report: MultiModelBenchReport?
    private var activePhase: String?
    private var lastChunkAt = Date()
    private var warnedForChunkAt: Date?
    private var phaseFootprintMax: UInt64 = 0
    private var stopped = false
    private var thread: Thread?
    /// Check mode owns its report; on a hang the monitor calls this with
    /// (phase, stalled model or nil, seconds since its last chunk, phase
    /// footprint max) and exits 3.
    private let hangHandler: (@Sendable (String, String?, Double, UInt64) -> Void)?
    /// Check mode: per-model liveness. Called with a limit in seconds, returns
    /// the model with a request in flight that has gone longest without a
    /// chunk, when that is at least the limit. Replaces the one global
    /// last-chunk timer, so one streaming model cannot mask a stalled sibling.
    private let stallProbe: (@Sendable (Double) -> MultiModelBenchStall?)?
    private var warnedStallModel: String?

    init(
        outPath: String?,
        watchdogSeconds: Double,
        stallProbe: (@Sendable (Double) -> MultiModelBenchStall?)? = nil,
        hangHandler: (@Sendable (String, String?, Double, UInt64) -> Void)? = nil
    ) {
        self.outPath = outPath
        self.watchdogSeconds = watchdogSeconds
        self.stallProbe = stallProbe
        self.hangHandler = hangHandler
    }

    func start() {
        let thread = Thread { [self] in self.loop() }
        thread.name = "multi-model-bench-watchdog"
        thread.stackSize = 1 << 20
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func chunkArrived() {
        lock.lock()
        lastChunkAt = Date()
        lock.unlock()
    }

    func phaseBegan(_ phase: String) {
        lock.lock()
        activePhase = phase
        lastChunkAt = Date()
        phaseFootprintMax = Self.physFootprintBytes() ?? 0
        lock.unlock()
    }

    /// Ends the phase and returns the max phys_footprint sampled during it.
    func phaseEnded() -> UInt64? {
        let current = Self.physFootprintBytes() ?? 0
        lock.lock()
        defer { lock.unlock() }
        activePhase = nil
        let value = max(phaseFootprintMax, current)
        return value == 0 ? nil : value
    }

    func publish(_ report: MultiModelBenchReport, writeFile: Bool) {
        lock.lock()
        self.report = report
        lock.unlock()
        if writeFile { write(report) }
    }

    private func loop() {
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            let footprint = Self.physFootprintBytes()
            // The probe takes the report box's lock; call it outside ours.
            let stall = stallProbe?(watchdogSeconds)
            let nearStall = stall == nil ? stallProbe?(watchdogSeconds / 2) : nil
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            if activePhase != nil, let footprint { phaseFootprintMax = max(phaseFootprintMax, footprint) }
            if stallProbe != nil {
                guard let phase = activePhase else {
                    lock.unlock()
                    continue
                }
                if let nearStall, warnedStallModel != nearStall.model {
                    warnedStallModel = nearStall.model
                    FileHandle.standardError.write(Data("multi-model-bench: WATCHDOG warn phase=\(phase) model=\(nearStall.model) seconds_since_last_chunk=\(Int(nearStall.idleSeconds)) pid=\(getpid())\n".utf8))
                } else if nearStall == nil, stall == nil {
                    warnedStallModel = nil
                }
                guard let stall else {
                    lock.unlock()
                    continue
                }
                let footprintMax = phaseFootprintMax
                lock.unlock()
                hangHandler?(phase, stall.model, stall.idleSeconds, footprintMax)
                FileHandle.standardError.write(Data("multi-model-bench: HANG phase=\(phase) model=\(stall.model) seconds_since_last_chunk=\(Int(stall.idleSeconds)); exiting 3\n".utf8))
                // _exit: see below.
                _exit(3)
            }
            let idle = Date().timeIntervalSince(lastChunkAt)
            // Half-way warning, once per stall, so an operator or script can
            // `sample` the process before the watchdog exits it.
            if let phase = activePhase, idle >= watchdogSeconds / 2, idle < watchdogSeconds, warnedForChunkAt != lastChunkAt {
                warnedForChunkAt = lastChunkAt
                FileHandle.standardError.write(Data("multi-model-bench: WATCHDOG warn phase=\(phase) seconds_since_last_chunk=\(Int(idle)) pid=\(getpid())\n".utf8))
            }
            guard let phase = activePhase, idle >= watchdogSeconds else {
                lock.unlock()
                continue
            }
            let footprintMax = phaseFootprintMax
            if let hangHandler {
                lock.unlock()
                hangHandler(phase, nil, idle, footprintMax)
                // _exit: exit() runs C++ static destructors under the MLX
                // threads still encoding, which segfaulted (rc 139) in the smoke.
                _exit(3)
            }
            guard var hung = report else {
                lock.unlock()
                continue
            }
            lock.unlock()
            hung.hang = MultiModelBenchHang(phase: phase, secondsSinceLastChunk: idle)
            if let index = hung.phases.lastIndex(where: { $0.phase == phase }) {
                hung.phases[index].physFootprintMaxBytes = footprintMax
            }
            write(hung)
            if let data = try? Self.encode(hung) {
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data("\n".utf8))
            }
            FileHandle.standardError.write(Data("multi-model-bench: HANG phase=\(phase) seconds_since_last_chunk=\(Int(idle)); exiting 3\n".utf8))
            exit(3)
        }
    }

    private func write(_ report: MultiModelBenchReport) {
        guard let outPath, let data = try? Self.encode(report) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("multi-model-bench: cannot write \(outPath): \(error)\n".utf8))
        }
    }

    static func encode(_ report: MultiModelBenchReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(report)
    }

    /// Process phys_footprint (TASK_VM_INFO): counts Metal/unified allocations RSS misses.
    static func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

// MARK: - Report schema

struct MultiModelBenchReport: Encodable, Sendable {
    let schema: String
    let generatedAtUnixSeconds: Double
    let host: MultiModelBenchHost
    let binaryVersion: String
    let config: MultiModelBenchConfig
    let processEnvironment: MultiModelBenchProcessEnvironment
    var loads: [MultiModelBenchLoad]
    var phases: [MultiModelBenchPhaseResult]
    var slowdown: [MultiModelBenchSlowdown]
    var parity: [MultiModelBenchParity]
    var hang: MultiModelBenchHang?
    var complete: Bool
}

struct MultiModelBenchHost: Encodable, Sendable {
    let chip: String
    let cpuBrand: String?
    let hardwareModel: String
    let memoryGB: Int
    let physicalMemoryBytes: UInt64

    static func current() -> MultiModelBenchHost {
        let evidence = HostEvidence.current()
        var size: size_t = 0
        var brand: String?
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                brand = String(cString: buffer)
            }
        }
        return MultiModelBenchHost(
            chip: evidence.chip,
            cpuBrand: brand,
            hardwareModel: evidence.hardwareModel,
            memoryGB: evidence.memoryGB,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }
}

struct MultiModelBenchConfig: Encodable, Sendable {
    let modelA: String
    let modelB: String
    let maxTokens: Int
    let promptTokensTarget: Int
    let promptCharacters: Int
    let runs: Int
    let phases: [String]
    let loadOrder: [String]
    let watchdogSeconds: Double
    let temperature: Double
    let topP: Double
    let stream: Bool
    /// Left at the request default (nil); templates may still open a think block.
    let reasoningEffort: String?
    /// `ChatCompletionRequest` has no EOS-suppression switch; a request can end
    /// before `max_tokens` and each sample records its own count and finish reason.
    let ignoreEosSupported: Bool
    let tokenCapturePath: String
}

struct MultiModelBenchProcessEnvironment: Encodable, Sendable {
    let firstLoadedModelFamily: String?
    let commandBufferBudgetAppliedMb: Int?
    let mlxMaxMbPerBuffer: String?
}

struct MultiModelBenchLoad: Encodable, Sendable {
    let model: String
    let modelID: String
    let modelFamily: String?
    let loadSeconds: Double
    let mlxActiveBytes: Int
    let mlxPeakBytes: Int
    let mlxCacheBytes: Int
    let mlxCacheLimitBytes: Int
    let mlxMemoryLimitBytes: Int
    let physFootprintBytes: UInt64?
    let mlxMaxMbPerBuffer: String?
}

struct MultiModelBenchSample: Encodable, Sendable {
    let run: Int
    let requestID: String?
    let promptTokens: Int
    let completionTokens: Int
    let finishReason: String
    let runtimeTtftMilliseconds: Int64?
    let clientTtftMilliseconds: Double?
    let decodeSeconds: Double?
    /// (completion_tokens - 1) / (last chunk - first chunk).
    let decodeTokensPerSecond: Double?
    let wallSeconds: Double
    let chunkCount: Int
    let outputKind: String
    let outputTokenIDs: [Int]?
    let outputText: String?
    let outputSha256: String
}

struct MultiModelBenchModelStats: Encodable, Sendable {
    var warmup: MultiModelBenchSample?
    var runs: [MultiModelBenchSample] = []
    /// Medians over `runs`; over the warmup alone when `--runs 1`.
    var medianDecodeTokensPerSecond: Double?
    var medianClientTtftMilliseconds: Double?
    var medianWallSeconds: Double?
    var medianSource: String?

    var allSamples: [MultiModelBenchSample] { (warmup.map { [$0] } ?? []) + runs }

    mutating func finalizeMedians() {
        let source = runs.isEmpty ? (warmup.map { [$0] } ?? []) : runs
        medianSource = runs.isEmpty ? "warmup" : "runs"
        medianDecodeTokensPerSecond = Self.median(source.compactMap(\.decodeTokensPerSecond))
        medianClientTtftMilliseconds = Self.median(source.compactMap(\.clientTtftMilliseconds))
        medianWallSeconds = Self.median(source.map(\.wallSeconds))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

struct MultiModelBenchPhaseResult: Encodable, Sendable {
    let phase: String
    let startedAtUnixSeconds: Double
    var endedAtUnixSeconds: Double?
    var completed: Bool
    var mlxPeakBytes: Int?
    var physFootprintMaxBytes: UInt64?
    var a: MultiModelBenchModelStats?
    var b: MultiModelBenchModelStats?
    var error: String?

    func stats(_ slot: MultiModelBenchSlot) -> MultiModelBenchModelStats? {
        slot == .a ? a : b
    }

    mutating func append(_ sample: MultiModelBenchSample, slot: MultiModelBenchSlot, isWarmup: Bool) {
        var stats = (slot == .a ? a : b) ?? MultiModelBenchModelStats()
        if isWarmup { stats.warmup = sample } else { stats.runs.append(sample) }
        if slot == .a { a = stats } else { b = stats }
    }

    mutating func finalizeMedians() {
        a?.finalizeMedians()
        b?.finalizeMedians()
    }
}

struct MultiModelBenchSlowdown: Encodable, Sendable {
    let model: String
    let phase: String
    let soloMedianDecodeTokensPerSecond: Double?
    let concurrentMedianDecodeTokensPerSecond: Double?
    /// concurrent median decode tok/s ÷ solo median decode tok/s.
    let ratio: Double?
}

struct MultiModelBenchParity: Encodable, Sendable {
    let model: String
    let phase: String
    let run: Int
    let referencePhase: String
    let parity: Bool
    let firstDivergingIndex: Int?
}

struct MultiModelBenchHang: Encodable, Sendable {
    let phase: String
    let secondsSinceLastChunk: Double
    /// Check mode: the model whose in-flight request stopped producing chunks.
    var model: String? = nil
}

/// A model with a request in flight and no chunk for `idleSeconds`.
struct MultiModelBenchStall: Sendable, Equatable {
    let model: String
    let idleSeconds: Double
}
#endif
