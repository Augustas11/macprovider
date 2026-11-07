import XCTest
@testable import MacProviderCore

/// SPEC-038 FR-CB2 (v0.3.36): MLX's memory limit below the working set.
final class MLXMemoryBudgetTests: XCTestCase {
    private let gib = 1024 * 1024 * 1024

    func testLimitIsTenPercentBelowWorkingSet() {
        // 96 GiB Mac with an 83.5 GB working set (exo-explore/exo#2523).
        let workingSet = 83_500_000_000
        let limit = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: workingSet, physicalMemoryBytes: UInt64(96 * gib))
        XCTAssertEqual(limit, workingSet - workingSet / 10)
    }

    func testStudioLimitSitsAtTheObservedFaultSize() {
        // 256 GB M3 Ultra: working set 239.14 GB; MLX's unset default is
        // 261.1 GB. GLM-5.3-Flash serving peaks (182-198 GB) stay under it.
        let limit = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: 239_140_000_000, physicalMemoryBytes: UInt64(256 * gib))!
        XCTAssertEqual(limit, 215_226_000_000)
        XCTAssertGreaterThan(limit, 198_000_000_000)
    }

    func testLimitNeverExceedsWorkingSetOrNinetyPercentOfRAM() {
        let physical = 256 * gib
        for workingSet in [8 * gib, 192 * gib, 239 * gib, 250 * gib, 256 * gib] {
            for resident in [0, 100 * gib, 230 * gib, 260 * gib, Int.max] {
                let limit = MLXMemoryBudget.limitBytes(
                    recommendedWorkingSetBytes: workingSet,
                    physicalMemoryBytes: UInt64(physical),
                    residentBytes: resident)!
                XCTAssertLessThanOrEqual(limit, workingSet, "ws \(workingSet) resident \(resident)")
                XCTAssertGreaterThan(limit, 0)
                if resident == 0 {
                    XCTAssertLessThanOrEqual(limit, physical - physical / 10)
                }
            }
        }
    }

    func testRaisedWorkingSetIsCappedByTheR012FreeMemoryFloor() {
        // With 10% headroom on both bounds, RAM binds only when the reported
        // working set exceeds it (a raised wired limit or a misreport).
        let physical = 128 * gib
        let limit = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: 140 * gib, physicalMemoryBytes: UInt64(physical))
        XCTAssertEqual(limit, physical - physical / 10)
    }

    func testSmallMacFloorKeepsAModelThatFitsTheWorkingSet() {
        // 8 GiB Mac: a 5.2 GiB model sits above the 90% cap but inside the
        // working set, so the limit rises to resident + 512 MiB.
        let workingSet = 5_726_623_744 // 5.33 GiB
        let resident = 5_583_457_484 // 5.2 GiB
        let limit = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: workingSet, physicalMemoryBytes: UInt64(8 * gib), residentBytes: resident)
        XCTAssertEqual(limit, workingSet)
        let smaller = MLXMemoryBudget.limitBytes(
            recommendedWorkingSetBytes: workingSet, physicalMemoryBytes: UInt64(8 * gib), residentBytes: 4 * gib)
        XCTAssertEqual(smaller, workingSet - workingSet / 10)
    }

    func testNoWorkingSetKeepsMLXDefault() {
        XCTAssertNil(MLXMemoryBudget.limitBytes(recommendedWorkingSetBytes: nil, physicalMemoryBytes: UInt64(16 * gib)))
        XCTAssertNil(MLXMemoryBudget.limitBytes(recommendedWorkingSetBytes: 0, physicalMemoryBytes: UInt64(16 * gib)))
    }

    func testAdmissionAtTheLimit() {
        XCTAssertTrue(MLXMemoryBudget.admits(activeBytes: 100, requestedBytes: 30, limitBytes: 130))
        XCTAssertFalse(MLXMemoryBudget.admits(activeBytes: 100, requestedBytes: 31, limitBytes: 130))
        XCTAssertFalse(MLXMemoryBudget.admits(activeBytes: 131, requestedBytes: 0, limitBytes: 130))
        XCTAssertFalse(MLXMemoryBudget.admits(activeBytes: Int.max, requestedBytes: 1, limitBytes: Int.max))
    }

    func testKVBytesSaturatesAndIgnoresUnknownGeometry() {
        XCTAssertEqual(MLXMemoryBudget.kvBytes(tokens: 4, bytesPerToken: 10), 40)
        XCTAssertEqual(MLXMemoryBudget.kvBytes(tokens: 4, bytesPerToken: 0), 0)
        XCTAssertEqual(MLXMemoryBudget.kvBytes(tokens: -3, bytesPerToken: 10), 0)
        XCTAssertEqual(MLXMemoryBudget.kvBytes(tokens: Int.max, bytesPerToken: 2), Int.max)
    }
}
