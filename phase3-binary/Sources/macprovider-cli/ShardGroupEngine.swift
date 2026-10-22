import Foundation
import MacProviderCore

// Issue #2084 head-side session engine for a shard group (SPEC-051). The head owns
// stage 0 (embedding and first layers) and drives every request through the chain:
// it accepts generation requests, keeps up to `maxInFlight` of them in flight across
// the stages (SPEC-051-R017), pipelines each prompt in chunks, streams each request's
// tokens as they come back from the last stage, keeps per-request activation digests
// and collects every member's signed sub-receipt when the request ends
// (SPEC-051-R019). On loss of the downstream stage it replays the in-flight requests
// into a spare when one is configured, and otherwise ends each request with an
// explicit error carrying its delivered-token count (SPEC-051-R021, R022).
//
// Model compute and socket I/O are synchronous, so the engine runs on its own
// thread; callers submit requests from any thread and receive events through a
// callback or an AsyncThrowingStream.

struct ShardGenerationRequest: Sendable {
    var promptTokens: [Int]
    var maxTokens: Int
    /// Sampling on the last stage; travels in the request's `control` open frame.
    var control: ShardRequestControl
    /// A sampled token in this set ends the request with `.stop`; it is not delivered.
    var stopTokenIDs: Set<Int>
    /// Lab teacher forcing: decode step i is fed `teacherTokens[i - 1]` instead of the
    /// token sampled at step i - 1.
    var teacherTokens: [Int]?
    /// The request id every member names in its sub-receipt (the coordinator request
    /// id); nil uses the engine's decimal request id.
    var receiptRequestID: String?

    init(
        promptTokens: [Int],
        maxTokens: Int,
        control: ShardRequestControl = ShardRequestControl(temperature: 0),
        stopTokenIDs: Set<Int> = [],
        teacherTokens: [Int]? = nil,
        receiptRequestID: String? = nil
    ) {
        self.promptTokens = promptTokens
        self.maxTokens = maxTokens
        self.control = control
        self.stopTokenIDs = stopTokenIDs
        self.teacherTokens = teacherTokens
        self.receiptRequestID = receiptRequestID
    }
}

enum ShardFinishReason: String, Sendable {
    case length
    case stop
    case cancelled
}

/// Head-side measurements of one request.
struct ShardRequestTiming: Sendable {
    var prefillStart: TimeInterval = 0
    var firstTokenAt: TimeInterval?
    var lastTokenAt: TimeInterval?
    /// Head send of a decode activation to that step's token arriving back.
    var stepRoundTrips: [Double] = []
    var headDecodeCompute: [Double] = []
    var prefillChunkCompute: [Double] = []
    var prefillPayloadBytes = 0
    var prefillChunks = 0
    var decodeHopPayloadBytes = 0
    var activationDType = ""
}

/// SPEC-051-R019 evidence for one request: every member's signed sub-receipt in
/// chain order and the verdict of the head's own check of signatures and chain.
struct ShardRequestAttestation: Sendable {
    /// `ok`, `broken`, or `unverifiable_member_lost` when a member was lost before
    /// its sub-receipt reached the head.
    let verdict: String
    let fault: ShardAttestationFault?
    let groupEpoch: UInt64
    let receipts: [ShardSignedSubReceipt]
    /// Spare replacements this request went through.
    let replays: [ShardBenchReplayReport]
}

struct ShardGenerationSummary: Sendable {
    let requestID: UInt64
    let reason: ShardFinishReason
    let promptTokens: Int
    /// Delivered tokens, in order; a stop token is not among them.
    let tokens: [Int]
    /// Token steps the head received: delivered tokens, a stop token, and a token
    /// that came back after a cancel and was dropped.
    let tokenSteps: Int
    let stopToken: Int?
    /// Teacher-forced runs: the last stage's logit summary of every step.
    let summaries: [ShardLogitSummary]
    let timing: ShardRequestTiming
    let attestation: ShardRequestAttestation
}

enum ShardGenerationEvent: Sendable {
    case token(Int, ShardLogitSummary?)
    case finished(ShardGenerationSummary)
}

enum ShardGroupEngineError: Error, Equatable, CustomStringConvertible {
    /// The engine is not running (never started, shut down, or its chain failed).
    case unavailable(String)
    case invalidRequest(String)
    /// SPEC-051-R021: failed before any token of this request was delivered; the
    /// attempt carries no completion and may be retried elsewhere.
    case failedBeforeFirstToken(cause: String)
    /// SPEC-051-R022: the stream ends after `delivered` tokens; none is re-emitted.
    case streamTerminated(delivered: Int, cause: String)

    var description: String {
        switch self {
        case .unavailable(let detail): return "shard group unavailable: \(detail)"
        case .invalidRequest(let detail): return "invalid shard group request: \(detail)"
        case .failedBeforeFirstToken(let cause): return "shard group failed before the first token: \(cause)"
        case .streamTerminated(let delivered, let cause): return "stream terminated after delivering \(delivered) tokens: \(cause)"
        }
    }
}

/// A stage that answers nothing within the progress budget is a failed member
/// (SPEC-051-R013), handled like a lost link.
enum ShardGroupEngineFault: Error, CustomStringConvertible {
    case progressDeadline(silentMilliseconds: Int, budgetMilliseconds: Int)

    var description: String {
        switch self {
        case .progressDeadline(let silent, let budget):
            return "no answer from the chain for \(silent) ms with work outstanding (budget \(budget) ms)"
        }
    }
}

/// One downstream member the head's group configuration names, in stage order.
struct ShardGroupExpectedMember: Equatable, Sendable {
    let memberDeviceID: String
    let layers: Range<Int>
    /// SPEC-051-R011: the key the member must announce and, on a protected link,
    /// authenticate with; nil (a lab chain) checks only the announced key.
    var publicKey: String? = nil
}

struct ShardGroupEngineOptions: Sendable {
    var link: ShardLinkConfiguration
    /// Bounds the handshake and the session-end acknowledgement.
    var connectTimeout: TimeInterval
    /// SPEC-051 `decode_hop_deadline_ms`.
    var decodeHopDeadline: TimeInterval
    /// SPEC-051 `prefill_chunk_deadline_ms`; also bounds the head's own chunk compute.
    var prefillChunkDeadline: TimeInterval
    /// SPEC-051 `replay_deadline_ms`.
    var replayDeadline: TimeInterval
    var maxInFlight: Int
    /// Prompt tokens per prefill chunk; nil sends each prompt as one chunk.
    var prefillChunk: Int?
    var expectedStages: Int?
    /// When set, the chain must be exactly these members with these layers.
    var expectedMembers: [ShardGroupExpectedMember]?
    /// When set, every stage must report this model digest (SPEC-051-R008).
    var modelDigest: String?
    /// Spare for the downstream stage of a two-stage chain.
    var spare: ShardBenchEndpoint?
    /// When set, the spare must be this member with these layers.
    var spareMember: ShardGroupExpectedMember?
    var replayBufferBytes: Int
    /// The tail returns a top-k logit summary with every token (teacher forcing).
    var logitTopK: Int?
    /// The head's member device identity, signing its own sub-receipts.
    var signer: ShardMemberSigner
    /// SPEC-051-R006: the context per sequence the group serves; every member
    /// must have proved its stage fit for at least this. nil (the lab bench)
    /// checks only concurrency.
    var servingContextTokens: Int? = nil
}

/// Per-request digests and counts of one member, for its sub-receipts.
struct ShardMemberLedgerBook {
    private struct Ledger {
        var input = ShardActivationDigestChain()
        var output = ShardActivationDigestChain()
        var promptTokens = 0
        var decodeSteps = 0
    }

    private var ledgers = [UInt64: Ledger]()

    var requestIDs: [UInt64] { ledgers.keys.sorted() }

    static func processedTokens(_ header: ShardStageFrameHeader) -> Int {
        header.kind == .activation && header.shape.count == 3 ? Int(header.shape[1]) : 0
    }

    /// Fold one frame received upstream (the head: a returned token).
    mutating func recordInput(_ header: ShardStageFrameHeader, _ payload: Data) {
        ledgers[header.requestID, default: Ledger()].input.fold(
            requestID: header.requestID, tokenStep: header.tokenStep, payload: payload)
    }

    /// Fold one frame sent downstream; it counts toward the prompt tokens or decode
    /// steps this member processed.
    mutating func recordOutput(_ header: ShardStageFrameHeader, _ payload: Data, processedTokens: Int) {
        var ledger = ledgers[header.requestID, default: Ledger()]
        ledger.output.fold(requestID: header.requestID, tokenStep: header.tokenStep, payload: payload)
        count(&ledger, header: header, processedTokens: processedTokens)
        ledgers[header.requestID] = ledger
    }

    /// The last stage filled its KV with a chunk and sent nothing; the tokens count.
    mutating func recordFill(_ header: ShardStageFrameHeader, processedTokens: Int) {
        var ledger = ledgers[header.requestID, default: Ledger()]
        count(&ledger, header: header, processedTokens: processedTokens)
        ledgers[header.requestID] = ledger
    }

    private func count(_ ledger: inout Ledger, header: ShardStageFrameHeader, processedTokens: Int) {
        if header.tokenStep == 0 {
            ledger.promptTokens += processedTokens
        } else {
            ledger.decodeSteps += 1
        }
    }

    /// Start a request's account over (a spare replay re-sends its frames).
    mutating func reset(_ requestID: UInt64) {
        ledgers[requestID] = Ledger()
    }

    mutating func remove(_ requestID: UInt64) {
        ledgers[requestID] = nil
    }

    /// `requestID` keys the ledger (the transport id); `receiptRequestID` is the id
    /// the sub-receipt names.
    func receipt(
        requestID: UInt64, receiptRequestID: String, memberDeviceID: String, groupEpoch: UInt64, stageIndex: Int,
        layers: Range<Int>
    ) -> ShardMemberSubReceipt {
        let ledger = ledgers[requestID] ?? Ledger()
        return ShardMemberSubReceipt(
            memberDeviceID: memberDeviceID, groupEpoch: groupEpoch, stageIndex: stageIndex,
            layerStart: layers.lowerBound, layerEnd: layers.upperBound, requestID: receiptRequestID,
            promptTokens: ledger.promptTokens, decodeSteps: ledger.decodeSteps,
            inDigest: ledger.input.hex, outDigest: ledger.output.hex)
    }
}

/// Hello exchange helpers shared by the head engine and the member stage server.
enum ShardChainWire {
    static func sendHello(
        _ link: ShardStageLink, _ chain: [ShardBenchHello], header: ShardStageFrameHeader, standby: Bool = false
    ) throws {
        try link.send(ShardStageFrame(
            header: header, payload: try JSONEncoder().encode(ShardBenchChainHello(stages: chain, standby: standby ? true : nil))))
    }

    /// The chain of the peer's hello; a standby hello is refused here.
    static func awaitHello(
        _ link: ShardStageLink, timeout: TimeInterval, stageIndex: Int, layers: Range<Int>
    ) throws -> [ShardBenchHello] {
        let hello = try awaitChainHello(link, timeout: timeout, stageIndex: stageIndex, layers: layers)
        guard hello.standby != true else { throw ShardBenchError.handshake("unexpected standby hello") }
        return hello.stages
    }

    /// Read until the peer's hello, echoing its link probes (request 0 activations)
    /// meanwhile with this stage's index and layers.
    static func awaitChainHello(
        _ link: ShardStageLink, timeout: TimeInterval, stageIndex: Int, layers: Range<Int>
    ) throws -> ShardBenchChainHello {
        while true {
            let frame = try link.receive(timeout: timeout)
            switch frame.header.kind {
            case .activation where frame.header.requestID == 0:
                var echo = frame.header
                echo.sourceStage = UInt16(stageIndex)
                echo.destinationStage = frame.header.sourceStage
                echo.layerStart = UInt32(layers.lowerBound)
                echo.layerEnd = UInt32(layers.upperBound)
                try link.send(ShardStageFrame(header: echo, payload: frame.payload))
            case .hello:
                do {
                    return try JSONDecoder().decode(ShardBenchChainHello.self, from: frame.payload)
                } catch {
                    throw ShardBenchError.handshake("undecodable hello: \(error)")
                }
            case .error:
                throw ShardBenchError.peerError(String(decoding: frame.payload, as: UTF8.self))
            default:
                throw ShardBenchError.handshake("expected hello, got \(frame.header.kind)")
            }
        }
    }

    /// SPEC-051-R011: on a protected link, the member that signed the key agreement
    /// must be the stage the chain hello names at the other end, with the key it
    /// signs its sub-receipts with.
    static func checkPeer(_ link: ShardStageLink, is hello: ShardBenchHello, stage: Int) throws {
        guard link.configuration.frameProtection != .crc32c else { return }
        guard let peer = link.peer else {
            throw ShardBenchError.handshake("the link to stage \(stage) has no authenticated peer")
        }
        guard hello.memberPublicKey == peer.publicKey else {
            throw ShardBenchError.handshake("the link to stage \(stage) was authenticated by \(peer.memberDeviceID), not by the key stage \(stage) announces")
        }
    }

    /// SPEC-051-R011: a stage the group configures a key for must announce that
    /// key; with `checkPeer` on its link, the peer that authenticated the link is
    /// then the configured member, not just whoever holds the key it announced.
    static func checkConfigured(_ hello: ShardBenchHello, key: String?, stage: Int) throws {
        guard let key else { return }
        guard hello.memberPublicKey == key else {
            throw ShardBenchError.handshake("stage \(stage) (\(hello.memberDeviceID ?? "unnamed")) announced a key the group does not configure for it")
        }
    }

    /// SPEC-051-R006, R017: a member must serve the group's concurrency and have
    /// proved its stage fit for the serving context. A member that does not say
    /// is taken at the smallest serving context.
    static func checkCapacity(_ hello: ShardBenchHello, slots: Int, contextTokens: Int?, stage: Int) throws {
        guard let capacity = hello.maxSequences, capacity >= slots else {
            throw ShardBenchError.handshake("stage \(stage) serves \(hello.maxSequences.map(String.init) ?? "an unknown number of") sequences, the group admits \(slots)")
        }
        if let contextTokens {
            let proved = hello.contextTokens ?? AutotuneModelContextCap.minimumServeContext
            guard proved >= contextTokens else {
                throw ShardBenchError.handshake("stage \(stage) proved its fit for \(proved) tokens per sequence, the group serves \(contextTokens)")
            }
        }
    }

    /// SPEC-051-R011: refuse a link whose authenticated peer is not the configured
    /// neighbour, before reading anything else from it. A crc32c link has no
    /// authenticated peer; its neighbour's hello is checked against the key instead.
    static func checkLinkPeer(_ link: ShardStageLink, key: String?, neighbour: String) throws {
        guard let key, link.configuration.frameProtection != .crc32c else { return }
        guard link.peer?.publicKey == key else {
            throw ShardBenchError.handshake("the \(neighbour) link was authenticated by \(link.peer?.memberDeviceID ?? "no peer"), not by the configured \(neighbour) key")
        }
    }

    static func decodeReceipts(_ payload: Data) throws -> [ShardSignedSubReceipt] {
        guard !payload.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([ShardSignedSubReceipt].self, from: payload)
        } catch {
            throw ShardBenchError.protocolViolation("undecodable sub-receipts in an abort frame: \(error)")
        }
    }
}

/// The head's live view of its links (SPEC-051-R007, R015): the round trips it
/// measures on its own links and the link reports members relay down the chain.
struct ShardGroupLinkHealth: Sendable, Equatable {
    /// Head to stage 1.
    var downstream: ShardLinkRoundTrip
    /// Last stage to the head when that is a separate link; nil when one link
    /// carries both directions.
    var upstream: ShardLinkRoundTrip?

    /// The relayed report of the link `from` -> `to` (stages >= 1) and when it last
    /// arrived; the tail's pings carry the chain's reports to the head.
    func reported(from: Int, to: Int) -> (health: ShardLinkHealth, at: TimeInterval)? {
        let carrier = upstream ?? downstream
        guard let at = carrier.peerLinksAt,
              let health = carrier.peerLinks.last(where: { Int($0.fromStage) == from && Int($0.toStage) == to })
        else { return nil }
        return (health, at)
    }
}

/// What the runtime and the coordinator heartbeat read about a running engine.
struct ShardGroupEngineStatus: Sendable {
    var running: Bool
    var groupEpoch: UInt64
    var chain: [ShardBenchHello]
    var inFlight: Int
    var queued: Int
    var replays: Int
    var failure: String?
    /// nil before the chain is up.
    var links: ShardGroupLinkHealth? = nil
    /// The spare while it has not taken over; nil without one.
    var spare: ShardGroupSpareHealth? = nil
}

final class ShardGroupEngine<Stage: ShardBenchStage>: @unchecked Sendable {
    typealias Sink = @Sendable (Result<ShardGenerationEvent, Error>) -> Void

    /// Idle receive slice: how long a new submission or cancel can wait for the loop.
    static var pollInterval: TimeInterval { 0.005 }
    static var probeRequestID: UInt64 { 0 }

    let options: ShardGroupEngineOptions
    /// Random id of this engine run, carried in the hello so member logs match it.
    let sessionID = String(format: "%016llx", UInt64.random(in: 0...UInt64.max))
    private let stage: Stage

    // Shared with submitting threads, under `lock`.
    private let lock = NSLock()
    private var pending = [Pending]()
    private var cancels = Set<UInt64>()
    private var shutdownRequested = false
    private var running = false
    private var stopError: Error?
    private var nextRequestID: UInt64 = 1
    private var published: ShardGroupEngineStatus
    private let stopped = DispatchGroup()

    // Engine thread only (and the starting thread before the loop exists).
    private var links: ShardBenchLinks?
    private var watch = ShardBenchLinkWatch()
    private var groupEpoch: UInt64
    private var replayBuffer: ShardReplayBuffer
    private var book = ShardMemberLedgerBook()
    private var active = [UInt64: Active]()
    private var awaiting = [UInt64: Active]()
    /// Requests failed by the head after frames went downstream; their abort answer is dropped.
    private var discarding = Set<UInt64>()
    private var replayReports = [ShardBenchReplayReport]()
    private var replacementLinks = [ShardBenchLinks]()
    private var expectedKeys = [Int: String]()
    /// The standby link to the spare while it has not taken over (SPEC-051-R007).
    private var standby: ShardSpareStandby?
    private var heardBytes: UInt64 = 0
    /// When the per-request deadlines were last evaluated (SPEC-051-R013).
    private var lastLivenessCheck: TimeInterval = 0
    /// SPEC-051-R022: after a takeover, the absolute replay deadline and the
    /// replayed requests whose next token (the spare's proof of KV catch-up)
    /// has not arrived yet.
    private var catchUp: (deadline: TimeInterval, pending: Set<UInt64>)?
    /// A frame read while collecting tokens for a decode batch that was not a
    /// token; the loop handles it next, exactly as if it had just arrived.
    private var heldFrame: ShardStageFrame?
    private var heardAt: TimeInterval = 0
    private var chainValue = [ShardBenchHello]()

    private struct Pending {
        let id: UInt64
        let request: ShardGenerationRequest
        let sink: Sink
    }

    private struct Active {
        let id: UInt64
        let request: ShardGenerationRequest
        let sink: Sink
        let cache: Stage.Cache
        var tokens: [Int] = []
        var steps = 0
        var summaries: [ShardLogitSummary] = []
        var timing = ShardRequestTiming()
        /// The last frame sent for this request (an activation, or the abort that
        /// collects its sub-receipts): its own progress clock (SPEC-051-R013).
        var lastSend: TimeInterval = 0
        /// A step was sent and its token has not come back.
        var outstanding = false
        var cancelled = false
        var reason: ShardFinishReason?
        var stopToken: Int?
    }

    init(stage: Stage, options: ShardGroupEngineOptions) {
        self.stage = stage
        self.options = options
        self.groupEpoch = options.link.groupEpoch
        self.replayBuffer = ShardReplayBuffer(capacityBytes: options.replayBufferBytes)
        self.published = ShardGroupEngineStatus(
            running: false, groupEpoch: options.link.groupEpoch, chain: [], inFlight: 0, queued: 0, replays: 0,
            failure: nil)
    }

    // MARK: Public surface

    /// The chain the handshake returned. Read after `start` returns.
    var chain: [ShardBenchHello] { chainValue }

    /// Spare replacements so far. Read from another thread only after the loop stopped.
    var replays: [ShardBenchReplayReport] { replayReports }

    /// The links in use (a spare replacement swaps them). Read after the loop stopped.
    var currentLinks: ShardBenchLinks? { links }

    var status: ShardGroupEngineStatus {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = published
        snapshot.queued = pending.count
        return snapshot
    }

    /// Handshake over open links on the calling thread (it blocks), then start the
    /// engine thread. On failure the links are closed and the error is thrown.
    func start(links: ShardBenchLinks) throws {
        self.links = links
        do {
            try checkHead()
            let chain = try headHandshake(links, expectedMembers: options.expectedMembers)
            for link in links.unique { link.armLiveness() }
            chainValue = chain
            expectedKeys = Self.announcedKeys(chain)
            if !links.isCollapsed { watch.watch(links.downstream, wake: links.upstream) }
            shardGroupLog("hello ok epoch=\(groupEpoch) session=\(sessionID) stages=\(chain.count)")
        } catch {
            Self.sendError(links, error, epoch: groupEpoch)
            links.close()
            throw error
        }
        if let spare = options.spare, chainValue.count == 2 {
            var configuration = options.link
            configuration.groupEpoch = groupEpoch + 1
            let standby = ShardSpareStandby(
                endpoint: spare, configuration: configuration, signer: options.signer, headHello: myHello(),
                expectedMemberID: options.spareMember?.memberDeviceID, expectedMemberKey: options.spareMember?.publicKey,
                requiredSlots: options.maxInFlight, requiredContextTokens: options.servingContextTokens,
                layers: chainValue[1].layerStart..<chainValue[1].layerEnd,
                modelDigest: options.modelDigest, handshakeTimeout: options.connectTimeout)
            standby.start()
            self.standby = standby
        }
        heardAt = now()
        heardBytes = links.upstream.statistics.bytesReceived
        lock.lock()
        running = true
        published.running = true
        published.chain = chainValue
        lock.unlock()
        publish()
        stopped.enter()
        let thread = Thread { [self] in loop() }
        thread.name = "shard-group-engine"
        thread.stackSize = 16 << 20
        thread.start()
    }

    /// Queue requests atomically (the engine admits them in this order) and return
    /// their ids. `sink` receives every event of every request in the batch.
    @discardableResult
    func submit(_ requests: [ShardGenerationRequest], sink: @escaping @Sendable (UInt64, Result<ShardGenerationEvent, Error>) -> Void) throws -> [UInt64] {
        for request in requests {
            guard !request.promptTokens.isEmpty else { throw ShardGroupEngineError.invalidRequest("empty prompt") }
            guard request.maxTokens > 0 else { throw ShardGroupEngineError.invalidRequest("max tokens must be > 0") }
            if let teacher = request.teacherTokens, teacher.count < request.maxTokens - 1 {
                throw ShardGroupEngineError.invalidRequest("\(teacher.count) teacher tokens for \(request.maxTokens) steps")
            }
        }
        lock.lock()
        defer { lock.unlock() }
        guard running, !shutdownRequested else {
            throw ShardGroupEngineError.unavailable(stopError.map { "\($0)" } ?? "the engine is not running")
        }
        return requests.map { request in
            let id = nextRequestID
            nextRequestID += 1
            pending.append(Pending(id: id, request: request, sink: { sink(id, $0) }))
            return id
        }
    }

    /// One request as a stream; finishing the stream early does not cancel it, `cancel` does.
    func stream(_ request: ShardGenerationRequest) throws -> (id: UInt64, events: AsyncThrowingStream<ShardGenerationEvent, Error>) {
        let (events, continuation) = AsyncThrowingStream<ShardGenerationEvent, Error>.makeStream()
        let ids = try submit([request]) { _, result in
            switch result {
            case .success(let event):
                continuation.yield(event)
                if case .finished = event { continuation.finish() }
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
        return (ids[0], events)
    }

    /// Stop a request: a queued one ends at once, an active one when its outstanding
    /// step returns (its members still answer the abort with their sub-receipts).
    func cancel(_ requestID: UInt64) {
        lock.lock()
        if let index = pending.firstIndex(where: { $0.id == requestID }) {
            let removed = pending.remove(at: index)
            lock.unlock()
            removed.sink(.success(.finished(ShardGenerationSummary(
                requestID: requestID, reason: .cancelled, promptTokens: 0, tokens: [], tokenSteps: 0, stopToken: nil, summaries: [],
                timing: ShardRequestTiming(),
                attestation: ShardRequestAttestation(verdict: "not_started", fault: nil, groupEpoch: 0, receipts: [], replays: [])))))
            return
        }
        cancels.insert(requestID)
        lock.unlock()
    }

    /// End the session after the outstanding requests finish (queued ones are
    /// refused), then wait for the engine thread. Throws why the engine stopped
    /// when that was not this shutdown.
    func shutdown() throws {
        lock.lock()
        shutdownRequested = true
        lock.unlock()
        stopped.wait()
        lock.lock()
        let error = stopError
        lock.unlock()
        if let error { throw error }
    }

    /// Wait until the engine thread exits (a chain failure or a shutdown).
    func waitUntilStopped(timeout: TimeInterval) -> Bool {
        stopped.wait(timeout: .now() + timeout) == .success
    }

    // MARK: Handshake

    private func checkHead() throws {
        guard stage.layers.lowerBound == 0 else {
            throw ShardBenchError.handshake("head must own layer 0 (got \(stage.layers))")
        }
    }

    private func myHello() -> ShardBenchHello {
        ShardBenchHello(
            role: .head, modelType: stage.modelType, totalLayers: stage.totalLayers, hiddenSize: stage.hiddenSize,
            layerStart: stage.layers.lowerBound, layerEnd: stage.layers.upperBound, session: sessionID,
            logitTopK: options.logitTopK, memberDeviceID: options.signer.memberDeviceID,
            memberPublicKey: options.signer.publicKeyBase64, modelDigest: options.modelDigest)
    }

    /// Send the one-stage chain down, read the complete chain back on the return link
    /// (echoing each receiving end's probes meanwhile) and check it.
    private func headHandshake(
        _ links: ShardBenchLinks, expectedMembers: [ShardGroupExpectedMember]?, timeout: TimeInterval? = nil
    ) throws -> [ShardBenchHello] {
        let mine = myHello()
        let wait = timeout ?? options.connectTimeout
        try ShardChainWire.sendHello(links.downstream, [mine], header: header(.hello, destination: 1))
        let acknowledged = try ShardChainWire.awaitHello(
            links.downstream, timeout: wait, stageIndex: 0, layers: stage.layers)
        let chain = links.isCollapsed
            ? acknowledged
            : try ShardChainWire.awaitHello(links.upstream, timeout: wait, stageIndex: 0, layers: stage.layers)
        try ShardBenchChain.validateComplete(chain)
        guard chain[0] == mine else { throw ShardBenchError.handshake("the returned chain does not start with this head") }
        if let expected = options.expectedStages, chain.count != expected {
            throw ShardBenchError.handshake("chain has \(chain.count) stages, expected \(expected)")
        }
        if options.spare != nil, chain.count != 2 {
            throw ShardBenchError.handshake("--spare replays the head's downstream stage, which needs a two-stage chain; this one has \(chain.count)")
        }
        if let members = expectedMembers {
            guard members.count == chain.count - 1 else {
                throw ShardBenchError.handshake("chain has \(chain.count - 1) members after the head, the group names \(members.count)")
            }
            for (offset, member) in members.enumerated() {
                let hello = chain[offset + 1]
                guard hello.memberDeviceID == member.memberDeviceID,
                      hello.layerStart == member.layers.lowerBound, hello.layerEnd == member.layers.upperBound
                else {
                    throw ShardBenchError.handshake("stage \(offset + 1) is \(hello.memberDeviceID ?? "unnamed") \(hello.layerLabel), the group names \(member.memberDeviceID) \(member.layers.lowerBound):\(member.layers.upperBound)")
                }
                try ShardChainWire.checkConfigured(hello, key: member.publicKey, stage: offset + 1)
            }
        }
        if let digest = options.modelDigest {
            for (index, hello) in chain.enumerated() where hello.modelDigest != digest {
                throw ShardBenchError.handshake("stage \(index) model digest \(hello.modelDigest ?? "none") differs from the head's \(digest)")
            }
        }
        for (index, hello) in chain.enumerated() where hello.memberPublicKey == nil {
            throw ShardBenchError.handshake("stage \(index) announced no member key")
        }
        for (index, hello) in chain.enumerated().dropFirst() {
            try ShardChainWire.checkCapacity(hello, slots: options.maxInFlight, contextTokens: options.servingContextTokens, stage: index)
        }
        try ShardChainWire.checkPeer(links.downstream, is: chain[1], stage: 1)
        try ShardChainWire.checkPeer(links.upstream, is: chain[chain.count - 1], stage: chain.count - 1)
        return chain
    }

    private static func announcedKeys(_ chain: [ShardBenchHello]) -> [Int: String] {
        var keys = [Int: String]()
        for (index, hello) in chain.enumerated() { keys[index] = hello.memberPublicKey }
        return keys
    }

    // MARK: Loop

    private func loop() {
        var exitError: Error?
        do {
            while true {
                if try processQueue() { break }
                guard let links else { throw ShardGroupEngineError.unavailable("no links") }
                let frame: ShardStageFrame
                do {
                    frame = try receiveUpstream(links, timeout: Self.pollInterval)
                } catch ShardLinkError.receiveTimedOut {
                    if let fault = livenessFault() { try replaceLostStage(fault) }
                    continue
                } catch {
                    try replaceLostStage(error)
                    continue
                }
                try handle(frame)
                // SPEC-051-R013: each request's deadline is checked whenever every
                // answer that already arrived has been handled, and at least once
                // per poll interval while answers keep arriving, so other
                // requests' traffic never postpones the check of a stalled one
                // (a return inbox that never drains does not hide it either).
                let drained = heldFrame == nil && self.links?.upstream.hasQueuedFrames == false
                if drained || now() - lastLivenessCheck >= Self.pollInterval, let fault = livenessFault() {
                    try replaceLostStage(fault)
                }
            }
            try sessionEnd()
        } catch {
            exitError = error
        }
        teardown(exitError)
    }

    private func receiveUpstream(_ links: ShardBenchLinks, timeout: TimeInterval) throws -> ShardStageFrame {
        let frame: ShardStageFrame
        if let held = heldFrame {
            heldFrame = nil
            frame = held
        } else {
            frame = try links.upstream.receive(timeout: timeout)
        }
        if frame.header.kind == .error {
            throw ShardBenchError.peerError(String(decoding: frame.payload, as: UTF8.self))
        }
        return frame
    }

    /// Admit queued requests up to the in-flight limit and apply cancels. True when a
    /// shutdown was asked and nothing is outstanding.
    private func processQueue() throws -> Bool {
        lock.lock()
        let room = max(0, options.maxInFlight - active.count - awaiting.count)
        let admitted = Array(pending.prefix(room))
        pending.removeFirst(admitted.count)
        let cancelled = cancels
        cancels = []
        let shutdown = shutdownRequested
        var refused = [Pending]()
        if shutdown {
            refused = pending
            pending = []
        }
        lock.unlock()
        for request in refused {
            request.sink(.failure(ShardGroupEngineError.unavailable("the engine is shutting down")))
        }
        for id in cancelled {
            active[id]?.cancelled = true
        }
        for (index, request) in admitted.enumerated() {
            do {
                try admit(request)
            } catch {
                // Not admitted yet: back to the front of the queue, so the teardown
                // this error leads to ends each of them with a typed error too.
                lock.lock()
                pending.insert(contentsOf: admitted[(index + 1)...], at: 0)
                lock.unlock()
                throw error
            }
        }
        publish()
        return shutdown && active.isEmpty && awaiting.isEmpty
    }

    private func admit(_ request: Pending) throws {
        let cache: Stage.Cache
        do {
            cache = try stage.newCache()
        } catch {
            request.sink(.failure(ShardGroupEngineError.failedBeforeFirstToken(cause: "head cache allocation failed: \(error)")))
            return
        }
        let id = request.id
        var control = request.request.control
        control.requestID = request.request.receiptRequestID ?? String(id)
        var entry = Active(id: id, request: request.request, sink: request.sink, cache: cache)
        entry.timing.prefillStart = now()
        entry.lastSend = entry.timing.prefillStart
        entry.outstanding = true
        active[id] = entry
        try headSend(ShardStageFrame(
            header: header(.control, requestID: id, destination: 1),
            payload: try JSONEncoder().encode(control)), buffered: true)
        // Chunk i goes down the chain as soon as the head computed it, so stage k+1
        // works on chunk i while stage k computes chunk i+1. Only the last chunk asks
        // the last stage for a token.
        let prompt = request.request.promptTokens
        let chunkSize = options.prefillChunk ?? prompt.count
        let starts = Array(stride(from: 0, to: prompt.count, by: chunkSize))
        for (chunkIndex, start) in starts.enumerated() {
            guard active[id] != nil else { return }
            let chunk = Array(prompt[start..<min(prompt.count, start + chunkSize)])
            let computeStart = now()
            let hidden = try stage.forward(tokens: chunk, cache: cache)
            let elapsed = now() - computeStart
            active[id]?.timing.prefillChunkCompute.append(elapsed)
            if elapsed > options.prefillChunkDeadline {
                // The head's own chunk is too large for the deadline: fail this request
                // only, and drop what its members answer to the abort.
                failHeadSide(id, cause: "\(ShardBenchError.prefillChunkDeadline(stage: 0, tokens: chunk.count, milliseconds: Int((elapsed * 1000).rounded()), deadlineMilliseconds: Int((options.prefillChunkDeadline * 1000).rounded())))")
                return
            }
            let isLast = chunkIndex == starts.count - 1
            try sendActivation(id, hidden, step: 0, flags: isLast ? [] : .fillOnly)
            active[id]?.timing.prefillPayloadBytes += hidden.payload.count
            active[id]?.timing.prefillChunks += 1
            active[id]?.timing.activationDType = String(describing: hidden.dtype)
        }
    }

    private func failHeadSide(_ id: UInt64, cause: String) {
        guard let entry = active.removeValue(forKey: id) else { return }
        replayBuffer.remove(requestID: id)
        book.remove(id)
        discarding.insert(id)
        _ = try? links?.downstream.send(ShardStageFrame(header: header(.abort, requestID: id, destination: 1)))
        entry.sink(.failure(ShardGroupEngineError.failedBeforeFirstToken(cause: cause)))
    }

    private func handle(_ frame: ShardStageFrame) throws {
        let header = frame.header
        switch header.kind {
        case .token, .tokenLogits:
            try handleTokens(frame)
        case .abort where header.requestID != Self.probeRequestID:
            try handleReceipts(frame)
        default:
            throw ShardBenchError.protocolViolation("unexpected \(header.kind) frame for request \(header.requestID) on the head's return link")
        }
    }

    /// SPEC-051-R017: take this token and every other token already waiting, then
    /// run the next decode step of all their requests in one batched forward.
    private func handleTokens(_ first: ShardStageFrame) throws {
        var rows = [(id: UInt64, token: Int)]()
        var frame: ShardStageFrame? = first
        while let current = frame {
            frame = nil
            if let row = try acceptToken(current) { rows.append(row) }
            guard rows.count < options.maxInFlight, let next = pollUpstream() else { break }
            guard next.header.kind == .token || next.header.kind == .tokenLogits,
                  !rows.contains(where: { $0.id == next.header.requestID })
            else {
                heldFrame = next
                break
            }
            frame = next
        }
        try step(rows)
    }

    /// The next upstream frame if one is already queued. A failing link answers
    /// nil here; the loop's next receive reports it and handles the loss.
    private func pollUpstream() -> ShardStageFrame? {
        guard heldFrame == nil, let links else { return nil }
        return try? links.upstream.receive(timeout: 0)
    }

    /// One batched head forward over the next decode position of `rows`, then each
    /// request's activation down the chain.
    private func step(_ rows: [(id: UInt64, token: Int)]) throws {
        let live = rows.filter { active[$0.id] != nil }
        guard !live.isEmpty else { return }
        let computeStart = now()
        let hidden = try stage.forwardBatch(tokens: live.map(\.token), caches: live.map { active[$0.id]!.cache })
        let elapsed = now() - computeStart
        for (row, activation) in zip(live, hidden) {
            guard let entry = active[row.id] else { continue }
            active[row.id]?.timing.headDecodeCompute.append(elapsed)
            active[row.id]?.timing.decodeHopPayloadBytes = activation.payload.count
            active[row.id]?.outstanding = true
            try sendActivation(row.id, activation, step: UInt32(entry.tokens.count))
        }
    }

    /// Account one returned token; the request's next decode input when it goes on.
    private func acceptToken(_ frame: ShardStageFrame) throws -> (id: UInt64, token: Int)? {
        let header = frame.header
        guard header.dtype == .int32, var entry = active[header.requestID], entry.outstanding else {
            throw ShardBenchError.protocolViolation("expected a token for an active request, got \(header.kind) request \(header.requestID)")
        }
        let token: Int
        var summary: ShardLogitSummary?
        if header.kind == .tokenLogits {
            let decoded = try ShardLogitSummaryCodec.decode(shape: header.shape, payload: frame.payload)
            token = Int(decoded.token)
            summary = decoded.summary
        } else {
            guard frame.payload.count == 4 else { throw ShardBenchError.protocolViolation("token frame of \(frame.payload.count) bytes") }
            token = Int(frame.payload.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) })
        }
        guard header.tokenStep == UInt32(entry.tokens.count) else {
            throw ShardBenchError.protocolViolation("request \(entry.id) token step \(header.tokenStep), expected \(entry.tokens.count)")
        }
        book.recordInput(header, frame.payload)
        if var pending = catchUp?.pending, pending.remove(header.requestID) != nil {
            catchUp = pending.isEmpty ? nil : (catchUp!.deadline, pending)
        }
        let arrived = now()
        entry.outstanding = false
        entry.steps += 1
        if entry.tokens.isEmpty {
            entry.timing.firstTokenAt = arrived
        } else {
            entry.timing.stepRoundTrips.append(arrived - entry.lastSend)
        }
        entry.timing.lastTokenAt = arrived
        if entry.cancelled {
            active[entry.id] = entry
            try finish(entry.id, .cancelled)
            return nil
        }
        if entry.request.stopTokenIDs.contains(token) {
            entry.stopToken = token
            active[entry.id] = entry
            try finish(entry.id, .stop)
            return nil
        }
        entry.tokens.append(token)
        if let summary { entry.summaries.append(summary) }
        active[entry.id] = entry
        // Delivered from here on, whatever happens to the next send (SPEC-051-R012).
        entry.sink(.success(.token(token, summary)))
        if entry.tokens.count >= entry.request.maxTokens {
            try finish(entry.id, .length)
            return nil
        }
        return (entry.id, entry.request.teacherTokens.map { $0[entry.tokens.count - 1] } ?? token)
    }

    /// The request is done on the head: forget its replay frames and send the abort
    /// that collects its members' sub-receipts.
    private func finish(_ id: UInt64, _ reason: ShardFinishReason) throws {
        guard var entry = active.removeValue(forKey: id) else { return }
        entry.reason = reason
        entry.lastSend = now()
        replayBuffer.remove(requestID: id)
        awaiting[id] = entry
        try headSend(ShardStageFrame(header: header(.abort, requestID: id, destination: 1)), buffered: false)
    }

    private func handleReceipts(_ frame: ShardStageFrame) throws {
        let id = frame.header.requestID
        if discarding.remove(id) != nil { return }
        guard let entry = awaiting[id] else {
            throw ShardBenchError.protocolViolation("sub-receipts for request \(id), which is not finishing")
        }
        // The request stays in `awaiting` until its receipts are in hand, so an
        // error here still reaches it through the teardown (R2-C03).
        let others = try ShardChainWire.decodeReceipts(frame.payload)
        let mine = try options.signer.sign(book.receipt(
            requestID: id, receiptRequestID: entry.request.receiptRequestID ?? String(id),
            memberDeviceID: options.signer.memberDeviceID, groupEpoch: groupEpoch, stageIndex: 0, layers: stage.layers))
        awaiting[id] = nil
        book.remove(id)
        let receipts = [mine] + others
        let verdict = ShardGroupAttestationVerifier.verify(signed: receipts, expectedKeys: expectedKeys)
        let attestation: ShardRequestAttestation
        switch verdict {
        case .ok:
            attestation = ShardRequestAttestation(
                verdict: "ok", fault: nil, groupEpoch: groupEpoch, receipts: receipts, replays: replaysOf(id))
        case .broken(let fault):
            shardGroupLog("request \(id) attestation broken: \(fault.kind.rawValue) \(fault.detail)")
            attestation = ShardRequestAttestation(
                verdict: "broken", fault: fault, groupEpoch: groupEpoch, receipts: receipts, replays: replaysOf(id))
        }
        deliverFinished(entry, attestation: attestation)
    }

    private func replaysOf(_ id: UInt64) -> [ShardBenchReplayReport] {
        replayReports.filter { $0.requests.contains(id) }
    }

    private func deliverFinished(_ entry: Active, attestation: ShardRequestAttestation) {
        entry.sink(.success(.finished(ShardGenerationSummary(
            requestID: entry.id, reason: entry.reason ?? .length, promptTokens: entry.request.promptTokens.count,
            tokens: entry.tokens, tokenSteps: entry.steps, stopToken: entry.stopToken, summaries: entry.summaries, timing: entry.timing,
            attestation: attestation))))
    }

    private func sendActivation(_ id: UInt64, _ hidden: ShardBenchActivation, step: UInt32, flags: ShardFrameFlags = []) throws {
        active[id]?.lastSend = now()
        let frameHeader = header(.activation, dtype: hidden.dtype, requestID: id, step: step, destination: 1,
                                 shape: hidden.shape, flags: flags)
        try headSend(ShardStageFrame(header: frameHeader, payload: hidden.payload), buffered: true)
    }

    /// Send downstream. A buffered frame is kept for replay first, so when this send
    /// is the one that finds the stage gone, the replay delivers it.
    private func headSend(_ frame: ShardStageFrame, buffered: Bool) throws {
        if buffered, options.spare != nil { replayBuffer.append(frame) }
        guard let links else { throw ShardGroupEngineError.unavailable("no links") }
        do {
            try links.downstream.send(frame)
        } catch {
            try replaceLostStage(error)
            return
        }
        if frame.header.kind == .activation {
            book.recordOutput(frame.header, frame.payload, processedTokens: ShardMemberLedgerBook.processedTokens(frame.header))
        }
    }

    // MARK: Liveness and deadlines

    /// A silent upstream peer (SPEC-051-R014), a failure the watch on the send-only
    /// link recorded, or outstanding work past its budget (SPEC-051-R013).
    private func livenessFault() -> Error? {
        lastLivenessCheck = now()
        if let failure = watch.failure { return failure }
        if let catchUp, now() > catchUp.deadline {
            let live = catchUp.pending.filter { active[$0] != nil }
            if !live.isEmpty {
                return ShardGroupEngineError.unavailable("the spare did not catch up \(live.count) replayed request(s) within the replay deadline")
            }
            self.catchUp = nil
        }
        guard let links else { return nil }
        let now = now()
        let bytes = links.upstream.statistics.bytesReceived
        if bytes != heardBytes {
            heardBytes = bytes
            heardAt = now
        }
        let window = options.link.heartbeatInterval * Double(max(1, options.link.missedHeartbeatLimit))
        if now - heardAt > window {
            return ShardLinkError.peerDead(silentMilliseconds: Int((now - heardAt) * 1000))
        }
        let hops = Double(max(1, chainValue.count - 1))
        var chunks = 0
        var decodes = awaiting.count
        var oldest = awaiting.values.map(\.lastSend).min() ?? .infinity
        for entry in active.values where entry.outstanding {
            if entry.timing.firstTokenAt == nil {
                chunks += max(1, entry.timing.prefillChunks)
            } else {
                decodes += 1
            }
            oldest = min(oldest, entry.lastSend)
        }
        guard chunks + decodes > 0 else { return nil }
        // Work queues behind other work at every stage: allow each outstanding chunk
        // and step its own deadline on top of one pass through the chain. Each
        // request is timed from its own last send, so other requests' progress or
        // heartbeats never hide one that stalled.
        var budget = (hops + Double(decodes)) * options.decodeHopDeadline
        if chunks > 0 { budget += (hops + Double(chunks)) * options.prefillChunkDeadline }
        let silent = now - oldest
        guard silent > budget else { return nil }
        return ShardGroupEngineFault.progressDeadline(
            silentMilliseconds: Int(silent * 1000), budgetMilliseconds: Int(budget * 1000))
    }

    // MARK: Stage loss and spare replay

    /// A lost, silent, hung or failing downstream stage, as opposed to a local bug.
    static func isStageLoss(_ error: Error) -> Bool {
        switch error {
        case is ShardLinkError, is ShardGroupEngineFault: return true
        case ShardBenchError.peerError: return true
        default: return false
        }
    }

    /// SPEC-051-R022: the downstream stage is gone. With a spare (once per engine)
    /// start the next epoch with it, rebuild its KV from the replay buffer and continue
    /// at the next undelivered token of every in-flight request. Otherwise fail the
    /// engine: each request ends with its delivered count. Requests that already
    /// finished keep their tokens; their sub-receipts went with the lost member.
    private func replaceLostStage(_ error: Error) throws {
        let cause = watch.failure ?? error
        guard Self.isStageLoss(cause) else { throw cause }
        guard let spare = options.spare, replayReports.isEmpty else {
            throw ShardGroupEngineError.unavailable(options.spare == nil ? "\(cause)" : "\(cause) (the spare was already used)")
        }
        let started = now()
        // One absolute takeover deadline bounds connecting, authenticating,
        // the handshake, the replay and the spare's catch-up (SPEC-051-R022).
        let deadline = started + options.replayDeadline
        let remaining = { max(0.001, deadline - self.now()) }
        watch.stop()
        watch = ShardBenchLinkWatch()
        links?.close()
        // Whatever the lost chain still had queued is not part of the replay.
        heldFrame = nil
        let inFlight = active.keys.sorted()
        if let lost = inFlight.first(where: { !replayBuffer.isReplayable($0) }) {
            throw ShardGroupEngineError.unavailable("\(cause); request \(lost) outgrew the \(options.replayBufferBytes)-byte replay buffer")
        }
        finishMemberLost(cause: "\(cause)")
        do {
            groupEpoch += 1
            var configuration = options.link
            configuration.groupEpoch = groupEpoch
            let link: ShardStageLink
            if let standbyLink = standby?.take() {
                // The spare is already joined and authenticated on its standby link.
                link = standbyLink
                shardGroupLog("taking over on the standby link to \(link.peerAddress) after \(cause)")
            } else {
                link = try ShardStageLink.connect(
                    host: spare.host, port: spare.port, timeout: remaining(), configuration: configuration)
                shardGroupLog("connected to spare \(link.peerAddress) after \(cause)")
                try link.authenticate(signer: options.signer, role: .initiator, timeout: remaining())
            }
            standby = nil
            let replacement = ShardBenchLinks(upstream: link, downstream: link)
            replacementLinks.append(replacement)
            let chain = try headHandshake(replacement, expectedMembers: options.spareMember.map { [$0] }, timeout: min(options.connectTimeout, remaining()))
            guard chain.count == 2 else { throw ShardBenchError.handshake("the spare chain has \(chain.count) stages") }
            link.armLiveness()
            chainValue = chain
            expectedKeys = Self.announcedKeys(chain)
            var frames = 0
            var bytes = 0
            for id in inFlight {
                book.reset(id)
                let delivered = active[id]?.tokens.count ?? 0
                for frame in try replayBuffer.replayPlan(requestID: id, deliveredTokens: delivered) {
                    try link.send(frame)
                    if frame.header.kind == .activation {
                        book.recordOutput(frame.header, frame.payload, processedTokens: ShardMemberLedgerBook.processedTokens(frame.header))
                    }
                    frames += 1
                    bytes += frame.payload.count
                }
            }
            let elapsed = now() - started
            guard elapsed <= options.replayDeadline else {
                throw ShardGroupEngineError.unavailable("\(cause); replay took \(Int(elapsed * 1000)) ms, over the replay deadline")
            }
            replayReports.append(ShardBenchReplayReport(
                groupEpoch: groupEpoch, cause: String(describing: cause), reason: ShardGroupWire.takeoverReason(cause),
                spare: link.peerAddress, requests: inFlight,
                deliveredTokens: inFlight.map { active[$0]?.tokens.count ?? 0 }, replayedFrames: frames,
                replayedBytes: bytes, milliseconds: (elapsed * 1_000_000).rounded() / 1000))
            links = replacement
            let now = now()
            // The replay re-sent every in-flight request: their clocks restart,
            // and each must prove catch-up with its next token by the deadline.
            for id in inFlight { active[id]?.lastSend = now }
            catchUp = inFlight.isEmpty ? nil : (deadline, Set(inFlight))
            heardAt = now
            heardBytes = link.statistics.bytesReceived
            publish()
        } catch let error as ShardGroupEngineError {
            throw error
        } catch {
            throw ShardGroupEngineError.unavailable("\(cause); replacing with the spare failed: \(error)")
        }
    }

    /// Requests waiting for sub-receipts when a member is lost keep their delivered
    /// tokens; their attestation cannot be completed.
    private func finishMemberLost(cause: String) {
        for (id, entry) in awaiting.sorted(by: { $0.key < $1.key }) {
            let mine = try? options.signer.sign(book.receipt(
                requestID: id, receiptRequestID: entry.request.receiptRequestID ?? String(id),
                memberDeviceID: options.signer.memberDeviceID, groupEpoch: groupEpoch, stageIndex: 0, layers: stage.layers))
            book.remove(id)
            deliverFinished(entry, attestation: ShardRequestAttestation(
                verdict: "unverifiable_member_lost",
                fault: nil, groupEpoch: groupEpoch, receipts: mine.map { [$0] } ?? [], replays: replaysOf(id)))
        }
        awaiting = [:]
        discarding = []
    }

    // MARK: Session end and teardown

    /// Request id 0 abort travels down the chain; the tail answers on the return link
    /// once it has seen it, so no stage reads the close as a failure.
    private func sessionEnd() throws {
        guard let links else { return }
        watch.stop()
        try links.downstream.send(ShardStageFrame(header: header(.abort, requestID: Self.probeRequestID, destination: 1)))
        let end = try receiveUpstream(links, timeout: options.connectTimeout)
        guard end.header.kind == .abort, end.header.requestID == Self.probeRequestID else {
            throw ShardBenchError.protocolViolation("expected the session-end acknowledgement, got \(end.header.kind) request \(end.header.requestID)")
        }
    }

    private func teardown(_ error: Error?) {
        watch.stop()
        standby?.stop()
        standby = nil
        if let error, let links { Self.sendError(links, error, epoch: groupEpoch) }
        links?.close()
        for replacement in replacementLinks { replacement.close() }
        let cause = error.map { error -> String in
            if case ShardGroupEngineError.unavailable(let detail) = error { return detail }
            return "\(error)"
        } ?? "the engine shut down"
        if error != nil {
            shardGroupLog("engine stopped: \(cause)")
            finishMemberLost(cause: cause)
            for id in active.keys.sorted() {
                guard let entry = active[id] else { continue }
                entry.sink(.failure(entry.tokens.isEmpty
                    ? ShardGroupEngineError.failedBeforeFirstToken(cause: cause)
                    : ShardGroupEngineError.streamTerminated(delivered: entry.tokens.count, cause: cause)))
            }
        }
        active = [:]
        replayBuffer = ShardReplayBuffer(capacityBytes: options.replayBufferBytes)
        lock.lock()
        running = false
        stopError = error
        let refused = pending
        pending = []
        published.running = false
        published.inFlight = 0
        published.failure = error.map { _ in cause }
        lock.unlock()
        for request in refused {
            request.sink(.failure(ShardGroupEngineError.unavailable(cause)))
        }
        stopped.leave()
    }

    private func publish() {
        let health = links.map { links in
            ShardGroupLinkHealth(
                downstream: links.downstream.roundTrip, upstream: links.isCollapsed ? nil : links.upstream.roundTrip)
        }
        let spare = standby?.health
        lock.lock()
        published.groupEpoch = groupEpoch
        published.chain = chainValue
        published.inFlight = active.count + awaiting.count
        published.replays = replayReports.count
        published.links = health
        published.spare = spare
        lock.unlock()
    }

    private static func sendError(_ links: ShardBenchLinks, _ error: Error, epoch: UInt64) {
        // Best effort on every link: one of them may be the one that failed.
        for link in links.unique {
            _ = try? link.send(ShardStageFrame(
                header: ShardStageFrameHeader(kind: .error, groupEpoch: epoch),
                payload: Data(String(describing: error).prefix(4096).utf8)))
        }
    }

    private func header(
        _ kind: ShardFrameKind,
        dtype: ShardTensorDType = .none,
        requestID: UInt64 = 0,
        step: UInt32 = 0,
        destination: Int,
        shape: [UInt32] = [],
        flags: ShardFrameFlags = []
    ) -> ShardStageFrameHeader {
        // The micro-batch id names the request's slot; each request is its own row.
        ShardStageFrameHeader(
            kind: kind, dtype: dtype, groupEpoch: groupEpoch, requestID: requestID,
            microBatchID: UInt32(truncatingIfNeeded: requestID), tokenStep: step, sourceStage: 0,
            destinationStage: UInt16(destination),
            layerStart: UInt32(stage.layers.lowerBound), layerEnd: UInt32(stage.layers.upperBound),
            shape: shape, flags: flags)
    }

    private func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }
}

/// One diagnostic line on stderr.
func shardGroupLog(_ line: String) {
    FileHandle.standardError.write(Data("shard-group: \(line)\n".utf8))
}

/// Blocking collector of engine events for synchronous callers (the lab harness).
final class ShardGenerationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var remaining: Int
    private var summaries = [UInt64: ShardGenerationSummary]()
    private var errors = [UInt64: Error]()

    init(count: Int) {
        remaining = count
    }

    func receive(_ id: UInt64, _ result: Result<ShardGenerationEvent, Error>) {
        lock.lock()
        var ended = false
        switch result {
        case .success(.token):
            break
        case .success(.finished(let summary)):
            summaries[id] = summary
            ended = true
        case .failure(let error):
            errors[id] = error
            ended = true
        }
        if ended { remaining -= 1 }
        let complete = ended && remaining == 0
        lock.unlock()
        if complete { done.signal() }
    }

    /// Wait for every request; summaries and errors keyed by request id.
    func wait() -> (summaries: [UInt64: ShardGenerationSummary], errors: [UInt64: Error]) {
        lock.lock()
        let empty = remaining == 0
        lock.unlock()
        if !empty { done.wait() }
        lock.lock()
        defer { lock.unlock() }
        return (summaries, errors)
    }
}
