import Foundation

struct RecommendationInputs {
    var specVersion: String
    var runID: String
    var startedAt: Date
    var endedAt: Date
    var machine: MachineFingerprint
    var targetContext: Int
    var candidateModels: [String]
    var stage1Replicates: Int
    var stage2Replicates: Int
    var gateTTFTMS: Int
    var tpsTieEpsilon: Double
    var recommendation: RecommendationCore?
    var infeasible: [InfeasibleEntry]
    var dbPath: String
}

struct MachineFingerprint: Equatable {
    var ramGB: Int
    var chip: String
    var osVersion: String
    var binaryVersion: String
}

struct RecommendationCore {
    var model: String
    var targetContext: Int
    var knobs: WinningKnobs
    var tpsMedian: Double
    var ttftP95MS: Double
    var replicates: Int
}

struct InfeasibleEntry {
    var model: String
    var rank: Int
    var reason: String
}

struct EmittedRecommendation {
    var terminalBlock: String
    var jsonString: String
    var recipeHash: String?
    var alternates: [String]
    var serveCommand: String
}

struct RecommendationEmitter {
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func build(_ inputs: RecommendationInputs) throws -> EmittedRecommendation {
        let alternates = Self.alternates(
            candidateModels: inputs.candidateModels,
            recommendation: inputs.recommendation
        )
        let serveCommand = inputs.recommendation.map(Self.serveCommand) ?? ""
        let recipeHash = try Self.recipeHash(inputs)
        let terminalBlock = Self.terminalBlock(
            inputs: inputs,
            alternates: alternates,
            serveCommand: serveCommand
        )
        let root = JSONRoot(
            inputs: inputs,
            alternates: alternates,
            serveCommand: serveCommand,
            recipeHash: recipeHash
        )
        let jsonData = try Self.jsonEncoder.encode(root)
        let jsonString = String(decoding: jsonData, as: UTF8.self)

        return EmittedRecommendation(
            terminalBlock: terminalBlock,
            jsonString: jsonString,
            recipeHash: recipeHash,
            alternates: alternates,
            serveCommand: serveCommand
        )
    }

    static func launchdRestartHint() -> String {
        """
        hint: to apply the new recipe live, restart the serve process:
          launchctl bootout gui/$UID/live.streamvc.macprovider && \\
            launchctl bootstrap gui/$UID ~/Library/LaunchAgents/live.streamvc.macprovider.plist
        """
    }

    static func recipeHash(_ inputs: RecommendationInputs) throws -> String? {
        guard inputs.recommendation != nil else {
            return nil
        }
        let value = recipeHashInput(inputs)
        return "sha256:\(try RFC8785JCS.sha256Hex(of: value))"
    }

    static func recipeHashInput(_ inputs: RecommendationInputs) -> RFC8785JCS.Value {
        let recommendation = inputs.recommendation
        let knobs: RFC8785JCS.Value
        if let recommendation {
            knobs = .object([
                "kv_bits": recommendation.knobs.kvBits.map(RFC8785JCS.Value.int) ?? .null,
                "max_concurrency_override": .int(recommendation.knobs.maxBatch),
                "max_context_override": .int(recommendation.knobs.maxContext),
            ])
        } else {
            knobs = .null
        }

        return .object([
            "binary_version": .string(inputs.machine.binaryVersion),
            "candidate_models": .array(inputs.candidateModels.map(RFC8785JCS.Value.string)),
            "chip": .string(inputs.machine.chip),
            "knobs": knobs,
            "model": recommendation.map { .string($0.model) } ?? .null,
            "ram_gb": .int(inputs.machine.ramGB),
            "target_context": .int(inputs.targetContext),
        ])
    }

    private static func terminalBlock(
        inputs: RecommendationInputs,
        alternates: [String],
        serveCommand: String
    ) -> String {
        guard let recommendation = inputs.recommendation else {
            var lines = [
                "========================== NO RECOMMENDATION ==========================",
                "No model was selected.",
                "",
                "infeasible:",
            ]
            if inputs.infeasible.isEmpty {
                lines.append("  - none recorded")
            } else {
                lines.append(contentsOf: inputs.infeasible.map {
                    "  - rank \($0.rank) \($0.model): \($0.reason)"
                })
            }
            lines.append("")
            lines.append("run_id: \(inputs.runID) | db: \(inputs.dbPath)")
            lines.append("========================================================================")
            return lines.joined(separator: "\n")
        }

        var lines = [
            "============================ RECOMMENDATION ============================",
            "model:           \(recommendation.model)",
            "target_context:  \(recommendation.targetContext)",
            "knobs:",
            "  kv_bits:                    \(recommendation.knobs.kvBits.map(String.init) ?? "unset")",
            "  max_concurrency_override:   \(recommendation.knobs.maxBatch)",
            "  max_context_override:       \(recommendation.knobs.maxContext)",
            "measured:",
            "  tps_median:        \(formatTPS(recommendation.tpsMedian)) tokens/sec",
            "  ttft_p95:          \(formatMS(recommendation.ttftP95MS)) ms",
            "  replicates:        \(recommendation.replicates)",
            "",
            "alternates (smaller candidates from input list, not probed):",
        ]
        if alternates.isEmpty {
            lines.append("  - none")
        } else {
            lines.append(contentsOf: alternates.map { "  - \($0)" })
        }
        lines.append(contentsOf: [
            "",
            "serve command (copy-paste):",
            multilineServeCommand(recommendation),
            "",
            "run_id: \(inputs.runID) | db: \(inputs.dbPath)",
            "========================================================================",
        ])
        return lines.joined(separator: "\n")
    }

    private static func alternates(
        candidateModels: [String],
        recommendation: RecommendationCore?
    ) -> [String] {
        guard let recommendation,
              let index = candidateModels.firstIndex(of: recommendation.model)
        else {
            return []
        }
        let next = candidateModels.index(after: index)
        guard next < candidateModels.endIndex else {
            return []
        }
        return Array(candidateModels[next...])
    }

    private static func serveCommand(_ recommendation: RecommendationCore) -> String {
        var parts = [
            "macprovider-cli serve",
            "--model \(recommendation.model)",
        ]
        if let kvBits = recommendation.knobs.kvBits {
            parts.append("--kv-bits \(kvBits)")
        }
        parts.append("--max-batch \(recommendation.knobs.maxBatch)")
        parts.append("--max-context \(recommendation.knobs.maxContext)")
        return parts.joined(separator: " ")
    }

    private static func multilineServeCommand(_ recommendation: RecommendationCore) -> String {
        var lines = [
            "  macprovider-cli serve \\",
            "    --model \(recommendation.model) \\",
        ]
        if let kvBits = recommendation.knobs.kvBits {
            lines.append("    --kv-bits \(kvBits) \\")
        }
        lines.append("    --max-batch \(recommendation.knobs.maxBatch) \\")
        lines.append("    --max-context \(recommendation.knobs.maxContext)")
        return lines.joined(separator: "\n")
    }

    private static func formatTPS(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func formatMS(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct JSONRoot: Encodable {
    var inputs: RecommendationInputs
    var alternates: [String]
    var serveCommand: String
    var recipeHash: String?

    enum CodingKeys: String, CodingKey {
        case specVersion = "spec_version"
        case runID = "run_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case machine
        case inputEcho = "inputs"
        case recommendation
        case alternates
        case infeasible
        case recipeHash = "recipe_hash"
        case dbPath = "db_path"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputs.specVersion, forKey: .specVersion)
        try container.encode(inputs.runID, forKey: .runID)
        try container.encode(Self.iso8601UTC(inputs.startedAt), forKey: .startedAt)
        try container.encode(Self.iso8601UTC(inputs.endedAt), forKey: .endedAt)
        try container.encode(MachineJSON(inputs.machine), forKey: .machine)
        try container.encode(InputsJSON(inputs), forKey: .inputEcho)
        if let recommendation = inputs.recommendation {
            try container.encode(RecommendationJSON(recommendation, serveCommand: serveCommand), forKey: .recommendation)
        } else {
            try container.encodeNil(forKey: .recommendation)
        }
        try container.encode(alternates, forKey: .alternates)
        try container.encode(inputs.infeasible.map(InfeasibleJSON.init), forKey: .infeasible)
        if let recipeHash {
            try container.encode(recipeHash, forKey: .recipeHash)
        } else {
            try container.encodeNil(forKey: .recipeHash)
        }
        try container.encode(inputs.dbPath, forKey: .dbPath)
    }

    private static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct MachineJSON: Encodable {
    var ramGB: Int
    var chip: String
    var osVersion: String
    var binaryVersion: String

    init(_ machine: MachineFingerprint) {
        ramGB = machine.ramGB
        chip = machine.chip
        osVersion = machine.osVersion
        binaryVersion = machine.binaryVersion
    }

    enum CodingKeys: String, CodingKey {
        case ramGB = "ram_gb"
        case chip
        case osVersion = "os_version"
        case binaryVersion = "binary_version"
    }
}

private struct InputsJSON: Encodable {
    var targetContext: Int
    var candidateModels: [String]
    var stage1Replicates: Int
    var stage2Replicates: Int
    var gateTTFTMS: Int
    var tpsTieEpsilon: Double

    init(_ inputs: RecommendationInputs) {
        targetContext = inputs.targetContext
        candidateModels = inputs.candidateModels
        stage1Replicates = inputs.stage1Replicates
        stage2Replicates = inputs.stage2Replicates
        gateTTFTMS = inputs.gateTTFTMS
        tpsTieEpsilon = inputs.tpsTieEpsilon
    }

    enum CodingKeys: String, CodingKey {
        case targetContext = "target_context"
        case candidateModels = "candidate_models"
        case stage1Replicates = "stage1_replicates"
        case stage2Replicates = "stage2_replicates"
        case gateTTFTMS = "gate_ttft_ms"
        case tpsTieEpsilon = "tps_tie_epsilon"
    }
}

private struct RecommendationJSON: Encodable {
    var recommendation: RecommendationCore
    var serveCommand: String

    init(_ recommendation: RecommendationCore, serveCommand: String) {
        self.recommendation = recommendation
        self.serveCommand = serveCommand
    }

    enum CodingKeys: String, CodingKey {
        case model
        case targetContext = "target_context"
        case knobs
        case tpsMedian = "tps_median"
        case ttftP95MS = "ttft_p95_ms"
        case replicates
        case serveCommand = "serve_command"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recommendation.model, forKey: .model)
        try container.encode(recommendation.targetContext, forKey: .targetContext)
        try container.encode(KnobsJSON(recommendation.knobs), forKey: .knobs)
        try container.encode(recommendation.tpsMedian, forKey: .tpsMedian)
        try container.encode(recommendation.ttftP95MS, forKey: .ttftP95MS)
        try container.encode(recommendation.replicates, forKey: .replicates)
        try container.encode(serveCommand, forKey: .serveCommand)
    }
}

private struct KnobsJSON: Encodable {
    var knobs: WinningKnobs

    init(_ knobs: WinningKnobs) {
        self.knobs = knobs
    }

    enum CodingKeys: String, CodingKey {
        case kvBits = "kv_bits"
        case maxConcurrencyOverride = "max_concurrency_override"
        case maxContextOverride = "max_context_override"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let kvBits = knobs.kvBits {
            try container.encode(kvBits, forKey: .kvBits)
        } else {
            try container.encodeNil(forKey: .kvBits)
        }
        try container.encode(knobs.maxBatch, forKey: .maxConcurrencyOverride)
        try container.encode(knobs.maxContext, forKey: .maxContextOverride)
    }
}

private struct InfeasibleJSON: Encodable {
    var model: String
    var rank: Int
    var reason: String

    init(_ entry: InfeasibleEntry) {
        model = entry.model
        rank = entry.rank
        reason = entry.reason
    }
}
