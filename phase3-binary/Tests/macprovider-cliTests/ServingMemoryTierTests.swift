import Foundation
import XCTest
@testable import macprovider_cli

final class ServingMemoryTierTests: XCTestCase {
    private let eightGiB: UInt64 = 8 * 1_073_741_824

    func testPhysicalMemoryBoundariesAndRequestedRowExtremes() {
        XCTAssertNil(ProviderCapacity.memoryTierRowCap(physicalMemoryBytes: 0))
        XCTAssertEqual(ProviderCapacity.memoryTierRowCap(physicalMemoryBytes: 1), 3)
        XCTAssertEqual(ProviderCapacity.memoryTierRowCap(physicalMemoryBytes: eightGiB), 3)
        XCTAssertNil(ProviderCapacity.memoryTierRowCap(physicalMemoryBytes: eightGiB + 1))
        XCTAssertNil(ProviderCapacity.memoryTierRowCap(physicalMemoryBytes: .max))
        for bytes: UInt64 in [0, 1, eightGiB, eightGiB + 1, .max] {
            XCTAssertEqual(ProviderCapacity.boundedServingRows(.min, physicalMemoryBytes: bytes), 1)
            XCTAssertEqual(ProviderCapacity.boundedServingRows(2, physicalMemoryBytes: bytes), 2)
            XCTAssertEqual(ProviderCapacity.boundedServingRows(.max, physicalMemoryBytes: bytes),
                           bytes > 0 && bytes <= eightGiB ? 3 : 32)
        }
    }

    func testEveryPlanBranchRespectsPhysicalRAMAndLowerPolicyBounds() {
        for owner in [false, true] {
            for provisional in [false, true] {
                for fitKnown in [false, true] {
                    for ceiling: Int? in [nil, 2, 12] {
                        let plan = AutoServedSlots.plan(
                            configuredSlots: 16, source: owner ? .owner : nil,
                            draftConfigured: false, emergencyOff: false,
                            provisionalPolicyEntry: provisional, recommendedSlots: { 16 },
                            memoryFitKnown: fitKnown, policyCeiling: ceiling,
                            physicalMemoryBytes: eightGiB
                        )
                        XCTAssertEqual(plan.rows, ceiling == 2 ? 2 : 3)
                        XCTAssertEqual(plan.initialServed, owner || provisional ? plan.rows : 1)
                        XCTAssertEqual(plan.ownerPinned, owner ? 16 : nil)
                    }
                }
            }
        }
        for (draft, off) in [(true, false), (false, true)] {
            let plan = AutoServedSlots.plan(
                configuredSlots: 16, source: nil, draftConfigured: draft, emergencyOff: off,
                provisionalPolicyEntry: true, recommendedSlots: { 16 }, physicalMemoryBytes: eightGiB
            )
            XCTAssertEqual(plan.rows, 1)
            XCTAssertEqual(plan.initialServed, 1)
        }
    }

    func testTighterFitAndRecommendationsAreNotRaisedByRAMCap() {
        let plan = AutoServedSlots.plan(
            configuredSlots: 16, source: nil, draftConfigured: false, emergencyOff: false,
            provisionalPolicyEntry: true, recommendedSlots: { 2 }, memoryFitKnown: true,
            physicalMemoryBytes: eightGiB
        )
        XCTAssertEqual(plan.rows, 2)
        XCTAssertEqual(plan.initialServed, 2)
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M1", memoryGB: 8, memoryFitCap: 12), 3)
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M3", memoryGB: 8, memoryFitCap: 2), 2)
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M3", memoryGB: 8, memoryFitCap: nil), 1)
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M3", memoryGB: 9, memoryFitCap: 12), 12)
        for memoryGB in [0, -1, Int.max] {
            XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M3", memoryGB: memoryGB, memoryFitCap: 12), 12)
        }
    }

    func testUncataloguedFitRequiresVerifiedBindingAndBoundedActualWeights() throws {
        let config = Data(#"{"num_hidden_layers":4,"hidden_size":1024,"num_attention_heads":8,"num_key_value_heads":2}"#.utf8)
        func fit(_ weights: UInt64?, verified: Bool, catalog: Int? = nil) -> Int? {
            AutoServedSlots.memoryFitSlots(
                configJSONData: config, memoryGB: 8, catalogMinRAMGB: catalog,
                contextTokens: 4096, weightsBytes: weights, verifiedArtifactBinding: verified
            )
        }
        let weights: UInt64 = 1_073_741_824
        let verified = try XCTUnwrap(fit(weights, verified: true))
        XCTAssertGreaterThan(verified, 0)
        // With actual bytes present the catalog fallback does not affect fit.
        XCTAssertEqual(verified, fit(weights, verified: false, catalog: 8))
        XCTAssertNil(fit(weights, verified: false))
        for invalid: UInt64? in [nil, 0, UInt64(Int.max) + 1, UInt64.max] {
            XCTAssertNil(fit(invalid, verified: true))
        }
        XCTAssertNil(AutoServedSlots.memoryFitSlots(
            configJSONData: Data("{}".utf8), memoryGB: 8, catalogMinRAMGB: nil,
            contextTokens: 4096, weightsBytes: weights, verifiedArtifactBinding: true
        ))
    }
}
