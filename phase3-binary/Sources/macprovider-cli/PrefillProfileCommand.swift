import ArgumentParser
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import MacProviderCore

// Lab-only: compiled out of plain release builds, command type and
// registration included.
#if DEBUG || MACPROVIDER_LAB_HARNESS
/// `prefill-profile` — lab-only split of one-row serial-path prefill time (#2409).
///
/// Loads the artifact through `ModelRuntime` (the serve load path) and, per
/// prompt length, after one untimed warm-up:
///  - `served`: the serve's network serial path for a keyless request
///    (`makeServeGenerateParameters`, `serveCache`, `serveIteratorParameters`,
///    `TokenIterator` with `.legacyRemainder(stepSize:)`, the post-prefill
///    clear, the first `next()`), once per `--step-sizes` entry and run:
///    time to first token, the iterator's return, and the time of each
///    prefill-progress callback (graph submission of each chunk);
///  - `synced`: the same chunk boundaries driven one forward at a time with
///    `eval(cache)` after each, then the buffer-cache clear, then the
///    remainder forward and its greedy token: per-chunk forward and clear
///    time and the prefill-end-to-first-token forward. `synced_no_clear` is
///    the same without the clears;
///  - `sections`: one synced run with the engine's `LabSectionTimer` on,
///    the exclusive time of each model section per chunk (shares of a
///    synchronized forward, not pipelined latency). Only in a build with
///    `-DMACPROVIDER_SECTION_TIMING` against an mlx-swift-lm that has the
///    timer (the #2409 fork); otherwise the pass records `unavailable`.
/// Greedy token ids of every mode are recorded; they must agree.
///
/// It also writes the model's leaf-module weight inventory (path, kind,
/// weight shape, quantization bits) for the compute-per-token ceiling.
struct PrefillProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefill-profile",
        abstract: "Split one-row serial prefill time by chunk and model section (lab only).",
        shouldDisplay: false
    )

    @Option(name: .customLong("model-dir"), help: "Local model directory.")
    var modelDir: String

    @Option(name: .customLong("prompt-text"), help: "UTF-8 text file; tokenized raw and repeated to each prompt length.")
    var promptText: String

    @Option(name: .customLong("prompt-tokens"), help: "Comma-separated prompt lengths. Default 4096,12288.")
    var promptTokens: String = "4096,12288"

    @Option(name: .customLong("step-sizes"), help: "Comma-separated prefill step sizes for the served pass; the first is the synced and sections pass's. Default 512 (serve default),2048.")
    var stepSizes: String = "512,2048"

    @Option(help: "Timed served runs per step size. Default 3.")
    var runs: Int = 3

    @Option(
        name: .customLong("mlx-cache-limit-mb"),
        help: "MLX buffer-cache bound, as serve's mlx_cache_limit_mb. Default: serve's default."
    )
    var mlxCacheLimitMB: Int?

    @Option(help: "Output JSON path.")
    var output: String

    func run() async throws {
        let lengths = Self.parseList(promptTokens)
        let steps = Self.parseList(stepSizes)
        guard !lengths.isEmpty, !steps.isEmpty, runs > 0 else {
            FileHandle.standardError.write(Data("prefill-profile: --prompt-tokens, --step-sizes need positive integers; --runs > 0\n".utf8))
            throw ExitCode(2)
        }
        let text = try String(contentsOfFile: promptText, encoding: .utf8)
        let mlxCacheLimitMB = ModelRuntime.resolvedMLXCacheLimitMB(
            configured: mlxCacheLimitMB, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        ) ?? ModelRuntime.defaultMLXCacheLimitMB
        let directory = try ModelRuntime.localModelDirectory(for: modelDir)
        let configData = try? Data(contentsOf: directory.appendingPathComponent("config.json"))
        let capabilities = ModelRuntime.pagedKVModelCapabilities(modelID: modelDir, configJSONData: configData)
        _ = ModelRuntime.applyMLXCommandBufferBudget(modelFamily: capabilities.modelFamily)
        Self.say("load start dir=\(directory.path) family=\(capabilities.modelFamily)")
        let loadStarted = Date()
        let runtime = try await ModelRuntime(modelID: modelDir, mlxCacheLimitMB: mlxCacheLimitMB)
        guard await runtime.isLoaded, let container = await runtime.currentSnapshot().container else {
            FileHandle.standardError.write(Data("prefill-profile: failed to load \(modelDir)\n".utf8))
            throw ExitCode(1)
        }
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        Self.say("load done seconds=\(String(format: "%.1f", loadSeconds))")

        let prepared = try await container.perform { context in
            let base = context.tokenizer.encode(text: text).map(Int32.init)
            guard !base.isEmpty else { throw ValidationError("prompt text tokenizes to nothing") }
            let longest = lengths.max()!
            let repeated = (0 ..< longest).map { base[$0 % base.count] }
            return Unchecked(value: (lengths.map { Array(repeated[0 ..< $0]) }, Self.inventory(context.model)))
        }
        let (prompts, inventory) = prepared.value as! ([[Int32]], [[String: Any]])

        var results: [[String: Any]] = []
        for tokens in prompts {
            let n = tokens.count
            var record: [String: Any] = ["tokens": n]
            Self.say("prompt \(n) warm-up")
            _ = try await container.perform { Unchecked(value: try Self.served($0.model, tokens: tokens, step: steps[0])) }
            var served: [[String: Any]] = []
            for step in steps {
                var stepRuns: [[String: Any]] = []
                for _ in 0 ..< runs {
                    stepRuns.append(try await container.perform {
                        Unchecked(value: try Self.served($0.model, tokens: tokens, step: step))
                    }.value as! [String: Any])
                }
                Self.say("prompt \(n) served step=\(step) ttft_ms=\(stepRuns.map { $0["ttft_ms"] as! Double })")
                served.append(["step": step, "runs": stepRuns])
            }
            record["served"] = served
            for (key, clear, sections) in [("synced", true, false), ("synced_no_clear", false, false), ("sections", true, true)] {
                record[key] = try await container.perform {
                    Unchecked(value: try Self.synced($0.model, tokens: tokens, step: steps[0], clear: clear, sections: sections))
                }.value
            }
            Self.say("prompt \(n) synced/sections done")
            results.append(record)
            Memory.clearCache()
        }

        let report: [String: Any] = [
            "schema": "prefill-profile-v1",
            "model_dir": directory.path,
            "model_family": capabilities.modelFamily,
            "mlx_swift_lm_revision": KVBuildIdentity.mlxSwiftLMRevision,
            "mlx_cache_limit_mb": mlxCacheLimitMB,
            "load_seconds": loadSeconds,
            "step_sizes": steps,
            "runs": runs,
            "inventory": inventory,
            "prompts": results,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: output), options: [.atomic])
        Self.say("wrote \(output)")
    }

    static func parseList(_ value: String) -> [Int] {
        let items = value.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard items.allSatisfy({ ($0 ?? 0) > 0 }) else { return [] }
        return items.compactMap { $0 }
    }

    /// The chunk lengths `.legacyRemainder(stepSize:)` gives `TokenIterator`
    /// (`LLMModel.prepare` reserves a full step) and the remainder the
    /// iterator's first forward takes.
    static func legacyChunks(total: Int, step: Int) -> (chunks: [Int], remainder: Int) {
        guard total > step else { return ([], total) }
        var chunks: [Int] = []
        var processed = 0
        while total - processed > step {
            chunks.append(step)
            processed += step
        }
        return (chunks, total - processed)
    }

    /// A JSON-shaped value handed out of `ModelContainer.perform` (its result
    /// must be `Sendable`); only this command reads it, on one task.
    private struct Unchecked: @unchecked Sendable { let value: Any }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1e6 }

    private final class Stamps: @unchecked Sendable {
        let lock = NSLock()
        var values: [Double] = []
        let start: UInt64
        init(start: UInt64) { self.start = start }
        func record() {
            lock.lock()
            values.append(PrefillProfileCommand.ms(start, PrefillProfileCommand.now()))
            lock.unlock()
        }
    }

    private static func serveParameters(_ model: any LanguageModel, tokens: Int, step: Int) throws -> GenerateParameters {
        try ModelRuntime.makeServeGenerateParameters(
            model: model, maxTokens: 2, promptTokens: tokens,
            maxContextTokens: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil).maxContextTokens,
            kvBitsOverride: nil, prefillStepSize: step, temperature: 0, topP: 1)
    }

    /// The serve's keyless network serial path to the first token.
    static func served(_ model: any LanguageModel, tokens: [Int32], step: Int) throws -> [String: Any] {
        let parameters = try serveParameters(model, tokens: tokens.count, step: step)
        let cache = try ModelRuntime.serveCache(model: model, baseParameters: parameters, forceSimpleKV: false)
        var iteratorParameters = ModelRuntime.serveIteratorParameters(
            parameters, forceSimpleKV: false, reusedCache: false, cache: cache)
        Stream().synchronize()
        let start = now()
        let stamps = Stamps(start: start)
        iteratorParameters.prefill.progress = { _, _ in stamps.record() }
        var iterator = try TokenIterator(
            input: LMInput(tokens: MLXArray(tokens)), model: model, cache: cache, parameters: iteratorParameters)
        let prepared = now()
        ModelRuntime.clearMLXBufferCacheAfterPrefill()
        let first = iterator.next()
        let firstAt = now()
        Stream().synchronize()
        let (chunks, remainder) = legacyChunks(total: tokens.count, step: step)
        return [
            "step": step, "chunks": chunks.count, "remainder_tokens": remainder,
            "ttft_ms": ms(start, firstAt), "prepare_ms": ms(start, prepared),
            "progress_ms": stamps.values, "first_token": first ?? -1,
        ]
    }

    /// The same chunk boundaries, one synchronized forward at a time.
    static func synced(
        _ model: any LanguageModel, tokens: [Int32], step: Int, clear: Bool, sections: Bool
    ) throws -> [String: Any] {
        let parameters = try serveParameters(model, tokens: tokens.count, step: step)
        let cache = try ModelRuntime.serveCache(model: model, baseParameters: parameters, forceSimpleKV: false)
        let (chunks, remainder) = legacyChunks(total: tokens.count, step: step)
        #if MACPROVIDER_SECTION_TIMING
        let saved = (LabSectionTimer.enabled, LabSectionTimer.emitLines)
        defer { (LabSectionTimer.enabled, LabSectionTimer.emitLines) = saved }
        LabSectionTimer.enabled = sections
        LabSectionTimer.emitLines = false
        _ = LabSectionTimer.drain()
        #else
        if sections { return ["step": step, "section_timing": "unavailable"] }
        #endif
        Stream().synchronize()
        let start = now()
        var offset = 0
        var records: [[String: Any]] = []
        for length in chunks {
            let input = MLXArray(Array(tokens[offset ..< offset + length])).reshaped(1, length)
            let t0 = now()
            _ = model(input, cache: cache)
            eval(cache)
            let t1 = now()
            if clear { Memory.clearCache() }
            let t2 = now()
            var chunk: [String: Any] = ["offset": offset, "tokens": length, "forward_ms": ms(t0, t1), "clear_ms": ms(t1, t2)]
            #if MACPROVIDER_SECTION_TIMING
            if sections { chunk["sections"] = sectionDictionary(LabSectionTimer.drain()) }
            #endif
            records.append(chunk)
            offset += length
        }
        let input = MLXArray(Array(tokens[offset...])).reshaped(1, remainder)
        let t0 = now()
        let logits = model(input, cache: cache)
        let token = argMax(logits[0, -1, 0...], axis: -1)
        eval(token)
        let t1 = now()
        var last: [String: Any] = ["offset": offset, "tokens": remainder, "forward_ms": ms(t0, t1), "first_token": token.item(Int.self)]
        #if MACPROVIDER_SECTION_TIMING
        if sections { last["sections"] = sectionDictionary(LabSectionTimer.drain()) }
        #endif
        return ["step": step, "clear": clear, "section_timing": sections, "chunks": records, "first_forward": last, "total_ms": ms(start, t1)]
    }

    #if MACPROVIDER_SECTION_TIMING
    private static func sectionDictionary(_ totals: [String: [String: LabSectionTimer.Total]]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (_, sections) in totals {
            for (name, total) in sections {
                let previous = out[name] as? [String: Any]
                out[name] = [
                    "calls": (previous?["calls"] as? Int ?? 0) + total.calls,
                    "ms": (previous?["ms"] as? Double ?? 0) + total.ms,
                ]
            }
        }
        return out
    }
    #endif

    /// Every module's own weight-like parameters: path, kind, shape, bits.
    static func inventory(_ model: any LanguageModel) -> [[String: Any]] {
        guard let root = model as? Module else { return [] }
        var entries: [[String: Any]] = []
        for (path, module) in root.namedModules() {
            let own = module.parameters().flattened().filter { !$0.0.contains(".") }
            let bits = (module as? Quantized)?.bits
            let kind = module is SwitchLinear ? "switch" : (module is Embedding ? "embedding" : "linear")
            for (key, array) in own where array.ndim >= 2 && key != "scales" && key != "biases" {
                var entry: [String: Any] = [
                    "path": path.isEmpty ? key : "\(path).\(key)", "kind": key == "weight" ? kind : "raw",
                    "shape": array.shape,
                ]
                if key == "weight", let bits { entry["bits"] = bits }
                entries.append(entry)
            }
        }
        return entries
    }

    private static func say(_ message: String) {
        let gb = { (bytes: Int) in String(format: "%.1f", Double(bytes) / 1e9) }
        FileHandle.standardError.write(Data(
            "prefill-profile: \(message) mlx_active_gb=\(gb(Memory.activeMemory)) mlx_peak_gb=\(gb(Memory.peakMemory))\n".utf8))
    }
}
#endif
