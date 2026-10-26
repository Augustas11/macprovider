import CryptoKit
import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084: the head-side session engine over in-process links, with the
/// deterministic fake stages of the shard-bench tests on the far side.
final class ShardGroupEngineTests: XCTestCase {
    private let splits = [0..<2, 2..<4]

    /// A started engine on a two-stage collapsed ring, its tail stage and a closure
    /// that waits for the tail session's result.
    private struct Rig {
        let engine: ShardGroupEngine<FakeShardStage>
        let tail: FakeShardStage
        let links: [ShardBenchLinks]
        let tailResult: () -> Result<ShardBenchSessionReport, Error>
    }

    private func rig(
        maxInFlight: Int = 4,
        spare: ShardBenchEndpoint? = nil,
        tailOnCall: ((Int, [ShardBenchLinks]) -> Void)? = nil,
        tailSigner: ShardMemberSigner? = nil,
        tailDelay: TimeInterval = 0,
        replayDeadline: TimeInterval = 5
    ) throws -> Rig {
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        stages[1].computeDelay = tailDelay
        if let tailOnCall { stages[1].onCall = { tailOnCall($0, links) } }
        let box = ShardBenchResultBox(count: 1)
        let done = DispatchSemaphore(value: 0)
        var tailOptions = ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1)
        tailOptions.signer = tailSigner
        let session = ShardBenchSession(options: tailOptions, stage: stages[1])
        Thread {
            box.set(0, Result { try session.run(links: links[1]) })
            done.signal()
        }.start()
        var engineOptions = Self.options(maxInFlight: maxInFlight, spare: spare)
        engineOptions.replayDeadline = replayDeadline
        let engine = ShardGroupEngine(stage: stages[0], options: engineOptions)
        try engine.start(links: links[0])
        return Rig(engine: engine, tail: stages[1], links: links, tailResult: {
            _ = done.wait(timeout: .now() + 20)
            return box.all[0]
        })
    }

    static func options(
        maxInFlight: Int = 4,
        spare: ShardBenchEndpoint? = nil,
        epoch: UInt64 = ShardBenchTestRig.epoch
    ) -> ShardGroupEngineOptions {
        ShardGroupEngineOptions(
            link: ShardBenchTestRig.configuration(epoch: epoch), connectTimeout: 5, decodeHopDeadline: 2,
            prefillChunkDeadline: 3, replayDeadline: 5, maxInFlight: maxInFlight, prefillChunk: nil,
            expectedStages: 2, expectedMembers: nil, modelDigest: nil, spare: spare, spareMember: nil,
            replayBufferBytes: 1 << 20, logitTopK: nil,
            signer: ShardMemberSigner(memberDeviceID: "head-device", key: Curve25519.Signing.PrivateKey()))
    }

    /// Drain one stream: delivered tokens, then the summary or the error.
    private func collect(_ events: AsyncThrowingStream<ShardGenerationEvent, Error>) async -> ([Int], Result<ShardGenerationSummary, Error>) {
        var tokens = [Int]()
        do {
            for try await event in events {
                switch event {
                case .token(let token, _): tokens.append(token)
                case .finished(let summary): return (tokens, .success(summary))
                }
            }
            return (tokens, .failure(ShardGroupEngineError.unavailable("stream ended without a summary")))
        } catch {
            return (tokens, .failure(error))
        }
    }

    func testConcurrentStreamsMatchTheReferenceAndCarrySignedChains() async throws {
        let prompts = [[5, 9, 2, 33, 71], [8, 1, 64], [3, 3, 3, 3]]
        let rig = try rig(maxInFlight: 2)
        let reference = try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 7)
        var streams = [AsyncThrowingStream<ShardGenerationEvent, Error>]()
        for prompt in prompts {
            streams.append(try rig.engine.stream(ShardGenerationRequest(promptTokens: prompt, maxTokens: 7)).events)
        }
        for (index, stream) in streams.enumerated() {
            let (tokens, result) = await collect(stream)
            let summary = try result.get()
            XCTAssertEqual(tokens, reference[index], "streamed tokens of request \(index)")
            XCTAssertEqual(summary.tokens, reference[index])
            XCTAssertEqual(summary.reason, .length)
            XCTAssertEqual(summary.promptTokens, prompts[index].count)
            XCTAssertEqual(summary.attestation.verdict, "ok")
            XCTAssertEqual(summary.attestation.receipts.map(\.receipt.memberDeviceID), ["head-device", "stage-1"])
            XCTAssertTrue(summary.attestation.receipts.allSatisfy(\.signatureIsValid))
            XCTAssertEqual(summary.attestation.receipts.map(\.receipt.decodeSteps), [6, 6])
        }
        XCTAssertEqual(rig.tail.controlsSeen.count, 3, "every request opens with its sampling control")
        try rig.engine.shutdown()
        XCTAssertEqual(try rig.tailResult().get().stage?.sequencesServed, 3)
    }

    func testMembersRelayTheirLinkRoundTripsToTheHead() throws {
        // A three-stage ring: the head times its own two links; the middle-to-tail
        // link only the tail can time, and its pings carry that to the head.
        let links = try ShardBenchTestRig.ring(stages: 3)
        let stages = ShardBenchTestRig.stages([0..<1, 1..<3, 3..<4], total: 4)
        let group = DispatchGroup()
        for index in 1...2 {
            let session = ShardBenchSession(
                options: ShardBenchTestRig.options(role: index == 2 ? .tail : .middle, prompts: [], tokens: 1), stage: stages[index])
            let stageLinks = links[index]
            group.enter()
            Thread {
                _ = try? session.run(links: stageLinks)
                group.leave()
            }.start()
        }
        var options = Self.options()
        options.expectedStages = 3
        let engine = ShardGroupEngine(stage: stages[0], options: options)
        try engine.start(links: links[0])
        let deadline = Date().addingTimeInterval(5)
        var health = engine.status.links
        while Date() < deadline, health?.reported(from: 1, to: 2) == nil || (health?.upstream?.samples ?? 0) < 3 || (health?.downstream.samples ?? 0) < 3 {
            Thread.sleep(forTimeInterval: 0.05)
            health = engine.status.links
        }
        let measured = try XCTUnwrap(health)
        XCTAssertGreaterThanOrEqual(measured.downstream.samples, 3)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(measured.upstream).samples, 3)
        let relayed = try XCTUnwrap(measured.reported(from: 1, to: 2))
        XCTAssertGreaterThan(relayed.health.samples, 0)
        XCTAssertNotNil(measured.reported(from: 0, to: 1), "stage 1's own measurement of the head link travels too")
        let reports = ShardGroupWire.linkReports(
            chain: engine.chain, providerID: "head-device", health: measured,
            now: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9, staleAfter: 1)
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(reports[1].rttP99Microseconds, Int(relayed.health.rttP99Microseconds))
        XCTAssertEqual(reports[0].rttP99Microseconds, measured.downstream.p99Microseconds)
        XCTAssertTrue(reports.allSatisfy(\.fresh))
        XCTAssertTrue(reports.allSatisfy { $0.rttP99Microseconds > 0 && $0.rttP99Microseconds < 50_000 })
        try engine.shutdown()
        _ = group.wait(timeout: .now() + 5)
    }

    func testSamplingParametersTravelToTheLastStage() async throws {
        let rig = try rig()
        let control = ShardRequestControl(temperature: 0.7, topP: 0.9, seed: 51)
        let (_, result) = await collect(try rig.engine.stream(
            ShardGenerationRequest(promptTokens: [4, 2], maxTokens: 2, control: control)).events)
        XCTAssertEqual(try result.get().tokens.count, 2)
        var expected = control
        expected.requestID = "1"
        XCTAssertEqual(rig.tail.controlsSeen, [expected], "the engine names its own request id when the caller gives none")
        try rig.engine.shutdown()
    }

    func testCancelMidStreamEndsTheRequestWithItsReceiptsAndKeepsTheEngine() async throws {
        // A 20 ms tail step, so the consumer's cancel races at most a step or two.
        let rig = try rig(tailDelay: 0.02)
        let (id, events) = try rig.engine.stream(ShardGenerationRequest(promptTokens: [7, 7, 1], maxTokens: 500))
        var delivered = 0
        var summary: ShardGenerationSummary?
        for try await event in events {
            switch event {
            case .token:
                delivered += 1
                if delivered == 3 { rig.engine.cancel(id) }
            case .finished(let finished):
                summary = finished
            }
        }
        let finished = try XCTUnwrap(summary)
        XCTAssertEqual(finished.reason, .cancelled)
        XCTAssertEqual(finished.tokens.count, delivered)
        XCTAssertGreaterThanOrEqual(delivered, 3)
        XCTAssertLessThan(delivered, 10, "the cancel lands within a step or two")
        XCTAssertEqual(finished.attestation.verdict, "ok", "members still answer the abort with sub-receipts")

        let (tokens, after) = await collect(try rig.engine.stream(ShardGenerationRequest(promptTokens: [8, 1, 64], maxTokens: 4)).events)
        XCTAssertEqual(tokens, try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: [[8, 1, 64]], tokens: 4)[0])
        XCTAssertEqual(try after.get().reason, .length)
        try rig.engine.shutdown()
    }

    func testAQueuedRequestCancelsWithoutTouchingTheChain() throws {
        let firstTailForward = DispatchSemaphore(value: 0)
        let releaseFirstTailForward = DispatchSemaphore(value: 0)
        let rig = try rig(maxInFlight: 1, tailOnCall: { call, _ in
            guard call == 1 else { return }
            firstTailForward.signal()
            _ = releaseFirstTailForward.wait(timeout: .now() + 5)
        })
        let collector = ShardGenerationCollector(count: 2)
        let ids = try rig.engine.submit(
            [ShardGenerationRequest(promptTokens: [1, 2], maxTokens: 3), ShardGenerationRequest(promptTokens: [3, 4], maxTokens: 3)],
            sink: collector.receive)
        XCTAssertEqual(firstTailForward.wait(timeout: .now() + 5), .success)
        rig.engine.cancel(ids[1])
        releaseFirstTailForward.signal()
        let (summaries, errors) = collector.wait()
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(summaries[ids[0]]?.reason, .length)
        XCTAssertEqual(summaries[ids[1]]?.reason, .cancelled)
        XCTAssertEqual(summaries[ids[1]]?.tokens, [])
        try rig.engine.shutdown()
        XCTAssertEqual(rig.tail.controlsSeen.count, 1, "the cancelled request never reached the tail")
    }

    func testStopTokenEndsTheRequestWithoutDeliveringIt() async throws {
        let prompt = [5, 9, 2, 33, 71]
        let reference = try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: [prompt], tokens: 12)[0]
        // The first reference token not seen before it: stopping on it ends at that index.
        let stopIndex = try XCTUnwrap((1..<reference.count).first { !reference[..<$0].contains(reference[$0]) })
        let rig = try rig()
        let (tokens, result) = await collect(try rig.engine.stream(ShardGenerationRequest(
            promptTokens: prompt, maxTokens: 12, stopTokenIDs: [reference[stopIndex]])).events)
        let summary = try result.get()
        XCTAssertEqual(summary.reason, .stop)
        XCTAssertEqual(summary.stopToken, reference[stopIndex])
        XCTAssertEqual(tokens, Array(reference[..<stopIndex]))
        XCTAssertEqual(summary.tokens, tokens)
        XCTAssertEqual(summary.attestation.verdict, "ok")
        try rig.engine.shutdown()
    }

    func testStageLossIsTypedWithEachRequestsDeliveredCount() throws {
        // Both prefills complete before tail call 5, where the tail's link goes down
        // mid-decode. How decode steps batch or interleave before that is timing, so
        // each request's delivered count must equal exactly the tokens its sink saw.
        let rig = try rig(tailOnCall: { call, links in if call == 5 { links[1].upstream.close() } })
        let collector = ShardGenerationCollector(count: 2)
        let seen = DeliveredTokenCounts()
        let ids = try rig.engine.submit(
            [ShardGenerationRequest(promptTokens: [5, 9, 2], maxTokens: 20), ShardGenerationRequest(promptTokens: [8, 1], maxTokens: 20)],
            sink: { id, result in
                if case .success(.token) = result { seen.add(id) }
                collector.receive(id, result)
            })
        let (summaries, errors) = collector.wait()
        XCTAssertTrue(summaries.isEmpty)
        for id in ids {
            guard case ShardGroupEngineError.streamTerminated(let delivered, _)? = errors[id] else {
                return XCTFail("expected streamTerminated, got \(String(describing: errors[id]))")
            }
            XCTAssertEqual(delivered, seen.count(id), "request \(id): delivered count equals the tokens streamed")
            XCTAssertGreaterThanOrEqual(delivered, 1, "request \(id): its prefill token was streamed before the loss")
        }
        XCTAssertTrue(rig.engine.waitUntilStopped(timeout: 5))
        XCTAssertFalse(rig.engine.status.running)
        XCTAssertThrowsError(try rig.engine.submit([ShardGenerationRequest(promptTokens: [1], maxTokens: 1)]) { _, _ in }) { error in
            guard case ShardGroupEngineError.unavailable = error else { return XCTFail("expected unavailable, got \(error)") }
        }
        XCTAssertThrowsError(try rig.tailResult().get())
    }

    func testStageLossBeforeTheFirstTokenIsRetryable() throws {
        // The tail dies on the first prefill it computes.
        let rig = try rig(tailOnCall: { call, links in if call == 1 { links[1].upstream.close() } })
        let collector = ShardGenerationCollector(count: 1)
        let ids = try rig.engine.submit([ShardGenerationRequest(promptTokens: [5, 9, 2], maxTokens: 4)], sink: collector.receive)
        let (_, errors) = collector.wait()
        guard case ShardGroupEngineError.failedBeforeFirstToken? = errors[ids[0]] else {
            return XCTFail("expected failedBeforeFirstToken, got \(String(describing: errors[ids[0]]))")
        }
    }

    /// R3-C02: the replay deadline covers the spare's KV catch-up, not only
    /// sending the replay. A spare that accepts the replay at once but rebuilds
    /// its KV slower than replay_deadline_ms ends the streams with an error
    /// instead of resuming late.
    func testSpareCatchUpBeyondTheReplayDeadlineTerminatesTheStream() async throws {
        let spareListener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let spareEpoch = ShardBenchTestRig.epoch + 1
        let spareStage = FakeShardStage(layers: 2..<4, totalLayers: 4)
        spareStage.computeDelay = 0.5
        Thread {
            _ = Result<ShardBenchSessionReport, Error> {
                let link = try spareListener.accept(timeout: 10, configuration: ShardBenchTestRig.configuration(epoch: spareEpoch))
                return try ShardBenchSession(
                    options: ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1, epoch: spareEpoch), stage: spareStage)
                    .run(links: ShardBenchLinks(upstream: link, downstream: link))
            }
        }.start()
        let rig = try rig(
            spare: ShardBenchEndpoint(host: "127.0.0.1", port: spareListener.port),
            tailOnCall: { call, links in if call == 6 { links[1].upstream.close() } },
            replayDeadline: 1.0)
        let standbyDeadline = Date().addingTimeInterval(5)
        while Date() < standbyDeadline, rig.engine.status.spare?.alive != true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let first = try rig.engine.stream(ShardGenerationRequest(promptTokens: [5, 9, 2, 33, 71], maxTokens: 8))
        let second = try rig.engine.stream(ShardGenerationRequest(promptTokens: [8, 1, 64], maxTokens: 8))
        let (_, result0) = await collect(first.events)
        let (_, result1) = await collect(second.events)
        XCTAssertThrowsError(try result0.get(), "catch-up past the replay deadline ends the stream")
        XCTAssertThrowsError(try result1.get())
    }

    func testLostTailIsReplacedBySpareWithoutReEmittingTokens() async throws {
        let spareListener = try ShardStageListener(host: "127.0.0.1", port: 0)
        let spareEpoch = ShardBenchTestRig.epoch + 1
        let spareDone = DispatchSemaphore(value: 0)
        let spareBox = ShardBenchResultBox(count: 1)
        let spareStage = FakeShardStage(layers: 2..<4, totalLayers: 4)
        Thread {
            let result = Result<ShardBenchSessionReport, Error> {
                let link = try spareListener.accept(timeout: 10, configuration: ShardBenchTestRig.configuration(epoch: spareEpoch))
                return try ShardBenchSession(
                    options: ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1, epoch: spareEpoch), stage: spareStage)
                    .run(links: ShardBenchLinks(upstream: link, downstream: link))
            }
            spareBox.set(0, result)
            spareDone.signal()
        }.start()
        let rig = try rig(
            spare: ShardBenchEndpoint(host: "127.0.0.1", port: spareListener.port),
            tailOnCall: { call, links in if call == 6 { links[1].upstream.close() } })
        // SPEC-051-R007: the head holds a standby link to the spare and measures it.
        let standbyDeadline = Date().addingTimeInterval(5)
        while Date() < standbyDeadline, rig.engine.status.spare?.alive != true || (rig.engine.status.spare?.roundTrip?.samples ?? 0) < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let standby = try XCTUnwrap(rig.engine.status.spare)
        XCTAssertTrue(standby.alive)
        XCTAssertEqual(standby.memberDeviceID, "stage-1")
        XCTAssertEqual(standby.interfaceType, nil, "the lab spare reports no interface")
        XCTAssertGreaterThanOrEqual(standby.roundTrip?.samples ?? 0, 2)
        let prompts = [[5, 9, 2, 33, 71], [8, 1, 64]]
        let reference = try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 8)
        let first = try rig.engine.stream(ShardGenerationRequest(promptTokens: prompts[0], maxTokens: 8))
        let second = try rig.engine.stream(ShardGenerationRequest(promptTokens: prompts[1], maxTokens: 8))
        let (tokens0, result0) = await collect(first.events)
        let (tokens1, result1) = await collect(second.events)
        XCTAssertEqual(tokens0, reference[0], "each token exactly once, matching an uninterrupted run")
        XCTAssertEqual(tokens1, reference[1])
        let summary0 = try result0.get()
        XCTAssertEqual(summary0.attestation.verdict, "ok")
        XCTAssertEqual(summary0.attestation.groupEpoch, spareEpoch)
        XCTAssertEqual(summary0.attestation.replays.count, 1)
        XCTAssertEqual(try result1.get().attestation.replays.first?.requests, [first.id, second.id])
        // The takeover ran on the standby link (the spare accepts one connection only)
        // and the attestation is one chain under the new epoch, from step 0.
        XCTAssertEqual(summary0.attestation.receipts.map(\.receipt.groupEpoch), [spareEpoch, spareEpoch])
        XCTAssertEqual(summary0.attestation.receipts.map(\.receipt.stageIndex), [0, 1])
        XCTAssertEqual(summary0.attestation.receipts[0].receipt.outDigest, summary0.attestation.receipts[1].receipt.inDigest)
        XCTAssertEqual(summary0.attestation.receipts[1].receipt.outDigest, summary0.attestation.receipts[0].receipt.inDigest)
        // SPEC-051-R019 takeover attestation: the new epoch's chain from step 0, and
        // the epoch it took over from with the reason.
        let tuple = try JSONSerialization.data(withJSONObject: [
            "request_id": String(first.id), "attempt_n": 1, "provider_id": "head-device", "receipt_version": "4",
        ], options: [.sortedKeys])
        let attestation = try ShardGroupWire.attestation(
            receipt: tuple.base64EncodedString() + "." + Data(repeating: 1, count: 64).base64EncodedString(),
            evidence: ShardGroupCompletionEvidence(attestation: summary0.attestation, tokenSteps: summary0.tokenSteps),
            key: rig.engine.options.signer.key)
        let takeover = try XCTUnwrap(attestation["takeover"] as? [String: Any])
        XCTAssertEqual(takeover["from_group_epoch"] as? Int, Int(ShardBenchTestRig.epoch))
        XCTAssertTrue(["peer_closed", "peer_error", "link_error", "peer_dead"].contains(takeover["reason"] as? String ?? ""), "\(takeover)")
        let segments = try XCTUnwrap(attestation["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0]["group_epoch"] as? Int, Int(spareEpoch))
        XCTAssertEqual(segments[0]["step_start"] as? Int, 0)
        XCTAssertNil(rig.engine.status.spare, "a spare that took over is no longer a spare")
        XCTAssertEqual(rig.engine.status.groupEpoch, spareEpoch)
        try rig.engine.shutdown()
        _ = spareDone.wait(timeout: .now() + 10)
        XCTAssertEqual(try spareBox.all[0].get().stage?.sequencesServed, 2)
        XCTAssertEqual(spareStage.controlsSeen.count, 2, "the replay re-opens each request's sampling")
    }

    func testRequestsAreValidated() throws {
        let rig = try rig()
        XCTAssertThrowsError(try rig.engine.submit([ShardGenerationRequest(promptTokens: [], maxTokens: 2)]) { _, _ in })
        XCTAssertThrowsError(try rig.engine.submit([ShardGenerationRequest(promptTokens: [1], maxTokens: 0)]) { _, _ in })
        try rig.engine.shutdown()
    }

    func testChainMustMatchTheGroupsMembersAndDigest() throws {
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        var tailOptions = ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1)
        tailOptions.modelDigest = "aa"
        let session = ShardBenchSession(options: tailOptions, stage: stages[1])
        Thread { _ = try? session.run(links: links[1]) }.start()
        var options = Self.options()
        options.expectedMembers = [ShardGroupExpectedMember(memberDeviceID: "stage-1", layers: 2..<4)]
        options.modelDigest = "bb"
        XCTAssertThrowsError(try ShardGroupEngine(stage: stages[0], options: options).start(links: links[0])) { error in
            XCTAssertTrue(String(describing: error).contains("stage 1 model digest aa differs from the head's bb"), "\(error)")
        }

        let links2 = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        let session2 = ShardBenchSession(options: ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1), stage: stages[1])
        Thread { _ = try? session2.run(links: links2[1]) }.start()
        var named = Self.options()
        named.expectedMembers = [ShardGroupExpectedMember(memberDeviceID: "mac-b", layers: 2..<4)]
        XCTAssertThrowsError(try ShardGroupEngine(stage: stages[0], options: named).start(links: links2[0])) { error in
            XCTAssertTrue(String(describing: error).contains("the group names mac-b 2:4"), "\(error)")
        }
    }

    func testMemberSignsWithItsDeviceKey() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let rig = try rig(tailSigner: ShardMemberSigner(memberDeviceID: "mac-b", key: key))
        let (_, result) = await collect(try rig.engine.stream(
            ShardGenerationRequest(promptTokens: [2, 4], maxTokens: 2, receiptRequestID: "req_7f3a")).events)
        let receipts = try result.get().attestation.receipts
        XCTAssertEqual(receipts.map(\.receipt.memberDeviceID), ["head-device", "mac-b"])
        XCTAssertEqual(receipts.map(\.receipt.requestID), ["req_7f3a", "req_7f3a"], "members name the coordinator request id")
        XCTAssertEqual(receipts[1].publicKey, key.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertTrue(receipts[1].signatureIsValid)
        try rig.engine.shutdown()
    }
}

private final class DeliveredTokenCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [UInt64: Int]()

    func add(_ id: UInt64) {
        lock.lock()
        counts[id, default: 0] += 1
        lock.unlock()
    }

    func count(_ id: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[id, default: 0]
    }
}
