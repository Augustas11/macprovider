import ArgumentParser
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MacProviderCore

/// `shard-bench` — issue #2084 go/no-go harness for two-stage pipeline decode over a
/// LAN link. Lab only: no coordinator, no buyer path, hidden from help.
///
/// Roles:
///   * `--role tail --listen host:port --layers a:N` owns the last layers, the final
///     norm, the LM head and sampling; it answers activations with tokens.
///   * `--role head --connect host:port --layers 0:a` owns the embedding and first
///     layers, drives `--concurrency K` independent sequences through the pipeline,
///     and prints the report.
///   * `--local-reference` decodes the same prompts with the stock single-process
///     model; the head compares its tokens against this (in process, or from
///     `--reference <json>`).
///
/// Either role may listen or connect. Decode is fixed-length (`--tokens`, EOS
/// ignored) so the sharded and reference runs are compared over the same steps.
/// Request id 0 is reserved for link probes: the tail echoes such activations.
struct ShardBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shard-bench",
        abstract: "Lab: two-stage pipeline-parallel decode over TCP with parity and per-hop timing (issue #2084).",
        shouldDisplay: false
    )

    @Option(help: "Stage role: head or tail. Omit with --local-reference.")
    var role: String?

    @Option(help: "Listen on host:port for the peer stage.")
    var listen: String?

    @Option(help: "Connect to the peer stage at host:port.")
    var connect: String?

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

    @Option(name: .customLong("group-epoch"), help: "Group epoch both stages must agree on.")
    var groupEpoch: UInt64 = 1

    @Option(name: .customLong("heartbeat-ms"), help: "Heartbeat interval in milliseconds.")
    var heartbeatMilliseconds: Int = 100

    @Option(name: .customLong("missed-heartbeats"), help: "Peer is dead after this many silent heartbeat intervals.")
    var missedHeartbeats: Int = 3

    @Option(name: .customLong("receive-timeout"), help: "Per-receive deadline in seconds (covers the peer's compute for one step).")
    var receiveTimeout: Double = 60

    @Option(name: .customLong("connect-timeout"), help: "Seconds to wait for the peer to connect or accept.")
    var connectTimeout: Double = 120

    @Option(name: .customLong("probe-count"), help: "Echo probes (decode-activation sized) measured before decoding.")
    var probeCount: Int = 200

    @Option(name: .customLong("max-sequences"), help: "Tail: most sequences it holds KV caches for at once.")
    var maxSequences: Int = 64

    @Option(help: "Head: reference JSON from a --local-reference run instead of an in-process reference decode.")
    var reference: String?

    @Flag(name: .customLong("no-parity"), help: "Head: skip the reference comparison.")
    var noParity = false

    @Flag(name: .customLong("no-warmup"), help: "Skip the short warmup sequence that compiles kernels before timing.")
    var noWarmup = false

    @Option(help: "Also write the JSON report to this path.")
    var output: String?

    static let defaultPrompt =
        "Explain, step by step, how a pipeline-parallel transformer splits its layers across machines and why the activations between stages are small."

    func validate() throws {
        guard tokens > 0, concurrency > 0, probeCount >= 0, maxSequences > 0 else {
            throw ValidationError("--tokens, --concurrency and --max-sequences must be > 0; --probe-count >= 0")
        }
        guard heartbeatMilliseconds > 0, missedHeartbeats > 0, receiveTimeout > 0, connectTimeout > 0 else {
            throw ValidationError("heartbeat and timeout options must be > 0")
        }
        if localReference { return }
        guard let role, ["head", "tail"].contains(role) else {
            throw ValidationError("--role head|tail is required unless --local-reference")
        }
        guard (listen == nil) != (connect == nil) else {
            throw ValidationError("pass exactly one of --listen or --connect")
        }
        guard layers != nil else { throw ValidationError("--layers a:b is required for a stage") }
        if concurrency > maxSequences, role == "tail" {
            throw ValidationError("--concurrency exceeds --max-sequences")
        }
    }

    func run() async throws {
        let directory = try ModelRuntime.localModelDirectory(for: model)
        let tokenizer = try await ChatTemplateCompatTokenizerLoader().load(from: directory)
        let prompts = (0..<concurrency).map { index in
            tokenizer.encode(text: index == 0 ? prompt : "\(prompt) (sequence \(index))", addSpecialTokens: true)
        }

        if localReference {
            let report = try await ShardBenchReference.decode(directory: directory, prompts: prompts, tokens: tokens)
            try emit(report)
            return
        }

        let options = try sessionOptions(directory: directory, prompts: prompts)
        // Read a reference file before the run so a bad path fails before any decoding.
        var referenceReport: ShardBenchReferenceReport?
        if let reference, role == "head" {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let data = try Data(contentsOf: URL(fileURLWithPath: (reference as NSString).expandingTildeInPath))
            referenceReport = try decoder.decode(ShardBenchReferenceReport.self, from: data)
        }
        let session: ShardBenchSessionReport
        do {
            let stage = ShardBenchStageBox(try await PipelineStageModel.load(directory: directory, layers: options.layers))
            session = try await ShardBenchThread.run { try ShardBenchSession(options: options, stage: stage.stage).run() }
        } catch {
            FileHandle.standardError.write(Data("shard-bench: \(error)\n".utf8))
            throw ExitCode(1)
        }

        guard var head = session.head else {
            try emit(session.tail)
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
    }

    private func sessionOptions(directory: URL, prompts: [[Int]]) throws -> ShardBenchSessionOptions {
        guard let layers else { throw ValidationError("--layers a:b is required") }
        let parts = layers.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int(parts[0]), let upper = Int(parts[1]), lower < upper else {
            throw ValidationError("--layers must be a:b with a < b")
        }
        let endpoint = try ShardBenchEndpoint.parse(listen ?? connect ?? "", listens: listen != nil)
        return ShardBenchSessionOptions(
            isHead: role == "head",
            endpoint: endpoint,
            directory: directory,
            modelLabel: model,
            layers: lower..<upper,
            prompts: prompts,
            tokens: tokens,
            temperature: temperature,
            seed: seed,
            link: ShardLinkConfiguration(
                groupEpoch: groupEpoch,
                heartbeatInterval: Double(heartbeatMilliseconds) / 1000,
                missedHeartbeatLimit: missedHeartbeats
            ),
            receiveTimeout: receiveTimeout,
            connectTimeout: connectTimeout,
            probeCount: probeCount,
            maxSequences: maxSequences,
            warmup: !noWarmup
        )
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

// MARK: - Options and reports

struct ShardBenchEndpoint: Sendable {
    let host: String
    let port: UInt16
    let listens: Bool

    static func parse(_ text: String, listens: Bool) throws -> ShardBenchEndpoint {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else {
            throw ValidationError("endpoint must be host:port, got '\(text)'")
        }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return ShardBenchEndpoint(host: host.isEmpty ? "0.0.0.0" : host, port: port, listens: listens)
    }
}

struct ShardBenchSessionOptions: Sendable {
    let isHead: Bool
    let endpoint: ShardBenchEndpoint
    let directory: URL
    let modelLabel: String
    let layers: Range<Int>
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

struct ShardBenchHeadReport: Encodable {
    let schema = "macprovider.shard-bench.head.v1"
    let model: String
    let modelType: String
    let layers: String
    let peerLayers: String
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
    /// Echo of one decode-sized activation frame: the transport + codec cost of one hop
    /// out and back, with no model compute.
    let probeRoundTrip: ShardBenchLatency
    /// Head send of a decode activation to the tail's token arriving back: includes the
    /// tail's compute (see the tail report) and, with concurrency > 1, queueing.
    let decodeStepRoundTrip: ShardBenchLatency
    let headDecodeCompute: ShardBenchLatency
    let decodeHopPayloadBytes: Int
    let decodeHopFrameBytes: Int
    let prefillHopPayloadBytes: [Int]
    let linkBytesSent: UInt64
    let linkBytesReceived: UInt64
    let heartbeatsSent: UInt64
    let heartbeatsReceived: UInt64
    var parity: ShardBenchParity?
    var referenceSingleStreamTokensPerSecond: Double?
}

struct ShardBenchTailReport: Encodable {
    let schema = "macprovider.shard-bench.tail.v1"
    let model: String
    let modelType: String
    let layers: String
    let totalLayers: Int
    let stageWeightBytes: Int
    let sequencesServed: Int
    let probesEchoed: Int
    let decodeCompute: ShardBenchLatency
    let prefillCompute: ShardBenchLatency
    let linkBytesSent: UInt64
    let linkBytesReceived: UInt64
}

struct ShardBenchSessionReport {
    var head: ShardBenchHeadReport?
    var tail: ShardBenchTailReport?
}

struct ShardBenchReferenceReport: Codable {
    var schema = "macprovider.shard-bench.reference.v1"
    let sequenceTokens: [[Int]]
    let promptTokens: [Int]
    let singleStreamTokensPerSecond: Double?
    let ttft: ShardBenchLatency
}

/// Hello payload: what each stage owns, checked by the peer before any activation.
struct ShardBenchHello: Codable, Equatable {
    let role: String
    let modelType: String
    let totalLayers: Int
    let hiddenSize: Int
    let layerStart: Int
    let layerEnd: Int
}

enum ShardBenchError: Error, CustomStringConvertible {
    case handshake(String)
    case protocolViolation(String)
    case peerError(String)
    case tooManySequences(Int)

    var description: String {
        switch self {
        case .handshake(let detail): return "handshake failed: \(detail)"
        case .protocolViolation(let detail): return "protocol violation: \(detail)"
        case .peerError(let detail): return "peer reported error: \(detail)"
        case .tooManySequences(let cap): return "more than \(cap) concurrent sequences"
        }
    }
}

// MARK: - Session

/// One stage's side of a shard-bench run. Runs on a dedicated thread: model compute
/// and socket I/O are synchronous and must not block Swift's cooperative pool.
final class ShardBenchSession {
    private let options: ShardBenchSessionOptions
    private let stage: PipelineStageModel
    private let probeRequestID: UInt64 = 0
    private let warmupRequestID: UInt64 = 1
    private let firstRequestID: UInt64 = 2

    init(options: ShardBenchSessionOptions, stage: PipelineStageModel) {
        self.options = options
        self.stage = stage
    }

    func run() throws -> ShardBenchSessionReport {
        if options.temperature > 0 { MLXRandom.seed(options.seed) }
        if options.isHead, !stage.plan.isFirst {
            throw ShardBenchError.handshake("head must own layer 0 (got \(options.layers))")
        }
        if !options.isHead, !stage.plan.isLast {
            throw ShardBenchError.handshake("tail must own the last layer \(stage.plan.totalLayers - 1)")
        }
        let link = try openLink()
        defer { link.close() }
        let peer: ShardBenchHello
        do {
            peer = try handshake(link: link, stage: stage)
        } catch {
            sendError(link, error)
            throw error
        }
        do {
            if options.isHead {
                return ShardBenchSessionReport(head: try runHead(link: link, stage: stage, peer: peer))
            }
            return ShardBenchSessionReport(tail: try runTail(link: link, stage: stage))
        } catch let error as ShardLinkError {
            throw error
        } catch {
            sendError(link, error)
            throw error
        }
    }

    private func openLink() throws -> ShardStageLink {
        let endpoint = options.endpoint
        if endpoint.listens {
            let listener = try ShardStageListener(host: endpoint.host, port: endpoint.port)
            FileHandle.standardError.write(Data("shard-bench: listening on \(endpoint.host):\(listener.port)\n".utf8))
            return try listener.accept(timeout: options.connectTimeout, configuration: options.link)
        }
        return try ShardStageLink.connect(
            host: endpoint.host, port: endpoint.port, timeout: options.connectTimeout, configuration: options.link)
    }

    private func handshake(link: ShardStageLink, stage: PipelineStageModel) throws -> ShardBenchHello {
        let mine = ShardBenchHello(
            role: options.isHead ? "head" : "tail",
            modelType: stage.modelType,
            totalLayers: stage.plan.totalLayers,
            hiddenSize: stage.hiddenSize,
            layerStart: stage.plan.layers.lowerBound,
            layerEnd: stage.plan.layers.upperBound
        )
        try link.send(ShardStageFrame(header: header(.hello, stage: stage), payload: try JSONEncoder().encode(mine)))
        let frame = try link.receive(timeout: options.connectTimeout)
        guard frame.header.kind == .hello else {
            throw ShardBenchError.handshake("expected hello, got \(frame.header.kind)")
        }
        let peer = try JSONDecoder().decode(ShardBenchHello.self, from: frame.payload)
        guard peer.role != mine.role else { throw ShardBenchError.handshake("both stages are \(peer.role)") }
        guard peer.modelType == mine.modelType, peer.totalLayers == mine.totalLayers, peer.hiddenSize == mine.hiddenSize else {
            throw ShardBenchError.handshake("peer model \(peer.modelType)/\(peer.totalLayers)L/\(peer.hiddenSize) differs from \(mine.modelType)/\(mine.totalLayers)L/\(mine.hiddenSize)")
        }
        let (head, tail) = options.isHead ? (mine, peer) : (peer, mine)
        guard head.layerEnd == tail.layerStart else {
            throw ShardBenchError.handshake("head layers end at \(head.layerEnd) but tail layers start at \(tail.layerStart)")
        }
        return peer
    }

    private func header(
        _ kind: ShardFrameKind,
        stage: PipelineStageModel,
        dtype: ShardTensorDType = .none,
        requestID: UInt64 = 0,
        microBatch: UInt32 = 0,
        step: UInt32 = 0,
        shape: [UInt32] = []
    ) -> ShardStageFrameHeader {
        let source: UInt16 = options.isHead ? 0 : 1
        return ShardStageFrameHeader(
            kind: kind, dtype: dtype, groupEpoch: options.link.groupEpoch, requestID: requestID,
            microBatchID: microBatch, tokenStep: step, sourceStage: source, destinationStage: 1 - source,
            layerStart: UInt32(stage.plan.layers.lowerBound), layerEnd: UInt32(stage.plan.layers.upperBound),
            shape: shape)
    }

    private func sendError(_ link: ShardStageLink, _ error: Error) {
        _ = try? link.send(ShardStageFrame(
            header: ShardStageFrameHeader(kind: .error, groupEpoch: options.link.groupEpoch),
            payload: Data(String(describing: error).prefix(4096).utf8)))
    }

    private func receive(_ link: ShardStageLink) throws -> ShardStageFrame {
        let frame = try link.receive(timeout: options.receiveTimeout)
        if frame.header.kind == .error {
            throw ShardBenchError.peerError(String(decoding: frame.payload, as: UTF8.self))
        }
        return frame
    }

    // MARK: Head

    private struct HeadSequence {
        let requestID: UInt64
        let microBatch: UInt32
        let cache: [KVCache]
        var tokens: [Int] = []
        var lastSend: TimeInterval = 0
        var prefillStart: TimeInterval = 0
        var firstTokenAt: TimeInterval?
        var lastTokenAt: TimeInterval?
    }

    private func runHead(link: ShardStageLink, stage: PipelineStageModel, peer: ShardBenchHello) throws -> ShardBenchHeadReport {
        // Probe: one decode-sized activation echoed by the tail, no model compute.
        let probeShape: [UInt32] = [1, 1, UInt32(stage.hiddenSize)]
        let probePayload = Data(count: 2 * stage.hiddenSize)
        var probeSamples = [Double]()
        let probeWarmup = min(10, options.probeCount)
        for index in 0..<(options.probeCount + probeWarmup) {
            let start = now()
            try link.send(ShardStageFrame(
                header: header(.activation, stage: stage, dtype: .bfloat16, requestID: probeRequestID, step: UInt32(index), shape: probeShape),
                payload: probePayload))
            let echo = try receive(link)
            guard echo.header.requestID == probeRequestID, echo.header.tokenStep == UInt32(index) else {
                throw ShardBenchError.protocolViolation("probe echo out of order")
            }
            if index >= probeWarmup { probeSamples.append(now() - start) }
        }

        if options.warmup {
            _ = try pipelineDecode(
                link: link, stage: stage, prompts: [options.prompts[0]], tokens: min(4, options.tokens),
                firstRequestID: warmupRequestID)
        }
        let run = try pipelineDecode(
            link: link, stage: stage, prompts: options.prompts, tokens: options.tokens, firstRequestID: firstRequestID)
        // Session end: request id 0 abort.
        try link.send(ShardStageFrame(header: header(.abort, stage: stage, requestID: probeRequestID)))

        let stats = link.statistics
        let decodeTPS = run.sequences.compactMap { sequence -> Double? in
            guard let first = sequence.firstTokenAt, let last = sequence.lastTokenAt, sequence.tokens.count > 1, last > first else {
                return nil
            }
            return Double(sequence.tokens.count - 1) / (last - first)
        }
        let totalTokens = run.sequences.reduce(0) { $0 + $1.tokens.count }
        return ShardBenchHeadReport(
            model: options.modelLabel,
            modelType: stage.modelType,
            layers: "\(stage.plan.layers.lowerBound):\(stage.plan.layers.upperBound)",
            peerLayers: "\(peer.layerStart):\(peer.layerEnd)",
            totalLayers: stage.plan.totalLayers,
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
            probeRoundTrip: ShardBenchLatency(seconds: probeSamples),
            decodeStepRoundTrip: ShardBenchLatency(seconds: run.stepRoundTrips),
            headDecodeCompute: ShardBenchLatency(seconds: run.headCompute),
            decodeHopPayloadBytes: run.decodeHopPayloadBytes,
            decodeHopFrameBytes: ShardStageFrameCodec.frameSize(rank: 3, payloadLength: run.decodeHopPayloadBytes),
            prefillHopPayloadBytes: run.prefillPayloadBytes,
            linkBytesSent: stats.bytesSent,
            linkBytesReceived: stats.bytesReceived,
            heartbeatsSent: stats.heartbeatsSent,
            heartbeatsReceived: stats.heartbeatsReceived,
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
        var activationDType: String
    }

    /// Keep every sequence in flight: the tail answers in arrival order, and while it
    /// computes one sequence's step the head computes the next sequence's, so with
    /// K >= 2 both stages stay busy.
    private func pipelineDecode(
        link: ShardStageLink,
        stage: PipelineStageModel,
        prompts: [[Int]],
        tokens: Int,
        firstRequestID: UInt64
    ) throws -> PipelineRun {
        var sequences = [HeadSequence]()
        var index = [UInt64: Int]()
        var run = PipelineRun(
            sequences: [], stepRoundTrips: [], headCompute: [], wallSeconds: 0,
            decodeHopPayloadBytes: 0, prefillPayloadBytes: [], activationDType: "")
        let start = now()
        for (offset, prompt) in prompts.enumerated() {
            let requestID = firstRequestID + UInt64(offset) * 2
            var sequence = HeadSequence(requestID: requestID, microBatch: UInt32(offset), cache: try stage.newCache())
            sequence.prefillStart = now()
            let hidden = try stage.forward(MLXArray(prompt.map(Int32.init)).reshaped(1, prompt.count), cache: sequence.cache)
            let payloadBytes = try sendActivation(link, stage: stage, hidden: hidden, sequence: &sequence, step: 0)
            run.prefillPayloadBytes.append(payloadBytes)
            run.activationDType = String(describing: hidden.dtype)
            index[requestID] = sequences.count
            sequences.append(sequence)
        }
        var remaining = sequences.count
        while remaining > 0 {
            let frame = try receive(link)
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
            if sequence.tokens.isEmpty {
                sequence.firstTokenAt = arrived
            } else {
                run.stepRoundTrips.append(arrived - sequence.lastSend)
            }
            sequence.tokens.append(token)
            sequence.lastTokenAt = arrived
            if sequence.tokens.count >= tokens {
                try link.send(ShardStageFrame(header: header(.abort, stage: stage, requestID: sequence.requestID)))
                remaining -= 1
            } else {
                let computeStart = now()
                let hidden = try stage.forward(MLXArray([Int32(token)]).reshaped(1, 1), cache: sequence.cache)
                run.headCompute.append(now() - computeStart)
                run.decodeHopPayloadBytes = try sendActivation(
                    link, stage: stage, hidden: hidden, sequence: &sequence, step: UInt32(sequence.tokens.count))
            }
            sequences[slot] = sequence
        }
        run.wallSeconds = now() - start
        run.sequences = sequences
        return run
    }

    private func sendActivation(
        _ link: ShardStageLink,
        stage: PipelineStageModel,
        hidden: MLXArray,
        sequence: inout HeadSequence,
        step: UInt32
    ) throws -> Int {
        let encoded = try PipelineActivationCodec.encode(hidden)
        sequence.lastSend = now()
        try link.send(ShardStageFrame(
            header: header(.activation, stage: stage, dtype: encoded.dtype, requestID: sequence.requestID,
                           microBatch: sequence.microBatch, step: step, shape: encoded.shape),
            payload: encoded.payload))
        return encoded.payload.count
    }

    // MARK: Tail

    private func runTail(link: ShardStageLink, stage: PipelineStageModel) throws -> ShardBenchTailReport {
        var caches = [UInt64: [KVCache]]()
        var served = Set<UInt64>()
        var probes = 0
        var decodeCompute = [Double]()
        var prefillCompute = [Double]()
        // The head may spend a long time loading its reference or warming up between
        // frames, but it heartbeats throughout, so only a dead or silent peer ends this.
        loop: while true {
            let frame = try link.receive(timeout: max(options.receiveTimeout, 3600))
            let header = frame.header
            switch header.kind {
            case .activation where header.requestID == probeRequestID:
                try link.send(ShardStageFrame(
                    header: self.header(.activation, stage: stage, dtype: header.dtype, requestID: probeRequestID,
                                        step: header.tokenStep, shape: header.shape),
                    payload: frame.payload))
                probes += 1
            case .activation:
                let start = now()
                let cache: [KVCache]
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
                let hidden = try PipelineActivationCodec.decode(dtype: header.dtype, shape: header.shape, payload: frame.payload)
                let logits = try stage.forward(hidden, cache: cache)
                let token = PipelineStageSampler.sample(logits: logits, temperature: options.temperature)
                var payload = Data(count: 4)
                payload.withUnsafeMutableBytes { $0.storeBytes(of: Int32(token).littleEndian, as: Int32.self) }
                try link.send(ShardStageFrame(
                    header: self.header(.token, stage: stage, dtype: .int32, requestID: header.requestID,
                                        microBatch: header.microBatchID, step: header.tokenStep, shape: [1]),
                    payload: payload))
                if header.tokenStep == 0 {
                    prefillCompute.append(now() - start)
                } else {
                    decodeCompute.append(now() - start)
                }
            case .abort where header.requestID == probeRequestID:
                break loop
            case .abort:
                caches[header.requestID] = nil
            case .error:
                throw ShardBenchError.peerError(String(decoding: frame.payload, as: UTF8.self))
            case .hello, .token, .heartbeat:
                throw ShardBenchError.protocolViolation("unexpected \(header.kind) frame on the tail")
            }
        }
        let stats = link.statistics
        return ShardBenchTailReport(
            model: options.modelLabel,
            modelType: stage.modelType,
            layers: "\(stage.plan.layers.lowerBound):\(stage.plan.layers.upperBound)",
            totalLayers: stage.plan.totalLayers,
            stageWeightBytes: stage.weightBytes,
            sequencesServed: served.count,
            probesEchoed: probes,
            decodeCompute: ShardBenchLatency(seconds: decodeCompute),
            prefillCompute: ShardBenchLatency(seconds: prefillCompute),
            linkBytesSent: stats.bytesSent,
            linkBytesReceived: stats.bytesReceived
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
