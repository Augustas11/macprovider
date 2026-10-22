import ArgumentParser
import CryptoKit
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

    @Option(help: "Head: sampling temperature the last stage applies to every sequence (0 = greedy; parity needs 0).")
    var temperature: Float = 0

    @Option(help: "MLX random seed for temperature sampling.")
    var seed: UInt64 = 0

    @Option(name: .customLong("group-epoch"), help: "Group epoch every stage must agree on.")
    var groupEpoch: UInt64 = 1

    @Option(name: .customLong("heartbeat-ms"), help: "Heartbeat interval in milliseconds.")
    var heartbeatMilliseconds: Int = 100

    @Option(name: .customLong("missed-heartbeats"), help: "Peer is dead after this many silent heartbeat intervals.")
    var missedHeartbeats: Int = 3

    @Option(name: .customLong("frame-protection"), help: "crc32c, or hmac-sha256 (SPEC-051-R011: per-link keys from a key agreement signed by each stage's member key). Every stage must pass the same value.")
    var frameProtection: String = ShardLinkFrameProtection.crc32c.rawValue

    @Option(name: .customLong("receive-timeout"), help: "Per-receive deadline in seconds (covers the peers' compute for one step).")
    var receiveTimeout: Double = 60

    @Option(name: .customLong("connect-timeout"), help: "Seconds to wait for peers to connect, accept and finish the handshake.")
    var connectTimeout: Double = 120

    @Option(name: .customLong("probe-count"), help: "Echo probes (decode-activation sized) this stage measures on its upstream link.")
    var probeCount: Int = 200

    @Option(name: .customLong("max-sequences"), help: "Middle/tail: most sequences it holds KV caches for at once.")
    var maxSequences: Int = 64

    @Option(help: "Head, two-stage chains: a spare tail (--role tail --listen, same --layers, --group-epoch one above the head's, a long --connect-timeout) that replaces the tail if it is lost mid-run.")
    var spare: String?

    @Option(name: .customLong("replay-buffer-mb"), help: "Head with --spare: MiB of sent activations kept per run for replay; a request past it is not replayable.")
    var replayBufferMegabytes: Int = 512

    @Option(name: .customLong("replay-deadline-ms"), help: "Head with --spare: time to reach the spare and replay the delivered prefix (SPEC-051 replay_deadline_ms, 1000..30000).")
    var replayDeadlineMilliseconds: Int = 10000

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

    @Option(help: "Head: teacher-forced (feed the reference tokens, compare per-step logit summaries within tolerance) or exact (greedy token identity).")
    var parity: String = ShardBenchParityMode.teacherForced.rawValue

    @Option(name: .customLong("top-k"), help: "Teacher-forced parity and --emit-logits: logit summary size (top-k ids and logprobs).")
    var topK: Int = 8

    @Option(name: .customLong("tie-margin"), help: "Teacher-forced parity: a top-1 flip passes when the reference top-1/top-2 margin is below this (nats) and the sharded top-1 is the reference top-2.")
    var tieMargin: Double = 0.05

    @Option(name: .customLong("logprob-tolerance"), help: "Teacher-forced parity: fail when the p99 |delta logprob| of the reference token exceeds this (nats).")
    var logprobTolerance: Double = 0.1

    @Flag(name: .customLong("emit-logits"), help: "--local-reference: also record each step's logit summary, for a teacher-forced --reference on another machine.")
    var emitLogits = false

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
        guard ShardBenchParityMode(rawValue: parity) != nil else { throw ValidationError("--parity must be teacher-forced or exact") }
        guard (1...ShardLogitSummaryCodec.maxTopK).contains(topK), tieMargin >= 0, logprobTolerance > 0 else {
            throw ValidationError("--top-k must be within 1..\(ShardLogitSummaryCodec.maxTopK), --tie-margin >= 0, --logprob-tolerance > 0")
        }
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
        if spare != nil {
            guard parsed == .head else { throw ValidationError("--spare is a head option") }
            guard replayBufferMegabytes > 0, (1000...30000).contains(replayDeadlineMilliseconds) else {
                throw ValidationError("--replay-buffer-mb must be > 0 and --replay-deadline-ms within 1000..30000")
            }
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
            let report = try await ShardBenchReference.decode(
                directory: directory, prompts: prompts, tokens: tokens, topK: emitLogits ? topK : nil)
            try emit(report)
            return
        }

        // Read a reference file before the run so a bad path fails before any decoding.
        var referenceReport: ShardBenchReferenceReport?
        if let reference, role == ShardBenchRole.head.rawValue {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let data = try Data(contentsOf: URL(fileURLWithPath: (reference as NSString).expandingTildeInPath))
            referenceReport = try decoder.decode(ShardBenchReferenceReport.self, from: data)
        }
        let parityMode: ShardBenchParityMode = noParity ? .skipped : ShardBenchParityMode(rawValue: parity) ?? .teacherForced
        var provider: (@Sendable () throws -> ShardBenchReferenceReport)?
        var referenceSource = ""
        if parityMode == .teacherForced, role == ShardBenchRole.head.rawValue {
            if let referenceReport, let reference {
                guard referenceReport.stepLogits != nil else {
                    throw ValidationError("\(reference) has no step logits; make it with --local-reference --emit-logits")
                }
                provider = { referenceReport }
                referenceSource = "file:\(reference)"
            } else {
                // In process, after the chain's hello: links heartbeat while it decodes.
                let (promptsCopy, tokensCopy, topKCopy) = (prompts, tokens, topK)
                provider = {
                    try ShardBenchThread.wait {
                        Memory.clearCache()
                        return try await ShardBenchReference.decode(directory: directory, prompts: promptsCopy, tokens: tokensCopy, topK: topKCopy)
                    }
                }
                referenceSource = "in_process_stock_model"
            }
        }
        let (options, layerRange) = try sessionOptions(
            prompts: prompts, parityMode: parityMode, referenceProvider: provider, referenceSource: referenceSource)
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
        if parityMode == .teacherForced {
            // The session compared logit summaries while it ran.
            head.referenceSingleStreamTokensPerSecond = referenceReport?.singleStreamTokensPerSecond
        } else if temperature > 0 {
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
        if head.parity?.verdict == "mismatch" || head.parity?.verdict == "fail" { throw ExitCode(3) }
        if head.attestation.verdict == "broken" { throw ExitCode(5) }
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

    private func sessionOptions(
        prompts: [[Int]],
        parityMode: ShardBenchParityMode,
        referenceProvider: (@Sendable () throws -> ShardBenchReferenceReport)?,
        referenceSource: String
    ) throws -> (ShardBenchSessionOptions, Range<Int>) {
        guard let layers, let role, let parsedRole = ShardBenchRole(rawValue: role) else {
            throw ValidationError("--role and --layers a:b are required")
        }
        let parts = layers.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int(parts[0]), let upper = Int(parts[1]), lower < upper else {
            throw ValidationError("--layers must be a:b with a < b")
        }
        guard let protection = ShardLinkFrameProtection(rawValue: frameProtection) else {
            throw ValidationError("--frame-protection must be crc32c or hmac-sha256")
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
                armLivenessOnOpen: false,
                frameProtection: protection
            ),
            receiveTimeout: receiveTimeout,
            connectTimeout: connectTimeout,
            probeCount: probeCount,
            maxSequences: maxSequences,
            warmup: !noWarmup,
            prefillChunk: prefillChunk,
            prefillChunkDeadline: Double(prefillChunkDeadlineMilliseconds) / 1000,
            memberID: memberID,
            spare: try spare.map { try ShardBenchEndpoint.parse($0) },
            replayBufferBytes: replayBufferMegabytes * 1_048_576,
            replayDeadline: Double(replayDeadlineMilliseconds) / 1000,
            parity: ShardBenchParityOptions(
                mode: parityMode, topK: topK, tieMargin: tieMargin, logprobTolerance: logprobTolerance,
                referenceProvider: referenceProvider, referenceSource: referenceSource)
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
    /// One request's sampling state on the last stage.
    associatedtype Sampler

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
    /// Last stage: a request's sampler from its `control` open frame.
    func makeSampler(_ control: ShardRequestControl) -> Sampler
    /// Last stage: boundary activation in, next token out.
    func sample(activation: ShardBenchActivation, cache: Cache, sampler: Sampler) throws -> Int
    /// Last stage: extend the KV with a fill-only activation; no token is sampled.
    func fill(activation: ShardBenchActivation, cache: Cache) throws
    /// Last stage: boundary activation in, top-k logit summary of the last position out.
    func summarize(activation: ShardBenchActivation, cache: Cache, topK: Int) throws -> ShardLogitSummary
    /// SPEC-051-R017: one decode position of each of several requests in one
    /// forward, row `i` on `caches[i]`. First stage: one token per row.
    func forwardBatch(tokens: [Int], caches: [Cache]) throws -> [ShardBenchActivation]
    /// Middle stage: one single-position activation per row.
    func forwardBatch(activations: [ShardBenchActivation], caches: [Cache]) throws -> [ShardBenchActivation]
    /// Last stage: one single-position activation per row, each sampled with its
    /// request's sampler.
    func sampleBatch(activations: [ShardBenchActivation], caches: [Cache], samplers: [Sampler]) throws -> [Int]
}

/// Row by row, for stages that cannot batch.
extension ShardBenchStage {
    func forwardBatch(tokens: [Int], caches: [Cache]) throws -> [ShardBenchActivation] {
        try zip(tokens, caches).map { try forward(tokens: [$0], cache: $1) }
    }

    func forwardBatch(activations: [ShardBenchActivation], caches: [Cache]) throws -> [ShardBenchActivation] {
        try zip(activations, caches).map { try forward(activation: $0, cache: $1) }
    }

    func sampleBatch(activations: [ShardBenchActivation], caches: [Cache], samplers: [Sampler]) throws -> [Int] {
        try activations.indices.map { try sample(activation: activations[$0], cache: caches[$0], sampler: samplers[$0]) }
    }
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

    func makeSampler(_ control: ShardRequestControl) -> PipelineStageSampler {
        PipelineStageSampler(control)
    }

    func sample(activation: ShardBenchActivation, cache: [KVCache], sampler: PipelineStageSampler) throws -> Int {
        let input = try PipelineActivationCodec.decode(dtype: activation.dtype, shape: activation.shape, payload: activation.payload)
        return sampler.sample(logits: try forward(input, cache: cache))
    }

    func summarize(activation: ShardBenchActivation, cache: [KVCache], topK: Int) throws -> ShardLogitSummary {
        let input = try PipelineActivationCodec.decode(dtype: activation.dtype, shape: activation.shape, payload: activation.payload)
        return PipelineLogitSummarizer.summarize(logits: try forward(input, cache: cache), topK: topK)
    }

    func fill(activation: ShardBenchActivation, cache: [KVCache]) throws {
        try fill(try PipelineActivationCodec.decode(dtype: activation.dtype, shape: activation.shape, payload: activation.payload), cache: cache)
    }

    func forwardBatch(tokens: [Int], caches: [[KVCache]]) throws -> [ShardBenchActivation] {
        guard canBatchDecode(caches) else { return try zip(tokens, caches).map { try forward(tokens: [$0], cache: $1) } }
        return try split(try forwardBatch(MLXArray(tokens.map(Int32.init)).reshaped(tokens.count, 1), caches: caches))
    }

    func forwardBatch(activations: [ShardBenchActivation], caches: [[KVCache]]) throws -> [ShardBenchActivation] {
        guard let input = try batchInput(activations, caches: caches) else {
            return try zip(activations, caches).map { try forward(activation: $0, cache: $1) }
        }
        return try split(try forwardBatch(input, caches: caches))
    }

    func sampleBatch(activations: [ShardBenchActivation], caches: [[KVCache]], samplers: [PipelineStageSampler]) throws -> [Int] {
        guard let input = try batchInput(activations, caches: caches) else {
            return try activations.indices.map { try sample(activation: activations[$0], cache: caches[$0], sampler: samplers[$0]) }
        }
        let logits = try forwardBatch(input, caches: caches)
        return samplers.indices.map { samplers[$0].sample(logits: logits[$0 ..< $0 + 1]) }
    }

    /// `[B, 1, hidden]` of single-position activations of one dtype, or nil when
    /// these rows cannot share a forward.
    private func batchInput(_ activations: [ShardBenchActivation], caches: [[KVCache]]) throws -> MLXArray? {
        guard let first = activations.first, canBatchDecode(caches),
              activations.allSatisfy({ $0.dtype == first.dtype && $0.shape.count == 3 && $0.shape[0] == 1 && $0.shape[1] == 1 && $0.shape == first.shape })
        else { return nil }
        return concatenated(try activations.map {
            try PipelineActivationCodec.decode(dtype: $0.dtype, shape: $0.shape, payload: $0.payload)
        }, axis: 0)
    }

    private func split(_ hidden: MLXArray) throws -> [ShardBenchActivation] {
        try (0..<hidden.dim(0)).map { row in
            let encoded = try PipelineActivationCodec.encode(hidden[row ..< row + 1])
            return ShardBenchActivation(dtype: encoded.dtype, shape: encoded.shape, payload: encoded.payload)
        }
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
    /// Head: spare for its downstream stage (two-stage chains), reached on stage loss.
    let spare: ShardBenchEndpoint?
    let replayBufferBytes: Int
    /// SPEC-051-R022: reaching the spare and replaying must finish within this.
    let replayDeadline: TimeInterval
    let parity: ShardBenchParityOptions
    /// Member device identity signing this stage's sub-receipts; nil signs with an
    /// ephemeral key under `memberID` (lab).
    var signer: ShardMemberSigner? = nil
    /// Model digest this stage reports in its hello (SPEC-051-R008).
    var modelDigest: String? = nil
    /// SPEC-051-R029 interface types this stage reports in its hello: of the link it
    /// receives on, and (a tail with a separate return link) of that link.
    var upstreamInterface: String? = nil
    var returnInterface: String? = nil
    /// Middle or tail: called once the handshake is done, with the chain this stage
    /// knows and its own stage index.
    var onJoined: (@Sendable ([ShardBenchHello], Int) -> Void)? = nil
    /// Spare: called when it answered the head's standby hello, with the chain
    /// through itself and its stage index.
    var onStandby: (@Sendable ([ShardBenchHello], Int) -> Void)? = nil
    /// SPEC-051-R011: what a configured member checks of the chain it joins: the
    /// key its upstream neighbour (the stage before, the head for stage 1 or a
    /// spare) and its downstream neighbour (the next stage, the head for a tail's
    /// return link) announce and authenticate with, its own stage position, and
    /// the head's identity. nil (the lab harness) checks only that each link's
    /// authenticated key is the one its neighbour announces.
    var expectedUpstreamKey: String? = nil
    var expectedDownstreamKey: String? = nil
    var expectedStageIndex: Int? = nil
    var expectedHeadID: String? = nil
    /// Keep every compute time for the report (lab runs). A production member
    /// keeps only counts, so its memory does not grow with the traffic it serves.
    var recordComputeSamples = true
}

enum ShardBenchParityMode: String, Sendable {
    case teacherForced = "teacher-forced"
    case exact
    case skipped
}

struct ShardBenchParityOptions: Sendable {
    var mode: ShardBenchParityMode
    var topK: Int
    var tieMargin: Double
    var logprobTolerance: Double
    /// Teacher-forced head: the reference run (tokens and step logits), fetched after
    /// the chain's hello.
    var referenceProvider: (@Sendable () throws -> ShardBenchReferenceReport)?
    var referenceSource: String

    static let skipped = ShardBenchParityOptions(
        mode: .skipped, topK: 8, tieMargin: 0.05, logprobTolerance: 0.1, referenceProvider: nil, referenceSource: "")
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
    var teacherForced: ShardTeacherForcedParity? = nil

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
    let session: String
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
    let replayBufferBytes: Int?
    /// Spare replacements during the run (SPEC-051-R022).
    let replays: [ShardBenchReplayReport]
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

struct ShardBenchReplayReport: Encodable {
    let groupEpoch: UInt64
    let cause: String
    /// SPEC-051-R019 takeover reason code (`ShardGroupWire.takeoverReason`).
    var reason: String = "link_error"
    let spare: String
    let requests: [UInt64]
    let deliveredTokens: [Int]
    let replayedFrames: Int
    let replayedBytes: Int
    let milliseconds: Double
}

struct ShardBenchAttestationReport: Encodable {
    /// `ok` when every request's chain verified; `partial` when some request finished
    /// under a member that was lost before its sub-receipt came back; `broken` on any
    /// failed chain or signature.
    let verdict: String
    let requests: [ShardBenchRequestAttestation]

    init(_ summaries: [ShardGenerationSummary]) {
        requests = summaries.map { summary in
            ShardBenchRequestAttestation(
                requestID: summary.requestID, verdict: summary.attestation.verdict, fault: summary.attestation.fault,
                receipts: summary.attestation.receipts.map(\.receipt))
        }
        verdict = requests.contains { $0.verdict == "broken" } ? "broken" : (requests.allSatisfy { $0.verdict == "ok" } ? "ok" : "partial")
    }
}

/// Report of a middle or tail stage.
struct ShardBenchStageReport: Encodable {
    let schema = "macprovider.shard-bench.stage.v1"
    let session: String
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
    /// SPEC-051-R017: the most requests' decode rows one forward of this stage ran.
    let decodeBatchRowsMax: Int
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
    /// The prompts' token ids, so a teacher-forced head can check it uses the same ones.
    var prompts: [[Int]]? = nil
    /// `--emit-logits`: `[sequence][step]` logit summaries; step i is the distribution
    /// after the prompt and the first i reference tokens.
    var stepLogits: [[ShardLogitSummary]]? = nil
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
    /// Head only: random id of this run, logged and reported by every stage so a
    /// stage's log can be matched to the head that drove it.
    var session: String?
    /// Head only: the tail returns a top-k logit summary with every token.
    var logitTopK: Int?
    /// Member device identity of this stage; it names it in its sub-receipts.
    var memberDeviceID: String?
    /// Raw Ed25519 public key (base64) this stage signs its sub-receipts with.
    var memberPublicKey: String?
    /// Digest of the model files this stage loaded from (SPEC-051-R008).
    var modelDigest: String?
    /// SPEC-051-R029 interface type of the link this stage receives on.
    var upstreamInterface: String?
    /// Tail with a separate return link: that link's interface type.
    var returnInterface: String?

    var layerLabel: String { "\(layerStart):\(layerEnd)" }
}

/// Hello payload: the chain so far. It grows by one stage per hop and comes back
/// to the head complete on the return link.
struct ShardBenchChainHello: Codable, Equatable {
    let stages: [ShardBenchHello]
    /// SPEC-051-R007: the head's standby link to its spare. The spare answers with
    /// the chain through itself and then waits on the same link for the real hello
    /// the head sends when the spare takes over.
    var standby: Bool? = nil
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
    /// SPEC-051-R022: the stream ends with an explicit error after these deliveries;
    /// no delivered token is re-emitted.
    case streamTerminated(delivered: [UInt64: Int], cause: String)
    case reference(String)

    var description: String {
        switch self {
        case .handshake(let detail): return "handshake failed: \(detail)"
        case .protocolViolation(let detail): return "protocol violation: \(detail)"
        case .peerError(let detail): return "peer reported error: \(detail)"
        case .tooManySequences(let cap): return "more than \(cap) concurrent sequences"
        case .prefillChunkDeadline(let stage, let tokens, let milliseconds, let deadline):
            return "stage \(stage) took \(milliseconds) ms for a \(tokens)-token prefill chunk, over the \(deadline) ms chunk deadline; use a smaller --prefill-chunk"
        case .reference(let detail): return "reference unusable for teacher-forced parity: \(detail)"
        case .streamTerminated(let delivered, let cause):
            let total = delivered.values.reduce(0, +)
            let perRequest = delivered.keys.sorted().map { "request \($0): \(delivered[$0] ?? 0)" }.joined(separator: ", ")
            return "stream terminated after delivering \(total) tokens (\(perRequest)): \(cause)"
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
    ///
    /// On an `hmac-sha256` link each link runs its key agreement as soon as it is
    /// up (SPEC-051-R011), signed by `signer`. The inbound link is accepted and
    /// authenticated on its own thread while the dialed link authenticates, so in a
    /// ring where every stage both dials and accepts no stage waits on a peer that
    /// is itself waiting.
    static func open(
        listen: ShardBenchEndpoint?,
        connect: ShardBenchEndpoint?,
        connectTimeout: TimeInterval,
        configuration: ShardLinkConfiguration,
        session: String,
        signer: ShardMemberSigner
    ) throws -> ShardBenchLinks {
        let listener = try listen.map { try ShardStageListener(host: $0.host, port: $0.port) }
        if let listen, let listener {
            shardBenchLog("listening on \(listen.host):\(listener.port) session=\(session)")
        }
        // The inbound side: accept, then authenticate as the responder.
        let inbound = ShardBenchWaitBox<ShardStageLink>()
        let inboundDone = DispatchSemaphore(value: 0)
        if let listener {
            let thread = Thread {
                var link: ShardStageLink?
                do {
                    let accepted = try listener.accept(timeout: connectTimeout, configuration: configuration)
                    link = accepted
                    try accepted.authenticate(signer: signer, role: .responder, timeout: connectTimeout)
                    inbound.result = .success(accepted)
                } catch {
                    link?.close()
                    inbound.result = .failure(error)
                }
                inboundDone.signal()
            }
            thread.name = "shard-bench.accept"
            thread.start()
        }
        func awaitInbound() -> Result<ShardStageLink, Error>? {
            guard listener != nil else { return nil }
            inboundDone.wait()
            return inbound.result
        }
        var dialed: ShardStageLink?
        do {
            if let connect {
                // Log before and while dialing, so a run that never connects says where it
                // was dialing and why each attempt failed.
                shardBenchLog("connecting to \(connect.host):\(connect.port) session=\(session) timeout=\(Int(connectTimeout))s")
                let started = Date()
                var lastLog = started
                do {
                    dialed = try ShardStageLink.connect(
                        host: connect.host, port: connect.port, timeout: connectTimeout, configuration: configuration,
                        onRetry: { attempt, code in
                            let now = Date()
                            guard attempt == 1 || now.timeIntervalSince(lastLog) >= 5 else { return }
                            lastLog = now
                            shardBenchLog("still connecting to \(connect.host):\(connect.port): attempt \(attempt), \(String(cString: strerror(code))) after \(Int(now.timeIntervalSince(started)))s")
                        })
                } catch {
                    shardBenchLog("connect to \(connect.host):\(connect.port) failed after \(Int(Date().timeIntervalSince(started)))s: \(error)")
                    throw error
                }
            }
            if let dialed {
                shardBenchLog("connected to \(dialed.peerAddress)")
                try dialed.authenticate(signer: signer, role: .initiator, timeout: connectTimeout)
            }
        } catch {
            dialed?.close()
            if case .success(let link)? = awaitInbound() { link.close() }
            throw error
        }
        var accepted: ShardStageLink?
        switch awaitInbound() {
        case .success(let link)?:
            accepted = link
        case .failure(let error)?:
            dialed?.close()
            throw error
        case nil:
            break
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

/// One stage's side of a shard-bench run. The head is a thin client of
/// `ShardGroupEngine`; a middle or tail is the member stage server that
/// `shard-member` also runs. Runs on a dedicated thread: model compute and socket
/// I/O are synchronous and must not block Swift's cooperative pool.
final class ShardBenchSession<Stage: ShardBenchStage> {
    private let options: ShardBenchSessionOptions
    private let stage: Stage
    private var watch = ShardBenchLinkWatch()
    private let probeRequestID: UInt64 = 0
    private var stageIndex = 0
    /// The head's run id; other stages adopt it from the chain hello.
    private var sessionID = "from-head"
    /// Tail: send a logit summary of this size with every token (the head asked for it).
    private var returnLogitTopK: Int?
    /// Per-request digests and counts for this member's sub-receipts.
    private var book = ShardMemberLedgerBook()
    /// The member device key (`signer`), or an ephemeral key in the lab harness.
    private let key: Curve25519.Signing.PrivateKey

    init(options: ShardBenchSessionOptions, stage: Stage) {
        self.options = options
        self.stage = stage
        self.key = options.signer?.key ?? Curve25519.Signing.PrivateKey()
    }

    private var signer: ShardMemberSigner {
        ShardMemberSigner(
            memberDeviceID: options.signer?.memberDeviceID ?? options.memberID ?? "stage-\(stageIndex)", key: key)
    }

    func run() throws -> ShardBenchSessionReport {
        let links = try ShardBenchLinks.open(
            listen: options.listen, connect: options.connect,
            connectTimeout: options.connectTimeout, configuration: options.link,
            session: options.role == .head ? "head" : "from-head", signer: signer)
        return try run(links: links)
    }

    /// Run over already-open links (unit tests wire in-process loopback pairs).
    func run(links: ShardBenchLinks) throws -> ShardBenchSessionReport {
        if options.role == .head {
            return ShardBenchSessionReport(head: try runHead(links: links))
        }
        defer {
            watch.stop()
            links.close()
        }
        do {
            try checkRole()
            switch options.role {
            case .head:
                throw ShardBenchError.handshake("unreachable: the head runs the engine")
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
        shardBenchLog("hello ok epoch=\(links.upstream.groupEpoch) session=\(sessionID) stage=\(stageIndex) stages=\(stages)")
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

    // MARK: Head

    private func runHead(links: ShardBenchLinks) throws -> ShardBenchHeadReport {
        let engine = ShardGroupEngine(stage: stage, options: ShardGroupEngineOptions(
            link: options.link, connectTimeout: options.connectTimeout,
            decodeHopDeadline: options.receiveTimeout, prefillChunkDeadline: options.prefillChunkDeadline,
            replayDeadline: options.replayDeadline, maxInFlight: max(1, options.prompts.count),
            prefillChunk: options.prefillChunk, expectedStages: options.expectedStages, expectedMembers: nil,
            modelDigest: options.modelDigest, spare: options.spare, spareMember: nil,
            replayBufferBytes: options.replayBufferBytes,
            logitTopK: options.parity.mode == .teacherForced ? options.parity.topK : nil,
            signer: signer))
        try engine.start(links: links)
        let measured: [ShardGenerationSummary]
        let wallSeconds: Double
        do {
            let reference = options.parity.mode == .teacherForced ? try teacherReference() : nil
            if options.warmup {
                _ = try runBatch(engine, [ShardGenerationRequest(
                    promptTokens: options.prompts[0], maxTokens: min(4, options.tokens), control: control(0))])
            }
            let requests = options.prompts.enumerated().map { index, prompt in
                ShardGenerationRequest(
                    promptTokens: prompt, maxTokens: options.tokens, control: control(index),
                    teacherTokens: reference?.sequenceTokens[index])
            }
            let start = now()
            measured = try runBatch(engine, requests)
            wallSeconds = now() - start
            try engine.shutdown()
            var parity: ShardBenchParity?
            if let reference, let stepLogits = reference.stepLogits {
                let result = try ShardLogitParity.compare(
                    reference: stepLogits.map { Array($0.prefix(options.tokens)) },
                    sharded: measured.map(\.summaries),
                    tieMargin: options.parity.tieMargin, logprobTolerance: options.parity.logprobTolerance)
                parity = ShardBenchParity(
                    verdict: result.verdict, source: options.parity.referenceSource, matchingTokens: nil,
                    firstMismatch: result.hardFailures.first.map {
                        "sequence \($0.sequence) step \($0.step): sharded \($0.shardedToken) vs reference \($0.referenceToken) (reference margin \($0.referenceMargin))"
                    },
                    teacherForced: result)
            }
            return headReport(engine: engine, measured: measured, wallSeconds: wallSeconds, parity: parity)
        } catch {
            _ = try? engine.shutdown()
            throw error
        }
    }

    /// Sampling for sequence `index`; a seeded run gives each sequence its own stream.
    private func control(_ index: Int) -> ShardRequestControl {
        ShardRequestControl(
            temperature: options.temperature, topP: 1,
            seed: options.temperature > 0 ? options.seed &+ UInt64(index) : nil)
    }

    /// Submit a batch, wait for all of it, and return the summaries in order. A
    /// request lost with its stage surfaces as `streamTerminated` with every
    /// request's delivered count.
    private func runBatch(_ engine: ShardGroupEngine<Stage>, _ requests: [ShardGenerationRequest]) throws -> [ShardGenerationSummary] {
        let collector = ShardGenerationCollector(count: requests.count)
        let ids = try engine.submit(requests) { collector.receive($0, $1) }
        let (summaries, errors) = collector.wait()
        guard errors.isEmpty else {
            var delivered = [UInt64: Int]()
            var cause = ""
            for id in ids {
                switch errors[id] {
                case ShardGroupEngineError.streamTerminated(let count, let detail)?:
                    delivered[id] = count
                    cause = detail
                case ShardGroupEngineError.failedBeforeFirstToken(let detail)?:
                    delivered[id] = 0
                    cause = detail
                case let other?:
                    throw other
                case nil:
                    delivered[id] = summaries[id]?.tokens.count ?? 0
                }
            }
            throw ShardBenchError.streamTerminated(delivered: delivered, cause: cause)
        }
        return try ids.map { id in
            guard let summary = summaries[id] else { throw ShardBenchError.protocolViolation("request \(id) never finished") }
            return summary
        }
    }

    private func headReport(
        engine: ShardGroupEngine<Stage>, measured: [ShardGenerationSummary], wallSeconds: Double, parity: ShardBenchParity?
    ) -> ShardBenchHeadReport {
        let chain = engine.chain
        let decodeTPS = measured.compactMap { summary -> Double? in
            guard let first = summary.timing.firstTokenAt, let last = summary.timing.lastTokenAt, summary.tokens.count > 1, last > first else {
                return nil
            }
            return Double(summary.tokens.count - 1) / (last - first)
        }
        let totalTokens = measured.reduce(0) { $0 + $1.tokens.count }
        let hops = ShardBenchChain.hops(chain)
        var linkReports = [ShardBenchLinkReport]()
        if let links = engine.currentLinks {
            linkReports = links.isCollapsed
                ? [ShardBenchLinkReport(name: "downstream+return", peerStage: 1, statistics: links.downstream.statistics, probe: hops.first?.probeRoundTrip)]
                : [ShardBenchLinkReport(name: "downstream", peerStage: 1, statistics: links.downstream.statistics, probe: hops.first?.probeRoundTrip),
                   ShardBenchLinkReport(name: "return", peerStage: chain.count - 1, statistics: links.upstream.statistics, probe: hops.last?.probeRoundTrip)]
        }
        let decodeHopPayloadBytes = measured.map(\.timing.decodeHopPayloadBytes).max() ?? 0
        return ShardBenchHeadReport(
            session: engine.sessionID,
            model: options.modelLabel,
            modelType: stage.modelType,
            layers: "\(stage.layers.lowerBound):\(stage.layers.upperBound)",
            stageCount: chain.count,
            stageLayers: chain.map(\.layerLabel),
            totalLayers: stage.totalLayers,
            hiddenSize: stage.hiddenSize,
            activationDtype: measured.first?.timing.activationDType ?? "",
            stageWeightBytes: stage.weightBytes,
            concurrency: options.prompts.count,
            tokensPerSequence: options.tokens,
            promptTokens: options.prompts.map(\.count),
            sequenceTokens: measured.map(\.tokens),
            totalTokens: totalTokens,
            singleStreamTokensPerSecond: decodeTPS.isEmpty ? nil : round3(decodeTPS.reduce(0, +) / Double(decodeTPS.count)),
            aggregateTokensPerSecond: round3(Double(totalTokens) / max(wallSeconds, 1e-9)),
            ttft: ShardBenchLatency(seconds: measured.compactMap { summary in
                summary.timing.firstTokenAt.map { $0 - summary.timing.prefillStart }
            }),
            probeRoundTrip: hops.first?.probeRoundTrip,
            hops: hops,
            decodeStepRoundTrip: ShardBenchLatency(seconds: measured.flatMap(\.timing.stepRoundTrips)),
            headDecodeCompute: ShardBenchLatency(seconds: measured.flatMap(\.timing.headDecodeCompute)),
            decodeHopPayloadBytes: decodeHopPayloadBytes,
            decodeHopFrameBytes: ShardStageFrameCodec.frameSize(rank: 3, payloadLength: decodeHopPayloadBytes),
            prefillHopPayloadBytes: measured.map(\.timing.prefillPayloadBytes),
            prefillChunkTokens: options.prefillChunk,
            prefillChunksPerSequence: measured.map(\.timing.prefillChunks),
            headPrefillChunkCompute: ShardBenchLatency(seconds: measured.flatMap(\.timing.prefillChunkCompute)),
            links: linkReports,
            attestation: ShardBenchAttestationReport(measured),
            replayBufferBytes: options.spare == nil ? nil : options.replayBufferBytes,
            replays: engine.replays,
            parity: parity,
            referenceSingleStreamTokensPerSecond: nil
        )
    }

    /// Fetch the teacher-forced reference and check it covers this run: same prompts,
    /// at least `tokens` steps of tokens and logit summaries per sequence.
    private func teacherReference() throws -> ShardBenchReferenceReport {
        guard let provider = options.parity.referenceProvider else {
            throw ShardBenchError.reference("no reference provider for teacher-forced parity")
        }
        let reference = try provider()
        guard let stepLogits = reference.stepLogits else { throw ShardBenchError.reference("it has no step logits") }
        if let prompts = reference.prompts {
            guard prompts == options.prompts else { throw ShardBenchError.reference("its prompts differ from this run's") }
        } else if reference.promptTokens != options.prompts.map(\.count) {
            throw ShardBenchError.reference("its prompt lengths \(reference.promptTokens) differ from \(options.prompts.map(\.count))")
        }
        guard reference.sequenceTokens.count == options.prompts.count, stepLogits.count == options.prompts.count else {
            throw ShardBenchError.reference("it has \(stepLogits.count) sequences, this run has \(options.prompts.count)")
        }
        for (index, (tokens, logits)) in zip(reference.sequenceTokens, stepLogits).enumerated()
        where tokens.count < options.tokens || logits.count < options.tokens {
            throw ShardBenchError.reference("sequence \(index) has \(min(tokens.count, logits.count)) steps, this run needs \(options.tokens)")
        }
        // The file's summaries bypass the summary codec: apply its checks here.
        for (index, logits) in stepLogits.enumerated() {
            for (step, summary) in logits.prefix(options.tokens).enumerated() {
                do {
                    try ShardLogitSummaryCodec.validate(summary)
                } catch {
                    throw ShardBenchError.reference("sequence \(index) step \(step): \(error)")
                }
            }
        }
        return reference
    }

    // MARK: Member handshake

    private func myHello() -> ShardBenchHello {
        ShardBenchHello(
            role: options.role, modelType: stage.modelType, totalLayers: stage.totalLayers,
            hiddenSize: stage.hiddenSize, layerStart: stage.layers.lowerBound, layerEnd: stage.layers.upperBound,
            memberDeviceID: signer.memberDeviceID, memberPublicKey: signer.publicKeyBase64,
            modelDigest: options.modelDigest, upstreamInterface: options.upstreamInterface,
            returnInterface: options.returnInterface)
    }

    private func adoptSession(_ chain: [ShardBenchHello]) {
        if let session = chain.first?.session { sessionID = session }
        returnLogitTopK = chain.first?.logitTopK
    }

    /// SPEC-051-R011: the chain so far places this member where its group config
    /// does, under the configured head, after the configured upstream neighbour.
    private func checkJoin(_ received: [ShardBenchHello]) throws {
        if let expected = options.expectedStageIndex, received.count != expected {
            throw ShardBenchError.handshake("the chain places this member at stage \(received.count), its group config at stage \(expected)")
        }
        if let head = options.expectedHeadID, received.first?.memberDeviceID != head {
            throw ShardBenchError.handshake("the chain's head is \(received.first?.memberDeviceID ?? "unnamed"), the group config names \(head)")
        }
        if let upstream = received.last {
            try ShardChainWire.checkConfigured(upstream, key: options.expectedUpstreamKey, stage: received.count - 1)
        }
    }

    /// Middle: take the chain so far, probe the upstream link, acknowledge upstream,
    /// pass the chain on and wait for the next stage's acknowledgement.
    private func middleHandshake(_ links: ShardBenchLinks) throws -> ShardBenchLatency {
        let received = try awaitHello(links.upstream)
        adoptSession(received)
        stageIndex = received.count
        var mine = myHello()
        try ShardBenchChain.validate(prefix: received, next: mine)
        try checkJoin(received)
        try ShardChainWire.checkPeer(links.upstream, is: received[received.count - 1], stage: stageIndex - 1)
        let probe = try measureProbes(links.upstream, peer: stageIndex - 1)
        mine.upstreamProbe = probe
        let chain = received + [mine]
        try sendHello(links.upstream, chain, destination: stageIndex - 1)
        try sendHello(links.downstream, chain, destination: stageIndex + 1)
        // The next stage acknowledges with the chain through itself.
        let acknowledged = try awaitHello(links.downstream)
        guard acknowledged.count > chain.count, Array(acknowledged.prefix(chain.count)) == chain else {
            throw ShardBenchError.handshake("stage \(stageIndex + 1) acknowledged a chain that does not extend this one")
        }
        try ShardChainWire.checkConfigured(acknowledged[stageIndex + 1], key: options.expectedDownstreamKey, stage: stageIndex + 1)
        try ShardChainWire.checkPeer(links.downstream, is: acknowledged[stageIndex + 1], stage: stageIndex + 1)
        options.onJoined?(acknowledged, stageIndex)
        return probe
    }

    /// Tail: take the chain, probe the upstream link and, when separate, the return
    /// link, then send the complete chain to the head.
    private func tailHandshake(_ links: ShardBenchLinks) throws -> (ShardBenchLatency, ShardBenchLatency?) {
        let received = try awaitTailHello(links)
        adoptSession(received)
        stageIndex = received.count
        var mine = myHello()
        try ShardBenchChain.validate(prefix: received, next: mine)
        try checkJoin(received)
        try ShardChainWire.checkPeer(links.upstream, is: received[received.count - 1], stage: stageIndex - 1)
        if !links.isCollapsed {
            try ShardChainWire.checkConfigured(received[0], key: options.expectedDownstreamKey, stage: 0)
            try ShardChainWire.checkPeer(links.downstream, is: received[0], stage: 0)
        }
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
        options.onJoined?(chain, stageIndex)
        return (upstreamProbe, returnProbe)
    }

    private func sendHello(_ link: ShardStageLink, _ chain: [ShardBenchHello], destination: Int) throws {
        try ShardChainWire.sendHello(link, chain, header: header(.hello, destination: destination))
    }

    private func awaitHello(_ link: ShardStageLink) throws -> [ShardBenchHello] {
        let hello = try ShardChainWire.awaitChainHello(link, timeout: options.connectTimeout, stageIndex: stageIndex, layers: stage.layers)
        guard hello.standby != true else {
            throw ShardBenchError.handshake("a standby hello reached a stage that is not a spare")
        }
        return hello.stages
    }

    /// Tail: the first hello, after any number of standby exchanges. A spare is a
    /// tail on one collapsed link; while the head only keeps the link to measure it,
    /// the spare answers each standby hello with the chain through itself and waits,
    /// heartbeating, for the hello of the takeover.
    private func awaitTailHello(_ links: ShardBenchLinks) throws -> [ShardBenchHello] {
        var hello = try ShardChainWire.awaitChainHello(
            links.upstream, timeout: options.connectTimeout, stageIndex: stageIndex, layers: stage.layers)
        while hello.standby == true {
            guard links.isCollapsed else {
                throw ShardBenchError.handshake("a standby hello on a tail with a separate return link")
            }
            stageIndex = hello.stages.count
            let mine = myHello()
            try ShardBenchChain.validate(prefix: hello.stages, next: mine)
            try checkJoin(hello.stages)
            try ShardChainWire.checkPeer(links.upstream, is: hello.stages[hello.stages.count - 1], stage: stageIndex - 1)
            let chain = hello.stages + [mine]
            try ShardChainWire.sendHello(links.upstream, chain, header: header(.hello, destination: 0), standby: true)
            // From here a silent head is a dead head; its heartbeats keep the link alive.
            links.upstream.armLiveness()
            options.onStandby?(chain, stageIndex)
            shardBenchLog("standby for the head at \(links.upstream.peerAddress) epoch=\(links.upstream.groupEpoch)")
            while true {
                do {
                    hello = try ShardChainWire.awaitChainHello(
                        links.upstream, timeout: 3600, stageIndex: stageIndex, layers: stage.layers)
                    break
                } catch ShardLinkError.receiveTimedOut {
                    continue
                }
            }
        }
        return hello.stages
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

    /// SPEC-051-R013: a stage whose compute for one prefill chunk passes the chunk
    /// deadline fails the session instead of risking the GPU watchdog.
    private func checkPrefillDeadline(_ elapsed: TimeInterval, tokens: Int) throws {
        guard elapsed > options.prefillChunkDeadline else { return }
        throw ShardBenchError.prefillChunkDeadline(
            stage: stageIndex, tokens: tokens, milliseconds: Int((elapsed * 1000).rounded()),
            deadlineMilliseconds: Int((options.prefillChunkDeadline * 1000).rounded()))
    }

    // MARK: Middle and tail

    /// A middle stage forwards each activation downstream; the tail samples with the
    /// request's sampling parameters and sends the token on the return link. A request
    /// abort releases the request's KV and sampler and travels on with this member's
    /// signed sub-receipt appended; the tail returns the collected sub-receipts to the
    /// head. Request 0 abort ends the session.
    private func runStage(
        links: ShardBenchLinks,
        upstreamProbe: ShardBenchLatency,
        returnProbe: ShardBenchLatency?
    ) throws -> ShardBenchStageReport {
        relayLinkHealth(links)
        var state = StageState()
        // A frame read while collecting a decode batch that did not join it.
        var held: ShardStageFrame?
        loop: while true {
            // The head may idle for a long time between requests, but it heartbeats
            // throughout, so only a dead or silent peer ends an idle wait. While a
            // request is open its next frame is due within the receive deadline
            // (SPEC-051-R013), whatever other traffic the link carries.
            let idle = state.receiptIDs.isEmpty && state.caches.isEmpty
            let frame = try held ?? receive(links.upstream, timeout: idle ? max(options.receiveTimeout, 3600) : options.receiveTimeout)
            held = nil
            let header = frame.header
            switch header.kind {
            case .activation where header.requestID == probeRequestID:
                throw ShardBenchError.protocolViolation("link probe after the handshake")
            case .control:
                let control: ShardRequestControl
                do {
                    control = try JSONDecoder().decode(ShardRequestControl.self, from: frame.payload)
                } catch {
                    throw ShardBenchError.protocolViolation("undecodable control for request \(header.requestID): \(error)")
                }
                // A request's control opens it once and takes one of the stage's
                // sequence slots, with its sampler (SEC-08).
                guard state.receiptIDs[header.requestID] == nil else {
                    throw ShardBenchError.protocolViolation("a second control for request \(header.requestID)")
                }
                guard state.receiptIDs.count < options.maxSequences else { throw ShardBenchError.tooManySequences(options.maxSequences) }
                state.receiptIDs[header.requestID] = control.requestID ?? String(header.requestID)
                if options.role == .tail {
                    state.samplers[header.requestID] = stage.makeSampler(control)
                } else {
                    try links.downstream.send(ShardStageFrame(
                        header: self.header(.control, requestID: header.requestID, microBatch: header.microBatchID,
                                            destination: downstreamIndex),
                        payload: frame.payload))
                }
            case .activation:
                // SPEC-051-R017: decode rows of other requests already waiting run
                // in the same forward.
                var rows = [frame]
                if batchable(header, state) {
                    while rows.count < options.maxSequences, let next = try poll(links.upstream) {
                        guard batchable(next.header, state), !rows.contains(where: { $0.header.requestID == next.header.requestID }) else {
                            held = next
                            break
                        }
                        rows.append(next)
                    }
                }
                if rows.count > 1 {
                    try runDecodeBatch(rows, links: links, state: &state)
                } else {
                    try runActivation(frame, links: links, state: &state)
                }
            case .abort where header.requestID == probeRequestID:
                // Session end: the next stage (or, from the tail, the head) closing its
                // side is now expected.
                watch.stop()
                try links.downstream.send(ShardStageFrame(
                    header: self.header(.abort, requestID: probeRequestID, destination: downstreamIndex)))
                break loop
            case .abort:
                // SPEC-051-R009 item 5: the request's KV goes with its end.
                state.caches[header.requestID] = nil
                state.samplers[header.requestID] = nil
                let receiptID = state.receiptIDs.removeValue(forKey: header.requestID) ?? String(header.requestID)
                let receipts = try ShardChainWire.decodeReceipts(frame.payload) + [try signer.sign(book.receipt(
                    requestID: header.requestID, receiptRequestID: receiptID, memberDeviceID: signer.memberDeviceID,
                    groupEpoch: links.upstream.groupEpoch, stageIndex: stageIndex, layers: stage.layers))]
                book.remove(header.requestID)
                try links.downstream.send(ShardStageFrame(
                    header: self.header(.abort, requestID: header.requestID, destination: downstreamIndex),
                    payload: try JSONEncoder().encode(receipts)))
            case .error:
                throw ShardBenchError.peerError(String(decoding: frame.payload, as: UTF8.self))
            case .hello, .token, .tokenLogits, .heartbeat, .keyExchange:
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
            session: sessionID,
            role: options.role,
            stageIndex: stageIndex,
            model: options.modelLabel,
            modelType: stage.modelType,
            layers: "\(stage.layers.lowerBound):\(stage.layers.upperBound)",
            totalLayers: stage.totalLayers,
            stageWeightBytes: stage.weightBytes,
            sequencesServed: state.served,
            decodeCompute: ShardBenchLatency(seconds: state.decodeCompute),
            prefillCompute: ShardBenchLatency(seconds: state.prefillCompute),
            decodeBatchRowsMax: state.decodeBatchRowsMax,
            links: linkReports
        )
    }

    /// A member stage's request state, released with each request's abort.
    private struct StageState {
        var caches = [UInt64: Stage.Cache]()
        var samplers = [UInt64: Stage.Sampler]()
        /// The request id each open request's control named for sub-receipts.
        var receiptIDs = [UInt64: String]()
        /// Requests this session served (a count, not their ids).
        var served = 0
        var decodeCompute = [Double]()
        var prefillCompute = [Double]()
        var decodeBatchRowsMax = 0
    }

    /// A decode activation of a request this stage already holds KV for, which can
    /// share a forward with other requests' decode rows. The teacher-forced tail
    /// (it returns logit summaries) runs each row alone.
    private func batchable(_ header: ShardStageFrameHeader, _ state: StageState) -> Bool {
        guard header.kind == .activation, header.requestID != probeRequestID, header.tokenStep > 0,
              !header.flags.contains(.fillOnly), state.caches[header.requestID] != nil
        else { return false }
        guard options.role == .tail else { return true }
        return returnLogitTopK == nil && state.samplers[header.requestID] != nil
    }

    /// The next frame if one is already queued; nil when none is.
    private func poll(_ link: ShardStageLink) throws -> ShardStageFrame? {
        do {
            return try link.receive(timeout: 0)
        } catch ShardLinkError.receiveTimedOut {
            return nil
        }
    }

    private func recordCompute(_ elapsed: TimeInterval, prefill: Bool, state: inout StageState) {
        guard options.recordComputeSamples else { return }
        if prefill {
            state.prefillCompute.append(elapsed)
        } else {
            state.decodeCompute.append(elapsed)
        }
    }

    /// SPEC-051-R017: one forward over several requests' decode rows; each row's
    /// output goes on as its own frame, in the order the rows arrived.
    private func runDecodeBatch(_ frames: [ShardStageFrame], links: ShardBenchLinks, state: inout StageState) throws {
        let start = now()
        let headers = frames.map(\.header)
        let inputs = frames.map { ShardBenchActivation(dtype: $0.header.dtype, shape: $0.header.shape, payload: $0.payload) }
        for frame in frames { book.recordInput(frame.header, frame.payload) }
        let caches = headers.map { state.caches[$0.requestID]! }
        if options.role == .tail {
            let tokens = try stage.sampleBatch(
                activations: inputs, caches: caches, samplers: headers.map { state.samplers[$0.requestID]! })
            for (header, token) in zip(headers, tokens) {
                var payload = Data(count: 4)
                payload.withUnsafeMutableBytes { $0.storeBytes(of: Int32(token).littleEndian, as: Int32.self) }
                let tokenHeader = self.header(.token, dtype: .int32, requestID: header.requestID,
                                              microBatch: header.microBatchID, step: header.tokenStep,
                                              destination: downstreamIndex, shape: [1])
                try links.downstream.send(ShardStageFrame(header: tokenHeader, payload: payload))
                book.recordOutput(tokenHeader, payload, processedTokens: ShardMemberLedgerBook.processedTokens(header))
            }
        } else {
            let outputs = try stage.forwardBatch(activations: inputs, caches: caches)
            for (header, output) in zip(headers, outputs) {
                let outputHeader = self.header(.activation, dtype: output.dtype, requestID: header.requestID,
                                               microBatch: header.microBatchID, step: header.tokenStep,
                                               destination: downstreamIndex, shape: output.shape, flags: header.flags)
                try links.downstream.send(ShardStageFrame(header: outputHeader, payload: output.payload))
                book.recordOutput(outputHeader, output.payload, processedTokens: ShardMemberLedgerBook.processedTokens(header))
            }
        }
        state.decodeBatchRowsMax = max(state.decodeBatchRowsMax, frames.count)
        recordCompute(now() - start, prefill: false, state: &state)
    }

    /// A middle stage forwards one activation downstream; the tail samples with the
    /// request's sampling parameters and sends the token on the return link.
    private func runActivation(_ frame: ShardStageFrame, links: ShardBenchLinks, state: inout StageState) throws {
        let header = frame.header
        let start = now()
        let cache: Stage.Cache
        if let existing = state.caches[header.requestID] {
            cache = existing
        } else {
            guard header.tokenStep == 0 else {
                throw ShardBenchError.protocolViolation("request \(header.requestID) step \(header.tokenStep) has no prefill")
            }
            guard state.caches.count < options.maxSequences else { throw ShardBenchError.tooManySequences(options.maxSequences) }
            cache = try stage.newCache()
            state.caches[header.requestID] = cache
            state.served += 1
        }
        let input = ShardBenchActivation(dtype: header.dtype, shape: header.shape, payload: frame.payload)
        book.recordInput(header, frame.payload)
        let processed = ShardMemberLedgerBook.processedTokens(header)
        if options.role == .tail, header.flags.contains(.fillOnly) {
            try stage.fill(activation: input, cache: cache)
            // A fill-only chunk sends nothing, but its tokens were processed.
            book.recordFill(header, processedTokens: processed)
        } else if options.role == .tail, let topK = returnLogitTopK {
            let summary = try stage.summarize(activation: input, cache: cache, topK: topK)
            let encoded = try ShardLogitSummaryCodec.encode(token: summary.top1, summary: summary)
            let tokenHeader = self.header(.tokenLogits, dtype: .int32, requestID: header.requestID,
                                          microBatch: header.microBatchID, step: header.tokenStep,
                                          destination: downstreamIndex, shape: encoded.shape)
            try links.downstream.send(ShardStageFrame(header: tokenHeader, payload: encoded.payload))
            book.recordOutput(tokenHeader, encoded.payload, processedTokens: processed)
        } else if options.role == .tail {
            guard let sampler = state.samplers[header.requestID] else {
                throw ShardBenchError.protocolViolation("request \(header.requestID) has no sampling control")
            }
            let token = try stage.sample(activation: input, cache: cache, sampler: sampler)
            var payload = Data(count: 4)
            payload.withUnsafeMutableBytes { $0.storeBytes(of: Int32(token).littleEndian, as: Int32.self) }
            let tokenHeader = self.header(.token, dtype: .int32, requestID: header.requestID,
                                          microBatch: header.microBatchID, step: header.tokenStep,
                                          destination: downstreamIndex, shape: [1])
            try links.downstream.send(ShardStageFrame(header: tokenHeader, payload: payload))
            book.recordOutput(tokenHeader, payload, processedTokens: processed)
        } else {
            let output = try stage.forward(activation: input, cache: cache)
            let outputHeader = self.header(.activation, dtype: output.dtype, requestID: header.requestID,
                                           microBatch: header.microBatchID, step: header.tokenStep,
                                           destination: downstreamIndex, shape: output.shape, flags: header.flags)
            try links.downstream.send(ShardStageFrame(header: outputHeader, payload: output.payload))
            book.recordOutput(outputHeader, output.payload, processedTokens: processed)
        }
        let elapsed = now() - start
        if header.tokenStep == 0 {
            recordCompute(elapsed, prefill: true, state: &state)
            try checkPrefillDeadline(elapsed, tokens: processed)
        } else {
            recordCompute(elapsed, prefill: false, state: &state)
        }
    }

    /// SPEC-051-R007: the head cannot time links it does not touch, so each member
    /// pings downstream with what its upstream neighbour reported plus its own
    /// measurement of its upstream link; the tail's pings bring every link to the head.
    private func relayLinkHealth(_ links: ShardBenchLinks) {
        let upstream = links.upstream
        let from = UInt16(stageIndex - 1)
        let to = UInt16(stageIndex)
        links.downstream.setHeartbeatReport { [weak upstream] in
            guard let upstream else { return [] }
            var entries = upstream.roundTrip.peerLinks.filter { !($0.fromStage == from && $0.toStage == to) }
            if let mine = upstream.roundTripHealth(from: from, to: to) { entries.append(mine) }
            return entries
        }
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
    static func decode(directory: URL, prompts: [[Int]], tokens: Int, topK: Int? = nil) async throws -> ShardBenchReferenceReport {
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: ChatTemplateCompatTokenizerLoader())
        return try await container.perform { context in
            var sequences = [[Int]]()
            var rates = [Double]()
            var ttfts = [Double]()
            var stepLogits = [[ShardLogitSummary]]()
            for prompt in prompts {
                var summaries = [ShardLogitSummary]()
                let cache = try context.model.newCache(parameters: nil)
                let start = Date()
                var logits = context.model(
                    LMInput.Text(tokens: MLXArray(prompt.map(Int32.init)).reshaped(1, prompt.count)),
                    cache: cache, state: nil).logits
                var token = argMax(logits[0, -1], axis: -1).item(Int.self)
                if let topK { summaries.append(PipelineLogitSummarizer.summarize(logits: logits, topK: topK)) }
                let first = Date()
                ttfts.append(first.timeIntervalSince(start))
                var generated = [token]
                while generated.count < tokens {
                    logits = context.model(
                        LMInput.Text(tokens: MLXArray([Int32(token)]).reshaped(1, 1)), cache: cache, state: nil).logits
                    token = argMax(logits[0, -1], axis: -1).item(Int.self)
                    if let topK { summaries.append(PipelineLogitSummarizer.summarize(logits: logits, topK: topK)) }
                    generated.append(token)
                }
                let elapsed = Date().timeIntervalSince(first)
                if generated.count > 1, elapsed > 0 { rates.append(Double(generated.count - 1) / elapsed) }
                sequences.append(generated)
                stepLogits.append(summaries)
            }
            return ShardBenchReferenceReport(
                sequenceTokens: sequences,
                promptTokens: prompts.map(\.count),
                singleStreamTokensPerSecond: rates.isEmpty ? nil : round3(rates.reduce(0, +) / Double(rates.count)),
                ttft: ShardBenchLatency(seconds: ttfts),
                prompts: prompts,
                stepLogits: topK == nil ? nil : stepLogits
            )
        }
    }
}

final class ShardBenchWaitBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
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
    /// The reverse, for a session thread: block it until an async body finishes.
    static func wait<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ShardBenchWaitBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

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
