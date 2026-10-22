import CryptoKit
import Darwin
import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084 freeze audit round 1: the head engine, member stage and member
/// runtime fixes, over in-process links and the deterministic fake stages.
final class ShardGroupAuditFixTests: XCTestCase {
    private let splits = [0..<2, 2..<4]

    /// The tail session of a two-stage collapsed ring on its own thread.
    private func startTail(
        _ links: [ShardBenchLinks], stage: FakeShardStage, configure: (inout ShardBenchSessionOptions) -> Void = { _ in }
    ) -> () -> Result<ShardBenchSessionReport, Error> {
        var options = ShardBenchTestRig.options(role: .tail, prompts: [], tokens: 1)
        configure(&options)
        let session = ShardBenchSession(options: options, stage: stage)
        let box = ShardBenchResultBox(count: 1)
        let done = DispatchSemaphore(value: 0)
        let tailLinks = links[1]
        Thread {
            box.set(0, Result { try session.run(links: tailLinks) })
            done.signal()
        }.start()
        return {
            _ = done.wait(timeout: .now() + 20)
            return box.all[0]
        }
    }

    // MARK: C01

    /// A failure while admitting one request of a batch ends every request of that
    /// batch with a typed error; none is left without a terminal event.
    func testFailedBatchAdmissionEndsEveryRequestOfTheBatch() throws {
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        let tail = startTail(links, stage: stages[1])
        // The head's first forward is the first request's prefill.
        stages[0].failOnCall = 1
        let engine = ShardGroupEngine(stage: stages[0], options: ShardGroupEngineTests.options(maxInFlight: 4))
        try engine.start(links: links[0])
        let collector = ShardGenerationCollector(count: 3)
        let requests = [[5, 9, 2], [8, 1], [3, 3, 3]].map { ShardGenerationRequest(promptTokens: $0, maxTokens: 4) }
        let ids = try engine.submit(requests) { collector.receive($0, $1) }
        let (summaries, errors) = collector.wait()
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertEqual(Set(errors.keys), Set(ids), "every request of the batch ends")
        for id in ids {
            switch errors[id] {
            case ShardGroupEngineError.failedBeforeFirstToken?, ShardGroupEngineError.unavailable?:
                break
            default:
                XCTFail("request \(id) ended with \(String(describing: errors[id]))")
            }
        }
        XCTAssertTrue(engine.waitUntilStopped(timeout: 5))
        _ = tail()
    }

    // MARK: C04

    /// SPEC-051-R017: decode rows of concurrent requests share forwards on every
    /// stage, and every request still gets exactly its own tokens.
    func testConcurrentRequestsShareDecodeForwardsOnEachStage() throws {
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        // Slow stages let several requests' rows wait for each of them.
        stages[0].computeDelay = 0.005
        stages[1].computeDelay = 0.01
        let tail = startTail(links, stage: stages[1])
        let engine = ShardGroupEngine(stage: stages[0], options: ShardGroupEngineTests.options(maxInFlight: 4))
        try engine.start(links: links[0])
        let prompts = [[5, 9, 2, 33], [8, 1, 64], [3, 3, 3], [7, 11]]
        let collector = ShardGenerationCollector(count: prompts.count)
        let ids = try engine.submit(prompts.map { ShardGenerationRequest(promptTokens: $0, maxTokens: 12) }) { collector.receive($0, $1) }
        let (summaries, errors) = collector.wait()
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let reference = try ShardBenchTestRig.reference(splits: splits, total: 4, prompts: prompts, tokens: 12)
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(summaries[id]?.tokens, reference[index], "request \(index)")
            XCTAssertEqual(summaries[id]?.attestation.verdict, "ok")
        }
        try engine.shutdown()
        let report = try tail().get()
        XCTAssertGreaterThan(report.stage?.decodeBatchRowsMax ?? 0, 1, "the tail sampled several requests' rows in one call")
        XCTAssertGreaterThan(stages[1].batchRows.max() ?? 0, 1)
        XCTAssertGreaterThan(stages[0].batchRows.max() ?? 0, 1, "the head stepped several requests in one forward")
    }

    // MARK: SEC-01

    /// SPEC-051-R011: the head refuses a stage that does not announce (and so did
    /// not authenticate with) the key its group configures for that member.
    func testHeadRefusesAStageWithoutItsConfiguredKey() throws {
        let tailKey = Curve25519.Signing.PrivateKey()
        for (configured, accepted) in [(Curve25519.Signing.PrivateKey().publicKey, false), (tailKey.publicKey, true)] {
            let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
            let stages = ShardBenchTestRig.stages(splits, total: 4)
            let tail = startTail(links, stage: stages[1]) {
                $0.signer = ShardMemberSigner(memberDeviceID: "tail-device", key: tailKey)
            }
            var options = ShardGroupEngineTests.options()
            options.expectedMembers = [ShardGroupExpectedMember(
                memberDeviceID: "tail-device", layers: 2..<4, publicKey: configured.rawRepresentation.base64EncodedString())]
            let engine = ShardGroupEngine(stage: stages[0], options: options)
            if accepted {
                try engine.start(links: links[0])
                try engine.shutdown()
                XCTAssertNoThrow(try tail().get())
            } else {
                XCTAssertThrowsError(try engine.start(links: links[0])) { error in
                    XCTAssertTrue("\(error)".contains("does not configure"), "\(error)")
                }
                _ = tail()
            }
        }
    }

    /// SPEC-051-R011: a member refuses a head whose key, identity or placement of
    /// it is not what its group config names, before it serves anything.
    func testMemberRefusesAnUnconfiguredUpstream() throws {
        let headKey = ShardGroupEngineTests.options().signer.publicKeyBase64
        let cases: [(String, (inout ShardBenchSessionOptions) -> Void)] = [
            ("does not configure", { $0.expectedUpstreamKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString() }),
            ("group config names", { $0.expectedHeadID = "another-head" }),
            ("group config at stage", { $0.expectedStageIndex = 2 }),
        ]
        for (message, configure) in cases {
            let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
            let stages = ShardBenchTestRig.stages(splits, total: 4)
            let tail = startTail(links, stage: stages[1], configure: configure)
            let engine = ShardGroupEngine(stage: stages[0], options: ShardGroupEngineTests.options())
            XCTAssertThrowsError(try engine.start(links: links[0]))
            guard case .failure(let error) = tail() else {
                XCTFail("\(message): the tail served")
                continue
            }
            XCTAssertTrue("\(error)".contains(message), "\(message): \(error)")
            XCTAssertFalse(headKey.isEmpty)
        }
    }

    // MARK: SEC-08 and C03 (member side)

    /// Plays the head's side of the handshake on a raw link.
    private func rawHead(_ link: ShardStageLink) throws {
        let hello = ShardBenchHello(
            role: .head, modelType: "fake", totalLayers: 4, hiddenSize: 4, layerStart: 0, layerEnd: 2, session: "raw",
            memberDeviceID: "head-device", memberPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        try ShardChainWire.sendHello(link, [hello], header: ShardStageFrameHeader(
            kind: .hello, groupEpoch: ShardBenchTestRig.epoch, destinationStage: 1, layerStart: 0, layerEnd: 2))
        _ = try ShardChainWire.awaitHello(link, timeout: 5, stageIndex: 0, layers: 0..<2)
    }

    private func control(_ id: UInt64) throws -> ShardStageFrame {
        ShardStageFrame(
            header: ShardStageFrameHeader(kind: .control, groupEpoch: ShardBenchTestRig.epoch, requestID: id, destinationStage: 1),
            payload: try JSONEncoder().encode(ShardRequestControl(temperature: 0)))
    }

    /// SEC-08: each request's control takes one of the stage's sequence slots, and
    /// a request opens once.
    func testRequestControlsAreBoundedBySequenceSlots() throws {
        for duplicate in [false, true] {
            let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
            let stages = ShardBenchTestRig.stages(splits, total: 4)
            let tail = startTail(links, stage: stages[1])
            try rawHead(links[0].upstream)
            let ids: [UInt64] = duplicate ? [1, 1] : Array(1...9)
            for id in ids { _ = try? links[0].upstream.send(try control(id)) }
            guard case .failure(let error) = tail() else {
                XCTFail("the tail kept serving")
                continue
            }
            if duplicate {
                XCTAssertTrue("\(error)".contains("a second control"), "\(error)")
            } else {
                guard case ShardBenchError.tooManySequences(8)? = error as? ShardBenchError else {
                    XCTFail("\(error)")
                    continue
                }
            }
        }
    }

    /// SPEC-051-R013: while a request is open, the member's next frame is due within
    /// its receive deadline even though the head keeps heartbeating.
    func testAnOpenRequestBoundsTheMembersWait() throws {
        let links = try ShardBenchTestRig.ring(stages: 2, collapsed: true)
        let stages = ShardBenchTestRig.stages(splits, total: 4)
        let started = Date()
        let tail = startTail(links, stage: stages[1])
        try rawHead(links[0].upstream)
        try links[0].upstream.send(try control(1))
        guard case .failure(let error) = tail() else { return XCTFail("the tail kept waiting") }
        XCTAssertEqual(error as? ShardLinkError, .receiveTimedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "bounded by the 5 s receive deadline, not the idle wait")
    }

    // MARK: C02

    /// SPEC-051-R015: a spare reports health for the epoch before its standby link's
    /// while it waits, and for the takeover epoch once it serves the stage.
    func testPromotedSpareReportsHealthForItsServingEpoch() throws {
        let config = ShardMemberConfig(
            groupProviderID: "head-device", groupEpoch: 4, role: .spare, stageIndex: 1, layerStart: 2, layerEnd: 4,
            listen: "127.0.0.1:0")
        var status = ShardMemberStatus(
            listening: true, chain: [], stageIndex: 1, upstreamPeer: "head-device", downstreamPeer: "head-device",
            upstreamInterface: "thunderbolt", downstreamInterface: "thunderbolt", sessionsServed: 0, lastError: nil, groupEpoch: 5)
        let report = ShardMemberHealthReport(healthy: true, reason: "", links: [.init(peer: "head-device", interfaceType: "thunderbolt", rttP99Microseconds: 300)])
        func epoch() throws -> Int {
            let data = try ShardGroupWire.memberHealth(config: config, status: status, memberDeviceID: "spare-device", report: report)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(object["group_epoch"] as? Int)
        }
        status.standby = true
        XCTAssertEqual(try epoch(), 4)
        status.standby = false
        XCTAssertEqual(try epoch(), 5)
    }

    // MARK: C07

    /// SPEC-051-R007: a link is classified by the interface owning its local address.
    func testLinkInterfaceIsTheOneOwningTheLocalAddress() throws {
        XCTAssertEqual(ShardLinkInterface.interfaceName(owning: "127.0.0.1"), "lo0")
        XCTAssertNil(ShardLinkInterface.interfaceName(owning: "203.0.113.77"))
        let (accepted, dialed) = try ShardBenchTestRig.pair()
        defer {
            accepted.close()
            dialed.close()
        }
        XCTAssertEqual(dialed.localHost, "127.0.0.1")
        XCTAssertEqual(ShardLinkInterface.classify(link: dialed), ShardLinkInterface.other, "loopback is never an admissible link")
    }

    // MARK: C08

    /// Every stage of a three-stage hmac-sha256 ring listens and dials; opening
    /// them all at once completes instead of each waiting on the next.
    func testProtectedRingOfThreeStagesOpens() throws {
        let base = UInt16.random(in: 40_000...60_000)
        let ports = [base, base + 1, base + 2]
        var configuration = ShardBenchTestRig.configuration(protection: .hmacSHA256)
        configuration.armLivenessOnOpen = false
        let box = ShardRingPeersBox()
        let group = DispatchGroup()
        for index in 0..<3 {
            group.enter()
            let listen = ShardBenchEndpoint(host: "127.0.0.1", port: ports[index])
            let connect = ShardBenchEndpoint(host: "127.0.0.1", port: ports[(index + 1) % 3])
            Thread {
                do {
                    let links = try ShardBenchLinks.open(
                        listen: listen, connect: connect, connectTimeout: 10, configuration: configuration, session: "ring",
                        signer: ShardMemberSigner(memberDeviceID: "stage-\(index)", key: Curve25519.Signing.PrivateKey()))
                    box.set(index, .success((links.upstream.peer?.memberDeviceID ?? "", links.downstream.peer?.memberDeviceID ?? "")))
                    links.close()
                } catch {
                    box.set(index, .failure(error))
                }
                group.leave()
            }.start()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success, "the ring did not open")
        for index in 0..<3 {
            let peers = try XCTUnwrap(box.get(index)).get()
            XCTAssertEqual(peers.0, "stage-\((index + 2) % 3)", "stage \(index) accepted its upstream")
            XCTAssertEqual(peers.1, "stage-\((index + 1) % 3)", "stage \(index) dialed its downstream")
        }
    }
}

private final class ShardRingPeersBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results = [Int: Result<(String, String), Error>]()

    func set(_ index: Int, _ result: Result<(String, String), Error>) {
        lock.lock()
        results[index] = result
        lock.unlock()
    }

    func get(_ index: Int) -> Result<(String, String), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return results[index]
    }
}
