import ArgumentParser
import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore

/// `msb-throughput` — continuous-batching multi-stream decode-throughput harness.
///
/// Produces the FR-CB15 / MSB-01..05 evidence required by
/// `docs/runbooks/continuous-batching-enable-gate.md`. It drives the SPEC-039
/// paged-KV shared-forward backend (`PagedKVSharedForwardBackend`) DIRECTLY over
/// the resident model, exactly as `ContinuousBatchScheduler.runDecodeStep()`
/// does, and measures aggregate decode tokens/sec across `--rows` concurrent
/// rows against BOTH the same engine's single-row baseline AND the production
/// serial decode path (`generate()`, the rate today's serve delivers).
///
/// Why this bypasses the serve path: the buyer-serve gate
/// (`ContinuousBatchingPolicy`) fail-closed-refuses every MoE tuple with
/// `.moePromotionEvidenceUnavailable` UNTIL live MSB-04 evidence exists — so the
/// evidence cannot be gathered through buyer traffic. This harness is the
/// controlled, single-threaded, no-coordinator, no-receipt measurement seam that
/// PRODUCES that evidence. It never joins a coordinator, serves a buyer, emits a
/// receipt, or advertises capacity. Correctness (bit-exact gather + cross-row MoE
/// isolation) is proven separately by `PagedKVParityTests` and the load-time
/// `PagedKVRuntimeParityProbe`; this command measures only throughput.
///
/// TPS semantics (decode-only, TTFT excluded): after prefill, one UNTIMED warm
/// decode step produces the first token (the TTFT-boundary step), then the timed
/// window spans exactly `--decode-tokens` further batched `decode(rows:)` steps.
/// This matches `decode-bench` generation-only semantics so the batched numbers
/// are apples-to-apples with the serial baseline. Aggregate TG is total decoded
/// tokens over the common wall window via `msbAggregateThroughput`.
///
/// Tuple fidelity: paged-KV block size and physical-block budget default to the
/// production `PagedKVConfig` values so the measured tuple matches what an
/// operator would actually enable.
struct MSBThroughputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msb-throughput",
        abstract: "Measure continuous-batching aggregate decode throughput (FR-CB15 / MSB-01..05).",
        discussion: """
            Drives the SPEC-039 paged-KV shared-forward backend directly (no
            coordinator, no buyer traffic, no receipts) and reports aggregate
            decode TG across N concurrent rows vs both the same engine's single-row
            baseline and the production serial decode path. Produces the live
            MSB-04 evidence the buyer-serve MoE gate requires before continuous
            batching can serve real traffic.
            """,
        shouldDisplay: false
    )

    @Option(help: "HuggingFace model ID or local path. Falls back to MACPROVIDER_MODEL.")
    var model: String?

    @Option(
        name: .customLong("rows"),
        help: "Concurrent batch rows (streams). MSB-04=2, MSB-02=4. Default 2."
    )
    var rows: Int = 2

    @Option(
        name: .customLong("prompt-tokens"),
        help: "Prompt tokens per row (distinct prompt per row). Default 1024."
    )
    var promptTokens: Int = 1024

    @Option(
        name: .customLong("decode-tokens"),
        help: "Timed decode tokens generated per row (excludes the untimed TTFT-boundary token). Default 256."
    )
    var decodeTokens: Int = 256

    @Option(help: "Number of timed runs (after a single warmup). Default 5.")
    var runs: Int = 5

    @Option(
        name: .customLong("block-size-tokens"),
        help: "Paged-KV logical block size in tokens. Defaults to the production PagedKVConfig value."
    )
    var blockSizeTokens: Int = PagedKVConfig.defaultBlockSizeTokens

    @Option(
        name: .customLong("max-physical-blocks"),
        help: "Paged-KV physical block pool budget (shared across all rows). Defaults to the production PagedKVConfig value."
    )
    var maxPhysicalBlocks: Int = PagedKVConfig.defaultMaxPhysicalBlocks

    @Flag(name: .customLong("stdout-only"), help: "Print JSON to stdout only; do not write a file.")
    var stdoutOnly: Bool = false

    @Option(help: "Full output path for the JSON result file. Default state/perf/msb-*.json.")
    var output: String?

    @Option(
        name: .customLong("output-dir"),
        help: "Output directory for the auto-named JSON result. Ignored when --output is set. Default 'state/perf'."
    )
    var outputDir: String = "state/perf"

    func run() async throws {
        guard let modelID = model ?? ProcessInfo.processInfo.environment["MACPROVIDER_MODEL"],
              !modelID.isEmpty else {
            FileHandle.standardError.write(Data(
                "msb-throughput: --model is required (or set MACPROVIDER_MODEL)\n".utf8
            ))
            throw ExitCode(2)
        }
        guard rows >= 1, promptTokens >= 2, decodeTokens >= 1, runs >= 1,
              blockSizeTokens >= 1, maxPhysicalBlocks >= 1 else {
            FileHandle.standardError.write(Data(
                "msb-throughput: --rows>=1, --prompt-tokens>=2, --decode-tokens>=1, --runs>=1, --block-size-tokens>=1, --max-physical-blocks>=1 required\n".utf8
            ))
            throw ExitCode(2)
        }

        let runtime = try await ModelRuntime(modelID: modelID)
        guard await runtime.isLoaded else {
            FileHandle.standardError.write(Data("msb-throughput: failed to load model \(modelID)\n".utf8))
            throw ExitCode(1)
        }
        let snapshot = await runtime.currentSnapshot()
        guard let container = snapshot.container else {
            FileHandle.standardError.write(Data("msb-throughput: runtime has no container post-load\n".utf8))
            throw ExitCode(1)
        }

        let layerCount = await container.perform { context in
            context.model.newCache(parameters: nil).count
        }
        guard layerCount > 0 else {
            FileHandle.standardError.write(Data("msb-throughput: model reports zero KV layers\n".utf8))
            throw ExitCode(1)
        }

        // Distinct prompt per row so no cross-row prefix reuse or shared
        // conversation cache can contaminate the aggregate (MSB-02/03/04 require
        // distinct conversation identity). Each prompt is exactly `promptTokens`.
        let batchedPrompts = try await buildDistinctPrompts(
            container: container, count: rows, tokens: promptTokens
        )
        let baselinePrompt = try await buildDistinctPrompts(
            container: container, count: 1, tokens: promptTokens
        )[0]

        var peakRSSMB = memoryRSSMB()

        // Production serial single-stream baseline (today's serve decode path:
        // `generate()` over contiguous KVCacheSimple). This is the rate the box
        // delivers today, and the denominator that decides whether continuous
        // batching is a throughput win. It decodes from the SAME exact prompt
        // token array as a batched row (identical length and content) so the
        // `aggregateVsProductionSerial` ratio is token-comparable, not skewed by
        // a different prompt length.
        var serialRunTPS: [Double] = []
        _ = try await runProductionSerialOnce(
            container: container, promptTokens: baselinePrompt, timedDecodeTokens: decodeTokens
        ) // warmup
        for _ in 0..<runs {
            let tps = try await runProductionSerialOnce(
                container: container, promptTokens: baselinePrompt, timedDecodeTokens: decodeTokens
            )
            serialRunTPS.append(tps)
            peakRSSMB = max(peakRSSMB, memoryRSSMB())
        }

        // Single-row baseline through the SAME paged backend (state-carrying
        // single-row path): isolates the batching effect from the paging tax.
        var pagedSingleRowTPS: [Double] = []
        _ = try await runBatchedDecode(
            container: container, prompts: [baselinePrompt], decodeSteps: decodeTokens
        ) // warmup
        for _ in 0..<runs {
            let r = try await runBatchedDecode(
                container: container, prompts: [baselinePrompt], decodeSteps: decodeTokens
            )
            try assertHealthy(r, expectedRows: 1, expectedTokens: decodeTokens, label: "paged-single-row")
            pagedSingleRowTPS.append(r.perRowTokensPerSecond)
            peakRSSMB = max(peakRSSMB, memoryRSSMB())
        }

        // Batched N-row aggregate throughput.
        var aggregateRunTPS: [Double] = []
        var perRowRunTPS: [Double] = []
        _ = try await runBatchedDecode(
            container: container, prompts: batchedPrompts, decodeSteps: decodeTokens
        ) // warmup
        for _ in 0..<runs {
            let r = try await runBatchedDecode(
                container: container, prompts: batchedPrompts, decodeSteps: decodeTokens
            )
            try assertHealthy(r, expectedRows: rows, expectedTokens: decodeTokens, label: "batched")
            let report = try msbAggregateThroughput(r.rowSamples)
            aggregateRunTPS.append(report.aggregateTokensPerSecond)
            perRowRunTPS.append(r.perRowTokensPerSecond)
            peakRSSMB = max(peakRSSMB, memoryRSSMB())
        }

        let serialP50 = decodeBenchPercentileTPS(serialRunTPS, p: 0.5)
        let pagedSingleP50 = decodeBenchPercentileTPS(pagedSingleRowTPS, p: 0.5)
        let aggregateP50 = decodeBenchPercentileTPS(aggregateRunTPS, p: 0.5)
        let perRowP50 = decodeBenchPercentileTPS(perRowRunTPS, p: 0.5)
        let upliftVsPaged = pagedSingleP50 > 0 ? aggregateP50 / pagedSingleP50 : 0
        let aggregateVsSerial = serialP50 > 0 ? aggregateP50 / serialP50 : 0
        let perRowFraction = pagedSingleP50 > 0 ? perRowP50 / pagedSingleP50 : 0

        let modelTag = modelID.split(separator: "/").last.map(String.init) ?? "model"
        let report = MSBThroughputReport(
            schemaVersion: 2,
            modelID: modelID,
            modelTag: modelTag,
            mlxSwiftLMPin: decodeBenchMLXPinTag(),
            rows: rows,
            promptTokensPerRow: promptTokens,
            decodeTokensPerRow: decodeTokens,
            productionSerialPromptTokens: baselinePrompt.count,
            layerCount: layerCount,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            runs: runs,
            productionSerialTPSRuns: serialRunTPS,
            productionSerialTPSp50: serialP50,
            productionSerialCVPct: coefficientOfVariationPct(serialRunTPS),
            pagedSingleRowTPSRuns: pagedSingleRowTPS,
            pagedSingleRowTPSp50: pagedSingleP50,
            pagedSingleRowCVPct: coefficientOfVariationPct(pagedSingleRowTPS),
            aggregateTPSRuns: aggregateRunTPS,
            aggregateTPSp50: aggregateP50,
            aggregateCVPct: coefficientOfVariationPct(aggregateRunTPS),
            perRowTPSp50: perRowP50,
            aggregateUpliftVsPagedSingleRow: upliftVsPaged,
            aggregateVsProductionSerial: aggregateVsSerial,
            perRowFractionOfPagedSingleRow: perRowFraction,
            peakRSSMB: peakRSSMB,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))

        FileHandle.standardError.write(Data((
            "msb-throughput: model=\(modelTag) rows=\(rows) block=\(blockSizeTokens) " +
            "serial_tps_p50=\(decodeBenchFormatTPS(serialP50)) " +
            "paged_1row_tps_p50=\(decodeBenchFormatTPS(pagedSingleP50)) " +
            "aggregate_tps_p50=\(decodeBenchFormatTPS(aggregateP50)) " +
            "uplift_vs_paged=\(String(format: "%.2fx", upliftVsPaged)) " +
            "aggregate_vs_serial=\(String(format: "%.2fx", aggregateVsSerial)) " +
            "peak_rss_mb=\(peakRSSMB)\n"
        ).utf8))

        guard !stdoutOnly else { return }
        let fileURL: URL
        if let explicitPath = output {
            fileURL = URL(fileURLWithPath: explicitPath)
            let parent = fileURL.deletingLastPathComponent()
            if parent.path != "/" {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
        } else {
            let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tsFormatter = ISO8601DateFormatter()
            tsFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
            let ts = tsFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let safeModelTag = decodeBenchSanitizeFilenameComponent(modelTag)
            fileURL = dir.appendingPathComponent("msb-\(rows)row-\(safeModelTag)-\(ts).json")
        }
        try json.write(to: fileURL, options: [.atomic])
        FileHandle.standardError.write(Data("msb-throughput: wrote \(fileURL.path)\n".utf8))
    }

    // MARK: - Batched decode driver

    /// Result of one batched decode run over N rows (timed window only).
    private struct BatchedRunResult {
        let rowSamples: [MSBAggregateThroughputInput]
        let decodeStart: Date
        let decodeEnd: Date

        /// Per-row decode TPS. All rows decode in lockstep (one token per row per
        /// batched step), so every row shares the same wall window.
        var perRowTokensPerSecond: Double {
            let wall = max(decodeEnd.timeIntervalSince(decodeStart), 0.000_001)
            let perRow = rowSamples.map(\.decodedTokens).max() ?? 0
            return Double(perRow) / wall
        }
    }

    /// Per-row mutable decode state, mirroring `ContinuousBatchScheduler.Row`.
    private struct DecodeRow {
        let id: String
        let prompt: [Int]
        let handle: PagedKVBlockTableHandle
        var generated: [Int] = []
        var currentToken: Int
    }

    /// Drive `PagedKVSharedForwardBackend.prefill` + a decode loop over
    /// `prompts.count` rows, mirroring `ContinuousBatchScheduler.runDecodeStep`
    /// bookkeeping exactly. Prefill (untimed) commits each prompt minus its last
    /// token. One untimed warm decode step then writes the final prompt token and
    /// produces the first (TTFT-boundary) token. The timed window spans exactly
    /// `decodeSteps` further steps, so the reported rate is decode-only.
    private func runBatchedDecode(
        container: ModelContainer,
        prompts: [[Int]],
        decodeSteps: Int
    ) async throws -> BatchedRunResult {
        let layers = await container.perform { $0.model.newCache(parameters: nil).count }
        let backend = PagedKVSharedForwardBackend(
            container: container,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1,
            layerCount: layers
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks
        )

        var rowsState: [DecodeRow] = []
        rowsState.reserveCapacity(prompts.count)
        var prefillInputs: [ContinuousBatchPrefillInput] = []
        for (index, prompt) in prompts.enumerated() {
            let id = "msb-row-\(index)"
            let promptLength = prompt.count
            let prefixLength = promptLength - 1
            let handle = try await allocator.allocate(
                conversationKey: id,
                maxTokens: promptLength + decodeSteps + 1,
                initialTokens: 0
            )
            if prefixLength > 0 {
                _ = try await allocator.extend(handle, by: prefixLength)
            }
            let prefillBinding = try await allocator.binding(for: handle)
            prefillInputs.append(ContinuousBatchPrefillInput(
                requestID: id,
                promptTokens: Array(prompt.prefix(prefixLength)),
                binding: prefillBinding,
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: prefixLength,
                isFinalChunk: true
            ))
            rowsState.append(DecodeRow(
                id: id, prompt: prompt, handle: handle, currentToken: prompt[promptLength - 1]
            ))
        }

        _ = try await backend.prefill(rows: prefillInputs)

        // One untimed warm decode step: writes the final prompt token and produces
        // the first generated token (the TTFT boundary decode-bench excludes).
        try await decodeOneStep(backend: backend, allocator: allocator, rows: &rowsState)

        let decodeStart = Date()
        for _ in 0..<decodeSteps {
            try await decodeOneStep(backend: backend, allocator: allocator, rows: &rowsState)
        }
        let decodeEnd = Date()

        // Timed tokens per row = the steps in the timed window (generated.count
        // minus the one untimed warm token). All rows share the lockstep window.
        let samples = rowsState.map {
            MSBAggregateThroughputInput(
                decodedTokens: max($0.generated.count - 1, 0),
                decodeStartedAt: decodeStart,
                decodeEndedAt: decodeEnd
            )
        }
        return BatchedRunResult(rowSamples: samples, decodeStart: decodeStart, decodeEnd: decodeEnd)
    }

    /// One batched `decode(rows:)` step across all rows, with the exact
    /// per-step allocator bookkeeping the scheduler uses. Fails fast on any
    /// row failure (the harness measures only healthy batched decode).
    private func decodeOneStep(
        backend: PagedKVSharedForwardBackend,
        allocator: PagedKVBlockAllocator,
        rows rowsState: inout [DecodeRow]
    ) async throws {
        var decodeInputs: [ContinuousBatchDecodeInput] = []
        decodeInputs.reserveCapacity(rowsState.count)
        for row in rowsState {
            let committed = row.prompt.count - 1 + row.generated.count
            let target = committed + 1
            _ = try await allocator.extend(row.handle, by: 1)
            try await allocator.beginDecodeStep(row.handle)
            let binding = try await allocator.binding(for: row.handle)
            decodeInputs.append(ContinuousBatchDecodeInput(
                requestID: row.id,
                currentToken: row.currentToken,
                generatedTokens: row.generated,
                promptTokens: row.prompt,
                samplerSeed: 0,
                temperature: 0,
                topP: 1,
                presencePenalty: 0,
                frequencyPenalty: 0,
                binding: binding,
                blockTable: binding.currentTable,
                committedKVTokenCount: committed,
                targetKVTokenCount: target,
                samplerStep: row.generated.count
            ))
        }
        let outcomes = try await backend.decode(rows: decodeInputs)
        for row in rowsState { try await allocator.endDecodeStep(row.handle) }

        var tokenByID: [String: Int] = [:]
        for outcome in outcomes {
            switch outcome {
            case .output(let output): tokenByID[output.requestID] = output.token
            case .rowFailure(let requestID):
                FileHandle.standardError.write(Data(
                    "msb-throughput: row \(requestID) failed in shared-forward decode\n".utf8
                ))
                throw ExitCode(1)
            }
        }
        for index in rowsState.indices {
            guard let token = tokenByID[rowsState[index].id] else {
                FileHandle.standardError.write(Data(
                    "msb-throughput: row \(rowsState[index].id) missing decode output\n".utf8
                ))
                throw ExitCode(1)
            }
            rowsState[index].generated.append(token)
            rowsState[index].currentToken = token
        }
    }

    private func assertHealthy(
        _ result: BatchedRunResult,
        expectedRows: Int,
        expectedTokens: Int,
        label: String
    ) throws {
        guard result.rowSamples.count == expectedRows,
              result.rowSamples.allSatisfy({ $0.decodedTokens == expectedTokens }) else {
            FileHandle.standardError.write(Data((
                "msb-throughput: \(label) run produced incomplete token counts " +
                "(expected \(expectedRows) rows x \(expectedTokens) tokens)\n"
            ).utf8))
            throw ExitCode(1)
        }
    }

    // MARK: - Production serial baseline

    /// One production serial single-stream decode via the `generate()` path
    /// (contiguous KVCacheSimple) — the decode rate today's serve delivers.
    /// Generation-only TPS (excludes TTFT), mirroring `DecodeBenchCommand.runOnce`.
    /// Decodes from the exact `promptTokens` array (same as a batched row) and
    /// requests `timedDecodeTokens + 1` so the first (TTFT-boundary) token is
    /// excluded and exactly `timedDecodeTokens` tokens fall inside the timed
    /// window — matching the batched path's token convention.
    private func runProductionSerialOnce(
        container: ModelContainer,
        promptTokens: [Int],
        timedDecodeTokens: Int
    ) async throws -> Double {
        let prefillStart = Date()
        nonisolated(unsafe) var firstTokenAt: Date? = nil
        var generationTokens = 0
        try await container.perform { context in
            let lmInput = LMInput(tokens: MLXArray(promptTokens.map { Int32($0) }))
            let parameters = GenerateParameters(maxTokens: timedDecodeTokens + 1, temperature: 0.0, topP: 1.0)
            let result: GenerateResult = try generate(
                input: lmInput, parameters: parameters, context: context
            ) { tokens in
                if firstTokenAt == nil, !tokens.isEmpty { firstTokenAt = Date() }
                return GenerateDisposition.more
            }
            generationTokens = result.generationTokenCount
        }
        let endAt = Date()
        let prefillEnd = firstTokenAt ?? endAt
        let decodeElapsed = max(endAt.timeIntervalSince(prefillEnd), 0.001)
        return Double(max(generationTokens - 1, 0)) / decodeElapsed
    }

    // MARK: - Prompt construction

    /// Build `count` distinct prompts, each exactly `tokens` tokens. Each prompt
    /// draws from a distinct topical corpus entry so no two rows share a reusable
    /// prefix and their MoE expert routing / greedy continuations differ.
    private func buildDistinctPrompts(
        container: ModelContainer,
        count: Int,
        tokens: Int
    ) async throws -> [[Int]] {
        return try await container.perform { context in
            var prompts: [[Int]] = []
            prompts.reserveCapacity(count)
            for index in 0..<count {
                let text = buildPromptText(index: index, targetTokens: tokens)
                var encoded = context.tokenizer.encode(text: text, addSpecialTokens: true)
                // Extend deterministically if the corpus text under-shot the target.
                var salt = 0
                while encoded.count < tokens {
                    let more = context.tokenizer.encode(
                        text: " \(index)-\(salt) " + Self.corpus[(index + salt) % Self.corpus.count],
                        addSpecialTokens: false
                    )
                    encoded.append(contentsOf: more)
                    salt += 1
                }
                prompts.append(Array(encoded.prefix(tokens)))
            }
            return prompts
        }
    }

    /// A distinct, topically-varied prompt string seeded by `index`, long enough
    /// to tokenize past `targetTokens`.
    private func buildPromptText(index: Int, targetTokens: Int) -> String {
        var text = "Document \(index) revision \(index * 7 + 3): "
        var salt = 0
        // Roughly 1 token per ~0.75 words; over-generate then the caller truncates.
        while text.count < targetTokens * 5 {
            text += Self.corpus[(index + salt) % Self.corpus.count] + " "
            salt += 1
        }
        return text
    }

    /// Distinct topical paragraphs so concurrent rows exercise different MoE
    /// expert routing rather than a shared repeated filler.
    private static let corpus: [String] = [
        "The distributed ledger reconciled every settlement receipt against the coordinator's canonical usage log before payout.",
        "Photosynthesis converts sunlight, water, and carbon dioxide into glucose while releasing oxygen through the stomata of leaves.",
        "The compiler lowered the intermediate representation into register-allocated machine code and scheduled the instructions for the pipeline.",
        "Ocean currents redistribute heat across latitudes, moderating coastal climates and driving the migration patterns of marine species.",
        "The orchestra tuned to the oboe's concert A before the conductor raised the baton for the symphony's turbulent opening movement.",
        "Continuous batching interleaves many decode streams through a shared forward pass while paging the key-value cache across physical blocks.",
        "The archaeologists catalogued each potsherd by stratigraphic layer, reconstructing the trade routes of the ancient river settlement.",
        "Gradient descent iteratively nudged the weights along the steepest downhill direction until the validation loss stopped improving.",
    ]

    // MARK: - Stats

    private func coefficientOfVariationPct(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return (variance.squareRoot() / mean) * 100.0
    }

    private func memoryRSSMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return max(0, Int(info.resident_size / 1_048_576))
    }
}

// MARK: - Wire schema

struct MSBThroughputReport: Codable, Sendable {
    let schemaVersion: Int
    let modelID: String
    let modelTag: String
    let mlxSwiftLMPin: String
    let rows: Int
    let promptTokensPerRow: Int
    let decodeTokensPerRow: Int
    let productionSerialPromptTokens: Int
    let layerCount: Int
    let blockSizeTokens: Int
    let maxPhysicalBlocks: Int
    let runs: Int
    let productionSerialTPSRuns: [Double]
    let productionSerialTPSp50: Double
    let productionSerialCVPct: Double
    let pagedSingleRowTPSRuns: [Double]
    let pagedSingleRowTPSp50: Double
    let pagedSingleRowCVPct: Double
    let aggregateTPSRuns: [Double]
    let aggregateTPSp50: Double
    let aggregateCVPct: Double
    let perRowTPSp50: Double
    let aggregateUpliftVsPagedSingleRow: Double
    let aggregateVsProductionSerial: Double
    let perRowFractionOfPagedSingleRow: Double
    let peakRSSMB: Int
    let timestamp: String
}
