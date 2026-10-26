#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import CryptoKit
import XCTest
@testable import macprovider_cli

final class NativeMTPHardwareE2EDeepseekTests: XCTestCase {
    func testDeepseekUsesEmbeddedThreeStageDSparkAndPoolBackend() throws {
        let config = try JSONSerialization.data(withJSONObject: [
            "model_type": "deepseek_v4", "num_hidden_layers": 43,
            "compress_ratios": [0, 0] + Array(repeating: [4, 128], count: 20).flatMap { $0 } + [4, 0, 0, 0],
            "sliding_window": 128,
        ])
        let family = try XCTUnwrap(NativeMTPHardwareE2EFamily.detect(configJSONData: config))
        XCTAssertEqual(family, .deepseekV4)
        XCTAssertEqual(family.familyAdapter, "deepseek_v4_dspark_v1")
        XCTAssertEqual(family.mtpDirectoryName, "target")
        XCTAssertEqual(family.predictionLayerCount, 3)
        XCTAssertEqual(family.maximumProposalDepth, 5)
        XCTAssertEqual(family.stateClass, "stageable_rewindable")
        XCTAssertEqual(family.quantizationLabel, "mlx_mxfp4_mxfp8")
        XCTAssertTrue(family.matchesPagedKind(.deepseekV4Pool(ratio: 4, windowTokens: 128)))
        XCTAssertTrue(family.matchesPagedKind(.deepseekV4Pool(ratio: 128, windowTokens: 128)))
        XCTAssertFalse(family.matchesPagedKind(.pagedAttention))
        XCTAssertFalse(family.admitsSampledRows)
    }

    func testDSparkDepthIsExplicitAndDefaultStaysOne() throws {
        XCTAssertEqual(try NativeMTPHardwareE2ECommand.parse([]).proposalDepth, 1)
        for depth in [1, 2, 3, 5] {
            XCTAssertEqual(try NativeMTPHardwareE2ECommand.parse([
                "--proposal-depth", String(depth),
            ]).proposalDepth, depth)
        }
        XCTAssertEqual(NativeMTPHardwareE2EFamily.glm5Next.maximumProposalDepth, 1)
        XCTAssertEqual(NativeMTPHardwareE2EFamily.qwen35.maximumProposalDepth, 1)
    }

    func testDSparkReservationIncludesEveryDepthAndGrowsWithContext() {
        let short = NativeMTPHardwareE2EFamily.deepseekV4.completeWindowBytesByDepth(
            maxContextTokens: 1024, maxDepth: 5)
        let long = NativeMTPHardwareE2EFamily.deepseekV4.completeWindowBytesByDepth(
            maxContextTokens: 32768, maxDepth: 5)
        XCTAssertEqual(short.count, 6)
        XCTAssertEqual(long.count, 6)
        for index in short.indices {
            XCTAssertGreaterThan(short[index], 0)
            XCTAssertGreaterThan(long[index], short[index])
            if index > 0 { XCTAssertGreaterThan(short[index], short[index - 1]) }
        }
        XCTAssertEqual(NativeMTPHardwareE2EFamily.qwen35.completeWindowBytesByDepth(
            maxContextTokens: 32768), [1_048_576, 2_097_152])
    }

    func testVariableVerificationRecordsActualDepthAndAcceptanceDenominators() {
        let recorder = NativeMTPDSparkRoundRecorder()
        recorder.record(requestID: "row", proposed: 3, accepted: 2)
        recorder.record(requestID: "row", proposed: 1, accepted: 0)
        recorder.record(requestID: "other", proposed: 5, accepted: 5)
        let metrics = recorder.metrics(requestIDs: ["row"], maximumDepth: 5)
        XCTAssertEqual(metrics["mtp_drafted_by_position"] as? [Int], [2, 1, 1, 0, 0])
        XCTAssertEqual(metrics["mtp_accepted_by_position"] as? [Int], [1, 1, 0, 0, 0])
        XCTAssertEqual(metrics["mtp_proposal_depth_histogram"] as? [Int], [0, 1, 0, 1, 0, 0])
        XCTAssertEqual(metrics["mtp_accepted_prefix_histogram"] as? [Int], [1, 0, 1, 0, 0, 0])
        XCTAssertEqual(metrics["mtp_resolved_rounds"] as? Int, 2)
    }

    func testFrozenCorpusChecksIdentityAndKeepsTheNaturalRequestMapping() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/lab/dsv4/dsv4-dspark-requests.json")
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let corpus = try NativeMTPFrozenDSparkCorpus.load(from: url, expectedSHA256: digest)
        XCTAssertEqual(corpus.requests.count, 12)
        for stratum in ["prose", "reasoning", "code"] {
            XCTAssertEqual(corpus.requests.filter { $0.stratum == stratum }.count, 4)
        }
        for item in corpus.requests {
            XCTAssertFalse(item.tokenIDs.isEmpty)
            XCTAssertNoThrow(try item.request(modelID: "deepseek/deepseek-v4-flash", maxTokens: 256))
        }
        XCTAssertThrowsError(try NativeMTPFrozenDSparkCorpus.load(
            from: url, expectedSHA256: String(repeating: "0", count: 64)))
    }

    func testLongCorpusRefusesWrongLengthsBeforeAnyModelLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: ["8192": [1, 2], "32768": [1, 2]])
            .write(to: url)
        XCTAssertThrowsError(try NativeMTPFrozenDSparkCorpus.loadLongPrompts(from: url))
        try JSONSerialization.data(withJSONObject: [
            "8192": Array(repeating: 1, count: 8192),
            "32768": Array(repeating: 2, count: 32768),
        ]).write(to: url)
        let prompts = try NativeMTPFrozenDSparkCorpus.loadLongPrompts(from: url)
        XCTAssertEqual(prompts[8192]?.count, 8192)
        XCTAssertEqual(prompts[32768]?.count, 32768)
    }

    func testDSparkFrozenMethodologyMustMatchTheFixtureFamily() throws {
        let policyURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/research/spec048-r015/glm53-flash-r015-v2/policy.json")
        var policy = try NativeMTPBenchPolicy.load(from: policyURL)
        policy.quantization = "mlx_mxfp4_mxfp8"
        policy.proposalDepth = 5
        XCTAssertNoThrow(try policy.validateFamily(.deepseekV4))
        XCTAssertThrowsError(try policy.validateFamily(.qwen35))
        XCTAssertThrowsError(try policy.validateFamily(.glm5Next))
        policy.quantization = "4bit"
        XCTAssertThrowsError(try policy.validateFamily(.deepseekV4))
    }
}
#endif
