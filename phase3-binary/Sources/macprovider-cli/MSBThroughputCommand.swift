import ArgumentParser
import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// `msb-throughput` — continuous-batching multi-stream decode-throughput harness.
///
/// Produces the FR-CB15 / MSB-01..05 evidence required by
/// `docs/runbooks/continuous-batching-enable-gate.md`. It drives the SPEC-039
/// paged-KV shared-forward backend (`PagedKVSharedForwardBackend`) DIRECTLY over
/// the resident model, exactly as `ContinuousBatchScheduler.runDecodeStep()`
/// does, and measures aggregate decode tokens/sec across `--rows` concurrent
/// rows against the SAME engine's single-row baseline.
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
/// TPS semantics (decode-only): the clock starts AFTER prefill and spans every
/// batched `decode(rows:)` step (each step advances all rows by one token), so
/// the denominator excludes TTFT/prefill, matching `decode-bench` generation-only
/// semantics. Aggregate TG is total decoded tokens over the common wall window
/// via `msbAggregateThroughput`.
struct MSBThroughputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msb-throughput",
        abstract: "Measure continuous-batching aggregate decode throughput (FR-CB15 / MSB-01..05).",
        discussion: """
            Drives the SPEC-039 paged-KV shared-forward backend directly (no
            coordinator, no buyer traffic, no receipts) and reports aggregate
            decode TG across N concurrent rows vs the same engine's single-row
            baseline. Produces the live MSB-04 evidence the buyer-serve MoE gate
            requires before continuous batching can serve real traffic.
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
        help: "Decode tokens generated per row. Default 256."
    )
    var decodeTokens: Int = 256

    @Option(help: "Number of timed runs (after a single warmup). Default 5.")
    var runs: Int = 5

    @Option(
        name: .customLong("block-size-tokens"),
        help: "Paged-KV logical block size in tokens. Default 256."
    )
    var blockSizeTokens: Int = 256

    @Option(
        name: .customLong("max-physical-blocks"),
        help: "Paged-KV physical block pool budget (shared across all rows). Default 1024."
    )
    var maxPhysicalBlocks: Int = 1024

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

        // Single-row baseline through the SAME backend (state-carrying single-row
        // path): isolates the batching effect from any engine/path difference.
        var baselineRunTPS: [Double] = []
        _ = try await runBatchedDecode(
            container: container, prompts: [baselinePrompt], decodeSteps: decodeTokens
        ) // warmup
        var peakRSSMB = memoryRSSMB()
        for _ in 0..<runs {
            let r = try await runBatchedDecode(
                container: container, prompts: [baselinePrompt], decodeSteps: decodeTokens
            )
            try assertHealthy(r, expectedRows: 1, expectedTokens: decodeTokens, label: "baseline")
            baselineRunTPS.append(r.perRowTokensPerSecond)
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

        let baselineP50 = decodeBenchPercentileTPS(baselineRunTPS, p: 0.5)
        let aggregateP50 = decodeBenchPercentileTPS(aggregateRunTPS, p: 0.5)
        let perRowP50 = decodeBenchPercentileTPS(perRowRunTPS, p: 0.5)
        let uplift = baselineP50 > 0 ? aggregateP50 / baselineP50 : 0
        let perRowFraction = baselineP50 > 0 ? perRowP50 / baselineP50 : 0
        let aggregateCVPct = coefficientOfVariationPct(aggregateRunTPS)
        let baselineCVPct = coefficientOfVariationPct(baselineRunTPS)

        let modelTag = modelID.split(separator: "/").last.map(String.init) ?? "model"
        let report = MSBThroughputReport(
            schemaVersion: 1,
            modelID: modelID,
            modelTag: modelTag,
            mlxSwiftLMPin: decodeBenchMLXPinTag(),
            rows: rows,
            promptTokensPerRow: promptTokens,
            decodeTokensPerRow: decodeTokens,
            layerCount: layerCount,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            runs: runs,
            baselineSingleRowTPSRuns: baselineRunTPS,
            baselineSingleRowTPSp50: baselineP50,
            baselineSingleRowCVPct: baselineCVPct,
            aggregateTPSRuns: aggregateRunTPS,
            aggregateTPSp50: aggregateP50,
            aggregateCVPct: aggregateCVPct,
            perRowTPSp50: perRowP50,
            aggregateUpliftVsBaseline: uplift,
            perRowFractionOfBaseline: perRowFraction,
            peakRSSMB: peakRSSMB,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))

        FileHandle.standardError.write(Data((
            "msb-throughput: model=\(modelTag) rows=\(rows) " +
            "baseline_tps_p50=\(decodeBenchFormatTPS(baselineP50)) " +
            "aggregate_tps_p50=\(decodeBenchFormatTPS(aggregateP50)) " +
            "uplift=\(String(format: "%.2fx", uplift)) " +
            "per_row_frac=\(String(format: "%.2f", perRowFraction)) " +
            "peak_rss_mb=\(peakRSSMB) agg_cv_pct=\(String(format: "%.1f", aggregateCVPct))\n"
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

    /// Result of one batched decode run over N rows.
    private struct BatchedRunResult {
        let rowSamples: [MSBAggregateThroughputInput]
        let rowFailures: Int
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

    /// Drive `PagedKVSharedForwardBackend.prefill` + a K-step `decode(rows:)` loop
    /// over `prompts.count` rows, mirroring `ContinuousBatchScheduler.runDecodeStep`
    /// bookkeeping exactly. Prefill (excluded from timing) commits each prompt minus
    /// its last token; the K timed decode steps write the final prompt token and then
    /// generate K-1 further tokens — K tokens counted per row, TTFT excluded.
    private func runBatchedDecode(
        container: ModelContainer,
        prompts: [[Int]],
        decodeSteps: Int
    ) async throws -> BatchedRunResult {
        let backend = PagedKVSharedForwardBackend(
            container: container,
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1,
            layerCount: await container.perform { $0.model.newCache(parameters: nil).count }
        )
        let allocator = try PagedKVBlockAllocator(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks
        )

        struct RowContext {
            let id: String
            let prompt: [Int]
            let handle: PagedKVBlockTableHandle
            var generated: [Int] = []
            var currentToken: Int
        }

        var rowContexts: [RowContext] = []
        rowContexts.reserveCapacity(prompts.count)
        var prefillInputs: [ContinuousBatchPrefillInput] = []
        for (index, prompt) in prompts.enumerated() {
            let id = "msb-row-\(index)"
            let promptLength = prompt.count
            let prefixLength = promptLength - 1
            let handle = try await allocator.allocate(
                conversationKey: id,
                maxTokens: promptLength + decodeSteps,
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
            rowContexts.append(RowContext(
                id: id, prompt: prompt, handle: handle, currentToken: prompt[promptLength - 1]
            ))
        }

        _ = try await backend.prefill(rows: prefillInputs)

        var rowFailures = 0
        let decodeStart = Date()
        for _ in 0..<decodeSteps {
            var decodeInputs: [ContinuousBatchDecodeInput] = []
            decodeInputs.reserveCapacity(rowContexts.count)
            for row in rowContexts {
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
            for row in rowContexts { try await allocator.endDecodeStep(row.handle) }

            var tokenByID: [String: Int] = [:]
            for outcome in outcomes {
                switch outcome {
                case .output(let output): tokenByID[output.requestID] = output.token
                case .rowFailure: rowFailures += 1
                }
            }
            for index in rowContexts.indices {
                guard let token = tokenByID[rowContexts[index].id] else { continue }
                rowContexts[index].generated.append(token)
                rowContexts[index].currentToken = token
            }
        }
        let decodeEnd = Date()

        // All rows share the lockstep wall window; per-row token counts are the
        // decoded lengths. `msbAggregateThroughput` unions the windows.
        let samples = rowContexts.map {
            MSBAggregateThroughputInput(
                decodedTokens: $0.generated.count,
                decodeStartedAt: decodeStart,
                decodeEndedAt: decodeEnd
            )
        }
        return BatchedRunResult(
            rowSamples: samples,
            rowFailures: rowFailures,
            decodeStart: decodeStart,
            decodeEnd: decodeEnd
        )
    }

    private func assertHealthy(
        _ result: BatchedRunResult,
        expectedRows: Int,
        expectedTokens: Int,
        label: String
    ) throws {
        guard result.rowFailures == 0 else {
            FileHandle.standardError.write(Data(
                "msb-throughput: \(label) run had \(result.rowFailures) row failure(s)\n".utf8
            ))
            throw ExitCode(1)
        }
        guard result.rowSamples.count == expectedRows,
              result.rowSamples.allSatisfy({ $0.decodedTokens == expectedTokens }) else {
            FileHandle.standardError.write(Data((
                "msb-throughput: \(label) run produced incomplete token counts " +
                "(expected \(expectedRows) rows x \(expectedTokens) tokens)\n"
            ).utf8))
            throw ExitCode(1)
        }
    }

    // MARK: - Prompt construction

    /// Build `count` distinct prompts, each exactly `tokens` tokens. Each prompt is
    /// seeded with a distinct integer prefix so no two rows share a reusable prefix
    /// and their greedy continuations differ.
    private func buildDistinctPrompts(
        container: ModelContainer,
        count: Int,
        tokens: Int
    ) async throws -> [[Int]] {
        let filler = "The quick brown fox jumps over the lazy dog near the riverbank while the sun sets slowly. "
        return try await container.perform { context in
            var prompts: [[Int]] = []
            prompts.reserveCapacity(count)
            for index in 0..<count {
                let seed = "Document \(index) revision \(index * 7 + 3): "
                var text = seed
                while true {
                    let encoded = context.tokenizer.encode(text: text, addSpecialTokens: true)
                    if encoded.count >= tokens {
                        prompts.append(Array(encoded.prefix(tokens)))
                        break
                    }
                    text += filler
                }
            }
            return prompts
        }
    }

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
    let layerCount: Int
    let blockSizeTokens: Int
    let maxPhysicalBlocks: Int
    let runs: Int
    let baselineSingleRowTPSRuns: [Double]
    let baselineSingleRowTPSp50: Double
    let baselineSingleRowCVPct: Double
    let aggregateTPSRuns: [Double]
    let aggregateTPSp50: Double
    let aggregateCVPct: Double
    let perRowTPSp50: Double
    let aggregateUpliftVsBaseline: Double
    let perRowFractionOfBaseline: Double
    let peakRSSMB: Int
    let timestamp: String
}
