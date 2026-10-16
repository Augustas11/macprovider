import ArgumentParser
import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// `glm-parity` — lab-only greedy parity against a reference oracle (epic #2029, T3).
///
/// Loads the artifact through `ModelRuntime` (the serve load path), prefills
/// the oracle's prompt token ids in `--prefill-step-size` chunks the way the
/// reference lane did (`scripts/lab/cb-studio/glm53_bench_vlm.py`, 2048), then
/// greedy-decodes `--steps` tokens. The free-running pass is timed with the
/// iterator's pipelining (`asyncEval` of the next token before reading the
/// current one), so the same run reports native single-stream decode tok/s.
/// When it leaves the oracle, a teacher-forced pass on a copy of the
/// post-prefill cache feeds the oracle's tokens and reports per-step top-1
/// agreement and logit error against the same history the oracle saw.
///
/// The oracle is the JSON that `scripts/lab/cb-studio/glm53_oracle_json.py`
/// writes from the reference `.npz`.
struct GLMParityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "glm-parity",
        abstract: "Greedy-decode parity against a reference oracle (lab only).",
        shouldDisplay: false
    )

    @Option(name: .customLong("model-dir"), help: "Local model directory.")
    var modelDir: String

    @Option(help: "Oracle JSON from scripts/lab/cb-studio/glm53_oracle_json.py. Repeat to run several contexts on one load.")
    var oracle: [String]

    @Option(help: "Greedy tokens to decode and compare (at most the oracle's). Default 256.")
    var steps: Int = 256

    @Option(
        name: .customLong("prefill-step-size"),
        help: "Prompt chunk size. Default 2048, the reference lane's chunk."
    )
    var prefillStepSize: Int = 2048

    @Option(help: "Full output path for the JSON result. Default: stdout only.")
    var output: String?

    func run() async throws {
        guard steps > 0, prefillStepSize > 0, !oracle.isEmpty else {
            FileHandle.standardError.write(Data(
                "glm-parity: --oracle is required; --steps and --prefill-step-size must be > 0\n".utf8
            ))
            throw ExitCode(2)
        }
        // Read and validate every oracle before the (long) model load.
        let references = try oracle.map { path -> (GLMParityOracle, Data) in
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let reference = try JSONDecoder().decode(GLMParityOracle.self, from: data)
            try reference.validate()
            return (reference, data)
        }

        let directory = try ModelRuntime.localModelDirectory(for: modelDir)
        let configData = try? Data(contentsOf: directory.appendingPathComponent("config.json"))
        let capabilities = ModelRuntime.pagedKVModelCapabilities(modelID: modelDir, configJSONData: configData)

        let loadStarted = Date()
        let runtime = try await ModelRuntime(modelID: modelDir)
        guard await runtime.isLoaded, let container = await runtime.currentSnapshot().container else {
            FileHandle.standardError.write(Data("glm-parity: failed to load \(modelDir)\n".utf8))
            throw ExitCode(1)
        }
        let loadSeconds = Date().timeIntervalSince(loadStarted)

        var runs: [GLMParityRun] = []
        for (reference, data) in references {
            let measured = try await Self.measure(
                container: container, reference: reference, steps: steps, prefillStepSize: prefillStepSize)
            runs.append(GLMParityRun(
                oracleSource: reference.source,
                oracleSourceSHA256: reference.sourceSHA256,
                oracleJSONSHA256: Self.sha256Hex(data),
                promptTokenSHA256: msbPromptTokenSHA256(reference.prompt),
                // Same digest as the reference lane's `prompt_sha256` (int32 little-endian).
                promptInt32SHA256: Self.sha256Hex(reference.prompt.withUnsafeInt32LittleEndianBytes()),
                measurement: measured
            ))
            FileHandle.standardError.write(Data(Self.summaryLine(source: reference.source, measured).utf8))
            Memory.clearCache()
        }

        let report = GLMParityReport(
            schema: "glm-parity-v1",
            modelDir: directory.path,
            modelFamily: capabilities.modelFamily,
            pagedKVFamilyRecognized: PagedKVAttachGate.recognizedModelFamilies.contains(capabilities.modelFamily),
            requiresMoEDispatch: capabilities.requiresMoEDispatch,
            mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
            mlxSwiftRevision: KVBuildIdentity.mlxSwiftRevision,
            prefillStepSize: prefillStepSize,
            stepsRequested: steps,
            loadSeconds: loadSeconds,
            runs: runs,
            peakPhysFootprintMB: msbLifetimePeakPhysFootprintMB(pid: getpid()),
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if let output {
            try json.write(to: URL(fileURLWithPath: output), options: [.atomic])
        }
    }

    private static func measure(
        container: ModelContainer,
        reference: GLMParityOracle,
        steps: Int,
        prefillStepSize stepSize: Int
    ) async throws -> GLMParityMeasurement {
        let decodeSteps = min(steps, reference.greedy.count)
        let promptTokens = reference.prompt
        let logitSteps = min(reference.topIdx.count, decodeSteps)
        return try await container.perform { context -> GLMParityMeasurement in
            let model = context.model
            let cache = try model.newCache(parameters: nil)
            Stream().synchronize()
            Memory.peakMemory = 0

            // Prefill exactly as the reference lane: full chunks, last chunk
            // included, logits of the final prompt position.
            let prefillStarted = Date()
            var lastLogits: MLXArray?
            var start = 0
            while start < promptTokens.count {
                let end = min(start + stepSize, promptTokens.count)
                let chunk = MLXArray(promptTokens[start ..< end].map(Int32.init)).reshaped([1, end - start])
                let logits = model(chunk, cache: cache)[0, -1, 0...].asType(.float32)
                eval(logits)
                lastLogits = logits
                start = end
            }
            guard let prefillLogits = lastLogits else { throw GLMParityError.emptyPrompt }
            let prefillSeconds = Date().timeIntervalSince(prefillStarted)
            let prefillPeak = Memory.peakMemory
            let forcedCache = cache.map { $0.copy() }

            // Free-running greedy decode, pipelined like `TokenIterator`.
            func gathered(_ logits: MLXArray, step: Int) -> MLXArray? {
                guard step < logitSteps else { return nil }
                return take(logits, MLXArray(reference.topIdx[step].map(Int32.init)))
            }
            var tokens: [Int] = []
            var freeLogits: [[Float]] = []
            var pendingToken = argMax(prefillLogits, axis: -1)
            var pendingGathered = gathered(prefillLogits, step: 0)
            asyncEval([pendingToken] + (pendingGathered.map { [$0] } ?? []))
            let decodeStarted = Date()
            var firstTokenAt = decodeStarted
            for step in 0 ..< decodeSteps {
                var nextToken: MLXArray?
                var nextGathered: MLXArray?
                if step + 1 < decodeSteps {
                    let logits = model(pendingToken.reshaped([1, 1]), cache: cache)[0, -1, 0...].asType(.float32)
                    let token = argMax(logits, axis: -1)
                    nextToken = token
                    nextGathered = gathered(logits, step: step + 1)
                    asyncEval([token] + (nextGathered.map { [$0] } ?? []))
                }
                tokens.append(pendingToken.item(Int.self))
                if let pendingGathered { freeLogits.append(pendingGathered.asArray(Float.self)) }
                if step == 0 { firstTokenAt = Date() }
                guard let nextToken else { break }
                pendingToken = nextToken
                pendingGathered = nextGathered
            }
            Stream().synchronize()
            let decodeEnded = Date()
            let decodePeak = Memory.peakMemory

            let freeComparison = GLMParityComparison(
                oracleGreedy: Array(reference.greedy.prefix(decodeSteps)),
                oracleTopIdx: Array(reference.topIdx.prefix(logitSteps)),
                oracleTopLogit: Array(reference.topLogit.prefix(logitSteps)),
                tokens: tokens,
                argmaxTokens: tokens,
                gatheredLogits: freeLogits
            )

            // Teacher-forced pass: only needed when the free run left the
            // oracle; until then both see the same history.
            var forced: GLMParityComparison?
            if freeComparison.firstDivergence != nil {
                var forcedTops = [argMax(prefillLogits, axis: -1).item(Int.self)]
                var forcedLogits: [[Float]] = gathered(prefillLogits, step: 0).map { [$0.asArray(Float.self)] } ?? []
                for step in 1 ..< decodeSteps {
                    let fed = MLXArray([Int32(reference.greedy[step - 1])]).reshaped([1, 1])
                    let logits = model(fed, cache: forcedCache)[0, -1, 0...].asType(.float32)
                    let top = argMax(logits, axis: -1)
                    if let values = gathered(logits, step: step) {
                        eval(top, values)
                        forcedLogits.append(values.asArray(Float.self))
                    } else {
                        eval(top)
                    }
                    forcedTops.append(top.item(Int.self))
                }
                forced = GLMParityComparison(
                    oracleGreedy: Array(reference.greedy.prefix(decodeSteps)),
                    oracleTopIdx: Array(reference.topIdx.prefix(logitSteps)),
                    oracleTopLogit: Array(reference.topLogit.prefix(logitSteps)),
                    tokens: forcedTops,
                    argmaxTokens: forcedTops,
                    gatheredLogits: forcedLogits
                )
            }

            let decodeSeconds = decodeEnded.timeIntervalSince(firstTokenAt)
            return GLMParityMeasurement(
                promptTokens: promptTokens.count,
                decodeTokens: tokens.count,
                prefillSeconds: prefillSeconds,
                prefillTokensPerSecond: Double(promptTokens.count) / max(prefillSeconds, 1e-9),
                ttftSeconds: firstTokenAt.timeIntervalSince(prefillStarted),
                decodeSeconds: decodeSeconds,
                // The first token comes from the prefill forward; the rest are decode forwards.
                decodeTokensPerSecond: Double(max(tokens.count - 1, 0)) / max(decodeSeconds, 1e-9),
                prefillPeakMemoryGB: Double(prefillPeak) / 1e9,
                peakMemoryGB: Double(decodePeak) / 1e9,
                freeRunning: freeComparison,
                teacherForced: forced
            )
        }
    }

    private static func summaryLine(source: String, _ measured: GLMParityMeasurement) -> String {
        let free = measured.freeRunning
        let divergence = free.firstDivergence.map { String($0) } ?? "none"
        let logitDiff = free.maxAbsLogitDiff.map { String(format: "%.4f", $0) } ?? "n/a"
        let prefill = String(format: "%.1f", measured.prefillTokensPerSecond)
        let decode = String(format: "%.2f", measured.decodeTokensPerSecond)
        let peak = String(format: "%.1f", measured.peakMemoryGB)
        var line = "glm-parity: oracle=\(source) prompt=\(measured.promptTokens)"
        line += " first_divergence=\(divergence) top1_first16=\(free.top1Agreement)/\(free.top1Compared)"
        line += " max_abs_logit_diff=\(logitDiff) prefill_tps=\(prefill) decode_tps=\(decode) peak_gb=\(peak)\n"
        return line
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum GLMParityError: Error, CustomStringConvertible {
    case emptyPrompt
    case invalidOracle(String)

    var description: String {
        switch self {
        case .emptyPrompt: "oracle prompt is empty"
        case .invalidOracle(let reason): "invalid oracle: \(reason)"
        }
    }
}

struct GLMParityOracle: Decodable {
    let schema: String
    let source: String
    let sourceSHA256: String
    let prompt: [Int]
    let greedy: [Int]
    let topIdx: [[Int]]
    let topLogit: [[Float]]

    enum CodingKeys: String, CodingKey {
        case schema, source, prompt, greedy
        case sourceSHA256 = "source_sha256"
        case topIdx = "top_idx"
        case topLogit = "top_logit"
    }

    func validate() throws {
        guard schema == "glm-parity-oracle-v1" else { throw GLMParityError.invalidOracle("schema \(schema)") }
        guard !prompt.isEmpty else { throw GLMParityError.emptyPrompt }
        guard !greedy.isEmpty else { throw GLMParityError.invalidOracle("no greedy tokens") }
        guard topIdx.count == topLogit.count, topIdx.count <= greedy.count,
              zip(topIdx, topLogit).allSatisfy({ $0.count == $1.count && !$0.isEmpty })
        else { throw GLMParityError.invalidOracle("top_idx/top_logit shapes") }
        let tokens = prompt + greedy + topIdx.flatMap { $0 }
        guard tokens.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }) else {
            throw GLMParityError.invalidOracle("token id out of range")
        }
    }
}

/// Greedy and logit agreement of one decode against the oracle. `tokens` are
/// the decoded tokens, `argmaxTokens` the per-step argmax (equal for a free
/// run), `gatheredLogits[s]` this run's logits at the oracle's top indices
/// for step `s`.
struct GLMParityComparison: Codable, Equatable, Sendable {
    let comparedTokens: Int
    let firstDivergence: Int?
    let matchingTokens: Int
    let top1Compared: Int
    let top1Agreement: Int
    let maxAbsLogitDiff: Double?
    let maxAbsLogitDiffPerStep: [Double]
    let tokens: [Int]

    init(
        oracleGreedy: [Int],
        oracleTopIdx: [[Int]],
        oracleTopLogit: [[Float]],
        tokens: [Int],
        argmaxTokens: [Int],
        gatheredLogits: [[Float]]
    ) {
        let compared = min(oracleGreedy.count, tokens.count)
        comparedTokens = compared
        firstDivergence = (0 ..< compared).first { oracleGreedy[$0] != tokens[$0] }
        matchingTokens = (0 ..< compared).filter { oracleGreedy[$0] == argmaxTokens[$0] }.count
        let top1Steps = min(oracleTopIdx.count, argmaxTokens.count)
        top1Compared = top1Steps
        top1Agreement = (0 ..< top1Steps).filter { argmaxTokens[$0] == oracleTopIdx[$0].first }.count
        let perStep = zip(gatheredLogits, oracleTopLogit).map { mine, theirs in
            zip(mine, theirs).map { Double(abs($0 - $1)) }.max() ?? 0
        }
        maxAbsLogitDiffPerStep = perStep
        maxAbsLogitDiff = perStep.max()
        self.tokens = tokens
    }
}

struct GLMParityMeasurement: Codable, Sendable {
    let promptTokens: Int
    let decodeTokens: Int
    let prefillSeconds: Double
    let prefillTokensPerSecond: Double
    let ttftSeconds: Double
    let decodeSeconds: Double
    let decodeTokensPerSecond: Double
    let prefillPeakMemoryGB: Double
    let peakMemoryGB: Double
    let freeRunning: GLMParityComparison
    let teacherForced: GLMParityComparison?
}

struct GLMParityRun: Encodable {
    let oracleSource: String
    let oracleSourceSHA256: String
    let oracleJSONSHA256: String
    let promptTokenSHA256: String
    let promptInt32SHA256: String
    let measurement: GLMParityMeasurement
}

struct GLMParityReport: Encodable {
    let schema: String
    let modelDir: String
    let modelFamily: String
    let pagedKVFamilyRecognized: Bool
    let requiresMoEDispatch: Bool
    let mlxSwiftLMRevision: String
    let mlxSwiftRevision: String
    let prefillStepSize: Int
    let stepsRequested: Int
    let loadSeconds: Double
    let runs: [GLMParityRun]
    let peakPhysFootprintMB: Int?
    let timestamp: String
}

private extension Array where Element == Int {
    func withUnsafeInt32LittleEndianBytes() -> Data {
        var data = Data(capacity: count * 4)
        for token in self {
            var value = Int32(truncatingIfNeeded: token).littleEndian
            Swift.withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
