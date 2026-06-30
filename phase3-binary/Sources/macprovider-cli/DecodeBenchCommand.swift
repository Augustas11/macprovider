import ArgumentParser
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore

/// `decode-bench` — pure decode-loop benchmark, no coordinator, no WS.
///
/// Phase 2 of `specs/perf-mlx-compile-bf16-upgrade.md`. Loads the same
/// `LLMModelFactory` / `MLXLMCommon` path the serve runtime uses, runs
/// a fixed-length prefill + decode, and reports prefill TPS, decode TPS
/// (p50 across N runs after one warmup), and decode wall time as JSON.
///
/// Honors the same env flags as the serve runtime:
///   * `MACPROVIDER_BF16_WEIGHTS=1` — fp16→bf16 cast at load time.
///   * `MACPROVIDER_COMPILED_DECODE=1` — currently scaffolded but not
///     wired into the runtime decode loop in this branch (the bench
///     reports the flag's state for downstream reproducibility but
///     decode uses the standard `generate(...)` path).
///
/// Output: a single JSON object on stdout, plus a human-readable summary
/// on stderr. Result JSON is also written to
/// `state/perf/<label>-<modelTag>-<pinTag>-<ts>.json` so the spec's
/// "do not proceed until this file exists" gate can latch.
struct DecodeBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode-bench",
        abstract: "Run a pure-decode benchmark for a target model (Phase 2 of perf/mlx-compile-bf16).",
        discussion: """
            Decoupled from the coordinator and WS paths. Measures prefill TPS
            and steady-state decode TPS over a fixed prompt + token budget.
            """
    )

    @Option(help: "HuggingFace model ID or local path. Falls back to MACPROVIDER_MODEL.")
    var model: String?

    @Option(help: "Number of decode tokens to generate per run. Default 256.")
    var tokens: Int = 256

    @Option(help: "Approximate prefill token target. The fixture prompt is replicated until token count meets/exceeds this. Default 512.")
    var prefill: Int = 512

    @Option(help: "Number of timed runs (after a single warmup). Default 3.")
    var runs: Int = 3

    @Option(help: "Optional label suffix for output filenames (e.g. 'baseline', 'bf16-on', 'compile-on'). Default 'baseline'.")
    var label: String = "baseline"

    @Option(help: "Output directory for JSON result files. Default 'state/perf/'.")
    var outputDir: String = "state/perf"

    @Flag(help: "Skip writing the JSON file to disk; print to stdout only.")
    var stdoutOnly: Bool = false

    func run() async throws {
        guard let modelID = model ?? ProcessInfo.processInfo.environment["MACPROVIDER_MODEL"], !modelID.isEmpty else {
            FileHandle.standardError.write(Data("decode-bench: --model is required (or set MACPROVIDER_MODEL)\n".utf8))
            throw ExitCode(2)
        }
        guard tokens > 0, prefill > 0, runs > 0 else {
            FileHandle.standardError.write(Data("decode-bench: --tokens, --prefill, --runs must all be > 0\n".utf8))
            throw ExitCode(2)
        }

        let env = ProcessInfo.processInfo.environment
        let bf16Enabled = WeightCast.isEnabledByEnvironment(env)
        let compiledEnabled = CompiledDecode.isEnabledByEnvironment(env)

        // Reuse the serve runtime's model load path so the bench sees the
        // same dtype histogram and same KVCache wiring it would in prod.
        let runtime = try await ModelRuntime(modelID: modelID)
        guard await runtime.isLoaded else {
            FileHandle.standardError.write(Data("decode-bench: failed to load model \(modelID)\n".utf8))
            throw ExitCode(1)
        }

        let snapshot = await runtime.currentSnapshot()
        guard let container = snapshot.container else {
            FileHandle.standardError.write(Data("decode-bench: runtime has no container post-load\n".utf8))
            throw ExitCode(1)
        }

        // Build a prompt that prefills to roughly the requested token count.
        // We don't try to hit the exact target — `prefill_tokens_actual` in
        // the output records what we got, which is what the analyst needs.
        let basePrompt = "Summarize the following technical document. "
        let replications = max(1, prefill / 8)
        let prompt = String(repeating: basePrompt, count: replications)

        // One warmup, then `runs` timed runs.
        var warmup: BenchSampleResult?
        var samples: [BenchSampleResult] = []
        for runIndex in 0..<(runs + 1) {
            let isWarmup = runIndex == 0
            let sample = try await runOnce(
                container: container,
                prompt: prompt,
                maxTokens: tokens,
                isWarmup: isWarmup
            )
            if isWarmup {
                warmup = sample
            } else {
                samples.append(sample)
            }
        }

        let pin = mlxSwiftExamplesPinTag()
        let modelTag = modelID
            .split(separator: "/")
            .last
            .map(String.init) ?? "model"
        let tsBase = ISO8601DateFormatter()
        tsBase.formatOptions = [.withInternetDateTime, .withTimeZone]
        let ts = tsBase.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let report = BenchReport(
            schemaVersion: 1,
            label: label,
            modelID: modelID,
            modelTag: modelTag,
            mlxSwiftExamplesPin: pin,
            promptTokensTarget: prefill,
            decodeTokensTarget: tokens,
            runs: runs,
            warmup: warmup,
            samples: samples,
            bf16WeightsEnvFlag: bf16Enabled,
            compiledDecodeEnvFlag: compiledEnabled,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))

        let p50Decode = percentileTPS(samples.map { $0.decodeTPS }, p: 0.5)
        let p50Prefill = percentileTPS(samples.map { $0.prefillTPS }, p: 0.5)
        FileHandle.standardError.write(Data((
            "decode-bench: model=\(modelTag) pin=\(pin) " +
            "prefill_tps_p50=\(formatTPS(p50Prefill)) decode_tps_p50=\(formatTPS(p50Decode)) " +
            "bf16=\(bf16Enabled) compiled=\(compiledEnabled) runs=\(runs)\n"
        ).utf8))

        guard !stdoutOnly else { return }
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `--label` and `--model` are operator-supplied. Sanitize the basename
        // components so values like `../etc/passwd` cannot escape `--output-dir`.
        // Cheap defense-in-depth — this is an operator-local subcommand, not a
        // remotely triggerable surface.
        let safeLabel = sanitizeFilenameComponent(label)
        let safeModelTag = sanitizeFilenameComponent(modelTag)
        let filename = "\(safeLabel)-\(safeModelTag)-\(pin)-\(ts).json"
        let fileURL = dir.appendingPathComponent(filename)
        try json.write(to: fileURL, options: [.atomic])
        FileHandle.standardError.write(Data("decode-bench: wrote \(fileURL.path)\n".utf8))
    }

    // MARK: - One sample

    private func runOnce(
        container: ModelContainer,
        prompt: String,
        maxTokens: Int,
        isWarmup: Bool
    ) async throws -> BenchSampleResult {
        let prefillStart = Date()
        var firstTokenAt: Date?
        var generationTokens = 0
        var promptTokens = 0
        try await container.perform { context in
            let input = try UserInput(chat: [.user(prompt)])
            let lmInput = try await context.processor.prepare(input: input)
            promptTokens = lmInput.text.tokens.size
            let parameters = GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.0,
                topP: 1.0
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
        let decodeElapsed = max(endAt.timeIntervalSince(prefillEnd), 0.001)
        let prefillTPS = Double(promptTokens) / prefillElapsed
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

// MARK: - Helpers

/// The mlx-swift-examples pin tag used for benchmark output filenames so a
/// future operator can disambiguate `baseline-Qwen-2.29.1-….json` from
/// runs taken on a different pin.
func mlxSwiftExamplesPinTag() -> String {
    // Source-of-truth lives in `phase3-binary/Package.swift`; surfacing
    // the version string here keeps the bench output reproducible.
    return "mlxsx-2.29.1"
}

/// Trivial nearest-rank percentile for small `runs` budgets (3–5). For
/// `runs == 3`, p50 is just the middle element after sort.
func percentileTPS(_ values: [Double], p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = max(0, min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded())))
    return sorted[rank]
}

private func formatTPS(_ v: Double) -> String {
    String(format: "%.1f", v)
}

/// Reduce an operator-supplied string to a basename-safe slug:
///   * keep ASCII alnum, `_`, `.`, `-`
///   * replace every other byte with `_`
///   * collapse runs of `_` and trim leading/trailing `_`/`.`
///   * cap length at 80 chars
///   * empty result falls back to `"unlabeled"`
///
/// Intentionally strict — false-positive collapses are fine for a
/// benchmark filename. The goal is to prevent path-traversal sequences
/// (`../`, `..\\`) and shell metacharacters from reaching the output
/// path, NOT to round-trip the operator's input.
func sanitizeFilenameComponent(_ input: String) -> String {
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
    let mlxSwiftExamplesPin: String
    let promptTokensTarget: Int
    let decodeTokensTarget: Int
    let runs: Int
    let warmup: BenchSampleResult?
    let samples: [BenchSampleResult]
    let bf16WeightsEnvFlag: Bool
    let compiledDecodeEnvFlag: Bool
    let timestamp: String
}
