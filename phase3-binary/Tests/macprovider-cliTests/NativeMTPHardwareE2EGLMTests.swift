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
        // The GLM drafter is greedy only: the lab tuple signs the greedy
        // profile, and Qwen3.5's lab tuple keeps the sampled one.
        XCTAssertEqual(family.requestFeatureProfile, "native_mtp_greedy_text_v1")
        XCTAssertFalse(family.admitsSampledRows)
        XCTAssertEqual(NativeMTPHardwareE2EFamily.qwen35.requestFeatureProfile, "native_mtp_sampled_text_v1")
        XCTAssertTrue(NativeMTPHardwareE2EFamily.qwen35.admitsSampledRows)
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

    /// Window A2: without the serve path's resident-weights ticket and MLX
    /// command-buffer budget the harness decoded GLM-5.3-Flash at ~2.2 s per
    /// step. Both harnesses take that setup from the fixture family; Qwen3.5
    /// keeps none of it, as serve does.
    func testHarnessUsesTheServeProcessSetupOfTheFamily() {
        XCTAssertEqual(NativeMTPHardwareE2EFamily.glm5Next.commandBufferBudgetMB, 65536)
        XCTAssertTrue(NativeMTPHardwareE2EFamily.glm5Next.holdsResidentWeights)
        XCTAssertNil(NativeMTPHardwareE2EFamily.qwen35.commandBufferBudgetMB)
        XCTAssertFalse(NativeMTPHardwareE2EFamily.qwen35.holdsResidentWeights)
        XCTAssertEqual(
            ModelRuntime.commandBufferBudgetMB(modelFamily: NativeMTPHardwareE2EFamily.glm5Next.modelFamily, configured: nil),
            65536
        )
        XCTAssertNotNil(ModelRuntime.residentWeightsTicket(
            modelFamily: NativeMTPHardwareE2EFamily.glm5Next.modelFamily,
            recommendedWorkingSetBytes: 239 * 1_073_741_824
        ))
        XCTAssertNil(ModelRuntime.residentWeightsTicket(
            modelFamily: NativeMTPHardwareE2EFamily.qwen35.modelFamily,
            recommendedWorkingSetBytes: 239 * 1_073_741_824
        ))
    }

    /// SPEC-048 R012 round reservation for glm5_next at the 4-slot design
    /// point: 4 rows x 2 verify columns (depth 1) at 64k context. Each row
    /// stages its 12 sparse latents (1,088 bytes per token) and two KDA state
    /// sets; the scheduler admits the four rounds only when available memory
    /// covers them above the 10% physical floor, never below it.
    func testGLMRoundReservationAtFourRowsTwoColumns64k() {
        let window = NativeMTPHardwareE2EFamily.glm5Next.completeWindowBytesByDepth(maxContextTokens: 65_536)
        XCTAssertEqual(window, [1_003_257_856, 1_150_877_696])
        XCTAssertEqual(window[1] - window[0], 147_619_840, "one KDA state set: 34 x 4,341,760")
        let reserved = 4 * window[1]
        XCTAssertEqual(reserved, 4_603_510_784)
        let physical = 274_877_906_944 // 256 GiB
        let floor = physical / 10
        func admits(_ available: Int) -> Bool {
            ContinuousBatchScheduler.nativeMTPSystemMemoryHeadroomAdmits(
                reservedAfter: reserved,
                sample: NativeMTPRoundSystemMemorySample(availableBytes: available, physicalBytes: physical)
            )
        }
        XCTAssertTrue(admits(reserved + floor))
        XCTAssertFalse(admits(reserved + floor - 1))
        XCTAssertFalse(ContinuousBatchScheduler.nativeMTPSystemMemoryHeadroomAdmits(reservedAfter: reserved, sample: nil))
        // Qwen3.5's harness keeps its placeholder window.
        XCTAssertEqual(NativeMTPHardwareE2EFamily.qwen35.completeWindowBytesByDepth(maxContextTokens: 65_536), [1_048_576, 2_097_152])
    }

    func testJourneySelfTestOptionsKeepTheRecordedChallengeByDefault() throws {
        let defaults = try NativeMTPJourneyE2ECommand.parse(["--root", "/fixture"])
        XCTAssertFalse(defaults.selfTestOnly)
        XCTAssertEqual(defaults.selfTestPrompts, [])
        XCTAssertEqual(defaults.selfTestChallengeID, "native-mtp-selftest-journey-0001")
        let glm = try NativeMTPJourneyE2ECommand.parse([
            "--root", "/fixture", "--selftest-only",
            "--selftest-prompt", "first", "--selftest-prompt", "second",
            "--selftest-challenge-id", "native-mtp-selftest-glm53-flash-0001",
        ])
        XCTAssertTrue(glm.selfTestOnly)
        XCTAssertEqual(glm.selfTestPrompts, ["first", "second"])
        XCTAssertEqual(glm.selfTestChallengeID, "native-mtp-selftest-glm53-flash-0001")
    }

    func testJourneyMixedCompositionExercisesCapacityAtBoundTwo() {
        let composition = NativeMTPJourneyRunner.mixedBatchComposition(
            qualifiedSlots: 4,
            maxNativeActiveRows: 2
        )

        XCTAssertEqual(composition.ineligibleRow, 3)
        XCTAssertEqual(composition.eligibleRows, 3)
        XCTAssertEqual(composition.nativeRows, 2)
        XCTAssertEqual(composition.capacityDowngrades, 1)
        XCTAssertFalse(composition.allEligibleRowsNative)
        XCTAssertNil(composition.allNativeCoverageRows)
        XCTAssertTrue(composition.loadGateExpected)
    }

    func testJourneyMixedCompositionKeepsAllEligibleRowsNativeAtBoundFour() {
        let composition = NativeMTPJourneyRunner.mixedBatchComposition(
            qualifiedSlots: 4,
            maxNativeActiveRows: 4
        )

        XCTAssertEqual(composition.ineligibleRow, 3)
        XCTAssertEqual(composition.eligibleRows, 3)
        XCTAssertEqual(composition.nativeRows, 3)
        XCTAssertEqual(composition.capacityDowngrades, 0)
        XCTAssertTrue(composition.allEligibleRowsNative)
        XCTAssertEqual(composition.allNativeCoverageRows, 4)
        XCTAssertFalse(composition.loadGateExpected)
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
