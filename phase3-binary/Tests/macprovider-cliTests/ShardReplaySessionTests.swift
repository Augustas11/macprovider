import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084 slice 5: a tail lost mid-decode is replaced by a spare rebuilt from
/// the head's replay buffer; the head delivers every token exactly once and the
/// tokens match an uninterrupted run.
final class ShardReplaySessionTests: XCTestCase {
    private let prompts = [[5, 9, 2, 33, 71], [8, 1, 64]]
    private let splits = [0..<2, 2..<4]

    /// A spare tail at `epoch + 1` accepting on a loopback listener; returns its
    /// endpoint and a closure that waits for its result.
    private func startSpare() throws -> (ShardBenchEndpoint, () -> Result<ShardBenchSessionReport, Error>) {
        let listener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let spareEpoch = ShardBenchTestRig.epoch + 1
        let box = ShardBenchResultBox(count: 1)
        let done = DispatchSemaphore(value: 0)
        Thread {
            let result = Result<ShardBenchSessionReport, Error> {
                let link = try listener.accept(timeout: 10, configuration: ShardBenchTestRig.configuration(epoch: spareEpoch))
                let options = ShardBenchTestRig.options(role: .tail, prompts: self.prompts, tokens: 6, epoch: spareEpoch)
                return try ShardBenchSession(options: options, stage: FakeShardStage(layers: 2..<4, totalLayers: 4))
                    .run(links: ShardBenchLinks(upstream: link, downstream: link))
            }
            box.set(0, result)
            done.signal()
        }.start()
        return (ShardBenchEndpoint(host: "127.0.0.1", port: listener.port), {
            _ = done.wait(timeout: .now() + 20)
            return box.all[0]
        })
    }

    func testTailLostMidDecodeIsReplacedBySpareAndParityHolds() throws {
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        // Tail calls 1-4 serve the warmup, 5-6 the two prefills, 7-8 the first decode
        // step of each; call 9 is mid-decode.
        stages[1].onCall = { call in if call == 9 { links[1].upstream.close() } }
        let (spare, spareResult) = try startSpare()
        let results = ShardBenchTestRig.run(stages, links: links, prompts: prompts, tokens: 6, spare: spare)

        let head = try XCTUnwrap(try results[0].get().head)
        XCTAssertEqual(head.sequenceTokens, try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 6))
        XCTAssertEqual(head.replays.count, 1)
        let replay = try XCTUnwrap(head.replays.first)
        XCTAssertEqual(replay.groupEpoch, ShardBenchTestRig.epoch + 1)
        XCTAssertEqual(replay.requests, [2, 3])
        XCTAssertEqual(replay.deliveredTokens, [2, 2], "two tokens of each request were delivered before the loss")
        XCTAssertGreaterThan(replay.replayedFrames, 2)
        // Both requests were in flight, so their chains verify end to end in the new epoch.
        XCTAssertEqual(head.attestation.verdict, "ok")
        XCTAssertEqual(head.attestation.requests.map { $0.receipts.map(\.groupEpoch) }, [[4, 4], [4, 4]])
        XCTAssertThrowsError(try results[1].get(), "the lost tail ends with its link closed")

        let spareReport = try XCTUnwrap(try spareResult().get().stage)
        XCTAssertEqual(spareReport.sequencesServed, 2)
    }

    func testWithoutASpareTheStreamEndsWithTheDeliveredCount() throws {
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        stages[1].onCall = { call in if call == 9 { links[1].upstream.close() } }
        let results = ShardBenchTestRig.run(stages, links: links, prompts: prompts, tokens: 6)
        XCTAssertThrowsError(try results[0].get()) { error in
            guard case ShardBenchError.streamTerminated(let delivered, _) = error else {
                return XCTFail("expected streamTerminated, got \(error)")
            }
            XCTAssertEqual(delivered.keys.sorted(), [2, 3])
            XCTAssertEqual(delivered, [2: 2, 3: 2])
            XCTAssertTrue(String(describing: error).contains("stream terminated after delivering 4 tokens (request 2: 2, request 3: 2)"), "\(error)")
        }
    }

    func testARequestThatOutgrewTheReplayBufferEndsTheStream() throws {
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        stages[1].onCall = { call in if call == 9 { links[1].upstream.close() } }
        let (spare, _) = try startSpare()
        // Prompt 0's prefill alone is 80 bytes of float32 activations.
        let results = ShardBenchTestRig.run(stages, links: links, prompts: prompts, tokens: 6, spare: spare, replayBufferBytes: 64)
        XCTAssertThrowsError(try results[0].get()) { error in
            XCTAssertTrue(String(describing: error).contains("outgrew the 64-byte replay buffer"), "\(error)")
        }
    }

    func testSpareNeedsATwoStageChain() throws {
        let results = ShardBenchTestRig.run(
            ShardBenchTestRig.stages([0..<1, 1..<3, 3..<4], total: 4), links: try ShardBenchTestRig.ring(stages: 3),
            prompts: prompts, tokens: 2, spare: ShardBenchEndpoint(host: "127.0.0.1", port: 9))
        XCTAssertThrowsError(try results[0].get()) { error in
            XCTAssertTrue(String(describing: error).contains("needs a two-stage chain"), "\(error)")
        }
    }
}
