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

    func forward(tokens: [Int], cache: Cache) throws -> ShardBenchActivation {
        try count()
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

    func sample(activation: ShardBenchActivation, cache: Cache, temperature: Float) throws -> Int {
        try count()
        let input = Self.decode(activation)
        for (offset, value) in input.enumerated() where offset % hiddenSize == 0 { cache.history.append(value) }
        let mixed = cache.history.enumerated().reduce(0) { ($0 &* 31 &+ Int($1.element) &+ $1.offset) % 1_000_003 }
        return mixed % 97
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

    static func configuration(epoch: UInt64 = ShardBenchTestRig.epoch) -> ShardLinkConfiguration {
        ShardLinkConfiguration(groupEpoch: epoch, heartbeatInterval: 0.05, missedHeartbeatLimit: 4, armLivenessOnOpen: false)
    }

    /// A connected loopback pair: (accepted side, dialing side).
    static func pair(epoch: UInt64 = ShardBenchTestRig.epoch) throws -> (ShardStageLink, ShardStageLink) {
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let dialed = try ShardStageLink.connect(
            host: "127.0.0.1", port: listener.port, timeout: 5, configuration: configuration(epoch: epoch))
        let accepted = try listener.accept(timeout: 5, configuration: configuration(epoch: epoch))
        return (accepted, dialed)
    }

    /// Links for a ring of `stages` stages, indexed by stage. With two stages and
    /// `collapsed`, one link carries both directions.
    static func ring(stages: Int, collapsed: Bool = false) throws -> [ShardBenchLinks] {
        if stages == 2, collapsed {
            let (tail, head) = try pair()
            return [ShardBenchLinks(upstream: head, downstream: head), ShardBenchLinks(upstream: tail, downstream: tail)]
        }
        // forward[i] joins stage i (dialing) to stage i+1 (accepting); back joins the
        // tail (dialing) to the head (accepting).
        let forward = try (0..<(stages - 1)).map { _ in try pair() }
        let back = try pair()
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
        prefillChunkDeadline: TimeInterval = 3
    ) -> ShardBenchSessionOptions {
        ShardBenchSessionOptions(
            role: role, listen: nil, connect: nil, expectedStages: expectedStages, modelLabel: "fake",
            prompts: prompts, tokens: tokens, temperature: 0, seed: 0, link: configuration(),
            receiveTimeout: 5, connectTimeout: 5, probeCount: probeCount, maxSequences: 8, warmup: true,
            prefillChunk: prefillChunk, prefillChunkDeadline: prefillChunkDeadline)
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
                let token = try chain[chain.count - 1].sample(activation: activation, cache: caches[chain.count - 1], temperature: 0)
                generated.append(token)
                input = [token]
            }
            return generated
        }
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
        prefillChunkDeadline: TimeInterval = 3
    ) -> [Result<ShardBenchSessionReport, Error>] {
        let results = ShardBenchResultBox(count: stages.count)
        let group = DispatchGroup()
        for (index, stage) in stages.enumerated() {
            let role: ShardBenchRole = index == 0 ? .head : (index == stages.count - 1 ? .tail : .middle)
            let stageOptions = options(
                role: role, prompts: prompts, tokens: tokens, expectedStages: index == 0 ? expectedStages : nil,
                prefillChunk: prefillChunk, prefillChunkDeadline: prefillChunkDeadline)
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
        // The head reports the measured run (3 + 2 chunks); the stages also served the
        // warmup's 3 chunks of prompt 0.
        XCTAssertEqual(head.headPrefillChunkCompute.count, 5)
        XCTAssertEqual(try results[1].get().stage?.prefillCompute.count, 8)
        XCTAssertEqual(try results[2].get().stage?.prefillCompute.count, 8)
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
