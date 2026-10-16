import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore

/// #1644 lab validation of the SPEC-036 §5A scoring thresholds on real chips.
///
/// `--emit-outputs` generates the model's own answers to the scoring corpus
/// (greedy and sampled, the FR-20 profiles) and writes them to a file.
/// `--score-outputs` scores such a file with the loaded model through the
/// provider's FR-21 scoring body (`ComputeScoreRuntime.score`) and reports
/// per-item `top1_rate` and `mean_logprob` against the cold prior and the hard
/// floors. Running the two on different chips, and scoring the outputs of a
/// substituted model under the claimed one, gives the honest cross-chip and
/// substitution numbers the thresholds are set from. `--concurrent-load`
/// scores while that many generations run in the same runtime and reports the
/// largest drift from the isolated scores.
///
/// Lab only: it loads a model in its own process and never touches a serving
/// provider. Outputs and reports carry corpus text and aggregates only.
struct MSBComputeScoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msb-compute-score",
        abstract: "Lab validation of the SPEC-036 cross-provider scoring thresholds (#1644).",
        shouldDisplay: false
    )

    @Option(help: "HuggingFace model ID or local path to load. Falls back to MACPROVIDER_MODEL.")
    var model: String?

    @Option(name: .customLong("corpus"), help: "Scoring corpus JSON ({\"prompts\":[{\"system\",\"user\"}]}). Required with --emit-outputs.")
    var corpus: String?

    @Option(name: .customLong("emit-outputs"), help: "Generate answers to the corpus with the loaded model and write them here.")
    var emitOutputs: String?

    @Option(name: .customLong("score-outputs"), help: "Score this outputs file with the loaded model. Default: the file just emitted.")
    var scoreOutputs: String?

    @Option(name: .customLong("report"), help: "Write the JSON score report here. Default: stdout only.")
    var report: String?

    @Option(name: .customLong("prompts"), help: "Use at most this many corpus prompts. Default all.")
    var prompts: Int?

    @Option(name: .customLong("max-tokens"), help: "max_tokens per generated answer. Default 256 (the largest FR-20 value).")
    var maxTokens: Int = 256

    @Option(name: .customLong("concurrent-load"), help: "Also score while this many generations run in the same runtime. Default 0.")
    var concurrentLoad: Int = 0

    func run() async throws {
        guard let modelID = model ?? ProcessInfo.processInfo.environment["MACPROVIDER_MODEL"], !modelID.isEmpty else {
            fail("--model is required", code: 2)
        }
        guard emitOutputs != nil || scoreOutputs != nil else {
            fail("pass --emit-outputs, --score-outputs, or both", code: 2)
        }
        guard maxTokens >= 16, maxTokens <= 4096, concurrentLoad >= 0, concurrentLoad <= 32, prompts.map({ $0 >= 1 }) ?? true else {
            fail("--max-tokens in 16...4096, --concurrent-load in 0...32 and --prompts >= 1 required", code: 2)
        }
        let runtime = try await ModelRuntime(modelID: modelID)
        guard await runtime.isLoaded else {
            fail("failed to load model \(modelID)", code: 1)
        }
        let chip = MSBComputeScoreLab.chipName()

        var emittedPath: String?
        if let emitOutputs {
            guard let corpus else { fail("--corpus is required with --emit-outputs", code: 2) }
            let file = try await generate(runtime: runtime, modelID: modelID, corpusPath: corpus, chip: chip)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: URL(fileURLWithPath: emitOutputs), options: [.atomic])
            emittedPath = emitOutputs
        }
        guard let source = scoreOutputs ?? emittedPath else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        let outputs = try JSONDecoder().decode(MSBComputeScoreLab.OutputsFile.self, from: data)
        let result = try await score(runtime: runtime, modelID: modelID, outputs: outputs, sourceSHA256: MSBComputeScoreLab.sha256Hex(data), chip: chip)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(result)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if let report {
            try json.write(to: URL(fileURLWithPath: report), options: [.atomic])
        }
    }

    private func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("msb-compute-score: \(message)\n".utf8))
        Foundation.exit(code)
    }

    private func generate(runtime: ModelRuntime, modelID: String, corpusPath: String, chip: String) async throws -> MSBComputeScoreLab.OutputsFile {
        let doc = try JSONDecoder().decode(MSBComputeScoreLab.Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
        let selected = Array(doc.prompts.prefix(prompts ?? doc.prompts.count))
        var items: [MSBComputeScoreLab.OutputItem] = []
        for (index, prompt) in selected.enumerated() {
            for profile in MSBComputeScoreLab.profiles {
                let body = try MSBComputeScoreLab.requestBody(modelID: modelID, prompt: prompt, profile: profile, maxTokens: maxTokens)
                let parsed = try ChatCompletionRequest.parse(data: body)
                let completion = try await runtime.complete(parsed)
                items.append(MSBComputeScoreLab.OutputItem(
                    id: "\(index)-\(profile.name)",
                    samplingClass: profile.samplingClass,
                    body: String(decoding: body, as: UTF8.self),
                    outputText: completion.content
                ))
                FileHandle.standardError.write(Data("msb-compute-score: generated \(items.count)/\(selected.count * MSBComputeScoreLab.profiles.count)\n".utf8))
            }
        }
        return MSBComputeScoreLab.OutputsFile(schemaVersion: 1, generatorModel: modelID, chip: chip, items: items)
    }

    private func score(runtime: ModelRuntime, modelID: String, outputs: MSBComputeScoreLab.OutputsFile, sourceSHA256: String, chip: String) async throws -> MSBComputeScoreLab.Report {
        var scored: [MSBComputeScoreLab.ScoredItem] = []
        for item in outputs.items {
            let parsed = try ChatCompletionRequest.parse(data: Data(item.body.utf8))
            let outcome = try await runtime.labComputeScore(parsed, scoredText: item.outputText)
            scored.append(MSBComputeScoreLab.ScoredItem(id: item.id, samplingClass: item.samplingClass, outcome: outcome))
        }
        var underLoad: MSBComputeScoreLab.UnderLoad?
        if concurrentLoad > 0, let first = outputs.items.first {
            // Background generations share the runtime while every item is
            // scored again; the drift is the largest |mean_logprob| change.
            let loadBody = try ChatCompletionRequest.parse(data: Data(first.body.utf8))
            let stop = MSBComputeScoreLab.StopFlag()
            let tally = MSBComputeScoreLab.LoadTally()
            let load = Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<concurrentLoad {
                        group.addTask {
                            while !stop.isSet {
                                do {
                                    _ = try await runtime.complete(loadBody)
                                    tally.record(ok: true, whileScoring: !stop.isSet)
                                } catch {
                                    tally.record(ok: false, whileScoring: !stop.isSet)
                                }
                            }
                        }
                    }
                }
            }
            var drift: Double?
            var statuses: [String: Int] = [:]
            for (index, item) in outputs.items.enumerated() {
                let parsed = try ChatCompletionRequest.parse(data: Data(item.body.utf8))
                let again: MSBComputeScoreLab.ScoredItem
                do {
                    let outcome = try await runtime.labComputeScore(parsed, scoredText: item.outputText)
                    again = MSBComputeScoreLab.ScoredItem(id: item.id, samplingClass: item.samplingClass, outcome: outcome)
                } catch {
                    statuses["error", default: 0] += 1
                    continue
                }
                statuses[again.status, default: 0] += 1
                if let a = again.meanLogprob, let b = scored[index].meanLogprob {
                    drift = max(drift ?? 0, abs(a - b))
                }
            }
            stop.set()
            await load.value
            let counts = tally.counts
            underLoad = MSBComputeScoreLab.UnderLoad(
                generationsOK: counts.ok,
                generationsFailed: counts.failed,
                generationsOKWhileScoring: counts.okWhileScoring,
                scoreStatuses: statuses,
                maxMeanLogprobDrift: drift
            )
        }
        return MSBComputeScoreLab.Report(
            schemaVersion: 1,
            scorerModel: modelID,
            chip: chip,
            generatorModel: outputs.generatorModel,
            generatorChip: outputs.chip,
            outputsSHA256: sourceSHA256,
            mlxSwiftLMPin: decodeBenchMLXPinTag(),
            thresholds: MSBComputeScoreLab.Thresholds(),
            summary: MSBComputeScoreLab.summarize(scored),
            concurrentLoad: concurrentLoad,
            underLoad: underLoad,
            items: scored,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}

enum MSBComputeScoreLab {
    struct Prompt: Codable, Sendable {
        let system: String
        let user: String
    }

    struct Corpus: Codable, Sendable {
        let prompts: [Prompt]
    }

    /// The FR-20 sampling profiles (coordinator `SamplingProfiles`).
    struct Profile: Sendable {
        let name: String
        let temperature: Double
        let topP: Double
        /// The coordinator's FR-22 classes: greedy, sampled (0.7), hot (1.0).
        var samplingClass: String { temperature == 0 ? "greedy" : (temperature > 0.85 ? "hot" : "sampled") }
    }

    static let profiles = [
        Profile(name: "greedy", temperature: 0, topP: 1),
        Profile(name: "t0.7", temperature: 0.7, topP: 0.95),
        Profile(name: "t1.0", temperature: 1.0, topP: 1.0),
    ]

    struct OutputItem: Codable, Sendable {
        let id: String
        let samplingClass: String
        let body: String
        let outputText: String

        enum CodingKeys: String, CodingKey {
            case id
            case samplingClass = "sampling_class"
            case body
            case outputText = "output_text"
        }
    }

    struct OutputsFile: Codable, Sendable {
        let schemaVersion: Int
        let generatorModel: String
        let chip: String
        let items: [OutputItem]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case generatorModel = "generator_model"
            case chip
            case items
        }
    }

    /// The SPEC-036 FR-22 cold prior and hard floors, as the coordinator
    /// applies them (`internal/computeintegrity/scoring.go`).
    struct Thresholds: Codable, Sendable {
        var priorGreedyTop1 = 0.85
        var priorGreedyMeanLogprob = -1.0
        var priorSampledMeanLogprob = -4.0
        var hardGreedyTop1 = 0.50
        var hardGreedyMeanLogprob = -3.0
        var hardSampledMeanLogprob = -6.0
        var minScoredTokens = 16

        enum CodingKeys: String, CodingKey {
            case priorGreedyTop1 = "prior_greedy_top1"
            case priorGreedyMeanLogprob = "prior_greedy_mean_logprob"
            case priorSampledMeanLogprob = "prior_sampled_mean_logprob"
            case hardGreedyTop1 = "hard_greedy_top1"
            case hardGreedyMeanLogprob = "hard_greedy_mean_logprob"
            case hardSampledMeanLogprob = "hard_sampled_mean_logprob"
            case minScoredTokens = "min_scored_tokens"
        }

        /// Hot measurements are judged against the hard floor only.
        func inPrior(_ item: ScoredItem) -> Bool? {
            guard let mean = item.meanLogprob, let top1 = item.top1Rate, item.scoredTokens >= minScoredTokens else { return nil }
            switch item.samplingClass {
            case "greedy": return top1 >= priorGreedyTop1 && mean >= priorGreedyMeanLogprob
            case "hot": return mean >= hardSampledMeanLogprob
            default: return mean >= priorSampledMeanLogprob
            }
        }

        func aboveHardFloor(_ item: ScoredItem) -> Bool? {
            guard let mean = item.meanLogprob, let top1 = item.top1Rate, item.scoredTokens >= minScoredTokens else { return nil }
            return item.samplingClass == "greedy"
                ? top1 >= hardGreedyTop1 && mean >= hardGreedyMeanLogprob
                : mean >= hardSampledMeanLogprob
        }
    }

    struct ScoredItem: Codable, Sendable {
        let id: String
        let samplingClass: String
        let status: String
        let promptTokens: Int
        let scoredTokens: Int
        let top1Rate: Double?
        let meanLogprob: Double?

        enum CodingKeys: String, CodingKey {
            case id
            case samplingClass = "sampling_class"
            case status
            case promptTokens = "prompt_tokens"
            case scoredTokens = "scored_tokens"
            case top1Rate = "top1_rate"
            case meanLogprob = "mean_logprob"
        }

        init(id: String, samplingClass: String, outcome: ComputeScoreRuntime.Outcome) {
            self.id = id
            self.samplingClass = samplingClass
            status = outcome.status.rawValue
            promptTokens = outcome.promptTokens
            let n = outcome.scores.logprobs.count
            scoredTokens = n
            if n > 0 {
                top1Rate = Double(outcome.scores.top1.filter { $0 }.count) / Double(n)
                meanLogprob = outcome.scores.logprobs.reduce(0, +) / Double(n)
            } else {
                top1Rate = nil
                meanLogprob = nil
            }
        }
    }

    struct ClassSummary: Codable, Sendable {
        let measured: Int
        let inColdPrior: Int
        let aboveHardFloor: Int
        let minMeanLogprob: Double?
        let medianMeanLogprob: Double?
        let minTop1Rate: Double?
        let medianTop1Rate: Double?

        enum CodingKeys: String, CodingKey {
            case measured
            case inColdPrior = "in_cold_prior"
            case aboveHardFloor = "above_hard_floor"
            case minMeanLogprob = "min_mean_logprob"
            case medianMeanLogprob = "median_mean_logprob"
            case minTop1Rate = "min_top1_rate"
            case medianTop1Rate = "median_top1_rate"
        }
    }

    struct Report: Codable, Sendable {
        let schemaVersion: Int
        let scorerModel: String
        let chip: String
        let generatorModel: String
        let generatorChip: String
        let outputsSHA256: String
        let mlxSwiftLMPin: String
        let thresholds: Thresholds
        let summary: [String: ClassSummary]
        let concurrentLoad: Int
        /// Nil when `--concurrent-load` is 0. The second pass passes only
        /// when generations succeeded while it ran, every item scored `ok`,
        /// and the drift is set and small.
        let underLoad: UnderLoad?
        let items: [ScoredItem]
        let timestamp: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case scorerModel = "scorer_model"
            case chip
            case generatorModel = "generator_model"
            case generatorChip = "generator_chip"
            case outputsSHA256 = "outputs_sha256"
            case mlxSwiftLMPin = "mlx_swift_lm_pin"
            case thresholds
            case summary
            case concurrentLoad = "concurrent_load"
            case underLoad = "under_load"
            case items
            case timestamp
        }
    }

    struct UnderLoad: Codable, Sendable {
        let generationsOK: Int
        let generationsFailed: Int
        let generationsOKWhileScoring: Int
        let scoreStatuses: [String: Int]
        let maxMeanLogprobDrift: Double?

        enum CodingKeys: String, CodingKey {
            case generationsOK = "generations_ok"
            case generationsFailed = "generations_failed"
            case generationsOKWhileScoring = "generations_ok_while_scoring"
            case scoreStatuses = "score_statuses"
            case maxMeanLogprobDrift = "max_mean_logprob_drift"
        }
    }

    final class LoadTally: @unchecked Sendable {
        private let lock = NSLock()
        private var ok = 0
        private var failed = 0
        private var okWhileScoring = 0

        func record(ok succeeded: Bool, whileScoring: Bool) {
            lock.withLock {
                if succeeded {
                    ok += 1
                    if whileScoring { okWhileScoring += 1 }
                } else {
                    failed += 1
                }
            }
        }

        var counts: (ok: Int, failed: Int, okWhileScoring: Int) {
            lock.withLock { (ok, failed, okWhileScoring) }
        }
    }

    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    static func requestBody(modelID: String, prompt: Prompt, profile: Profile, maxTokens: Int) throws -> Data {
        let object: [String: Any] = [
            "model": modelID,
            "messages": [
                ["role": "system", "content": prompt.system],
                ["role": "user", "content": prompt.user],
            ],
            "max_tokens": maxTokens,
            "temperature": profile.temperature,
            "top_p": profile.topP,
            "stream": false,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func summarize(_ items: [ScoredItem]) -> [String: ClassSummary] {
        let thresholds = Thresholds()
        var out: [String: ClassSummary] = [:]
        for cls in ["greedy", "sampled", "hot"] {
            let measured = items.filter { $0.samplingClass == cls && thresholds.inPrior($0) != nil }
            let means = measured.compactMap(\.meanLogprob).sorted()
            let tops = measured.compactMap(\.top1Rate).sorted()
            out[cls] = ClassSummary(
                measured: measured.count,
                inColdPrior: measured.filter { thresholds.inPrior($0) == true }.count,
                aboveHardFloor: measured.filter { thresholds.aboveHardFloor($0) == true }.count,
                minMeanLogprob: means.first,
                medianMeanLogprob: median(means),
                minTop1Rate: tops.first,
                medianTop1Rate: median(tops)
            )
        }
        return out
    }

    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}
