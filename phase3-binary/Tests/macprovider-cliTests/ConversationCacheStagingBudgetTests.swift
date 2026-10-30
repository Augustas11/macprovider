import XCTest
@testable import macprovider_cli

/// Arithmetic only: no model, tensor allocation or memory-pressure mutation.
final class ConversationCacheStagingBudgetTests: XCTestCase {
    private let gib = 1 << 30

    private func budget(physical: Int, available: Int, configured: Bool = true) -> ConversationCacheMemoryBudget {
        let result = ConversationCacheMemoryBudget(probe: .init(identity: "staging-test") {
            .init(availableBytes: available, physicalBytes: physical)
        })
        result.configure(maxContextTokens: 200_000, slots: 4,
                         residentTokens: 26_214_400, verifyBytes: 0)
        if configured {
            result.observe(geometry: .init(fixedRowBytes: 150_616_064, bytesPerToken: 11_968))
        }
        return result
    }

    func testReportedEntryFitsBothDirectionsWithinMeasuredStudioReserve() {
        let free = (4_223_692 + 371_987 + 28_736) * 16_384
        let result = budget(physical: 256 * gib, available: free)
        let required = 2 * 1_445_244_936
        XCTAssertEqual(required, 2_890_489_872)
        XCTAssertEqual(result.stagingByteLimit(), 4 * gib)
        XCTAssertLessThan(required, result.stagingByteLimit())
        XCTAssertEqual(result.hotByteLimit(), 8 * gib)
    }

    func testStagingSplitsRemainingHeadroomAndProtectsHotServingAndSystemFloors() {
        let physical = 256 * gib
        let serving = 800_000 * 11_968 + 4 * 150_616_064
        let reserved = (physical + 9) / 10 + serving + serving / 20 + 8 * gib
        let required = 2_890_489_872
        for extra in [0, 1, 2 * required - 1, 2 * required, 2 * required + 1] {
            let result = budget(physical: physical, available: reserved + extra)
            XCTAssertEqual(result.stagingByteLimit(), extra / 2)
            XCTAssertEqual(required <= result.stagingByteLimit(), extra >= 2 * required)
        }
        XCTAssertEqual(budget(physical: physical, available: reserved - 1).stagingByteLimit(), 0)
    }

    func testSmallMemoryTiersCannotAdmitLongGLMStagingEvenWhenIdle() {
        for memory in [8, 16, 32] {
            let result = ConversationCacheMemoryBudget(probe: .init(identity: "small-\(memory)") {
                .init(availableBytes: memory * (1 << 30), physicalBytes: memory * (1 << 30))
            })
            XCTAssertEqual(result.stagingByteLimit(), 256 * 1024 * 1024)
            XCTAssertLessThan(result.stagingByteLimit(), 2_890_489_872)
            XCTAssertLessThanOrEqual(budget(physical: memory * gib, available: memory * gib).stagingByteLimit(),
                                     256 * 1024 * 1024)
            XCTAssertEqual(budget(physical: memory * gib, available: gib).stagingByteLimit(), 0)
        }
    }

    func testUnknownInvalidAndOverflowMeasurementsFailClosed() {
        XCTAssertEqual(budget(physical: 256 * gib, available: 100 * gib, configured: false).stagingByteLimit(), 0)
        for (physical, available) in [(0, 1), (8 * gib, -1), (256 * gib, 0)] {
            XCTAssertEqual(budget(physical: physical, available: available).stagingByteLimit(), 0)
        }
        let missing = ConversationCacheMemoryBudget(probe: .init(identity: "missing") { nil })
        XCTAssertEqual(missing.stagingByteLimit(), 0)
        let overflow = budget(physical: Int.max, available: Int.max)
        overflow.configure(maxContextTokens: Int.max, slots: Int.max, residentTokens: Int.max, verifyBytes: Int.max)
        XCTAssertEqual(overflow.stagingByteLimit(), 0)
    }
}
