import ArgumentParser
import Foundation

struct AutotuneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autotune",
        abstract: "Find the biggest feasible model for this Mac and recommend serve knobs."
    )

    @Option(help: "Target context in tokens.")
    var targetContext = 2000

    @Option(help: "Override default ordered model list as comma-separated HuggingFace model IDs. Operator order is preserved.")
    var candidateModels: String?

    @Option(help: "Trim the default list above this model size, e.g. 16B. Ignored when --candidate-models is set.")
    var maxModelSize: String?

    @Option(help: "Trim the default list below this model size, e.g. 7B. Ignored when --candidate-models is set.")
    var minModelSize: String?

    @Option(help: "Stage 2 KV-cache bit cells. Use 'unset' for no --kv-bits flag.")
    var kvBitsAxis = "unset,4,8"

    @Option(help: "Stage 2 max-batch cells.")
    var maxBatchAxis = "1,2"

    @Option(help: "Stage 2 max-context cells as absolute token caps. Empty means target-context only.")
    var maxContextAxis = ""

    @Option(help: "Stage 1 replicates per candidate.")
    var stage1Replicates = 1

    @Option(help: "Stage 2 replicates per knob cell.")
    var stage2Replicates = 3

    @Option(name: .customLong("gate-ttft-ms"), help: "Maximum p95 TTFT in milliseconds for feasibility.")
    var gateTTFTMS = 60_000

    @Option(help: "Relative throughput tie band for TTFT tiebreak.")
    var tpsTieEpsilon = 0.02

    @Option(help: "Hard wall-clock budget in seconds.")
    var maxDuration = 7_200

    @Option(help: "Grace period in seconds for draining or stopping providers.")
    var drainGrace = 30

    @Option(help: "Local provider port for candidate probes.")
    var port = 18_080

    @Option(help: "SQLite database path.")
    var dbPath = Self.defaultDBPath

    @Option(help: "Number of recent autotune runs to retain.")
    var retainRuns = 50

    @Flag(name: .customLong("json"), help: "Emit recommendation as JSON.")
    var emitJSON = false

    @Flag(help: "Write the final recommendation to config.yaml.")
    var apply = false

    @Flag(help: "Drain an already-running serve process before tuning.")
    var drain = false

    @Flag(help: "After draining a foreground serve process, restart it at exit.")
    var restartForeground = false

    @Flag(help: "Print the candidate plan and exit without serving.")
    var dryRun = false

    @Flag(help: "Re-render the latest persisted report and exit.")
    var reportOnly = false

    @Flag(name: [.short, .long], help: "Stream per-trial details to stderr.")
    var verbose = false

    static let defaultCandidates: [AutotuneCandidate] = [
        AutotuneCandidate(modelID: "mlx-community/Qwen2.5-32B-Instruct-4bit", sizeB: 32),
        AutotuneCandidate(modelID: "mlx-community/Qwen2.5-14B-Instruct-4bit", sizeB: 14),
        AutotuneCandidate(modelID: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", sizeB: 7),
        AutotuneCandidate(modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit", sizeB: 3),
        AutotuneCandidate(modelID: "mlx-community/Llama-3.2-1B-Instruct-4bit", sizeB: 1),
    ]

    static var defaultDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macprovider/autotune.sqlite")
            .path
    }

    mutating func validate() throws {
        try validateBasicInputs()
        // Surface --candidate-models parse errors (e.g. empty cells from
        // typos like `a,,b`) at flag-parse time per FR-A.1 / FR-B.1
        // "reject invalid cells at flag-parse time." candidatePlan() is a
        // pure function; the call here is just a parse-time gate.
        _ = try candidatePlan()
    }

    func run() throws {
        let plan = try candidatePlan()

        if dryRun {
            printDryRun(plan)
            return
        }

        if reportOnly {
            FileHandle.standardError.write(Data(("autotune --report-only is not implemented until SPEC-013 Step 9.\n").utf8))
            throw ExitCode(2)
        }

        FileHandle.standardError.write(Data(("autotune execution is not implemented yet; use --dry-run for Step 1 scaffold verification.\n").utf8))
        throw ExitCode(2)
    }

    func candidatePlan() throws -> AutotunePlan {
        if let candidateModels, !candidateModels.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let models = try Self.parseCSVStrict(candidateModels, flag: "--candidate-models")
            guard !models.isEmpty else {
                throw ValidationError("--candidate-models must contain at least one model id")
            }
            let warning: String? = (maxModelSize != nil || minModelSize != nil)
                ? "warning: --candidate-models supplied; ignoring --max-model-size/--min-model-size"
                : nil
            return AutotunePlan(candidates: models, source: .explicit, warning: warning)
        }

        let maxSize = try maxModelSize.map(Self.parseSizeB)
        let minSize = try minModelSize.map(Self.parseSizeB)
        if let minSize, let maxSize, minSize > maxSize {
            throw ValidationError("--min-model-size must be <= --max-model-size")
        }

        let filtered = Self.defaultCandidates.filter { candidate in
            if let maxSize, candidate.sizeB > maxSize {
                return false
            }
            if let minSize, candidate.sizeB < minSize {
                return false
            }
            return true
        }
        guard !filtered.isEmpty else {
            throw ValidationError("model-size filters removed every default candidate")
        }
        return AutotunePlan(candidates: filtered.map(\.modelID), source: .defaultList, warning: nil)
    }

    func printDryRun(_ plan: AutotunePlan) {
        if let warning = plan.warning {
            FileHandle.standardError.write(Data(("\(warning)\n").utf8))
        }
        for line in dryRunLines(plan) {
            print(line)
        }
    }

    /// Builds the dry-run line list for stdout. Exposed so tests can assert
    /// content (especially candidate order) without capturing stdout.
    func dryRunLines(_ plan: AutotunePlan) -> [String] {
        var lines: [String] = []
        lines.append("autotune: dry run")
        lines.append("autotune: target_context=\(targetContext)")
        lines.append("autotune: candidates (\(plan.source.description)):")
        for (index, model) in plan.candidates.enumerated() {
            lines.append("  \(index + 1). \(model)")
        }
        lines.append("autotune: stage1_replicates=\(stage1Replicates) stage2_replicates=\(stage2Replicates)")
        lines.append("autotune: gate_ttft_ms=\(gateTTFTMS) tps_tie_epsilon=\(tpsTieEpsilon)")
        lines.append("autotune: kv_bits_axis=\(kvBitsAxis) max_batch_axis=\(maxBatchAxis) max_context_axis=\(maxContextAxis.isEmpty ? "<target-context>" : maxContextAxis)")
        lines.append("autotune: port=\(port) db_path=\(dbPath) retain_runs=\(retainRuns)")
        lines.append("[dry-run] would evaluate Stage 1 candidates in this order and then hill-climb knobs only within the first feasible model.")
        return lines
    }

    private func validateBasicInputs() throws {
        guard targetContext > 0 else {
            throw ValidationError("--target-context must be >= 1")
        }
        guard stage1Replicates >= 1 else {
            throw ValidationError("--stage1-replicates must be >= 1")
        }
        guard stage2Replicates >= 1 else {
            throw ValidationError("--stage2-replicates must be >= 1")
        }
        guard gateTTFTMS > 0 else {
            throw ValidationError("--gate-ttft-ms must be > 0")
        }
        guard tpsTieEpsilon >= 0 else {
            throw ValidationError("--tps-tie-epsilon must be >= 0")
        }
        guard maxDuration > 0 else {
            throw ValidationError("--max-duration must be > 0")
        }
        guard drainGrace >= 0 else {
            throw ValidationError("--drain-grace must be >= 0")
        }
        guard port > 0 && port <= 65_535 else {
            throw ValidationError("--port must be in 1...65535")
        }
        guard retainRuns >= 1 else {
            throw ValidationError("--retain-runs must be >= 1")
        }
        _ = try Self.parseKvBitsAxis(kvBitsAxis)
        _ = try Self.parsePositiveIntAxis(maxBatchAxis, flag: "--max-batch-axis")
        _ = try Self.parseMaxContextAxis(maxContextAxis, targetContext: targetContext)
    }

    /// Tolerant CSV split: trims each token and DROPS empty tokens.
    /// Use for fields where empty cells are operator-irrelevant noise.
    /// Do NOT use for FR-validated lists; use `parseCSVStrict` instead.
    static func parseCSV(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Strict CSV split for FR-validated lists. Preserves empty subsequences
    /// (so a stray comma produces an empty token) and rejects empty tokens
    /// with a clear error naming the flag. Closes round-1 audit A.4 / B.5:
    /// `parseCSV` silently dropped empty cells, allowing
    /// `--max-context-axis 4000,,8000` and `--candidate-models a,,b` to
    /// parse as 2-element lists instead of throwing.
    static func parseCSVStrict(_ raw: String, flag: String) throws -> [String] {
        let tokens = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for token in tokens {
            if token.isEmpty {
                throw ValidationError("\(flag) contains an empty cell; check for stray commas")
            }
        }
        return tokens
    }

    static func parseSizeB(_ raw: String) throws -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixStripped: String
        if trimmed.lowercased().hasSuffix("b") {
            suffixStripped = String(trimmed.dropLast())
        } else {
            suffixStripped = trimmed
        }
        guard let value = Double(suffixStripped), value > 0 else {
            throw ValidationError("model size must be a positive value like 7B")
        }
        return value
    }

    static func parseKvBitsAxis(_ raw: String) throws -> [Int?] {
        let cells = try parseCSVStrict(raw, flag: "--kv-bits-axis")
        guard !cells.isEmpty else {
            throw ValidationError("--kv-bits-axis must contain at least one cell")
        }
        return try cells.map { cell in
            if cell.lowercased() == "unset" {
                return nil
            }
            guard let value = Int(cell), value == 4 || value == 8 else {
                throw ValidationError("--kv-bits-axis cells must be unset, 4, or 8")
            }
            return value
        }
    }

    static func parsePositiveIntAxis(_ raw: String, flag: String) throws -> [Int] {
        let cells = try parseCSVStrict(raw, flag: flag)
        guard !cells.isEmpty else {
            throw ValidationError("\(flag) must contain at least one cell")
        }
        return try cells.map { cell in
            guard let value = Int(cell), value > 0 else {
                throw ValidationError("\(flag) cells must be positive integers")
            }
            return value
        }
    }

    static func parseMaxContextAxis(_ raw: String, targetContext: Int) throws -> [Int] {
        // Empty raw value (the default) maps to a single cell at --target-context
        // per FR-B.1's "empty default treated as [--target-context]" rule. We
        // check the raw form here so a literal empty string is OK while a
        // stray-comma form like "," or "4000,,8000" still fails strict parse.
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [targetContext]
        }
        let cells = try parseCSVStrict(raw, flag: "--max-context-axis")
        let values = try cells.map { cell in
            guard let value = Int(cell), value > 0 else {
                throw ValidationError("--max-context-axis cells must be positive integers")
            }
            guard value >= targetContext else {
                throw ValidationError("--max-context-axis cell \(value) is below --target-context \(targetContext)")
            }
            return value
        }.sorted()
        guard Set(values).count == values.count else {
            throw ValidationError("--max-context-axis must not contain duplicate cells")
        }
        return values
    }
}

struct AutotuneCandidate: Equatable {
    let modelID: String
    let sizeB: Double
}

struct AutotunePlan: Equatable {
    enum Source: Equatable, CustomStringConvertible {
        case defaultList
        case explicit

        var description: String {
            switch self {
            case .defaultList:
                return "largest-first default list"
            case .explicit:
                return "operator-supplied order"
            }
        }
    }

    let candidates: [String]
    let source: Source
    let warning: String?
}
