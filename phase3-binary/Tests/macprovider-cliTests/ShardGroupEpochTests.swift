import CryptoKit
import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084 SPEC-051-R023: the head never builds a chain at an epoch the
/// coordinator already accepted, and members follow it to a later epoch.
final class ShardGroupEpochTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shard-epoch-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheEpochStoreKeepsTheHighestAcceptedEpochOwnerOnly() throws {
        let store = ShardGroupEpochStore.defaultStore(groupProviderID: "prov-head", home: root)
        XCTAssertNil(try store.lastRegisteredEpoch())
        XCTAssertEqual(try store.buildEpoch(configured: 3), 3, "nothing accepted yet: the configured epoch")
        try store.record(4)
        XCTAssertEqual(try store.lastRegisteredEpoch(), 4)
        XCTAssertEqual(try store.buildEpoch(configured: 3), 5)
        XCTAssertEqual(try store.buildEpoch(configured: 9), 9, "an owner who raised the configured epoch wins")
        try store.record(2)
        XCTAssertEqual(try store.lastRegisteredEpoch(), 4, "never lowered")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["prov-head.json"], "the temporary file was renamed into place")
        let other = ShardGroupEpochStore(url: store.url, groupProviderID: "someone-else")
        XCTAssertThrowsError(try other.lastRegisteredEpoch(), "another group's state is refused")
    }

    private func memberConfig(epoch: UInt64) -> ShardMemberConfig {
        ShardMemberConfig(
            groupProviderID: "head-device", groupEpoch: epoch, stageIndex: 1, layerStart: 2, layerEnd: 4, listen: "127.0.0.1:0", maxSequences: 8,
            supervision: ShardSupervisionConfig(
                heartbeatIntervalMilliseconds: 50, heartbeatMissLimit: 4, decodeHopDeadlineMilliseconds: 2000,
                prefillChunkDeadlineMilliseconds: 3000, replayDeadlineMilliseconds: 5000))
    }

    private func headLinks(port: UInt16, epoch: UInt64, signer: ShardMemberSigner) throws -> ShardBenchLinks {
        try ShardBenchLinks.open(
            listen: nil, connect: ShardBenchEndpoint(host: "127.0.0.1", port: port), connectTimeout: 5,
            configuration: ShardBenchTestRig.configuration(epoch: epoch), session: "test", signer: signer)
    }

    func testAMemberFollowsTheHeadToALaterEpochAndRefusesAnEarlierOne() async throws {
        let server = ShardMemberStageServer(
            stage: FakeShardStage(layers: 2..<4, totalLayers: 4), config: memberConfig(epoch: 3),
            signer: ShardMemberSigner(memberDeviceID: "mac-b", key: Curve25519.Signing.PrivateKey()), modelDigest: nil, modelLabel: "fake")
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        // A head rebuilt at epoch 5 after a takeover at 4: the member joins it.
        var options = ShardGroupEngineTests.options(epoch: 5)
        let engine = ShardGroupEngine(stage: FakeShardStage(layers: 0..<2, totalLayers: 4), options: options)
        try engine.start(links: try headLinks(port: port, epoch: 5, signer: options.signer))
        var status = server.status
        for _ in 0..<100 where status.groupEpoch == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            status = server.status
        }
        XCTAssertEqual(status.groupEpoch, 5)
        let hello = try XCTUnwrap(try ShardGroupWire.memberHello(
            config: memberConfig(epoch: 3), status: status, memberDeviceID: "mac-b", artifactHashAlgorithm: "a", artifactHash: "b",
            weightsVerified: true, stageFits: true))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: hello) as? [String: Any])?["group_epoch"] as? Int, 5,
                       "the member's hello names the head's epoch")
        let collector = ShardGenerationCollector(count: 1)
        let ids = try engine.submit([ShardGenerationRequest(promptTokens: [4, 5, 6], maxTokens: 3)], sink: collector.receive)
        let summary = try XCTUnwrap(collector.wait().summaries[ids[0]])
        XCTAssertEqual(summary.attestation.receipts.map(\.receipt.groupEpoch), [5, 5], "sub-receipts name the adopted epoch")
        try engine.shutdown()

        // A head at epoch 2, below the member's configured 3, is refused.
        options = ShardGroupEngineTests.options(epoch: 2)
        let stale = ShardGroupEngine(stage: FakeShardStage(layers: 0..<2, totalLayers: 4), options: options)
        XCTAssertThrowsError(try stale.start(links: try headLinks(port: port, epoch: 2, signer: options.signer)))
        status = server.status
        for _ in 0..<100 where !(status.lastError ?? "").contains("epochMismatch") {
            try await Task.sleep(nanoseconds: 20_000_000)
            status = server.status
        }
        XCTAssertTrue((status.lastError ?? "").contains("epochMismatch"), "\(status.lastError ?? "nil")")
        XCTAssertTrue(status.listening, "a refused head leaves the member listening")
    }
}
