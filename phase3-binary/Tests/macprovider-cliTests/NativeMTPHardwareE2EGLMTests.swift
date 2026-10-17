#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
@testable import macprovider_cli
import XCTest

/// The lab `native-mtp-hardware-e2e` harness on a GLM-5.3-Flash fixture: the
/// family comes from `target/config.json`, and the lab throughput phase is
/// an opt-in, bounded option.
final class NativeMTPHardwareE2EGLMTests: XCTestCase {
    func testGLMTargetSelectsTheEmbeddedGLM5NextFamily() throws {
        let family = try XCTUnwrap(NativeMTPHardwareE2EFamily.detect(configJSONData: GLM5NextPagedKVWiringTests.config()))
        XCTAssertEqual(family, .glm5Next)
        XCTAssertEqual(family.familyAdapter, "glm5_next_mtp_v1")
        XCTAssertTrue(family.embeddedMTP)
        XCTAssertEqual(family.mtpDirectoryName, "target")
        XCTAssertEqual(family.blockSizeTokens, 256)
        XCTAssertTrue(family.matchesPagedKind(.pagedMLA(kpool: 4)))
        XCTAssertFalse(family.matchesPagedKind(.pagedAttention))
    }

    /// JOURNEY step-05 places forced rejections at the fixture's real block
    /// boundaries; Qwen3.5 keeps exactly its 32-token, 256-row, crossing-only
    /// behaviour.
    func testJourneyBoundaryFollowsTheFamilyBlockAndKeepsQwen() {
        XCTAssertEqual(NativeMTPJourneyRunner.boundaryBlockTokens(family: .qwen35), 32)
        XCTAssertEqual(NativeMTPJourneyRunner.boundaryRowTokens(blockTokens: 32), 256)
        XCTAssertEqual(NativeMTPJourneyRunner.boundaryMode(family: .qwen35), .blockBoundary(blockTokens: 32, includeBlockStart: false))
        XCTAssertEqual(NativeMTPJourneyRunner.boundaryBlockTokens(family: .glm5Next), 256)
        XCTAssertEqual(NativeMTPJourneyRunner.boundaryRowTokens(blockTokens: 256), 1024)
        XCTAssertEqual(NativeMTPJourneyRunner.boundaryMode(family: .glm5Next), .blockBoundary(blockTokens: 256, includeBlockStart: true))
    }

    func testThroughputPhaseIsOptInAndBounded() throws {
        XCTAssertEqual(try NativeMTPHardwareE2ECommand.parse([]).throughputTokens, 0)
        XCTAssertEqual(
            try NativeMTPHardwareE2ECommand.parse(["--throughput-tokens", "256", "--max-batch", "4"]).throughputTokens,
            256
        )
    }
}
#endif
