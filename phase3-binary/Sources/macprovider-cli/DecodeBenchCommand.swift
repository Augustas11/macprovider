import ArgumentParser
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore

/// `decode-bench` — pure decode-loop benchmark, no coordinator, no WS.
///
/// T0-01 of `docs/runbooks/PLAN_THROUGHPUT_ENGINEERING_RUNBOOK.md`. Loads the same
/// `LLMModelFactory` / `MLXLMCommon` path the serve runtime uses, runs
/// a fixed-length prefill + decode, and reports prefill TPS, decode TPS
/// (p50 across N runs after one warmup), and decode wall time as JSON.
///
/// TPS semantics (generation-only): denominator is time from first generated
/// token to last, excluding TTFT (prefill wall-clock). Matches
/// `Stage1Iterator.swift` v1.7.8 Track A4 semantics — "generation-only
/// throughput" where `generationElapsed = endedAt - firstTokenAt`.
///
/// Does NOT wire CompiledDecode or bf16 weight cast — harness only.
/// Those are T2-01 scope. The JSON output records `compiledDecodeEnvFlag`
/// and `bf16WeightsEnvFlag` as `false` so downstream tooling has a stable
/// schema to diff against T2-01 results.
struct DecodeBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode-bench",
        abstract: "Run a pure-decode benchmark for a target model (T0-01 of throughput runbook).",
        discussion: """
            Decoupled from the coordinator and WS paths. Measures prefill TPS
            and steady-state decode TPS over a fixed prompt + token budget.

            TPS semantics: generation-only (excludes TTFT), matching Stage1Iterator
            v1.7.8 Track A4 semantics.
            """,
        shouldDisplay: false
    )

    @Option(help: "HuggingFace model ID or local path. Falls back to MACPROVIDER_MODEL.")
    var model: String?

    @Option(
        name: .customLong("decode-tokens"),
        help: "Number of decode tokens to generate per run. Default 256."
    )
    var decodeTokens: Int = 256

    @Option(
        name: .customLong("prefill-tokens"),
        help: "Approximate prefill token target. The fixture prompt is replicated until token count meets/exceeds this. Default 512."
    )
    var prefillTokens: Int = 512

    @Option(
        name: .customLong("prefill-step-size"),
        help: "Prefill chunk size (GenerateParameters.prefillStepSize / model.prepare windowSize). Default 512."
    )
    var prefillStepSize: Int = 512

    @Option(help: "Number of timed runs (after a single warmup). Default 3.")
    var runs: Int = 3

    @Option(
        help: "Optional label suffix for auto-generated output filenames (e.g. 'baseline'). Default 'baseline'."
    )
    var label: String = "baseline"

    @Option(
        help: "Full output path for JSON result file. When set, writes to this exact path instead of the auto-generated state/perf/ path."
    )
    var output: String?

    @Option(
        name: .customLong("output-dir"),
        help: "Output directory for auto-generated JSON result files. Ignored when --output is set. Default 'state/perf/'."
    )
    var outputDir: String = "state/perf"

    @Flag(help: "Skip writing the JSON file to disk; print to stdout only.")
    var stdoutOnly: Bool = false

    @Flag(
        name: .customLong("report-sparsity"),
        help: "Append implied_active_params_B and decode_regime to the JSON output using DecodeBandwidthModel (T2-02). Requires --total-params-b and --bandwidth-tier."
    )
    var reportSparsity: Bool = false

    @Option(
        name: .customLong("total-params-b"),
        help: "Total model parameter count in billions (e.g. 20.0 for gpt-oss-20b). Required when --report-sparsity is set."
    )
    var totalParamsB: Double?

    @Option(
        name: .customLong("bandwidth-gbps"),
        help: "Host memory bandwidth in GB/s for sparsity diagnostics (e.g. 120 for M4, 273 for M4 Pro). Required when --report-sparsity is set."
    )
    var bandwidthGBps: Double?

    func run() async throws {
        guard let modelID = model ?? ProcessInfo.processInfo.environment["MACPROVIDER_MODEL"],
              !modelID.isEmpty else {
            FileHandle.standardError.write(Data(
                "decode-bench: --model is required (or set MACPROVIDER_MODEL)\n".utf8
            ))
            throw ExitCode(2)
        }
        guard decodeTokens > 0, prefillTokens > 0, prefillStepSize > 0, runs > 0 else {
            FileHandle.standardError.write(Data(
                "decode-bench: --decode-tokens, --prefill-tokens, --prefill-step-size, --runs must all be > 0\n".utf8
            ))
            throw ExitCode(2)
        }

        let env = ProcessInfo.processInfo.environment
        // bf16 cast is NOT in T2-01 scope — WeightCast lands separately.
        let bf16Enabled = false
        // T2-01: honor MACPROVIDER_COMPILED_DECODE; default OFF.
        let compiledEnabled = CompiledDecode.isEnabledByEnvironment(env)

        // Reuse the serve runtime's model load path so the bench sees the
        // same dtype histogram and same KVCache wiring it would in prod.
        let runtime = try await ModelRuntime(modelID: modelID)
        guard await runtime.isLoaded else {
            FileHandle.standardError.write(Data(
                "decode-bench: failed to load model \(modelID)\n".utf8
            ))
            throw ExitCode(1)
        }

        let snapshot = await runtime.currentSnapshot()
        guard let container = snapshot.container else {
            FileHandle.standardError.write(Data(
                "decode-bench: runtime has no container post-load\n".utf8
            ))
            throw ExitCode(1)
        }

        // Build a prompt that prefills to roughly the requested token count.
        // We don't try to hit the exact target — `prefillTokensActual` in
        // the output records what we got, which is what the analyst needs.
        let basePrompt = "Summarize the following technical document. "
        let replications = max(1, prefillTokens / 8)
        let prompt = String(repeating: basePrompt, count: replications)

        // One warmup run, then `runs` timed runs.
        var warmupSample: BenchSampleResult?
        var samples: [BenchSampleResult] = []
        for runIndex in 0..<(runs + 1) {
            let isWarmup = runIndex == 0
            let sample: BenchSampleResult
            if compiledEnabled {
                sample = try await runCompiledOnce(
                    container: container,
                    prompt: prompt,
                    maxTokens: decodeTokens,
                    isWarmup: isWarmup
                )
            } else {
                sample = try await runOnce(
                    container: container,
                    prompt: prompt,
                    maxTokens: decodeTokens,
                    isWarmup: isWarmup
                )
            }
            if isWarmup {
                warmupSample = sample
            } else {
                samples.append(sample)
            }
        }

        let pin = decodeBenchMLXPinTag()
        let modelTag = modelID
            .split(separator: "/")
            .last
            .map(String.init) ?? "model"

        var tsFormatter = ISO8601DateFormatter()
        tsFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        let ts = tsFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let sparsityReport = decodeBenchSparsityReport(
            enabled: reportSparsity,
            totalParamsB: totalParamsB,
            bandwidthGBps: bandwidthGBps,
            p50DecodeTPS: decodeBenchPercentileTPS(samples.map(\.decodeTPS), p: 0.5)
        )

        let report = BenchReport(
            schemaVersion: 1,
            label: label,
            modelID: modelID,
            modelTag: modelTag,
            mlxSwiftLMPin: pin,
            prefillTokensTarget: prefillTokens,
            prefillStepSize: prefillStepSize,
            decodeTokensTarget: decodeTokens,
            runs: runs,
            warmup: warmupSample,
            samples: samples,
            bf16WeightsEnvFlag: bf16Enabled,
            compiledDecodeEnvFlag: compiledEnabled,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sparsity: sparsityReport
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))

        let p50Decode = decodeBenchPercentileTPS(samples.map(\.decodeTPS), p: 0.5)
        let p50Prefill = decodeBenchPercentileTPS(samples.map(\.prefillTPS), p: 0.5)
        FileHandle.standardError.write(Data((
            "decode-bench: model=\(modelTag) pin=\(pin) " +
            "prefill_tps_p50=\(decodeBenchFormatTPS(p50Prefill)) " +
            "decode_tps_p50=\(decodeBenchFormatTPS(p50Decode)) " +
            "bf16=\(bf16Enabled) compiled=\(compiledEnabled) runs=\(runs)\n"
        ).utf8))

        guard !stdoutOnly else { return }

        let fileURL: URL
        if let explicitPath = output {
            fileURL = URL(fileURLWithPath: explicitPath)
            if let parent = fileURL.deletingLastPathComponent() as URL?, parent.path != "/" {
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true
                )
            }
        } else {
            let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeLabel = decodeBenchSanitizeFilenameComponent(label)
            let safeModelTag = decodeBenchSanitizeFilenameComponent(modelTag)
            let filename = "\(safeLabel)-\(safeModelTag)-\(pin)-\(ts).json"
            fileURL = dir.appendingPathComponent(filename)
        }
        try json.write(to: fileURL, options: [.atomic])
        FileHandle.standardError.write(Data("decode-bench: wrote \(fileURL.path)\n".utf8))
    }

    // MARK: - One sample

    /// Compiled decode loop using `CompiledDecodeStep`.
    ///
    /// Runs prefill via the standard `model.prepare()` path (handles chunked
    /// prefill correctly), then transitions to `MLX.compile()`-wrapped
    /// per-token forwards for the decode phase.
    ///
    /// Token sampling is greedy (temperature=0, argMax) to match the
    /// correctness gate — compiled and uncompiled should produce identical
    /// token IDs for the same prompt.
    private func runCompiledOnce(
        container: ModelContainer,
        prompt: String,
        maxTokens: Int,
        isWarmup: Bool
    ) async throws -> BenchSampleResult {
        let prefillStart = Date()
        nonisolated(unsafe) var firstTokenAt: Date? = nil
        var promptTokensCount = 0
        var decodedTokenCount = 0

        try await container.perform { context in
            let input = UserInput(chat: [.user(prompt)])
            let lmInput = try await context.processor.prepare(input: input)
            promptTokensCount = lmInput.text.tokens.size

            let parameters = GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.0,
                topP: 1.0,
                prefillStepSize: prefillStepSize
            )
            // Create the cache separately so we hold a reference to the same
            // KVCache instances the model will mutate during prefill. After
            // prepare() returns, innerState() will be non-empty and we can
            // safely construct CompiledDecodeStep.
            let cache = context.model.newCache(parameters: parameters)

            // Prefill: model.prepare() handles chunked prefill internally.
            // `.tokens` → need one more model call for the remaining token chunk.
            // `.logits` → first-token logits are already available.
            let firstTokenArray: MLXArray
            switch try context.model.prepare(lmInput, cache: cache, windowSize: parameters.prefillStepSize) {
            case .tokens(let textInput):
                // Process the remaining prefix tokens to get first-token logits.
                // `withPreparedCache` is a no-op when sequenceLengths is nil
                // (unbatched 1-D token array); still called for correctness parity
                // with TokenIterator.step().
                let output = withPreparedCache(cache, lengths: textInput.sequenceLengths) {
                    context.model(textInput[text: .newAxis], cache: cache.isEmpty ? nil : cache, state: nil)
                }
                eval(output.logits)
                firstTokenArray = argMax(output.logits[0..., -1, 0...], axis: -1)

            case .logits(let output):
                eval(output.logits)
                firstTokenArray = argMax(output.logits[0..., -1, 0...], axis: -1)
            }

            eval(firstTokenArray)
            // Force cache synchronization: evaluating the logits covers most
            // of the computation graph, but an explicit cache eval matches what
            // LLMModel.prepare() does and satisfies ADV-1 (non-empty innerState
            // precondition in CompiledDecodeStep).
            eval(cache)
            firstTokenAt = Date()

            // Cache is now populated with the prefill + first decode forward.
            // Constructing CompiledDecodeStep here satisfies ADV-1 (populated
            // cache precondition from CompiledDecode.swift).
            let step = CompiledDecodeStep(model: context.model, cache: cache, enabled: true)

            // Build EOS set: mirrors buildStopTokenIds() from mlx-swift-lm Evaluate.swift.
            // Must include extraEOSTokens (string→ID) so chat templates that use tokens
            // like "<|im_end|>" (Qwen) are correctly recognised as stop tokens.
            var eosIds: Set<Int> = context.configuration.eosTokenIds
            if let tokEOS = context.tokenizer.eosTokenId { eosIds.insert(tokEOS) }
            if let unkID = context.tokenizer.unknownTokenId { eosIds.insert(unkID) }
            for token in context.configuration.extraEOSTokens {
                if let id = context.tokenizer.convertTokenToId(token) { eosIds.insert(id) }
            }

            decodedTokenCount = 1  // count first token
            var currentToken = firstTokenArray.reshaped(1, 1)

            for _ in 1 ..< maxTokens {
                // compiled step: model(currentToken [1,1], cache:) → logits [1,1,vocab]
                let logits = step.step(currentToken)
                eval(logits)
                let nextToken = argMax(logits[0..., -1, 0...], axis: -1)
                eval(nextToken)
                let tokenId = nextToken.item(Int.self)
                if eosIds.contains(tokenId) { break }
                currentToken = nextToken.reshaped(1, 1)
                decodedTokenCount += 1
            }

            // Synchronize stream before returning — mirrors TokenIterator's
            // Stream().synchronize() call to avoid scheduler tear-down assertions.
            Stream().synchronize()
        }

        let endAt = Date()
        let prefillEnd = firstTokenAt ?? endAt
        let prefillElapsed = max(prefillEnd.timeIntervalSince(prefillStart), 0.001)
        let decodeElapsed = max(endAt.timeIntervalSince(prefillEnd), 0.001)
        let prefillTPS = Double(promptTokensCount) / prefillElapsed
        // -1: first token is the TTFT boundary token, not counted in decode TPS
        let decodeTPS = Double(max(decodedTokenCount - 1, 0)) / decodeElapsed

        return BenchSampleResult(
            isWarmup: isWarmup,
            promptTokensActual: promptTokensCount,
            decodeTokensActual: decodedTokenCount,
            prefillSeconds: prefillElapsed,
            decodeSeconds: decodeElapsed,
            ttftSeconds: prefillElapsed,
            prefillTPS: prefillTPS,
            decodeTPS: decodeTPS
        )
    }

    private func runOnce(
        container: ModelContainer,
        prompt: String,
        maxTokens: Int,
        isWarmup: Bool
    ) async throws -> BenchSampleResult {
        let prefillStart = Date()
        // Capture first-token timestamp from inside the generate callback.
        // `nonisolated(unsafe)` is needed because the closure is @Sendable
        // (container.perform isolates to the ModelContext actor) but we
        // only write once (first token) and read after await returns.
        nonisolated(unsafe) var firstTokenAt: Date? = nil
        var promptTokens = 0
        var generationTokens = 0
        try await container.perform { context in
            let input = UserInput(chat: [.user(prompt)])
            let lmInput = try await context.processor.prepare(input: input)
            promptTokens = lmInput.text.tokens.size
            let parameters = GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.0,
                topP: 1.0,
                prefillStepSize: prefillStepSize
            )
            let result: GenerateResult = try generate(
                input: lmInput,
                parameters: parameters,
                context: context
            ) { tokens in
                if firstTokenAt == nil, !tokens.isEmpty {
                    firstTokenAt = Date()
                }
                return GenerateDisposition.more
            }
            generationTokens = result.generationTokenCount
        }
        let endAt = Date()
        let prefillEnd = firstTokenAt ?? endAt
        let prefillElapsed = max(prefillEnd.timeIntervalSince(prefillStart), 0.001)
        // Generation-only elapsed time: from first generated token to last.
        // Matches Stage1Iterator.swift v1.7.8 Track A4 semantics —
        // denominator excludes TTFT so catalog `min_sustained_tps` gates apply.
        let decodeElapsed = max(endAt.timeIntervalSince(prefillEnd), 0.001)
        let prefillTPS = Double(promptTokens) / prefillElapsed
        // Subtract 1 because the first token is the TTFT boundary token,
        // not a "generated beyond prefill" token.
        let decodeTPS = Double(max(generationTokens - 1, 0)) / decodeElapsed

        return BenchSampleResult(
            isWarmup: isWarmup,
            promptTokensActual: promptTokens,
            decodeTokensActual: generationTokens,
            prefillSeconds: prefillElapsed,
            decodeSeconds: decodeElapsed,
            ttftSeconds: prefillElapsed,
            prefillTPS: prefillTPS,
            decodeTPS: decodeTPS
        )
    }
}

// MARK: - Helpers (module-level, prefixed to avoid collision)

/// The mlx-swift-lm pin tag used for benchmark output filenames so a
/// future operator can disambiguate runs taken on different pins.
/// Source of truth: `phase3-binary/Package.resolved` — update when pin bumps.
func decodeBenchMLXPinTag() -> String {
    return "mlxlm-3.31.4"
}

/// Nearest-rank percentile for small `runs` budgets (3–5).
/// For `runs == 3`, p50 is the middle element after sort.
func decodeBenchPercentileTPS(_ values: [Double], p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = max(0, min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded())))
    return sorted[rank]
}

func decodeBenchFormatTPS(_ v: Double) -> String {
    String(format: "%.1f", v)
}

struct MSBAggregateThroughputInput: Sendable, Equatable {
    let decodedTokens: Int
    let decodeStartedAt: Date
    let decodeEndedAt: Date
}

struct MSBAggregateThroughputReport: Sendable, Equatable {
    let totalDecodedTokens: Int
    let commonWallSeconds: TimeInterval
    let aggregateTokensPerSecond: Double
}

enum MSBAggregateThroughputError: Error, Equatable {
    case emptySamples
    case invalidSample
    case tokenCountOverflow
}

func msbAggregateThroughput(_ samples: [MSBAggregateThroughputInput]) throws -> MSBAggregateThroughputReport {
    guard !samples.isEmpty else {
        throw MSBAggregateThroughputError.emptySamples
    }
    var totalDecodedTokens = 0
    var start = samples[0].decodeStartedAt
    var end = samples[0].decodeEndedAt
    for sample in samples {
        guard sample.decodedTokens >= 0, sample.decodeEndedAt > sample.decodeStartedAt else {
            throw MSBAggregateThroughputError.invalidSample
        }
        let (sum, overflowed) = totalDecodedTokens.addingReportingOverflow(sample.decodedTokens)
        guard !overflowed else {
            throw MSBAggregateThroughputError.tokenCountOverflow
        }
        totalDecodedTokens = sum
        start = min(start, sample.decodeStartedAt)
        end = max(end, sample.decodeEndedAt)
    }
    let commonWallSeconds = end.timeIntervalSince(start)
    guard commonWallSeconds > 0 else {
        throw MSBAggregateThroughputError.invalidSample
    }
    return MSBAggregateThroughputReport(
        totalDecodedTokens: totalDecodedTokens,
        commonWallSeconds: commonWallSeconds,
        aggregateTokensPerSecond: Double(totalDecodedTokens) / commonWallSeconds
    )
}

/// Reduce an operator-supplied string to a basename-safe slug.
/// Prevents path-traversal sequences (`../`) from reaching the output path.
func decodeBenchSanitizeFilenameComponent(_ input: String) -> String {
    let allowed: Set<Character> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"
    )
    var out = String()
    out.reserveCapacity(input.count)
    var lastWasUnderscore = false
    for ch in input {
        if allowed.contains(ch) {
            out.append(ch)
            lastWasUnderscore = (ch == "_")
        } else if !lastWasUnderscore {
            out.append("_")
            lastWasUnderscore = true
        }
    }
    let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_."))
    let capped = String(trimmed.prefix(80))
    return capped.isEmpty ? "unlabeled" : capped
}

/// Build a `SparsityReport` using `DecodeBandwidthModel` if all inputs are present.
/// Returns `nil` (and logs a warning) when the flag is set but required args are missing.
func decodeBenchSparsityReport(
    enabled: Bool,
    totalParamsB: Double?,
    bandwidthGBps bw: Double?,
    p50DecodeTPS: Double
) -> SparsityReport? {
    guard enabled else { return nil }

    guard let totalB = totalParamsB, totalB > 0 else {
        FileHandle.standardError.write(Data(
            "decode-bench: --report-sparsity requires --total-params-b > 0; skipping sparsity report\n".utf8
        ))
        return nil
    }
    guard let bandwidth = bw, bandwidth > 0 else {
        FileHandle.standardError.write(Data(
            "decode-bench: --report-sparsity requires --bandwidth-gbps > 0 (e.g. 120 for M4, 273 for M4 Pro); skipping sparsity report\n".utf8
        ))
        return nil
    }
    guard p50DecodeTPS > 0 else { return nil }

    let impliedReadGB = DecodeBandwidthModel.impliedReadGBPerToken(
        decodeTokensPerSecond: p50DecodeTPS,
        bandwidthGBps: bandwidth
    )
    let impliedActiveB = DecodeBandwidthModel.impliedActiveParams(
        decodeTokensPerSecond: p50DecodeTPS,
        bandwidthGBps: bandwidth
    ) / 1e9
    let totalWeightGB = totalB * DecodeBandwidthModel.fourBitBytesPerParam
    let regime = DecodeBandwidthModel.classifyRegime(
        impliedReadGB: impliedReadGB,
        totalWeightGB: totalWeightGB
    )

    return SparsityReport(
        bandwidthGBps: bandwidth,
        totalParamsB: totalB,
        p50DecodeTPS: p50DecodeTPS,
        impliedReadGBPerToken: impliedReadGB,
        impliedActiveParamsB: impliedActiveB,
        activeParamsFractionPct: (impliedActiveB / totalB) * 100.0,
        decodeRegime: regime.rawValue
    )
}

// MARK: - Wire schema

struct BenchSampleResult: Codable, Sendable {
    let isWarmup: Bool
    let promptTokensActual: Int
    let decodeTokensActual: Int
    let prefillSeconds: TimeInterval
    let decodeSeconds: TimeInterval
    let ttftSeconds: TimeInterval
    let prefillTPS: Double
    let decodeTPS: Double
}

struct BenchReport: Codable, Sendable {
    let schemaVersion: Int
    let label: String
    let modelID: String
    let modelTag: String
    let mlxSwiftLMPin: String
    let prefillTokensTarget: Int
    let prefillStepSize: Int
    let decodeTokensTarget: Int
    let runs: Int
    let warmup: BenchSampleResult?
    let samples: [BenchSampleResult]
    let bf16WeightsEnvFlag: Bool
    let compiledDecodeEnvFlag: Bool
    let timestamp: String
    /// T2-02: optional sparsity diagnostics from DecodeBandwidthModel.
    /// Present when `--report-sparsity` is set; null otherwise.
    let sparsity: SparsityReport?
}

/// Sparsity diagnostics emitted when `decode-bench --report-sparsity` is set.
/// All fields derive from `DecodeBandwidthModel` (T2-02 runbook artifact).
struct SparsityReport: Codable, Sendable {
    let bandwidthGBps: Double
    let totalParamsB: Double
    let p50DecodeTPS: Double
    let impliedReadGBPerToken: Double
    let impliedActiveParamsB: Double
    let activeParamsFractionPct: Double
    let decodeRegime: String
}
