import CryptoKit
import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Deterministic stand-in for a pipeline stage. Every output depends on the stage's
/// whole per-sequence history (its "KV"), so a lost, duplicated or reordered frame
/// changes the tokens, as it would with a real model.
final class FakeShardStage: ShardBenchStage {
    final class Cache {
        var history: [Float] = []
    }

    /// Greedy and deterministic whatever the request asks; tests record what it asked.
    typealias Sampler = ShardRequestControl

    let modelType = "fake"
    let hiddenSize = 4
    let layers: Range<Int>
    let totalLayers: Int
    let weightBytes = 0
    /// Throw on this forward call (1-based), to simulate a stage failing mid-decode.
    var failOnCall: Int?
    /// Called before each forward with the 1-based call number.
    var onCall: ((Int) -> Void)?
    /// Sleep this long in every forward, to push a prefill chunk past its deadline.
    var computeDelay: TimeInterval = 0
    private var calls = 0

    init(layers: Range<Int>, totalLayers: Int) {
        self.layers = layers
        self.totalLayers = totalLayers
    }

    struct Failure: Error, CustomStringConvertible {
        let call: Int
        var description: String { "fake stage failure on call \(call)" }
    }

    func newCache() throws -> Cache { Cache() }

    /// Token inputs of every first-stage forward, in order.
    private(set) var tokensSeen: [[Int]] = []

    func forward(tokens: [Int], cache: Cache) throws -> ShardBenchActivation {
        try count()
        tokensSeen.append(tokens)
        var rows = [Float]()
        for token in tokens {
            rows += [Float(token), Float(token % 7), Float(cache.history.count % 5), Float(layers.upperBound)]
            cache.history.append(Float(token))
        }
        return Self.encode(rows, tokens: tokens.count)
    }

    func forward(activation: ShardBenchActivation, cache: Cache) throws -> ShardBenchActivation {
        try count()
        let input = Self.decode(activation)
        var output = [Float]()
        for (offset, value) in input.enumerated() {
            if offset % hiddenSize == 0 { cache.history.append(value) }
            output.append(value + Float(layers.lowerBound) + Float(cache.history.count % 5))
        }
        return Self.encode(output, tokens: Int(activation.shape[1]))
    }

    /// Every request's sampling control, in arrival order.
    private(set) var controlsSeen: [ShardRequestControl] = []

    func makeSampler(_ control: ShardRequestControl) -> ShardRequestControl {
        controlsSeen.append(control)
        return control
    }

    func sample(activation: ShardBenchActivation, cache: Cache, sampler: ShardRequestControl) throws -> Int {
        try count()
        return Self.mix(activation, into: cache) % 97
    }

    /// Top-k ids are distinct (97 is prime), the first one is what `sample` returns,
    /// and `logprobShift` moves every logprob so a test can perturb this stage.
    func summarize(activation: ShardBenchActivation, cache: Cache, topK: Int) throws -> ShardLogitSummary {
        try count()
        let mixed = Self.mix(activation, into: cache)
        return ShardLogitSummary(
            topTokens: (0..<topK).map { Int32((mixed + $0 * 7) % 97) },
            topLogprobs: (0..<topK).map { -0.1 - 0.5 * Float($0) + logprobShift },
            logSumExp: Float(mixed % 13))
    }

    /// Added to every logprob this stage summarizes.
    var logprobShift: Float = 0

    private static func mix(_ activation: ShardBenchActivation, into cache: Cache) -> Int {
        for (offset, value) in decode(activation).enumerated() where offset % 4 == 0 { cache.history.append(value) }
        return cache.history.enumerated().reduce(0) { ($0 &* 31 &+ Int($1.element) &+ $1.offset) % 1_000_003 }
    }

    func fill(activation: ShardBenchActivation, cache: Cache) throws {
        try count()
        for (offset, value) in Self.decode(activation).enumerated() where offset % hiddenSize == 0 { cache.history.append(value) }
    }

    private func count() throws {
        calls += 1
        onCall?(calls)
        if computeDelay > 0 { Thread.sleep(forTimeInterval: computeDelay) }
        if let failOnCall, calls == failOnCall { throw Failure(call: calls) }
    }

    static func encode(_ values: [Float], tokens: Int) -> ShardBenchActivation {
        var data = Data(capacity: values.count * 4)
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return ShardBenchActivation(dtype: .float32, shape: [1, UInt32(tokens), 4], payload: data)
    }

    static func decode(_ activation: ShardBenchActivation) -> [Float] {
        activation.payload.withUnsafeBytes { buffer in
            (0..<(buffer.count / 4)).map { Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }
}

/// Shared harness: loopback links, session options and an in-process reference.
enum ShardBenchTestRig {
    static let epoch: UInt64 = 3

    static func configuration(
        epoch: UInt64 = ShardBenchTestRig.epoch, protection: ShardLinkFrameProtection = .crc32c
    ) -> ShardLinkConfiguration {
        ShardLinkConfiguration(
            groupEpoch: epoch, heartbeatInterval: 0.05, missedHeartbeatLimit: 4, armLivenessOnOpen: false, frameProtection: protection)
    }

    /// A connected loopback pair: (accepted side, dialing side). With `signers` the
    /// pair is an hmac-sha256 link whose two ends ran their key agreement.
    static func pair(
        epoch: UInt64 = ShardBenchTestRig.epoch, signers: (accepted: ShardMemberSigner, dialed: ShardMemberSigner)? = nil
    ) throws -> (ShardStageLink, ShardStageLink) {
        let link = configuration(epoch: epoch, protection: signers == nil ? .crc32c : .hmacSHA256)
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let dialed = try ShardStageLink.connect(host: "127.0.0.1", port: listener.port, timeout: 5, configuration: link)
        let accepted = try listener.accept(timeout: 5, configuration: link)
        if let signers {
            let responder = DispatchGroup()
            responder.enter()
            let outcome = ShardBenchWaitBox<ShardLinkPeer?>()
            Thread {
                outcome.result = Result { try accepted.authenticate(signer: signers.accepted, role: .responder, timeout: 5) }
                responder.leave()
            }.start()
            try dialed.authenticate(signer: signers.dialed, role: .initiator, timeout: 5)
            responder.wait()
            _ = try outcome.result?.get()
        }
        return (accepted, dialed)
    }

    /// Links for a ring of `stages` stages, indexed by stage. With two stages and
    /// `collapsed`, one link carries both directions. With `signers` (one per stage)
    /// every link is hmac-sha256, authenticated by the stages it joins.
    static func ring(stages: Int, collapsed: Bool = false, signers: [ShardMemberSigner]? = nil) throws -> [ShardBenchLinks] {
        func joining(accepted: Int, dialed: Int) -> (accepted: ShardMemberSigner, dialed: ShardMemberSigner)? {
            signers.map { ($0[accepted], $0[dialed]) }
        }
        if stages == 2, collapsed {
            let (tail, head) = try pair(signers: joining(accepted: 1, dialed: 0))
            return [ShardBenchLinks(upstream: head, downstream: head), ShardBenchLinks(upstream: tail, downstream: tail)]
        }
        // forward[i] joins stage i (dialing) to stage i+1 (accepting); back joins the
        // tail (dialing) to the head (accepting).
        let forward = try (0..<(stages - 1)).map { try pair(signers: joining(accepted: $0 + 1, dialed: $0)) }
        let back = try pair(signers: joining(accepted: 0, dialed: stages - 1))
        return (0..<stages).map { index in
            let upstream = index == 0 ? back.0 : forward[index - 1].0
            let downstream = index == stages - 1 ? back.1 : forward[index].1
            return ShardBenchLinks(upstream: upstream, downstream: downstream)
        }
    }

    static func options(
        role: ShardBenchRole,
        prompts: [[Int]],
        tokens: Int,
        probeCount: Int = 5,
        expectedStages: Int? = nil,
        prefillChunk: Int? = nil,
        prefillChunkDeadline: TimeInterval = 3,
        epoch: UInt64 = ShardBenchTestRig.epoch,
        spare: ShardBenchEndpoint? = nil,
        replayBufferBytes: Int = 1 << 20,
        listen: ShardBenchEndpoint? = nil,
        connect: ShardBenchEndpoint? = nil,
        connectTimeout: TimeInterval = 5,
        parity: ShardBenchParityOptions = .skipped,
        protection: ShardLinkFrameProtection = .crc32c
    ) -> ShardBenchSessionOptions {
        ShardBenchSessionOptions(
            role: role, listen: listen, connect: connect, expectedStages: expectedStages, modelLabel: "fake",
            prompts: prompts, tokens: tokens, temperature: 0, seed: 0, link: configuration(epoch: epoch, protection: protection),
            receiveTimeout: 5, connectTimeout: connectTimeout, probeCount: probeCount, maxSequences: 8, warmup: true,
            prefillChunk: prefillChunk, prefillChunkDeadline: prefillChunkDeadline, memberID: nil,
            spare: spare, replayBufferBytes: replayBufferBytes, replayDeadline: 5, parity: parity)
    }

    static func stages(_ splits: [Range<Int>], total: Int) -> [FakeShardStage] {
        splits.map { FakeShardStage(layers: $0, totalLayers: total) }
    }

    /// Decode with the same stages chained in process, no links.
    static func reference(splits: [Range<Int>], total: Int, prompts: [[Int]], tokens: Int) throws -> [[Int]] {
        let chain = stages(splits, total: total)
        return try prompts.map { prompt in
            let caches = try chain.map { try $0.newCache() }
            var generated = [Int]()
            var input = prompt
            while generated.count < tokens {
                var activation = try chain[0].forward(tokens: input, cache: caches[0])
                for index in 1..<(chain.count - 1) {
                    activation = try chain[index].forward(activation: activation, cache: caches[index])
                }
                let token = try chain[chain.count - 1].sample(
                    activation: activation, cache: caches[chain.count - 1], sampler: ShardRequestControl(temperature: 0))
                generated.append(token)
                input = [token]
            }
            return generated
        }
    }

    /// Greedy reference with per-step logit summaries from the same stages in process.
    static func referenceReport(splits: [Range<Int>], total: Int, prompts: [[Int]], tokens: Int, topK: Int) throws -> ShardBenchReferenceReport {
        let chain = stages(splits, total: total)
        var sequences = [[Int]]()
        var stepLogits = [[ShardLogitSummary]]()
        for prompt in prompts {
            let caches = try chain.map { try $0.newCache() }
            var generated = [Int]()
            var summaries = [ShardLogitSummary]()
            var input = prompt
            while generated.count < tokens {
                var activation = try chain[0].forward(tokens: input, cache: caches[0])
                for index in 1..<(chain.count - 1) {
                    activation = try chain[index].forward(activation: activation, cache: caches[index])
                }
                let summary = try chain[chain.count - 1].summarize(activation: activation, cache: caches[chain.count - 1], topK: topK)
                summaries.append(summary)
                generated.append(Int(summary.top1))
                input = [Int(summary.top1)]
            }
            sequences.append(generated)
            stepLogits.append(summaries)
        }
        return ShardBenchReferenceReport(
            sequenceTokens: sequences, promptTokens: prompts.map(\.count), singleStreamTokensPerSecond: nil,
            ttft: ShardBenchLatency(seconds: []), prompts: prompts, stepLogits: stepLogits)
    }

    static func teacherForced(_ reference: ShardBenchReferenceReport, topK: Int = 4) -> ShardBenchParityOptions {
        ShardBenchParityOptions(
            mode: .teacherForced, topK: topK, tieMargin: 0.05, logprobTolerance: 0.1,
            referenceProvider: { reference }, referenceSource: "test")
    }

    /// Run every stage's session on its own thread; results indexed by stage.
    static func run(
        _ stages: [FakeShardStage],
        links: [ShardBenchLinks],
        prompts: [[Int]],
        tokens: Int,
        expectedStages: Int? = nil,
        beforeRun: [Int: () -> Void] = [:],
        prefillChunk: Int? = nil,
        prefillChunkDeadline: TimeInterval = 3,
        spare: ShardBenchEndpoint? = nil,
        replayBufferBytes: Int = 1 << 20,
        parity: ShardBenchParityOptions = .skipped,
        signers: [ShardMemberSigner]? = nil
    ) -> [Result<ShardBenchSessionReport, Error>] {
        let results = ShardBenchResultBox(count: stages.count)
        let group = DispatchGroup()
        for (index, stage) in stages.enumerated() {
            let role: ShardBenchRole = index == 0 ? .head : (index == stages.count - 1 ? .tail : .middle)
            var stageOptions = options(
                role: role, prompts: prompts, tokens: tokens, expectedStages: index == 0 ? expectedStages : nil,
                prefillChunk: prefillChunk, prefillChunkDeadline: prefillChunkDeadline,
                spare: index == 0 ? spare : nil, replayBufferBytes: replayBufferBytes,
                parity: index == 0 ? parity : .skipped, protection: signers == nil ? .crc32c : .hmacSHA256)
            stageOptions.signer = signers?[index]
            let session = ShardBenchSession(options: stageOptions, stage: stage)
            let stageLinks = links[index]
            let prepare = beforeRun[index]
            group.enter()
            Thread {
                prepare?()
                results.set(index, Result { try session.run(links: stageLinks) })
                group.leave()
            }.start()
        }
        _ = group.wait(timeout: .now() + 30)
        return results.all
    }
}

final class ShardBenchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ShardBenchSessionReport, Error>?]

    init(count: Int) { results = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ result: Result<ShardBenchSessionReport, Error>) {
        lock.lock()
        results[index] = result
        lock.unlock()
    }

    var all: [Result<ShardBenchSessionReport, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return results.map { $0 ?? .failure(ShardBenchError.protocolViolation("session did not finish")) }
    }
}

/// Issue #2084 slice 1: N-stage chains. The head addresses a ring of S stages over
/// loopback links; middles forward, the tail returns tokens to the head.
final class ShardBenchChainTests: XCTestCase {
    private let prompts = [[5, 9, 2, 33, 71], [8, 1, 64]]

    func testThreeStageRingMatchesInProcessChainWithPerHopStats() throws {
        let splits = [0..<1, 1..<3, 3..<4]
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages(splits, total: 4), links: try ShardBenchTestRig.ring(stages: 3),
            prompts: prompts, tokens: 6, expectedStages: 3)
        let head = try XCTUnwrap(try results[0].get().head)
        XCTAssertEqual(head.sequenceTokens, try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 6))
        XCTAssertEqual(head.stageCount, 3)
        XCTAssertEqual(head.stageLayers, ["0:1", "1:3", "3:4"])
        XCTAssertEqual(head.hops.map { [$0.from, $0.to] }, [[0, 1], [1, 2], [2, 0]])
        XCTAssertEqual(head.hops.map(\.carriesReturn), [false, false, true])
        XCTAssertEqual(head.hops.map { $0.probeRoundTrip?.count }, [5, 5, 5])
        XCTAssertEqual(head.links.map(\.name), ["downstream", "return"])
        XCTAssertEqual(head.links.map(\.peerStage), [1, 2])

        let middle = try XCTUnwrap(try results[1].get().stage)
        XCTAssertEqual(middle.role, .middle)
        XCTAssertEqual(middle.stageIndex, 1)
        XCTAssertEqual(middle.sequencesServed, 3, "warmup plus two sequences")
        XCTAssertEqual(middle.links.map(\.name), ["upstream", "downstream"])
        XCTAssertEqual(middle.links.map(\.peerStage), [0, 2])
        XCTAssertGreaterThan(middle.links[1].bytesSent, 0)

        let tail = try XCTUnwrap(try results[2].get().stage)
        XCTAssertEqual(tail.role, .tail)
        XCTAssertEqual(tail.stageIndex, 2)
        XCTAssertEqual(tail.links.map(\.name), ["upstream", "return"])
        XCTAssertEqual(tail.links.map(\.peerStage), [1, 0])
        XCTAssertEqual(tail.links[1].probeRoundTrip?.count, 5)
    }

    // MARK: Slice 4: group attestation

    func testHeadVerifiesTheChainedSubReceiptsOfEveryRequest() throws {
        let splits = [0..<1, 1..<3, 3..<4]
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages(splits, total: 4), links: try ShardBenchTestRig.ring(stages: 3),
            prompts: prompts, tokens: 6)
        let head = try XCTUnwrap(try results[0].get().head)
        XCTAssertEqual(head.attestation.verdict, "ok")
        XCTAssertEqual(head.attestation.requests.map(\.requestID), [2, 3], "measured requests only, not the warmup")
        for (request, prompt) in zip(head.attestation.requests, prompts) {
            XCTAssertEqual(request.verdict, "ok")
            XCTAssertNil(request.fault)
            XCTAssertEqual(request.receipts.map(\.stageIndex), [0, 1, 2])
            XCTAssertEqual(request.receipts.map(\.memberDeviceID), ["stage-0", "stage-1", "stage-2"])
            XCTAssertEqual(request.receipts.map { "\($0.layerStart):\($0.layerEnd)" }, ["0:1", "1:3", "3:4"])
            XCTAssertEqual(request.receipts.map(\.promptTokens), [prompt.count, prompt.count, prompt.count])
            XCTAssertEqual(request.receipts.map(\.decodeSteps), [5, 5, 5])
            XCTAssertEqual(request.receipts[0].outDigest, request.receipts[1].inDigest)
            XCTAssertEqual(request.receipts[1].outDigest, request.receipts[2].inDigest)
            XCTAssertEqual(request.receipts[2].outDigest, request.receipts[0].inDigest)
            XCTAssertNotEqual(request.receipts[0].outDigest, request.receipts[1].outDigest)
        }
        XCTAssertNotEqual(head.attestation.requests[0].receipts[0].outDigest, head.attestation.requests[1].receipts[0].outDigest)
    }

    // MARK: SPEC-051-R011 frame protection

    private func signers(_ count: Int) -> [ShardMemberSigner] {
        (0..<count).map { ShardMemberSigner(memberDeviceID: "mac-\($0)", key: Curve25519.Signing.PrivateKey()) }
    }

    func testHMACProtectedThreeStageRingServesOverAuthenticatedLinks() throws {
        let splits = [0..<1, 1..<3, 3..<4]
        let members = signers(3)
        let links = try ShardBenchTestRig.ring(stages: 3, signers: members)
        XCTAssertEqual(links[0].downstream.peer?.publicKey, members[1].publicKeyBase64)
        XCTAssertEqual(links[0].upstream.peer?.publicKey, members[2].publicKeyBase64)
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages(splits, total: 4), links: links, prompts: prompts, tokens: 6, expectedStages: 3, signers: members)
        let head = try XCTUnwrap(try results[0].get().head)
        XCTAssertEqual(head.sequenceTokens, try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 6))
        XCTAssertEqual(head.attestation.verdict, "ok")
        XCTAssertEqual(head.attestation.requests.first?.receipts.map(\.memberDeviceID), ["mac-0", "mac-1", "mac-2"])
        XCTAssertNoThrow(try results[1].get())
        XCTAssertNoThrow(try results[2].get())
    }

    func testALinkAuthenticatedByAnotherKeyThanTheChainNamesIsRefused() throws {
        let members = signers(2)
        let impostor = ShardMemberSigner(memberDeviceID: "mac-1", key: Curve25519.Signing.PrivateKey())
        // The tail's link was authenticated by `impostor`; its hello announces mac-1's key.
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true, signers: [members[0], impostor])
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages([0..<2, 2..<4], total: 4), links: links, prompts: prompts, tokens: 2, signers: members)
        XCTAssertThrowsError(try results[0].get()) { error in
            XCTAssertTrue(String(describing: error).contains("not by the key stage 1 announces"), "\(error)")
        }
    }

    func testFourStageRingWithTwoMiddles() throws {
        let splits = [0..<2, 2..<3, 3..<5, 5..<6]
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages(splits, total: 6), links: try ShardBenchTestRig.ring(stages: 4),
            prompts: prompts, tokens: 5)
        let head = try XCTUnwrap(try results[0].get().head)
        XCTAssertEqual(head.sequenceTokens, try ShardBenchTestRig.reference(splits: splits, total: 6, prompts: prompts, tokens: 5))
        XCTAssertEqual(head.hops.count, 4)
        XCTAssertEqual(try results[2].get().stage?.stageIndex, 2)
        XCTAssertEqual(try results[3].get().stage?.stageIndex, 3)
    }

    func testTwoStageSingleLinkCarriesActivationsAndTokens() throws {
        let splits = [0..<2, 2..<4]
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages(splits, total: 4), links: try ShardBenchTestRig.ring(stages: 2, collapsed: true),
            prompts: prompts, tokens: 4)
        let head = try XCTUnwrap(try results[0].get().head)
        XCTAssertEqual(head.sequenceTokens, try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 4))
        XCTAssertEqual(head.hops, [ShardBenchHopReport(from: 0, to: 1, carriesReturn: true, probeRoundTrip: head.probeRoundTrip)])
        XCTAssertEqual(head.links.map(\.name), ["downstream+return"])
        XCTAssertEqual(try results[1].get().stage?.links.map(\.name), ["upstream+return"])
    }

    func testLayerGapIsRefusedAtTheStageThatSeesIt() throws {
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages([0..<1, 2..<3, 3..<4], total: 4), links: try ShardBenchTestRig.ring(stages: 3),
            prompts: prompts, tokens: 2)
        XCTAssertThrowsError(try results[1].get()) { error in
            XCTAssertTrue(String(describing: error).contains("stage 0 layers end at 1 but stage 1 starts at 2"), "\(error)")
        }
        XCTAssertThrowsError(try results[0].get())
        XCTAssertThrowsError(try results[2].get())
    }

    func testHeadRefusesAnUnexpectedStageCount() throws {
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages([0..<2, 2..<4], total: 4), links: try ShardBenchTestRig.ring(stages: 2),
            prompts: prompts, tokens: 2, expectedStages: 3)
        XCTAssertThrowsError(try results[0].get()) { error in
            XCTAssertTrue(String(describing: error).contains("chain has 2 stages, expected 3"), "\(error)")
        }
    }

    func testMiddleFailureReachesTheHeadAsAPeerError() throws {
        let stages = ShardBenchTestRig.stages([0..<1, 1..<3, 3..<4], total: 4)
        stages[1].failOnCall = 4
        let start = Date()
        let results = ShardBenchTestRig.run(stages, links: try ShardBenchTestRig.ring(stages: 3), prompts: prompts, tokens: 6)
        XCTAssertThrowsError(try results[0].get()) { error in
            XCTAssertTrue(String(describing: error).contains("fake stage failure on call 4"), "\(error)")
        }
        XCTAssertThrowsError(try results[1].get())
        XCTAssertThrowsError(try results[2].get())
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testStageSilentForOverASecondBeforeItsHelloIsNotDeclaredDead() throws {
        // The tail's links stay silent (no heartbeats) for 1.2 s after accept, as a
        // stage still busy before its hello would be; liveness is armed only after the
        // hello exchange, so the head and middle wait instead of declaring it dead.
        let splits = [0..<1, 1..<3, 3..<4]
        let links = try ShardBenchTestRig.ring(stages: 3)
        for link in links[2].unique { link.pauseHeartbeatsForTesting() }
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages(splits, total: 4), links: links, prompts: prompts, tokens: 3,
            beforeRun: [2: {
                Thread.sleep(forTimeInterval: 1.2)
                for link in links[2].unique { link.resumeHeartbeatsForTesting() }
            }])
        let head = try XCTUnwrap(try results[0].get().head)
        XCTAssertEqual(head.sequenceTokens, try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 3))
        XCTAssertNoThrow(try results[1].get())
        XCTAssertNoThrow(try results[2].get())
    }

    // MARK: Slice 2: chunked pipelined prefill

    func testChunkedPrefillThroughThreeStagesMatchesTheUnchunkedReference() throws {
        let splits = [0..<1, 1..<3, 3..<4]
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages(splits, total: 4), links: try ShardBenchTestRig.ring(stages: 3),
            prompts: prompts, tokens: 5, prefillChunk: 2)
        let head = try XCTUnwrap(try results[0].get().head)
        XCTAssertEqual(head.sequenceTokens, try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 5))
        XCTAssertEqual(head.prefillChunkTokens, 2)
        XCTAssertEqual(head.prefillChunksPerSequence, [3, 2])
        // Fill-only chunks are part of the digest chain and of the tail's prompt count.
        XCTAssertEqual(head.attestation.verdict, "ok")
        XCTAssertEqual(head.attestation.requests.map { $0.receipts.map(\.promptTokens) }, [[5, 5, 5], [3, 3, 3]])
        // The head reports the measured run (3 + 2 chunks); the stages also served the
        // warmup's 3 chunks of prompt 0.
        XCTAssertEqual(head.headPrefillChunkCompute.count, 5)
        XCTAssertEqual(try results[1].get().stage?.prefillCompute.count, 8)
        XCTAssertEqual(try results[2].get().stage?.prefillCompute.count, 8)
    }

    /// The shape of the two-Mac chunked run: the head dials (`--connect`) before the
    /// tail listens (`--listen`), one link, `--prefill-chunk 8`, 32 tokens, through the
    /// same `run()` path the CLI uses, so link opening is covered too.
    func testTwoStageChunkedRunOverDialedLinkProducesAHeadReport() throws {
        let port = try ShardStageListener(host: "127.0.0.1", port: 0).port
        let endpoint = ShardBenchEndpoint(host: "127.0.0.1", port: port)
        let prompt = Array(1...30)
        let splits = [0..<14, 14..<28]
        let stages = ShardBenchTestRig.stages(splits, total: 28)
        let head = ShardBenchSession(
            options: ShardBenchTestRig.options(role: .head, prompts: [prompt], tokens: 32, prefillChunk: 8, connect: endpoint, connectTimeout: 20),
            stage: stages[0])
        let tail = ShardBenchSession(
            options: ShardBenchTestRig.options(role: .tail, prompts: [prompt], tokens: 32, listen: endpoint, connectTimeout: 20),
            stage: stages[1])
        let results = ShardBenchResultBox(count: 2)
        let group = DispatchGroup()
        group.enter()
        Thread {
            results.set(0, Result { try head.run() })
            group.leave()
        }.start()
        group.enter()
        Thread {
            Thread.sleep(forTimeInterval: 0.7)
            results.set(1, Result { try tail.run() })
            group.leave()
        }.start()
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        let headReport = try XCTUnwrap(try results.all[0].get().head)
        let tailReport = try XCTUnwrap(try results.all[1].get().stage)
        XCTAssertEqual(headReport.sequenceTokens,
                       try ShardBenchTestRig.reference(splits: splits, total: 28, prompts: [prompt], tokens: 32))
        XCTAssertEqual(headReport.prefillChunksPerSequence, [4])
        XCTAssertEqual(headReport.attestation.verdict, "ok")
        XCTAssertEqual(headReport.links.map(\.name), ["downstream+return"])
        // The tail served this head: same session id, warmup (3 decode steps) plus 31.
        XCTAssertEqual(tailReport.session, headReport.session)
        XCTAssertEqual(tailReport.decodeCompute.count, 34)
        XCTAssertEqual(tailReport.prefillCompute.count, 8, "4 warmup chunks + 4 measured chunks")
    }

    func testPrefillChunkOverTheDeadlineFailsTheRun() throws {
        let stages = ShardBenchTestRig.stages([0..<1, 1..<3, 3..<4], total: 4)
        stages[1].computeDelay = 0.15
        let results = ShardBenchTestRig.run(
            stages, links: try ShardBenchTestRig.ring(stages: 3), prompts: prompts, tokens: 3,
            prefillChunk: 2, prefillChunkDeadline: 0.1)
        XCTAssertThrowsError(try results[1].get()) { error in
            guard case ShardBenchError.prefillChunkDeadline(let stage, let tokens, _, let deadline) = error else {
                return XCTFail("expected a chunk deadline failure, got \(error)")
            }
            XCTAssertEqual(stage, 1)
            XCTAssertEqual(tokens, 2)
            XCTAssertEqual(deadline, 100)
        }
        XCTAssertThrowsError(try results[0].get()) { error in
            XCTAssertTrue(String(describing: error).contains("chunk deadline"), "\(error)")
        }
    }

    // MARK: Teacher-forced parity

    func testTeacherForcedRunOverThreeStagesPassesWithFullAgreement() throws {
        let splits = [0..<1, 1..<3, 3..<4]
        let reference = try ShardBenchTestRig.referenceReport(splits: splits, total: 4, prompts: prompts, tokens: 6, topK: 4)
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages(splits, total: 4), links: try ShardBenchTestRig.ring(stages: 3),
            prompts: prompts, tokens: 6, prefillChunk: 2, parity: ShardBenchTestRig.teacherForced(reference))
        let head = try XCTUnwrap(try results[0].get().head)
        let parity = try XCTUnwrap(head.parity?.teacherForced)
        XCTAssertEqual(head.parity?.verdict, "pass")
        XCTAssertEqual(parity.steps, 12)
        XCTAssertEqual(parity.top1AgreementRate, 1)
        XCTAssertEqual(parity.maxAbsDeltaLogprob, 0)
        XCTAssertEqual(parity.meanTopKOverlap, 1)
        XCTAssertEqual(head.sequenceTokens, reference.sequenceTokens)
        XCTAssertEqual(head.attestation.verdict, "ok", "token-logit frames are in the digest chain")
    }

    func testTeacherForcedRunFeedsReferenceTokensNotItsOwnSamples() throws {
        // A reference that continues with tokens the chain would not pick: the head must
        // feed them anyway, so the parity reports what the chain does on that prefix.
        let splits = [0..<2, 2..<4]
        let base = try ShardBenchTestRig.referenceReport(splits: splits, total: 4, prompts: [prompts[0]], tokens: 4, topK: 4)
        let reference = ShardBenchReferenceReport(
            sequenceTokens: [[1, 2, 3, 4]], promptTokens: base.promptTokens, singleStreamTokensPerSecond: nil,
            ttft: base.ttft, prompts: base.prompts, stepLogits: base.stepLogits)
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        let results = ShardBenchTestRig.run(
            stages, links: try ShardBenchTestRig.ring(stages: 2, collapsed: true),
            prompts: [prompts[0]], tokens: 4, parity: ShardBenchTestRig.teacherForced(reference))
        let head = try XCTUnwrap(try results[0].get().head)
        // Warmup decodes its own samples; the measured run's decode inputs are 1, 2, 3.
        XCTAssertEqual(Array(stages[0].tokensSeen.suffix(4)), [prompts[0], [1], [2], [3]])
        XCTAssertEqual(head.parity?.teacherForced?.steps, 4)
        XCTAssertEqual(head.parity?.verdict, "fail", "the base logits were for a different prefix after step 0")
        XCTAssertEqual(head.parity?.teacherForced?.hardFailures.first?.step, 1)
    }

    func testTeacherForcedShiftedLogprobsFailTheTolerance() throws {
        let splits = [0..<2, 2..<4]
        let reference = try ShardBenchTestRig.referenceReport(splits: splits, total: 4, prompts: prompts, tokens: 5, topK: 4)
        // A tail whose logprobs are all 0.3 nats off: top-1 agrees, tolerance fails.
        let shifted = ShardBenchTestRig.stages(splits, total: 4)
        shifted[1].logprobShift = 0.3
        let failing = ShardBenchTestRig.run(
            shifted, links: try ShardBenchTestRig.ring(stages: 2, collapsed: true),
            prompts: prompts, tokens: 5, parity: ShardBenchTestRig.teacherForced(reference))
        let parity = try XCTUnwrap(try failing[0].get().head?.parity?.teacherForced)
        XCTAssertEqual(parity.verdict, "fail")
        XCTAssertEqual(parity.top1AgreementRate, 1)
        XCTAssertTrue(parity.hardFailures.isEmpty)
        XCTAssertEqual(parity.p99AbsDeltaLogprob, 0.3, accuracy: 1e-6)
    }

    func testChainValidation() throws {
        func hello(_ role: ShardBenchRole, _ range: Range<Int>, total: Int = 4, model: String = "m") -> ShardBenchHello {
            ShardBenchHello(role: role, modelType: model, totalLayers: total, hiddenSize: 8,
                            layerStart: range.lowerBound, layerEnd: range.upperBound)
        }
        XCTAssertNoThrow(try ShardBenchChain.validateComplete([hello(.head, 0..<1), hello(.middle, 1..<2), hello(.tail, 2..<4)]))
        // Too short, missing tail, overlapping layers, different model, tail not at the end.
        XCTAssertThrowsError(try ShardBenchChain.validateComplete([hello(.head, 0..<4)]))
        XCTAssertThrowsError(try ShardBenchChain.validateComplete([hello(.head, 0..<2), hello(.middle, 2..<4)]))
        XCTAssertThrowsError(try ShardBenchChain.validateComplete([hello(.head, 0..<2), hello(.tail, 1..<4)]))
        XCTAssertThrowsError(try ShardBenchChain.validateComplete([hello(.head, 0..<2), hello(.tail, 2..<4, model: "x")]))
        XCTAssertThrowsError(try ShardBenchChain.validateComplete([hello(.head, 0..<2), hello(.tail, 2..<3)]))
        XCTAssertThrowsError(try ShardBenchChain.validateComplete([hello(.head, 0..<1), hello(.tail, 1..<2), hello(.tail, 2..<4)]))
        XCTAssertThrowsError(try ShardBenchChain.validate(prefix: [hello(.middle, 0..<1)], next: hello(.tail, 1..<4)))
    }
}
