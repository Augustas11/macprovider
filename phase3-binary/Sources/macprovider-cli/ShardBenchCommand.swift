import ArgumentParser
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore

/// `shard-bench` — issue #2084 go/no-go harness for pipeline-parallel decode over
/// LAN links. Lab only: no coordinator, no buyer path, hidden from help.
///
/// Roles:
///   * `--role head --layers 0:a` owns the embedding and first layers, drives
///     `--concurrency K` independent sequences through the chain, and prints the
///     report.
///   * `--role middle --layers a:b` receives activations from upstream, runs its
///     layers and forwards downstream.
///   * `--role tail --layers b:N` owns the last layers, the final norm, the LM head
///     and sampling; it returns token ids to the head.
///   * `--plan --members id=SIZE[:weight],... --context N` prints a placement plan
///     for the model from its config and safetensors headers, without loading it.
///   * `--local-reference` decodes the same prompts with the stock single-process
///     model; the head compares its tokens against this (in process, or from
///     `--reference <json>`).
///
/// Wiring: `--listen` accepts the upstream stage and `--connect` dials the
/// downstream stage. The chain is a ring: the head dials stage 1, each stage dials
/// the next, and the tail dials the head's `--listen` for the token return link. A
/// two-stage run may pass only one endpoint per side; that single link then carries
/// activations out and tokens back (either side may listen).
///
/// Decode is fixed-length (`--tokens`, EOS ignored) so the sharded and reference
/// runs are compared over the same steps. Request id 0 is reserved: link probes
/// during the handshake, and the session-end abort.
struct ShardBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shard-bench",
        abstract: "Lab: pipeline-parallel decode over TCP with parity and per-hop timing (issue #2084).",
        shouldDisplay: false
    )

    @Option(help: "Stage role: head, middle or tail. Omit with --local-reference.")
    var role: String?

    @Option(help: "Listen on host:port for the upstream stage (head: for the tail's token return link).")
    var listen: String?

    @Option(help: "Connect to the downstream stage at host:port (tail: to the head's return listener).")
    var connect: String?

    @Option(help: "Head: refuse a chain that does not have exactly this many stages.")
    var stages: Int?

    @Option(help: "HuggingFace model ID (local HF cache) or local model directory.")
    var model: String

    @Option(help: "This stage's layer range a:b (b exclusive).")
    var layers: String?

    @Flag(name: .customLong("local-reference"), help: "Decode with the stock single-process model and report its tokens.")
    var localReference = false

    @Option(help: "Tokens to generate per sequence.")
    var tokens: Int = 64

    @Option(help: "Prompt text. Sequence i > 0 appends a distinct suffix so concurrent sequences differ.")
    var prompt: String = ShardBenchCommand.defaultPrompt

    @Option(help: "Independent sequences the head keeps in flight across the stages.")
    var concurrency: Int = 1

    @Option(help: "Sampling temperature on the last stage (0 = greedy; parity needs 0).")
    var temperature: Float = 0

    @Option(help: "MLX random seed for temperature sampling.")
    var seed: UInt64 = 0

    @Option(name: .customLong("group-epoch"), help: "Group epoch every stage must agree on.")
    var groupEpoch: UInt64 = 1

    @Option(name: .customLong("heartbeat-ms"), help: "Heartbeat interval in milliseconds.")
    var heartbeatMilliseconds: Int = 100

    @Option(name: .customLong("missed-heartbeats"), help: "Peer is dead after this many silent heartbeat intervals.")
    var missedHeartbeats: Int = 3

    @Option(name: .customLong("receive-timeout"), help: "Per-receive deadline in seconds (covers the peers' compute for one step).")
    var receiveTimeout: Double = 60

    @Option(name: .customLong("connect-timeout"), help: "Seconds to wait for peers to connect, accept and finish the handshake.")
    var connectTimeout: Double = 120

    @Option(name: .customLong("probe-count"), help: "Echo probes (decode-activation sized) this stage measures on its upstream link.")
    var probeCount: Int = 200

    @Option(name: .customLong("max-sequences"), help: "Middle/tail: most sequences it holds KV caches for at once.")
    var maxSequences: Int = 64

    @Option(name: .customLong("member-id"), help: "Member device id this stage names in its sub-receipts (default stage-<index>).")
    var memberID: String?

    @Option(name: .customLong("prefill-chunk"), help: "Head: split each prompt into chunks of this many tokens, pipelined across the stages (default: one chunk).")
    var prefillChunk: Int?

    @Option(name: .customLong("prefill-chunk-deadline-ms"), help: "Each stage's compute for one prefill chunk must finish within this (SPEC-051 prefill_chunk_deadline_ms, 500..4000).")
    var prefillChunkDeadlineMilliseconds: Int = 3000

    @Option(help: "Head: reference JSON from a --local-reference run instead of an in-process reference decode.")
    var reference: String?

    @Flag(name: .customLong("no-parity"), help: "Head: skip the reference comparison.")
    var noParity = false

    @Flag(name: .customLong("no-warmup"), help: "Skip the short warmup sequence that compiles kernels before timing.")
    var noWarmup = false

    @Option(help: "Also write the JSON report to this path.")
    var output: String?

    @Flag(help: "Print a layer placement plan for --members and exit (reads config and safetensors headers only).")
    var plan = false

    @Option(help: "--plan: members in stage order, id=SIZE[:weight] comma separated (SIZE: bytes or e.g. 230GB, 214GiB; weight: relative compute).")
    var members: String?

    @Option(help: "--plan: tokens of KV each stage must hold.")
    var context: Int = 4096

    @Option(name: .customLong("tight-headroom"), help: "--plan: a stage with less headroom than this fraction of its usable memory marks the plan tight.")
    var tightHeadroom: Double = 0.05

    static let defaultPrompt =
        "Explain, step by step, how a pipeline-parallel transformer splits its layers across machines and why the activations between stages are small."

    func validate() throws {
        guard tokens > 0, concurrency > 0, probeCount >= 0, maxSequences > 0 else {
            throw ValidationError("--tokens, --concurrency and --max-sequences must be > 0; --probe-count >= 0")
        }
        guard heartbeatMilliseconds > 0, missedHeartbeats > 0, receiveTimeout > 0, connectTimeout > 0 else {
            throw ValidationError("heartbeat and timeout options must be > 0")
        }
        if plan {
            guard members != nil else { throw ValidationError("--plan needs --members") }
            guard context >= 0, tightHeadroom >= 0, tightHeadroom < 1 else {
                throw ValidationError("--context must be >= 0 and --tight-headroom within [0, 1)")
            }
            return
        }
        if let prefillChunk, prefillChunk <= 0 { throw ValidationError("--prefill-chunk must be > 0") }
        guard (500...4000).contains(prefillChunkDeadlineMilliseconds) else {
            throw ValidationError("--prefill-chunk-deadline-ms must be within 500..4000")
        }
        if localReference { return }
        guard let role, let parsed = ShardBenchRole(rawValue: role) else {
            throw ValidationError("--role head|middle|tail is required unless --local-reference")
        }
        guard listen != nil || connect != nil else {
            throw ValidationError("pass --listen and/or --connect")
        }
        if parsed == .middle, listen == nil || connect == nil {
            throw ValidationError("a middle stage needs --listen (upstream) and --connect (downstream)")
        }
        if let stages {
            guard parsed == .head, stages >= 2 else { throw ValidationError("--stages is a head option and must be >= 2") }
        }
        guard layers != nil else { throw ValidationError("--layers a:b is required for a stage") }
        if concurrency > maxSequences, parsed != .head {
            throw ValidationError("--concurrency exceeds --max-sequences")
        }
    }

    func run() async throws {
        let directory = try ModelRuntime.localModelDirectory(for: model)
        if plan {
            try runPlan(directory: directory)
            return
        }
        let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(from: directory)
        let prompts = (0..<concurrency).map { index in
            tokenizer.encode(text: index == 0 ? prompt : "\(prompt) (sequence \(index))", addSpecialTokens: true)
        }

        if localReference {
            let report = try await ShardBenchReference.decode(directory: directory, prompts: prompts, tokens: tokens)
            try emit(report)
            return
        }

        let (options, layerRange) = try sessionOptions(prompts: prompts)
        // Read a reference file before the run so a bad path fails before any decoding.
        var referenceReport: ShardBenchReferenceReport?
        if let reference, options.role == .head {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let data = try Data(contentsOf: URL(fileURLWithPath: (reference as NSString).expandingTildeInPath))
            referenceReport = try decoder.decode(ShardBenchReferenceReport.self, from: data)
        }
        let session: ShardBenchSessionReport
        do {
            let stage = ShardBenchStageBox(try await PipelineStageModel.load(directory: directory, layers: layerRange))
            session = try await ShardBenchThread.run { try ShardBenchSession(options: options, stage: stage.stage).run() }
        } catch {
            FileHandle.standardError.write(Data("shard-bench: \(error)\n".utf8))
            throw ExitCode(1)
        }

        guard var head = session.head else {
            if let stage = session.stage { try emit(stage) }
            return
        }
        if temperature > 0 {
            head.parity = ShardBenchParity(verdict: "not_applicable", source: "temperature>0", matchingTokens: nil, firstMismatch: nil)
        } else if let expected = referenceReport, let reference {
            head.parity = ShardBenchParity.compare(head.sequenceTokens, expected.sequenceTokens, source: "file:\(reference)")
            head.referenceSingleStreamTokensPerSecond = expected.singleStreamTokensPerSecond
        } else if noParity {
            head.parity = ShardBenchParity(verdict: "skipped", source: "--no-parity", matchingTokens: nil, firstMismatch: nil)
        } else {
            Memory.clearCache()
            let expected = try await ShardBenchReference.decode(directory: directory, prompts: prompts, tokens: tokens)
            head.parity = ShardBenchParity.compare(head.sequenceTokens, expected.sequenceTokens, source: "in_process_stock_model")
            head.referenceSingleStreamTokensPerSecond = expected.singleStreamTokensPerSecond
        }
        try emit(head)
        if head.parity?.verdict == "mismatch" { throw ExitCode(3) }
        if head.attestation.verdict != "ok" { throw ExitCode(5) }
    }

    private func runPlan(directory: URL) throws {
        let input = try ShardBenchPlanInput.model(directory: directory)
        let planned: ShardPlacementPlan
        do {
            planned = try ShardPlacementPlanner.plan(
                members: try ShardBenchPlanInput.members(members ?? ""), model: input.model,
                contextTokens: context, tightHeadroomFraction: tightHeadroom)
        } catch let error as ShardPlacementError {
            FileHandle.standardError.write(Data("shard-bench: placement refused: \(error)\n".utf8))
            throw ExitCode(4)
        }
        try emit(ShardBenchPlanReport(
            model: model, modelType: input.modelType, numLayers: input.model.layerWeightBytes.count,
            layerWeightBytes: input.model.layerWeightBytes, embeddingBytes: input.model.embeddingBytes,
            headBytes: input.model.headBytes, sharedBytes: input.model.sharedBytes,
            kvBytesPerTokenPerLayer: input.model.kvBytesPerTokenPerLayer, plan: planned,
            layerArguments: planned.stages.map { "\($0.layerStart):\($0.layerEnd)" }))
    }

    private func sessionOptions(prompts: [[Int]]) throws -> (ShardBenchSessionOptions, Range<Int>) {
        guard let layers, let role, let parsedRole = ShardBenchRole(rawValue: role) else {
            throw ValidationError("--role and --layers a:b are required")
        }
        let parts = layers.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int(parts[0]), let upper = Int(parts[1]), lower < upper else {
            throw ValidationError("--layers must be a:b with a < b")
        }
        let options = ShardBenchSessionOptions(
            role: parsedRole,
            listen: try listen.map { try ShardBenchEndpoint.parse($0) },
            connect: try connect.map { try ShardBenchEndpoint.parse($0) },
            expectedStages: stages,
            modelLabel: model,
            prompts: prompts,
            tokens: tokens,
            temperature: temperature,
            seed: seed,
            // Peer-dead detection arms after the hello exchange (SPEC-051-R014 applies to
            // a joined group); until then the connect timeout bounds every wait.
            link: ShardLinkConfiguration(
                groupEpoch: groupEpoch,
                heartbeatInterval: Double(heartbeatMilliseconds) / 1000,
                missedHeartbeatLimit: missedHeartbeats,
                armLivenessOnOpen: false
            ),
            receiveTimeout: receiveTimeout,
            connectTimeout: connectTimeout,
            probeCount: probeCount,
            maxSequences: maxSequences,
            warmup: !noWarmup,
            prefillChunk: prefillChunk,
            prefillChunkDeadline: Double(prefillChunkDeadlineMilliseconds) / 1000,
            memberID: memberID
        )
        return (options, lower..<upper)
    }

    private func emit<T: Encodable>(_ report: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try encoder.encode(report)
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if let output {
            try json.write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath), options: .atomic)
        }
    }
}

// MARK: - Placement plan input

struct ShardBenchPlanReport: Encodable {
    let schema = "macprovider.shard-bench.plan.v1"
    let model: String
    let modelType: String
    let numLayers: Int
    let layerWeightBytes: [Int64]
    let embeddingBytes: Int64
    let headBytes: Int64
    let sharedBytes: Int64
    let kvBytesPerTokenPerLayer: Int64
    let plan: ShardPlacementPlan
    /// `--layers` value for each stage, in order.
    let layerArguments: [String]
}

/// Planner inputs read from a model directory: per-layer bytes from the safetensors
/// headers (no tensor data is read) and KV size from `config.json`, assigned the way
/// `PipelineStageModel.loadStageWeights` loads them.
enum ShardBenchPlanInput {
    static func members(_ text: String) throws -> [ShardPlacementMember] {
        try text.split(separator: ",").map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty else {
                throw ValidationError("member '\(entry)' must be id=SIZE[:weight]")
            }
            let value = parts[1].split(separator: ":", maxSplits: 1)
            var weight: Double?
            if value.count == 2 {
                guard let parsed = Double(value[1]) else { throw ValidationError("member '\(entry)': bad weight") }
                weight = parsed
            }
            return ShardPlacementMember(id: String(parts[0]), usableMemoryBytes: try bytes(String(value[0])), computeWeight: weight)
        }
    }

    static func bytes(_ text: String) throws -> Int64 {
        let units: [(String, Double)] = [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576),
                                         ("TB", 1e12), ("GB", 1e9), ("MB", 1e6)]
        for (suffix, scale) in units where text.hasSuffix(suffix) {
            guard let number = Double(text.dropLast(suffix.count)), number > 0 else { break }
            return Int64((number * scale).rounded())
        }
        guard let plain = Int64(text), plain > 0 else {
            throw ValidationError("size '\(text)' must be bytes or a number with TB/GB/MB/TiB/GiB/MiB")
        }
        return plain
    }

    static func model(directory: URL) throws -> (model: ShardPlacementModel, modelType: String) {
        let config = try PipelineStageModel.readConfig(directory: directory)
        let layerCount = try PipelineStageModel.totalLayers(config: config)
        let tensors = try tensorBytes(directory: directory)
        var layers = Array(repeating: Int64(0), count: layerCount)
        var embedding: Int64 = 0
        var head: Int64 = 0
        var shared: Int64 = 0
        var hasHead = false
        for (key, size) in tensors {
            if key.hasPrefix("model.layers.") {
                let digits = key.dropFirst("model.layers.".count).prefix(while: \.isNumber)
                // Layers past num_hidden_layers (e.g. MTP heads) are never loaded by a stage.
                if let index = Int(digits), index < layerCount { layers[index] += size }
            } else if key.hasPrefix("model.embed_tokens.") {
                embedding += size
            } else if key.hasPrefix("lm_head.") {
                head += size
                hasHead = true
            } else if key.hasPrefix("model.norm.") {
                head += size
            } else {
                shared += size
            }
        }
        // A tied-embedding last stage loads the embedding table as its head.
        if !hasHead { head += embedding }
        return (ShardPlacementModel(
            layerWeightBytes: layers, embeddingBytes: embedding, headBytes: head, sharedBytes: shared,
            kvBytesPerTokenPerLayer: try kvBytesPerTokenPerLayer(config: config)), config["model_type"] as? String ?? "unknown")
    }

    /// Tensor name -> byte length from every `.safetensors` header in `directory`.
    static func tensorBytes(directory: URL) throws -> [String: Int64] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !files.isEmpty else { throw PipelineStageError.noWeights(directory) }
        var sizes = [String: Int64]()
        for file in files {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
                throw PipelineStageError.invalidConfig("\(file.lastPathComponent): no safetensors header")
            }
            let length = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            guard length <= 100 * 1024 * 1024, let header = try handle.read(upToCount: Int(length)), header.count == Int(length),
                  let object = try JSONSerialization.jsonObject(with: header) as? [String: Any]
            else {
                throw PipelineStageError.invalidConfig("\(file.lastPathComponent): unreadable safetensors header")
            }
            for (name, value) in object where name != "__metadata__" {
                guard let tensor = value as? [String: Any], let offsets = tensor["data_offsets"] as? [NSNumber], offsets.count == 2 else {
                    throw PipelineStageError.invalidConfig("\(file.lastPathComponent): tensor \(name) has no data_offsets")
                }
                sizes[name, default: 0] += offsets[1].int64Value - offsets[0].int64Value
            }
        }
        return sizes
    }

    /// KV bytes per token per layer as the stage runtime allocates them (bf16 keys and
    /// values; DeepSeek-V3's attention caches the expanded per-head keys and values).
    static func kvBytesPerTokenPerLayer(config: [String: Any]) throws -> Int64 {
        let element: Int64 = 2
        guard let heads = config["num_attention_heads"] as? Int, heads > 0 else {
            throw PipelineStageError.invalidConfig("num_attention_heads missing")
        }
        if config["model_type"] as? String == "deepseek_v3" {
            guard let nope = config["qk_nope_head_dim"] as? Int, let rope = config["qk_rope_head_dim"] as? Int,
                  let value = config["v_head_dim"] as? Int
            else {
                throw PipelineStageError.invalidConfig("deepseek_v3 head dims missing")
            }
            return Int64(heads * (nope + rope + value)) * element
        }
        guard let hidden = config["hidden_size"] as? Int else { throw PipelineStageError.invalidConfig("hidden_size missing") }
        let kvHeads = config["num_key_value_heads"] as? Int ?? heads
        let headDim = config["head_dim"] as? Int ?? hidden / heads
        return Int64(2 * kvHeads * headDim) * element
    }
}

// MARK: - Stage seam

/// One boundary tensor as it travels in a frame.
struct ShardBenchActivation: Equatable, Sendable {
    let dtype: ShardTensorDType
    let shape: [UInt32]
    let payload: Data
}

/// What a session needs from its stage: the MLX `PipelineStageModel` in the harness,
/// a deterministic stand-in in unit tests of the chain wiring.
protocol ShardBenchStage: AnyObject {
    associatedtype Cache

    var modelType: String { get }
    var hiddenSize: Int { get }
    var layers: Range<Int> { get }
    var totalLayers: Int { get }
    var weightBytes: Int { get }

    func newCache() throws -> Cache
    /// First stage: token ids in, boundary activation out.
    func forward(tokens: [Int], cache: Cache) throws -> ShardBenchActivation
    /// Middle stage: boundary activation in and out.
    func forward(activation: ShardBenchActivation, cache: Cache) throws -> ShardBenchActivation
    /// Last stage: boundary activation in, next token out.
    func sample(activation: ShardBenchActivation, cache: Cache, temperature: Float) throws -> Int
    /// Last stage: extend the KV with a fill-only activation; no token is sampled.
    func fill(activation: ShardBenchActivation, cache: Cache) throws
}

extension PipelineStageModel: ShardBenchStage {
    var layers: Range<Int> { plan.layers }
    var totalLayers: Int { plan.totalLayers }

    func forward(tokens: [Int], cache: [KVCache]) throws -> ShardBenchActivation {
        let hidden = try forward(MLXArray(tokens.map(Int32.init)).reshaped(1, tokens.count), cache: cache)
        let encoded = try PipelineActivationCodec.encode(hidden)
        return ShardBenchActivation(dtype: encoded.dtype, shape: encoded.shape, payload: encoded.payload)
    }

    func forward(activation: ShardBenchActivation, cache: [KVCache]) throws -> ShardBenchActivation {
        let input = try PipelineActivationCodec.decode(dtype: activation.dtype, shape: activation.shape, payload: activation.payload)
        let encoded = try PipelineActivationCodec.encode(try forward(input, cache: cache))
        return ShardBenchActivation(dtype: encoded.dtype, shape: encoded.shape, payload: encoded.payload)
    }

    func sample(activation: ShardBenchActivation, cache: [KVCache], temperature: Float) throws -> Int {
        let input = try PipelineActivationCodec.decode(dtype: activation.dtype, shape: activation.shape, payload: activation.payload)
        return PipelineStageSampler.sample(logits: try forward(input, cache: cache), temperature: temperature)
    }

    func fill(activation: ShardBenchActivation, cache: [KVCache]) throws {
        try fill(try PipelineActivationCodec.decode(dtype: activation.dtype, shape: activation.shape, payload: activation.payload), cache: cache)
    }
}

// MARK: - Options and reports

enum ShardBenchRole: String, Codable, Sendable {
    case head
    case middle
    case tail
}

struct ShardBenchEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16

    static func parse(_ text: String) throws -> ShardBenchEndpoint {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else {
            throw ValidationError("endpoint must be host:port, got '\(text)'")
        }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return ShardBenchEndpoint(host: host.isEmpty ? "0.0.0.0" : host, port: port)
    }
}

struct ShardBenchSessionOptions: Sendable {
    let role: ShardBenchRole
    /// Accepts the upstream stage (head: the tail's return link).
    let listen: ShardBenchEndpoint?
    /// Dials the downstream stage (tail: the head's return listener).
    let connect: ShardBenchEndpoint?
    let expectedStages: Int?
    let modelLabel: String
    let prompts: [[Int]]
    let tokens: Int
    let temperature: Float
    let seed: UInt64
    let link: ShardLinkConfiguration
    let receiveTimeout: TimeInterval
    let connectTimeout: TimeInterval
    let probeCount: Int
    let maxSequences: Int
    let warmup: Bool
    /// Head: prompt tokens per prefill chunk; nil sends the whole prompt as one chunk.
    let prefillChunk: Int?
    /// SPEC-051-R013: one stage's compute for one prefill chunk must stay below this.
    let prefillChunkDeadline: TimeInterval
    /// Member device id in this stage's sub-receipts; nil names it `stage-<index>`.
    let memberID: String?
}

struct ShardBenchLatency: Codable, Equatable {
    let count: Int
    let p50Microseconds: Double?
    let p99Microseconds: Double?
    let meanMicroseconds: Double?
    let maxMicroseconds: Double?

    init(seconds samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        func pick(_ q: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            let index = min(sorted.count - 1, Int((q * Double(sorted.count - 1)).rounded()))
            return (sorted[index] * 1e6 * 10).rounded() / 10
        }
        p50Microseconds = pick(0.5)
        p99Microseconds = pick(0.99)
        meanMicroseconds = sorted.isEmpty ? nil : ((sorted.reduce(0, +) / Double(sorted.count)) * 1e7).rounded() / 10
        maxMicroseconds = sorted.last.map { ($0 * 1e7).rounded() / 10 }
    }
}

struct ShardBenchParity: Codable, Equatable {
    var verdict: String
    var source: String
    var matchingTokens: Int?
    var firstMismatch: String?

    static func compare(_ actual: [[Int]], _ expected: [[Int]], source: String) -> ShardBenchParity {
        guard actual.count == expected.count else {
            return ShardBenchParity(
                verdict: "mismatch", source: source, matchingTokens: 0,
                firstMismatch: "sequence count \(actual.count) vs reference \(expected.count)")
        }
        var matching = 0
        for (index, (lhs, rhs)) in zip(actual, expected).enumerated() {
            for step in 0..<max(lhs.count, rhs.count) {
                let left = step < lhs.count ? lhs[step] : nil
                let right = step < rhs.count ? rhs[step] : nil
                guard left == right else {
                    return ShardBenchParity(
                        verdict: "mismatch", source: source, matchingTokens: matching,
                        firstMismatch: "sequence \(index) step \(step): sharded \(left.map(String.init) ?? "none") vs reference \(right.map(String.init) ?? "none")")
                }
                matching += 1
            }
        }
        return ShardBenchParity(verdict: "match", source: source, matchingTokens: matching, firstMismatch: nil)
    }
}

/// One link as seen from this stage: counters plus, on the link this stage
/// received its upstream hello on, the echo-probe round trip it measured.
struct ShardBenchLinkReport: Encodable, Equatable {
    let name: String
    let peerStage: Int
    let framesSent: UInt64
    let framesReceived: UInt64
    let bytesSent: UInt64
    let bytesReceived: UInt64
    let heartbeatsSent: UInt64
    let heartbeatsReceived: UInt64
    let probeRoundTrip: ShardBenchLatency?

    init(name: String, peerStage: Int, statistics: ShardLinkStatistics, probe: ShardBenchLatency?) {
        self.name = name
        self.peerStage = peerStage
        framesSent = statistics.framesSent
        framesReceived = statistics.framesReceived
        bytesSent = statistics.bytesSent
        bytesReceived = statistics.bytesReceived
        heartbeatsSent = statistics.heartbeatsSent
        heartbeatsReceived = statistics.heartbeatsReceived
        probeRoundTrip = probe
    }
}

/// One hop of the ring, `from` -> `to`, with the echo-probe round trip the receiving
/// end measured during the handshake. `carriesReturn` marks a two-stage link that
/// also carries the tokens back.
struct ShardBenchHopReport: Encodable, Equatable {
    let from: Int
    let to: Int
    let carriesReturn: Bool
    let probeRoundTrip: ShardBenchLatency?
}

struct ShardBenchHeadReport: Encodable {
    let schema = "macprovider.shard-bench.head.v2"
    let model: String
    let modelType: String
    let layers: String
    let stageCount: Int
    let stageLayers: [String]
    let totalLayers: Int
    let hiddenSize: Int
    let activationDtype: String
    let stageWeightBytes: Int
    let concurrency: Int
    let tokensPerSequence: Int
    let promptTokens: [Int]
    let sequenceTokens: [[Int]]
    let totalTokens: Int
    /// Mean over sequences of decode tokens/s, excluding each sequence's first token.
    let singleStreamTokensPerSecond: Double?
    /// Every generated token over the wall time from the first prefill to the last token.
    let aggregateTokensPerSecond: Double
    let ttft: ShardBenchLatency
    /// Echo round trip of one decode-sized activation frame on the head's first link:
    /// the transport + codec cost of one hop out and back, with no model compute.
    let probeRoundTrip: ShardBenchLatency?
    /// Every hop of the ring with its own probe round trip.
    let hops: [ShardBenchHopReport]
    /// Head send of a decode activation to the token arriving back: includes every
    /// downstream stage's compute (see their reports) and, with concurrency > 1, queueing.
    let decodeStepRoundTrip: ShardBenchLatency
    let headDecodeCompute: ShardBenchLatency
    let decodeHopPayloadBytes: Int
    let decodeHopFrameBytes: Int
    /// Boundary bytes of each sequence's whole prefill, summed over its chunks.
    let prefillHopPayloadBytes: [Int]
    let prefillChunkTokens: Int?
    let prefillChunksPerSequence: [Int]
    let headPrefillChunkCompute: ShardBenchLatency
    let links: [ShardBenchLinkReport]
    /// SPEC-051-R019 chain check of every measured request's member sub-receipts.
    let attestation: ShardBenchAttestationReport
    var parity: ShardBenchParity?
    var referenceSingleStreamTokensPerSecond: Double?
}

struct ShardBenchRequestAttestation: Encodable {
    let requestID: UInt64
    let verdict: String
    let fault: ShardAttestationFault?
    /// One per member in chain order; `out_digest` of each equals `in_digest` of the
    /// next on an unbroken chain.
    let receipts: [ShardMemberSubReceipt]
}

struct ShardBenchAttestationReport: Encodable {
    /// `ok` only when every request's chain verified.
    let verdict: String
    let requests: [ShardBenchRequestAttestation]

    static func verify(head: [ShardMemberSubReceipt], others: [ShardMemberSubReceipt], requests: [UInt64]) -> ShardBenchAttestationReport {
        let rows = requests.map { requestID -> ShardBenchRequestAttestation in
            let chain = head.filter { $0.requestID == requestID } + others.filter { $0.requestID == requestID }
            switch ShardGroupAttestationVerifier.verify(chain) {
            case .ok:
                return ShardBenchRequestAttestation(requestID: requestID, verdict: "ok", fault: nil, receipts: chain)
            case .broken(let fault):
                return ShardBenchRequestAttestation(requestID: requestID, verdict: "broken", fault: fault, receipts: chain)
            }
        }
        return ShardBenchAttestationReport(verdict: rows.allSatisfy { $0.verdict == "ok" } ? "ok" : "broken", requests: rows)
    }
}

/// Report of a middle or tail stage.
struct ShardBenchStageReport: Encodable {
    let schema = "macprovider.shard-bench.stage.v1"
    let role: ShardBenchRole
    let stageIndex: Int
    let model: String
    let modelType: String
    let layers: String
    let totalLayers: Int
    let stageWeightBytes: Int
    let sequencesServed: Int
    let decodeCompute: ShardBenchLatency
    let prefillCompute: ShardBenchLatency
    let links: [ShardBenchLinkReport]
}

struct ShardBenchSessionReport {
    var head: ShardBenchHeadReport?
    var stage: ShardBenchStageReport?
}

struct ShardBenchReferenceReport: Codable {
    var schema = "macprovider.shard-bench.reference.v1"
    let sequenceTokens: [[Int]]
    let promptTokens: [Int]
    let singleStreamTokensPerSecond: Double?
    let ttft: ShardBenchLatency
}

/// What one stage owns, carried in the chain hello.
struct ShardBenchHello: Codable, Equatable {
    let role: ShardBenchRole
    let modelType: String
    let totalLayers: Int
    let hiddenSize: Int
    let layerStart: Int
    let layerEnd: Int
    /// Round trip of the link to the previous stage, measured by this stage.
    var upstreamProbe: ShardBenchLatency?
    /// Tail with a separate return link: round trip of that link to the head.
    var returnProbe: ShardBenchLatency?

    var layerLabel: String { "\(layerStart):\(layerEnd)" }
}

/// Hello payload: the chain so far. It grows by one stage per hop and comes back
/// to the head complete on the return link.
struct ShardBenchChainHello: Codable, Equatable {
    let stages: [ShardBenchHello]
}

enum ShardBenchChain {
    /// `next` may follow `prefix`: same model, contiguous layers, the head first and
    /// only middles in between.
    static func validate(prefix: [ShardBenchHello], next: ShardBenchHello) throws {
        guard let first = prefix.first, first.role == .head, first.layerStart == 0 else {
            throw ShardBenchError.handshake("the chain must start at the head owning layer 0")
        }
        for (index, hello) in prefix.enumerated().dropFirst() where hello.role != .middle {
            throw ShardBenchError.handshake("stage \(index) is a \(hello.role.rawValue) before the end of the chain")
        }
        guard next.role != .head else { throw ShardBenchError.handshake("a second head at stage \(prefix.count)") }
        guard next.modelType == first.modelType, next.totalLayers == first.totalLayers, next.hiddenSize == first.hiddenSize else {
            throw ShardBenchError.handshake("stage \(prefix.count) model \(next.modelType)/\(next.totalLayers)L/\(next.hiddenSize) differs from \(first.modelType)/\(first.totalLayers)L/\(first.hiddenSize)")
        }
        let previous = prefix[prefix.count - 1]
        guard previous.layerEnd == next.layerStart else {
            throw ShardBenchError.handshake("stage \(prefix.count - 1) layers end at \(previous.layerEnd) but stage \(prefix.count) starts at \(next.layerStart)")
        }
    }

    /// A whole ring: at least two stages, each link valid, ending at a tail that owns
    /// the last layer.
    static func validateComplete(_ chain: [ShardBenchHello]) throws {
        guard chain.count >= 2 else { throw ShardBenchError.handshake("a chain needs at least two stages, got \(chain.count)") }
        for index in 1..<chain.count {
            try validate(prefix: Array(chain[..<index]), next: chain[index])
        }
        guard let last = chain.last, last.role == .tail, last.layerEnd == last.totalLayers else {
            throw ShardBenchError.handshake("the chain must end at a tail owning layer \(chain[0].totalLayers - 1)")
        }
    }

    /// Ring hops with the probe each receiving end measured.
    static func hops(_ chain: [ShardBenchHello]) -> [ShardBenchHopReport] {
        let last = chain.count - 1
        let separateReturn = chain[last].returnProbe != nil
        var hops = (1..<chain.count).map { index in
            ShardBenchHopReport(
                from: index - 1, to: index, carriesReturn: chain.count == 2 && !separateReturn,
                probeRoundTrip: chain[index].upstreamProbe)
        }
        if separateReturn {
            hops.append(ShardBenchHopReport(from: last, to: 0, carriesReturn: true, probeRoundTrip: chain[last].returnProbe))
        }
        return hops
    }
}

enum ShardBenchError: Error, CustomStringConvertible {
    case handshake(String)
    case protocolViolation(String)
    case peerError(String)
    case tooManySequences(Int)
    case prefillChunkDeadline(stage: Int, tokens: Int, milliseconds: Int, deadlineMilliseconds: Int)

    var description: String {
        switch self {
        case .handshake(let detail): return "handshake failed: \(detail)"
        case .protocolViolation(let detail): return "protocol violation: \(detail)"
        case .peerError(let detail): return "peer reported error: \(detail)"
        case .tooManySequences(let cap): return "more than \(cap) concurrent sequences"
        case .prefillChunkDeadline(let stage, let tokens, let milliseconds, let deadline):
            return "stage \(stage) took \(milliseconds) ms for a \(tokens)-token prefill chunk, over the \(deadline) ms chunk deadline; use a smaller --prefill-chunk"
        }
    }
}

// MARK: - Links

/// One diagnostic line on stderr; stdout carries only the JSON report.
private func shardBenchLog(_ line: String) {
    FileHandle.standardError.write(Data("shard-bench: \(line)\n".utf8))
}

/// A stage's two links. `upstream` is the one it receives work on (head: the token
/// return link) and `downstream` the one it sends on (tail: the return link). In a
/// two-stage ring both may be the same link.
struct ShardBenchLinks {
    let upstream: ShardStageLink
    let downstream: ShardStageLink

    var isCollapsed: Bool { upstream === downstream }

    var unique: [ShardStageLink] { isCollapsed ? [upstream] : [upstream, downstream] }

    func close() {
        for link in unique { link.close() }
    }

    /// Bind first, then dial, then accept: every stage's listener is up before any
    /// stage blocks in accept, so a ring opens in any start order.
    static func open(
        listen: ShardBenchEndpoint?,
        connect: ShardBenchEndpoint?,
        connectTimeout: TimeInterval,
        configuration: ShardLinkConfiguration
    ) throws -> ShardBenchLinks {
        let listener = try listen.map { try ShardStageListener(host: $0.host, port: $0.port) }
        if let listen, let listener {
            shardBenchLog("listening on \(listen.host):\(listener.port)")
        }
        let dialed = try connect.map {
            try ShardStageLink.connect(host: $0.host, port: $0.port, timeout: connectTimeout, configuration: configuration)
        }
        if let dialed { shardBenchLog("connected to \(dialed.peerAddress)") }
        var accepted: ShardStageLink?
        if let listener {
            do {
                accepted = try listener.accept(timeout: connectTimeout, configuration: configuration)
            } catch {
                dialed?.close()
                throw error
            }
        }
        if let accepted { shardBenchLog("accepted peer \(accepted.peerAddress)") }
        switch (accepted, dialed) {
        case let (upstream?, downstream?):
            return ShardBenchLinks(upstream: upstream, downstream: downstream)
        case let (single?, nil), let (nil, single?):
            return ShardBenchLinks(upstream: single, downstream: single)
        case (nil, nil):
            throw ValidationError("pass --listen and/or --connect")
        }
    }
}

/// Drains a link the main loop only sends on, so the peer's heartbeats are consumed
/// and its death or error report is noticed while the main loop is blocked on the
/// other link. On a failure it records the cause and closes `wake`, which ends that
/// blocked receive; the session then reports the recorded cause.
final class ShardBenchLinkWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var recorded: Error?

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func watch(_ link: ShardStageLink, wake: ShardStageLink) {
        let thread = Thread { [self] in
            while true {
                do {
                    let frame = try link.receive(timeout: 3600)
                    if frame.header.kind == .error {
                        record(ShardBenchError.peerError(String(decoding: frame.payload, as: UTF8.self)), wake: wake)
                    } else {
                        record(ShardBenchError.protocolViolation("unexpected \(frame.header.kind) frame on a send-only link"), wake: wake)
                    }
                    return
                } catch ShardLinkError.receiveTimedOut {
                    continue
                } catch {
                    record(error, wake: wake)
                    return
                }
            }
        }
        thread.start()
    }

    /// After this, link failures are expected (session end) and no longer recorded.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private func record(_ error: Error, wake: ShardStageLink) {
        lock.lock()
        let ignore = stopped
        if !ignore, recorded == nil { recorded = error }
        lock.unlock()
        if !ignore { wake.close() }
    }
}

// MARK: - Session

/// One stage's side of a shard-bench run. Runs on a dedicated thread: model compute
/// and socket I/O are synchronous and must not block Swift's cooperative pool.
final class ShardBenchSession<Stage: ShardBenchStage> {
    private let options: ShardBenchSessionOptions
    private let stage: Stage
    private let watch = ShardBenchLinkWatch()
    private let probeRequestID: UInt64 = 0
    private let warmupRequestID: UInt64 = 1
    private let firstRequestID: UInt64 = 2
    private var stageIndex = 0
    /// Per-request digests and counts for this member's sub-receipts.
    private var ledgers = [UInt64: MemberLedger]()

    private struct MemberLedger {
        var input = ShardActivationDigestChain()
        var output = ShardActivationDigestChain()
        var promptTokens = 0
        var decodeSteps = 0
    }

    init(options: ShardBenchSessionOptions, stage: Stage) {
        self.options = options
        self.stage = stage
    }

    func run() throws -> ShardBenchSessionReport {
        let links = try ShardBenchLinks.open(
            listen: options.listen, connect: options.connect,
            connectTimeout: options.connectTimeout, configuration: options.link)
        return try run(links: links)
    }

    /// Run over already-open links (unit tests wire in-process loopback pairs).
    func run(links: ShardBenchLinks) throws -> ShardBenchSessionReport {
        defer {
            watch.stop()
            links.close()
        }
        if options.temperature > 0 { MLXRandom.seed(options.seed) }
        do {
            try checkRole()
            switch options.role {
            case .head:
                let chain = try headHandshake(links)
                helloSucceeded(links, stages: "\(chain.count)")
                if !links.isCollapsed { watch.watch(links.downstream, wake: links.upstream) }
                return ShardBenchSessionReport(head: try runHead(links: links, chain: chain))
            case .middle:
                let upstreamProbe = try middleHandshake(links)
                helloSucceeded(links, stages: "?")
                watch.watch(links.downstream, wake: links.upstream)
                return ShardBenchSessionReport(stage: try runStage(links: links, upstreamProbe: upstreamProbe, returnProbe: nil))
            case .tail:
                let (upstreamProbe, returnProbe) = try tailHandshake(links)
                helloSucceeded(links, stages: "\(stageIndex + 1)")
                if !links.isCollapsed { watch.watch(links.downstream, wake: links.upstream) }
                return ShardBenchSessionReport(stage: try runStage(links: links, upstreamProbe: upstreamProbe, returnProbe: returnProbe))
            }
        } catch {
            // A watched link's failure closed the receive link to wake us; report the cause.
            let cause = watch.failure ?? error
            sendError(links, cause)
            throw cause
        }
    }

    /// The hello exchange is done: from here a silent peer is a dead peer.
    private func helloSucceeded(_ links: ShardBenchLinks, stages: String) {
        for link in links.unique { link.armLiveness() }
        shardBenchLog("hello ok epoch=\(options.link.groupEpoch) stage=\(stageIndex) stages=\(stages)")
    }

    private func checkRole() throws {
        let first = stage.layers.lowerBound == 0
        let last = stage.layers.upperBound == stage.totalLayers
        switch options.role {
        case .head where !first:
            throw ShardBenchError.handshake("head must own layer 0 (got \(stage.layers))")
        case .tail where !last:
            throw ShardBenchError.handshake("tail must own the last layer \(stage.totalLayers - 1)")
        case .middle where first || last:
            throw ShardBenchError.handshake("a middle stage owns neither layer 0 nor the last layer (got \(stage.layers))")
        default:
            return
        }
    }

    // MARK: Handshake

    private func myHello() -> ShardBenchHello {
        ShardBenchHello(
            role: options.role, modelType: stage.modelType, totalLayers: stage.totalLayers,
            hiddenSize: stage.hiddenSize, layerStart: stage.layers.lowerBound, layerEnd: stage.layers.upperBound)
    }

    /// Head: send the one-stage chain down, then read the complete chain back on the
    /// return link, echoing each receiving end's probes meanwhile.
    private func headHandshake(_ links: ShardBenchLinks) throws -> [ShardBenchHello] {
        let mine = myHello()
        stageIndex = 0
        try sendHello(links.downstream, [mine], destination: 1)
        let acknowledged = try awaitHello(links.downstream)
        let chain = links.isCollapsed ? acknowledged : try awaitHello(links.upstream)
        try ShardBenchChain.validateComplete(chain)
        guard chain[0] == mine else { throw ShardBenchError.handshake("the returned chain does not start with this head") }
        if let expected = options.expectedStages, chain.count != expected {
            throw ShardBenchError.handshake("chain has \(chain.count) stages, expected \(expected)")
        }
        return chain
    }

    /// Middle: take the chain so far, probe the upstream link, acknowledge upstream,
    /// pass the chain on and wait for the next stage's acknowledgement.
    private func middleHandshake(_ links: ShardBenchLinks) throws -> ShardBenchLatency {
        let received = try awaitHello(links.upstream)
        var mine = myHello()
        try ShardBenchChain.validate(prefix: received, next: mine)
        stageIndex = received.count
        let probe = try measureProbes(links.upstream, peer: stageIndex - 1)
        mine.upstreamProbe = probe
        let chain = received + [mine]
        try sendHello(links.upstream, chain, destination: stageIndex - 1)
        try sendHello(links.downstream, chain, destination: stageIndex + 1)
        _ = try awaitHello(links.downstream)
        return probe
    }

    /// Tail: take the chain, probe the upstream link and, when separate, the return
    /// link, then send the complete chain to the head.
    private func tailHandshake(_ links: ShardBenchLinks) throws -> (ShardBenchLatency, ShardBenchLatency?) {
        let received = try awaitHello(links.upstream)
        var mine = myHello()
        try ShardBenchChain.validate(prefix: received, next: mine)
        stageIndex = received.count
        let upstreamProbe = try measureProbes(links.upstream, peer: stageIndex - 1)
        mine.upstreamProbe = upstreamProbe
        var returnProbe: ShardBenchLatency?
        if !links.isCollapsed {
            try sendHello(links.upstream, received + [mine], destination: stageIndex - 1)
            returnProbe = try measureProbes(links.downstream, peer: 0)
            mine.returnProbe = returnProbe
        }
        let chain = received + [mine]
        try ShardBenchChain.validateComplete(chain)
        try sendHello(links.downstream, chain, destination: 0)
        return (upstreamProbe, returnProbe)
    }

    private func sendHello(_ link: ShardStageLink, _ chain: [ShardBenchHello], destination: Int) throws {
        try link.send(ShardStageFrame(
            header: header(.hello, destination: destination),
            payload: try JSONEncoder().encode(ShardBenchChainHello(stages: chain))))
    }

    /// Read until the peer's hello, echoing its link probes meanwhile.
    private func awaitHello(_ link: ShardStageLink) throws -> [ShardBenchHello] {
        while true {
            let frame = try receive(link, timeout: options.connectTimeout)
            switch frame.header.kind {
            case .activation where frame.header.requestID == probeRequestID:
                var echo = frame.header
                echo.sourceStage = UInt16(stageIndex)
                echo.destinationStage = frame.header.sourceStage
                echo.layerStart = UInt32(stage.layers.lowerBound)
                echo.layerEnd = UInt32(stage.layers.upperBound)
                try link.send(ShardStageFrame(header: echo, payload: frame.payload))
            case .hello:
                do {
                    return try JSONDecoder().decode(ShardBenchChainHello.self, from: frame.payload).stages
                } catch {
                    throw ShardBenchError.handshake("undecodable hello: \(error)")
                }
            default:
                throw ShardBenchError.handshake("expected hello, got \(frame.header.kind)")
            }
        }
    }

    /// Echo probes of one decode-sized activation on `link`: transport + codec cost of
    /// one hop out and back, no model compute.
    private func measureProbes(_ link: ShardStageLink, peer: Int) throws -> ShardBenchLatency {
        let shape: [UInt32] = [1, 1, UInt32(stage.hiddenSize)]
        let payload = Data(count: 2 * stage.hiddenSize)
        var samples = [Double]()
        let warmup = min(10, options.probeCount)
        for index in 0..<(options.probeCount + warmup) {
            let start = now()
            try link.send(ShardStageFrame(
                header: header(.activation, dtype: .bfloat16, requestID: probeRequestID, step: UInt32(index),
                               destination: peer, shape: shape),
                payload: payload))
            let echo = try receive(link, timeout: options.receiveTimeout)
            guard echo.header.kind == .activation, echo.header.requestID == probeRequestID,
                  echo.header.tokenStep == UInt32(index)
            else {
                throw ShardBenchError.protocolViolation("probe echo out of order")
            }
            if index >= warmup { samples.append(now() - start) }
        }
        return ShardBenchLatency(seconds: samples)
    }

    private func header(
        _ kind: ShardFrameKind,
        dtype: ShardTensorDType = .none,
        requestID: UInt64 = 0,
        microBatch: UInt32 = 0,
        step: UInt32 = 0,
        destination: Int,
        shape: [UInt32] = [],
        flags: ShardFrameFlags = []
    ) -> ShardStageFrameHeader {
        ShardStageFrameHeader(
            kind: kind, dtype: dtype, groupEpoch: options.link.groupEpoch, requestID: requestID,
            microBatchID: microBatch, tokenStep: step, sourceStage: UInt16(stageIndex),
            destinationStage: UInt16(destination),
            layerStart: UInt32(stage.layers.lowerBound), layerEnd: UInt32(stage.layers.upperBound),
            shape: shape, flags: flags)
    }

    /// Fold one frame this member received upstream (or, the head, a returned token).
    private func recordInput(_ header: ShardStageFrameHeader, _ payload: Data) {
        ledgers[header.requestID, default: MemberLedger()].input.fold(
            requestID: header.requestID, tokenStep: header.tokenStep, payload: payload)
    }

    /// Fold one frame this member sent downstream; activations count toward the
    /// prompt tokens or decode steps it processed.
    private func recordOutput(_ header: ShardStageFrameHeader, _ payload: Data, processedTokens: Int) {
        var ledger = ledgers[header.requestID, default: MemberLedger()]
        ledger.output.fold(requestID: header.requestID, tokenStep: header.tokenStep, payload: payload)
        if header.tokenStep == 0 {
            ledger.promptTokens += processedTokens
        } else {
            ledger.decodeSteps += 1
        }
        ledgers[header.requestID] = ledger
    }

    private func subReceipts() -> [ShardMemberSubReceipt] {
        ledgers.keys.sorted().map { requestID in
            let ledger = ledgers[requestID]!
            return ShardMemberSubReceipt(
                memberDeviceID: options.memberID ?? "stage-\(stageIndex)", groupEpoch: options.link.groupEpoch,
                stageIndex: stageIndex, layerStart: stage.layers.lowerBound, layerEnd: stage.layers.upperBound,
                requestID: requestID, promptTokens: ledger.promptTokens, decodeSteps: ledger.decodeSteps,
                inDigest: ledger.input.hex, outDigest: ledger.output.hex)
        }
    }

    private static func decodeReceipts(_ payload: Data) throws -> [ShardMemberSubReceipt] {
        guard !payload.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([ShardMemberSubReceipt].self, from: payload)
        } catch {
            throw ShardBenchError.protocolViolation("undecodable sub-receipts in the session-end frame: \(error)")
        }
    }

    /// Where this stage's downstream sends go: the next stage, or the head for the tail.
    private var downstreamIndex: Int { options.role == .tail ? 0 : stageIndex + 1 }

    private func sendError(_ links: ShardBenchLinks, _ error: Error) {
        // Best effort on every link: one of them may be the one that failed.
        for link in links.unique {
            _ = try? link.send(ShardStageFrame(
                header: ShardStageFrameHeader(kind: .error, groupEpoch: options.link.groupEpoch),
                payload: Data(String(describing: error).prefix(4096).utf8)))
        }
    }

    private func receive(_ link: ShardStageLink, timeout: TimeInterval? = nil) throws -> ShardStageFrame {
        let frame = try link.receive(timeout: timeout ?? options.receiveTimeout)
        if frame.header.kind == .error {
            throw ShardBenchError.peerError(String(decoding: frame.payload, as: UTF8.self))
        }
        return frame
    }

    // MARK: Head

    private struct HeadSequence {
        let requestID: UInt64
        let microBatch: UInt32
        let cache: Stage.Cache
        var tokens: [Int] = []
        var lastSend: TimeInterval = 0
        var prefillStart: TimeInterval = 0
        var firstTokenAt: TimeInterval?
        var lastTokenAt: TimeInterval?
    }

    private func runHead(links: ShardBenchLinks, chain: [ShardBenchHello]) throws -> ShardBenchHeadReport {
        if options.warmup {
            _ = try pipelineDecode(
                links: links, prompts: [options.prompts[0]], tokens: min(4, options.tokens), firstRequestID: warmupRequestID)
        }
        let run = try pipelineDecode(links: links, prompts: options.prompts, tokens: options.tokens, firstRequestID: firstRequestID)
        // Session end: request id 0 abort travels down the chain; the tail answers on
        // the return link once it has seen it, so no stage reads a close as a failure.
        watch.stop()
        try links.downstream.send(ShardStageFrame(header: header(.abort, requestID: probeRequestID, destination: 1)))
        let end = try receive(links.upstream)
        guard end.header.kind == .abort, end.header.requestID == probeRequestID else {
            throw ShardBenchError.protocolViolation("expected the session-end acknowledgement, got \(end.header.kind) request \(end.header.requestID)")
        }
        // The acknowledgement carries every downstream member's sub-receipts in stage order.
        let attestation = ShardBenchAttestationReport.verify(
            head: subReceipts(), others: try Self.decodeReceipts(end.payload), requests: run.sequences.map(\.requestID))

        let decodeTPS = run.sequences.compactMap { sequence -> Double? in
            guard let first = sequence.firstTokenAt, let last = sequence.lastTokenAt, sequence.tokens.count > 1, last > first else {
                return nil
            }
            return Double(sequence.tokens.count - 1) / (last - first)
        }
        let totalTokens = run.sequences.reduce(0) { $0 + $1.tokens.count }
        let hops = ShardBenchChain.hops(chain)
        let linkReports = links.isCollapsed
            ? [ShardBenchLinkReport(name: "downstream+return", peerStage: 1, statistics: links.downstream.statistics, probe: hops.first?.probeRoundTrip)]
            : [ShardBenchLinkReport(name: "downstream", peerStage: 1, statistics: links.downstream.statistics, probe: hops.first?.probeRoundTrip),
               ShardBenchLinkReport(name: "return", peerStage: chain.count - 1, statistics: links.upstream.statistics, probe: hops.last?.probeRoundTrip)]
        return ShardBenchHeadReport(
            model: options.modelLabel,
            modelType: stage.modelType,
            layers: "\(stage.layers.lowerBound):\(stage.layers.upperBound)",
            stageCount: chain.count,
            stageLayers: chain.map(\.layerLabel),
            totalLayers: stage.totalLayers,
            hiddenSize: stage.hiddenSize,
            activationDtype: run.activationDType,
            stageWeightBytes: stage.weightBytes,
            concurrency: options.prompts.count,
            tokensPerSequence: options.tokens,
            promptTokens: options.prompts.map(\.count),
            sequenceTokens: run.sequences.map(\.tokens),
            totalTokens: totalTokens,
            singleStreamTokensPerSecond: decodeTPS.isEmpty ? nil : round3(decodeTPS.reduce(0, +) / Double(decodeTPS.count)),
            aggregateTokensPerSecond: round3(Double(totalTokens) / max(run.wallSeconds, 1e-9)),
            ttft: ShardBenchLatency(seconds: run.sequences.compactMap { sequence in
                sequence.firstTokenAt.map { $0 - sequence.prefillStart }
            }),
            probeRoundTrip: hops.first?.probeRoundTrip,
            hops: hops,
            decodeStepRoundTrip: ShardBenchLatency(seconds: run.stepRoundTrips),
            headDecodeCompute: ShardBenchLatency(seconds: run.headCompute),
            decodeHopPayloadBytes: run.decodeHopPayloadBytes,
            decodeHopFrameBytes: ShardStageFrameCodec.frameSize(rank: 3, payloadLength: run.decodeHopPayloadBytes),
            prefillHopPayloadBytes: run.prefillPayloadBytes,
            prefillChunkTokens: options.prefillChunk,
            prefillChunksPerSequence: run.prefillChunks,
            headPrefillChunkCompute: ShardBenchLatency(seconds: run.prefillChunkCompute),
            links: linkReports,
            attestation: attestation,
            parity: nil,
            referenceSingleStreamTokensPerSecond: nil
        )
    }

    private struct PipelineRun {
        var sequences: [HeadSequence]
        var stepRoundTrips: [Double]
        var headCompute: [Double]
        var wallSeconds: Double
        var decodeHopPayloadBytes: Int
        var prefillPayloadBytes: [Int]
        var prefillChunks: [Int]
        var prefillChunkCompute: [Double]
        var activationDType: String
    }

    /// Keep every sequence in flight: each stage answers in arrival order, and while a
    /// downstream stage computes one sequence's step the head computes the next
    /// sequence's, so with K >= S every stage stays busy.
    private func pipelineDecode(
        links: ShardBenchLinks,
        prompts: [[Int]],
        tokens: Int,
        firstRequestID: UInt64
    ) throws -> PipelineRun {
        var sequences = [HeadSequence]()
        var index = [UInt64: Int]()
        var run = PipelineRun(
            sequences: [], stepRoundTrips: [], headCompute: [], wallSeconds: 0,
            decodeHopPayloadBytes: 0, prefillPayloadBytes: [], prefillChunks: [], prefillChunkCompute: [], activationDType: "")
        let start = now()
        for (offset, prompt) in prompts.enumerated() {
            let requestID = firstRequestID + UInt64(offset) * 2
            var sequence = HeadSequence(requestID: requestID, microBatch: UInt32(offset), cache: try stage.newCache())
            sequence.prefillStart = now()
            // Chunk i goes down the chain as soon as the head has computed it, so stage
            // k+1 works on chunk i while stage k computes chunk i+1. Only the last chunk
            // asks the tail for a token.
            let chunkSize = options.prefillChunk ?? max(1, prompt.count)
            let chunkStarts = Array(stride(from: 0, to: prompt.count, by: chunkSize))
            var payloadBytes = 0
            for (chunkIndex, chunkStart) in chunkStarts.enumerated() {
                let chunk = Array(prompt[chunkStart..<min(prompt.count, chunkStart + chunkSize)])
                let computeStart = now()
                let hidden = try stage.forward(tokens: chunk, cache: sequence.cache)
                let elapsed = now() - computeStart
                run.prefillChunkCompute.append(elapsed)
                try checkPrefillDeadline(elapsed, tokens: chunk.count)
                let isLast = chunkIndex == chunkStarts.count - 1
                try sendActivation(links.downstream, hidden, sequence: &sequence, step: 0, flags: isLast ? [] : .fillOnly)
                payloadBytes += hidden.payload.count
                run.activationDType = String(describing: hidden.dtype)
            }
            run.prefillPayloadBytes.append(payloadBytes)
            run.prefillChunks.append(chunkStarts.count)
            index[requestID] = sequences.count
            sequences.append(sequence)
        }
        var remaining = sequences.count
        while remaining > 0 {
            let frame = try receive(links.upstream)
            guard frame.header.kind == .token, frame.header.dtype == .int32, frame.payload.count == 4,
                  let slot = index[frame.header.requestID]
            else {
                throw ShardBenchError.protocolViolation("expected a token for an active request, got \(frame.header.kind) request \(frame.header.requestID)")
            }
            let arrived = now()
            let token = Int(frame.payload.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) })
            var sequence = sequences[slot]
            guard frame.header.tokenStep == UInt32(sequence.tokens.count) else {
                throw ShardBenchError.protocolViolation("request \(sequence.requestID) token step \(frame.header.tokenStep), expected \(sequence.tokens.count)")
            }
            recordInput(frame.header, frame.payload)
            if sequence.tokens.isEmpty {
                sequence.firstTokenAt = arrived
            } else {
                run.stepRoundTrips.append(arrived - sequence.lastSend)
            }
            sequence.tokens.append(token)
            sequence.lastTokenAt = arrived
            if sequence.tokens.count >= tokens {
                try links.downstream.send(ShardStageFrame(header: header(.abort, requestID: sequence.requestID, destination: 1)))
                remaining -= 1
            } else {
                let computeStart = now()
                let hidden = try stage.forward(tokens: [token], cache: sequence.cache)
                run.headCompute.append(now() - computeStart)
                try sendActivation(links.downstream, hidden, sequence: &sequence, step: UInt32(sequence.tokens.count))
                run.decodeHopPayloadBytes = hidden.payload.count
            }
            sequences[slot] = sequence
        }
        run.wallSeconds = now() - start
        run.sequences = sequences
        return run
    }

    private func sendActivation(
        _ link: ShardStageLink,
        _ hidden: ShardBenchActivation,
        sequence: inout HeadSequence,
        step: UInt32,
        flags: ShardFrameFlags = []
    ) throws {
        sequence.lastSend = now()
        let frameHeader = header(.activation, dtype: hidden.dtype, requestID: sequence.requestID,
                                 microBatch: sequence.microBatch, step: step, destination: 1, shape: hidden.shape,
                                 flags: flags)
        try link.send(ShardStageFrame(header: frameHeader, payload: hidden.payload))
        recordOutput(frameHeader, hidden.payload, processedTokens: hidden.shape.count == 3 ? Int(hidden.shape[1]) : 0)
    }

    /// SPEC-051-R013: a stage whose compute for one prefill chunk passes the chunk
    /// deadline fails the run instead of risking the GPU watchdog on a real group.
    private func checkPrefillDeadline(_ elapsed: TimeInterval, tokens: Int) throws {
        guard elapsed > options.prefillChunkDeadline else { return }
        throw ShardBenchError.prefillChunkDeadline(
            stage: stageIndex, tokens: tokens, milliseconds: Int((elapsed * 1000).rounded()),
            deadlineMilliseconds: Int((options.prefillChunkDeadline * 1000).rounded()))
    }

    // MARK: Middle and tail

    /// A middle stage forwards each activation downstream; the tail samples and sends
    /// the token on the return link. Both see per-request aborts and the session end.
    private func runStage(
        links: ShardBenchLinks,
        upstreamProbe: ShardBenchLatency,
        returnProbe: ShardBenchLatency?
    ) throws -> ShardBenchStageReport {
        var caches = [UInt64: Stage.Cache]()
        var served = Set<UInt64>()
        var decodeCompute = [Double]()
        var prefillCompute = [Double]()
        // The head may spend a long time loading its reference or warming up between
        // frames, but it heartbeats throughout, so only a dead or silent peer ends this.
        loop: while true {
            let frame = try receive(links.upstream, timeout: max(options.receiveTimeout, 3600))
            let header = frame.header
            switch header.kind {
            case .activation where header.requestID == probeRequestID:
                throw ShardBenchError.protocolViolation("link probe after the handshake")
            case .activation:
                let start = now()
                let cache: Stage.Cache
                if let existing = caches[header.requestID] {
                    cache = existing
                } else {
                    guard header.tokenStep == 0 else {
                        throw ShardBenchError.protocolViolation("request \(header.requestID) step \(header.tokenStep) has no prefill")
                    }
                    guard caches.count < options.maxSequences else { throw ShardBenchError.tooManySequences(options.maxSequences) }
                    cache = try stage.newCache()
                    caches[header.requestID] = cache
                    served.insert(header.requestID)
                }
                let input = ShardBenchActivation(dtype: header.dtype, shape: header.shape, payload: frame.payload)
                recordInput(header, frame.payload)
                let processed = header.shape.count == 3 ? Int(header.shape[1]) : 0
                if options.role == .tail, header.flags.contains(.fillOnly) {
                    try stage.fill(activation: input, cache: cache)
                    // A fill-only chunk sends nothing, but its tokens were processed.
                    ledgers[header.requestID, default: MemberLedger()].promptTokens += header.tokenStep == 0 ? processed : 0
                    ledgers[header.requestID, default: MemberLedger()].decodeSteps += header.tokenStep == 0 ? 0 : 1
                } else if options.role == .tail {
                    let token = try stage.sample(activation: input, cache: cache, temperature: options.temperature)
                    var payload = Data(count: 4)
                    payload.withUnsafeMutableBytes { $0.storeBytes(of: Int32(token).littleEndian, as: Int32.self) }
                    let tokenHeader = self.header(.token, dtype: .int32, requestID: header.requestID,
                                                  microBatch: header.microBatchID, step: header.tokenStep,
                                                  destination: downstreamIndex, shape: [1])
                    try links.downstream.send(ShardStageFrame(header: tokenHeader, payload: payload))
                    recordOutput(tokenHeader, payload, processedTokens: processed)
                } else {
                    let output = try stage.forward(activation: input, cache: cache)
                    let outputHeader = self.header(.activation, dtype: output.dtype, requestID: header.requestID,
                                                   microBatch: header.microBatchID, step: header.tokenStep,
                                                   destination: downstreamIndex, shape: output.shape, flags: header.flags)
                    try links.downstream.send(ShardStageFrame(header: outputHeader, payload: output.payload))
                    recordOutput(outputHeader, output.payload, processedTokens: processed)
                }
                if header.tokenStep == 0 {
                    let elapsed = now() - start
                    prefillCompute.append(elapsed)
                    try checkPrefillDeadline(elapsed, tokens: Int(header.shape.count == 3 ? header.shape[1] : 0))
                } else {
                    decodeCompute.append(now() - start)
                }
            case .abort where header.requestID == probeRequestID:
                // Session end: the next stage (or, from the tail, the head) closing its
                // side is now expected.
                watch.stop()
                // Pass the upstream members' sub-receipts on with this member's appended.
                let receipts = try Self.decodeReceipts(frame.payload) + subReceipts()
                try links.downstream.send(ShardStageFrame(
                    header: self.header(.abort, requestID: probeRequestID, destination: downstreamIndex),
                    payload: try JSONEncoder().encode(receipts)))
                break loop
            case .abort:
                caches[header.requestID] = nil
                if options.role == .middle {
                    try links.downstream.send(ShardStageFrame(
                        header: self.header(.abort, requestID: header.requestID, destination: downstreamIndex)))
                }
            case .error:
                throw ShardBenchError.peerError(String(decoding: frame.payload, as: UTF8.self))
            case .hello, .token, .heartbeat:
                throw ShardBenchError.protocolViolation("unexpected \(header.kind) frame on a \(options.role.rawValue) stage")
            }
        }
        let upstreamName = links.isCollapsed ? "upstream+return" : "upstream"
        var linkReports = [ShardBenchLinkReport(
            name: upstreamName, peerStage: stageIndex - 1, statistics: links.upstream.statistics, probe: upstreamProbe)]
        if !links.isCollapsed {
            linkReports.append(ShardBenchLinkReport(
                name: options.role == .tail ? "return" : "downstream", peerStage: downstreamIndex,
                statistics: links.downstream.statistics, probe: returnProbe))
        }
        return ShardBenchStageReport(
            role: options.role,
            stageIndex: stageIndex,
            model: options.modelLabel,
            modelType: stage.modelType,
            layers: "\(stage.layers.lowerBound):\(stage.layers.upperBound)",
            totalLayers: stage.totalLayers,
            stageWeightBytes: stage.weightBytes,
            sequencesServed: served.count,
            decodeCompute: ShardBenchLatency(seconds: decodeCompute),
            prefillCompute: ShardBenchLatency(seconds: prefillCompute),
            links: linkReports
        )
    }

    private func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }
}

private func round3(_ value: Double) -> Double {
    (value * 1000).rounded() / 1000
}

// MARK: - Reference decode

enum ShardBenchReference {
    /// Greedy fixed-length decode with the stock model loaded through
    /// `LLMModelFactory`, the same op sequence the stages run: whole-prompt prefill,
    /// then one token per forward.
    static func decode(directory: URL, prompts: [[Int]], tokens: Int) async throws -> ShardBenchReferenceReport {
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: ChatTemplateCompatTokenizerLoader())
        return try await container.perform { context in
            var sequences = [[Int]]()
            var rates = [Double]()
            var ttfts = [Double]()
            for prompt in prompts {
                let cache = try context.model.newCache(parameters: nil)
                let start = Date()
                var logits = context.model(
                    LMInput.Text(tokens: MLXArray(prompt.map(Int32.init)).reshaped(1, prompt.count)),
                    cache: cache, state: nil).logits
                var token = argMax(logits[0, -1], axis: -1).item(Int.self)
                let first = Date()
                ttfts.append(first.timeIntervalSince(start))
                var generated = [token]
                while generated.count < tokens {
                    logits = context.model(
                        LMInput.Text(tokens: MLXArray([Int32(token)]).reshaped(1, 1)), cache: cache, state: nil).logits
                    token = argMax(logits[0, -1], axis: -1).item(Int.self)
                    generated.append(token)
                }
                let elapsed = Date().timeIntervalSince(first)
                if generated.count > 1, elapsed > 0 { rates.append(Double(generated.count - 1) / elapsed) }
                sequences.append(generated)
            }
            return ShardBenchReferenceReport(
                sequenceTokens: sequences,
                promptTokens: prompts.map(\.count),
                singleStreamTokensPerSecond: rates.isEmpty ? nil : round3(rates.reduce(0, +) / Double(rates.count)),
                ttft: ShardBenchLatency(seconds: ttfts)
            )
        }
    }
}

/// Hands a loaded stage to the session thread. The stage is created in the async
/// context and then used only by that one thread.
final class ShardBenchStageBox: @unchecked Sendable {
    let stage: PipelineStageModel

    init(_ stage: PipelineStageModel) {
        self.stage = stage
    }
}

/// Run a synchronous body on its own thread and await its result.
enum ShardBenchThread {
    static func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let thread = Thread {
                continuation.resume(with: Result { try body() })
            }
            thread.stackSize = 16 << 20
            thread.start()
        }
    }
}
