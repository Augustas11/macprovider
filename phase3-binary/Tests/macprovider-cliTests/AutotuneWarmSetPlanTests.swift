import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-001-R017 arithmetic for a second model beside the primary: no model
/// is loaded. The plan is an estimate from files; a running provider's own
/// decision is `warm_set check` (`WarmSetCheckTests`).
final class AutotuneWarmSetPlanTests: XCTestCase {
    private let gib = 1 << 30
    private let margin = SharedModelMemoryRules.perMemberMarginBytes

    private func inputs(
        ramGiB: Int = 64, workingSetGiB: Int? = 48,
        primaryGiB: Int = 16, primaryKV: Int = 100_000, primaryContext: Int = 32_768, primarySlots: Int = 2,
        memberGiB: Int? = 4, memberKV: Int = 50_000, memberDeclaredMax: Int? = 131_072,
        primaryFamily: String? = "qwen3", memberFamily: String? = "llama", operatorMB: Int? = nil,
        operatorValue: String? = nil, primaryVerified: Bool = true, memberBound: Bool = true
    ) -> AutotuneWarmSetPlan.Inputs {
        AutotuneWarmSetPlan.Inputs(
            physicalMemoryBytes: UInt64(ramGiB) * UInt64(gib),
            recommendedWorkingSetBytes: workingSetGiB.map { $0 * gib },
            primary: .init(modelID: "main/model", artifactBytes: primaryGiB * gib, kvBytesPerToken: primaryKV,
                           declaredMaxContextTokens: 262_144, family: primaryFamily, catalogMinRAMGB: 32),
            primaryContextTokens: primaryContext, primarySlots: primarySlots, primaryVerified: primaryVerified,
            member: .init(modelID: "second/model", artifactBytes: memberGiB.map { $0 * gib }, kvBytesPerToken: memberKV,
                          declaredMaxContextTokens: memberDeclaredMax, family: memberFamily, catalogMinRAMGB: 8,
                          catalogBound: memberBound),
            operatorCommandBuffer: operatorValue ?? operatorMB.map(String.init))
    }

    func testFitsGivesTheSecondModelThePrimarysShapeWhenThereIsRoom() throws {
        let plan = AutotuneWarmSetPlan.compute(inputs(ramGiB: 192, workingSetGiB: 144))
        XCTAssertEqual(plan.decision, .fits)
        XCTAssertEqual(plan.reason, "fits")
        XCTAssertEqual(plan.members.map(\.role), ["primary", "member"])
        XCTAssertEqual(plan.members[0], .init(modelID: "main/model", role: "primary", contextTokens: 32_768, slots: 2,
                                              bytes: 16 * gib + 2 * 32_768 * 100_000))
        XCTAssertEqual(plan.members[1].contextTokens, 32_768)
        XCTAssertEqual(plan.members[1].slots, 2)
        XCTAssertEqual(plan.members[1].bytes, 4 * gib + 2 * 32_768 * 50_000)
        XCTAssertNil(plan.primaryFit)
    }

    func testFitsWithFewerSlotsThenOneSmallerRowWhenRoomIsShort() throws {
        // Shape arithmetic on its own: as many slots as fit, then one slot
        // at the largest context, never below the runtime's minimum row.
        let perSlot = 32_768 * 50_000
        XCTAssertTrue(AutotuneWarmSetPlan.memberShape(
            defaultContext: 32_768, defaultSlots: 4, declaredMax: nil, kvBytesPerToken: 50_000, allowance: 3 * perSlot + 1) == (32_768, 3))
        XCTAssertTrue(AutotuneWarmSetPlan.memberShape(
            defaultContext: 32_768, defaultSlots: 4, declaredMax: nil, kvBytesPerToken: 50_000, allowance: 10_000 * 50_000) == (10_000, 1))
        XCTAssertTrue(AutotuneWarmSetPlan.memberShape(
            defaultContext: 32_768, defaultSlots: 4, declaredMax: nil, kvBytesPerToken: 50_000, allowance: 0) == (4_096, 1))
        XCTAssertTrue(AutotuneWarmSetPlan.memberShape(
            defaultContext: 2_000, defaultSlots: 1, declaredMax: nil, kvBytesPerToken: 50_000, allowance: .max) == (4_096, 1),
            "the floor is the runtime's minimum row")
        XCTAssertTrue(AutotuneWarmSetPlan.memberShape(
            defaultContext: 32_768, defaultSlots: 2, declaredMax: 8_192, kvBytesPerToken: 50_000, allowance: .max) == (8_192, 2))
        XCTAssertTrue(AutotuneWarmSetPlan.memberShape(
            defaultContext: 32_768, defaultSlots: 2, declaredMax: nil, kvBytesPerToken: 0, allowance: 0) == (32_768, 2),
            "unknown KV geometry keeps the inherited shape")
        XCTAssertEqual(AutotuneWarmSetPlan.minimumContextTokens, SharedModelMemoryRules.minimumRowTokens)
        XCTAssertLessThanOrEqual(AutotuneModelContextCap.minimumServeContext, AutotuneWarmSetPlan.minimumContextTokens)
    }

    func testPrimaryMustShrinkWhenItsReservationFillsTheBudget() throws {
        // 48 GiB working set: 16 GiB weights + 8 rows of 32K at 100 KB/token
        // (~24.4 GiB) leave no room for 12 GiB more weights.
        let input = inputs(primarySlots: 8, memberGiB: 12)
        let plan = AutotuneWarmSetPlan.compute(input)
        XCTAssertEqual(plan.decision, .primaryMustShrink)
        XCTAssertEqual(plan.reason, "primary_reservation")
        XCTAssertEqual(plan.members[0].slots, 8, "the plan never lowers the primary")
        XCTAssertEqual(plan.members[1].slots, 1)
        XCTAssertEqual(plan.members[1].contextTokens, 4_096)
        let fit = try XCTUnwrap(plan.primaryFit)
        XCTAssertEqual(fit.contextTokens, 32_768)
        XCTAssertGreaterThanOrEqual(fit.slots, 1)
        XCTAssertLessThan(fit.slots, 8)
        // The suggested reservation is the largest the plan admits.
        var shrunk = input
        shrunk.primarySlots = fit.slots
        XCTAssertEqual(AutotuneWarmSetPlan.compute(shrunk).decision, .fits)
        shrunk.primarySlots = fit.slots + 1
        XCTAssertEqual(AutotuneWarmSetPlan.compute(shrunk).decision, .primaryMustShrink)
    }

    func testDoesNotFitWhenEvenTheSmallestPrimaryLeavesNoRoom() {
        let plan = AutotuneWarmSetPlan.compute(inputs(memberGiB: 40))
        XCTAssertEqual(plan.decision, .doesNotFit)
        XCTAssertEqual(plan.reason, "insufficient_memory")
        XCTAssertEqual(plan.members.map(\.role), ["primary"])
    }

    func testCommandBufferBudgetConflictDoesNotFit() {
        let conflict = AutotuneWarmSetPlan.compute(inputs(ramGiB: 512, workingSetGiB: 400, memberFamily: "deepseek_v4"))
        XCTAssertEqual(conflict.decision, .doesNotFit)
        XCTAssertEqual(conflict.reason, "command_buffer_budget_conflict")
        // The operator's own value is never a conflict, nor a family that
        // wants what the primary's family set.
        XCTAssertEqual(AutotuneWarmSetPlan.compute(inputs(ramGiB: 512, workingSetGiB: 400, memberFamily: "deepseek_v4", operatorMB: 1_024)).decision, .fits)
        XCTAssertEqual(AutotuneWarmSetPlan.compute(inputs(ramGiB: 512, workingSetGiB: 400, primaryFamily: "glm5_next", memberFamily: "deepseek_v4")).decision, .fits)
        // A family with no requirement runs under the primary's budget (the
        // lab's glm5_next + qwen pair).
        XCTAssertEqual(AutotuneWarmSetPlan.compute(inputs(ramGiB: 512, workingSetGiB: 400, primaryFamily: "glm5_next", memberFamily: "qwen")).decision,
                       .fits)
        XCTAssertFalse(conflict.summary(memberModelID: "second/model").contains("GPU buffer setting than the loaded model"))
        XCTAssertTrue(conflict.summary(memberModelID: "second/model").contains("MLX_MAX_MB_PER_BUFFER"))
        // The same answers as the budget a running provider holds.
        let expected: [(String, String, Bool)] = [
            ("qwen3", "deepseek_v4", true), ("glm5_next", "deepseek_v4", false), ("glm5_next", "llama", false),
            ("glm5_next", "qwen", false), ("qwen3", "llama", false),
        ]
        for (primary, member, conflicts) in expected {
            let budget = SharedModelMemoryBudget()
            if let mb = ModelRuntime.commandBufferBudgetMBByFamily[primary] {
                budget.recordCommandBufferBudget(modelFamily: primary, megabytes: mb)
            }
            let planned = AutotuneWarmSetPlan.commandBufferBudgetConflicts(family: member, primaryFamily: primary, operatorValue: nil)
            XCTAssertEqual(planned, conflicts, "\(primary) + \(member)")
            XCTAssertEqual(planned, budget.commandBufferBudgetConflict(modelFamily: member) != nil, "\(primary) + \(member)")
        }
    }

    /// Any non-empty `MLX_MAX_MB_PER_BUFFER` is the operator's, integer or
    /// not, in the plan as in the loader: never a conflict.
    func testANonIntegerOperatorCommandBufferValueIsTheOperatorsInThePlanAndTheLoader() {
        for value in ["64mb", " 1024 ", "abc"] {
            let plan = AutotuneWarmSetPlan.compute(
                inputs(ramGiB: 512, workingSetGiB: 400, memberFamily: "deepseek_v4", operatorValue: value))
            XCTAssertEqual(plan.decision, .fits, value)
            XCTAssertFalse(AutotuneWarmSetPlan.commandBufferBudgetConflicts(
                family: "deepseek_v4", primaryFamily: "qwen3", operatorValue: value), value)
            XCTAssertEqual(SharedModelMemoryRules.operatorCommandBufferBudget(value)?.family, "environment", value)
        }
        XCTAssertEqual(SharedModelMemoryRules.operatorCommandBufferBudget(" 1024 ")?.megabytes, 1_024)
        XCTAssertNil(SharedModelMemoryRules.operatorCommandBufferBudget("abc")?.megabytes)
        XCTAssertNil(SharedModelMemoryRules.operatorCommandBufferBudget(""))
        XCTAssertNil(SharedModelMemoryRules.operatorCommandBufferBudget(nil))
        // An empty value is unset, as for the loader: the conflict stands.
        XCTAssertEqual(AutotuneWarmSetPlan.compute(
            inputs(ramGiB: 512, workingSetGiB: 400, memberFamily: "deepseek_v4", operatorValue: "")).reason,
            "command_buffer_budget_conflict")
    }

    func testRefusalsThatNeedNoArithmetic() {
        XCTAssertEqual(AutotuneWarmSetPlan.compute(inputs(memberGiB: nil)).reason, "not_on_this_mac")
        XCTAssertEqual(AutotuneWarmSetPlan.compute(inputs(memberBound: false)).reason, "not_in_signed_catalog")
        XCTAssertEqual(AutotuneWarmSetPlan.compute(inputs(primaryVerified: false, memberBound: false)).decision, .fits)
        XCTAssertEqual(AutotuneWarmSetPlan.compute(inputs(workingSetGiB: nil)).reason, "memory_limit_unavailable")
        var same = inputs()
        same.member.modelID = "MAIN/model"
        XCTAssertEqual(AutotuneWarmSetPlan.compute(same).reason, "same_model")
    }

    /// Over a table of Macs and models the plan reaches every decision, and
    /// whenever it says `fits`, the second model's planned rows fit the
    /// limit beside the primary's. (Whether a running provider would load
    /// it is that provider's own decision: `WarmSetCheckTests`.)
    func testPlannedRowsFitTheLimitOverATable() throws {
        var checked = 0
        var decisions: [AutotuneWarmSetPlan.Decision: Int] = [:]
        for (ram, workingSet) in [(16, 11), (24, 16), (36, 27), (64, 48), (128, 96), (192, 144), (512, 400)] {
            for primaryGiB in [2, 8, 30] {
                for primarySlots in [1, 4, 16] {
                    for memberGiB in [1, 5, 20] {
                        for memberKV in [0, 40_000, 400_000] {
                            let input = inputs(
                                ramGiB: ram, workingSetGiB: workingSet, primaryGiB: primaryGiB, primaryContext: 16_384,
                                primarySlots: primarySlots, memberGiB: memberGiB, memberKV: memberKV)
                            let plan = AutotuneWarmSetPlan.compute(input)
                            let limit = try XCTUnwrap(plan.limitBytes)
                            decisions[plan.decision, default: 0] += 1
                            if plan.decision == .fits {
                                let primaryRows = max(
                                    MLXMemoryBudget.kvBytes(tokens: primarySlots * 16_384, bytesPerToken: 100_000),
                                    MLXMemoryBudget.kvBytes(tokens: 4_096, bytesPerToken: 100_000))
                                let member = plan.members[1]
                                let memberRows = MLXMemoryBudget.kvBytes(tokens: member.slots * member.contextTokens, bytesPerToken: memberKV)
                                let total = primaryGiB * gib + memberGiB * gib + primaryRows + memberRows + 2 * margin
                                XCTAssertLessThanOrEqual(total, limit, "planned rows exceed the runtime limit")
                                XCTAssertGreaterThanOrEqual(member.contextTokens, 4_096)
                                XCTAssertGreaterThanOrEqual(member.slots, 1)
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 7 * 3 * 3 * 3 * 3)
        XCTAssertGreaterThan(decisions[.fits] ?? 0, 0)
        XCTAssertGreaterThan(decisions[.primaryMustShrink] ?? 0, 0)
        XCTAssertGreaterThan(decisions[.doesNotFit] ?? 0, 0)
    }

    func testPlanEncodesItsDecisionAndMembers() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(AutotuneWarmSetPlan.compute(inputs(primarySlots: 8, memberGiB: 12))), as: UTF8.self)
        XCTAssertTrue(text.contains("\"decision\":\"primary_must_shrink\""), text)
        XCTAssertTrue(text.contains("\"primary_fit\":{\"context_tokens\":32768"), text)
        XCTAssertTrue(text.contains("\"model_id\":\"second\\/model\""), text)
        XCTAssertTrue(text.contains("\"role\":\"member\""), text)
        XCTAssertTrue(text.contains("\"estimate\":true"), text)
    }

    /// Golden: the several-artifact envelope with one artifact is today's
    /// single-model envelope, byte for byte, over a table of Macs.
    func testSeveralArtifactEnvelopeWithOneArtifactIsTodaysEnvelope() {
        for ram in [8, 16, 24, 36, 64, 96, 128, 192, 256, 512] {
            for minRAM in [1, 8, 32] {
                for size in [nil, 1, 3 * gib, 20 * gib, 600 * gib] as [Int?] {
                    XCTAssertEqual(
                        AutotuneModelContextCap.usableKVBytes(
                            hardwareMemoryGB: ram, catalogMinRAMGB: minRAM, verifiedArtifactSizesBytes: size.map { [$0] } ?? []),
                        AutotuneModelContextCap.usableKVBytes(
                            hardwareMemoryGB: ram, catalogMinRAMGB: minRAM, verifiedArtifactSizeBytes: size),
                        "\(ram) GB min \(minRAM) size \(String(describing: size))")
                }
            }
        }
        // Literal values of today's envelope: 64 GB, 20 GiB of weights, 4 GB
        // margin: (64 - 24) GiB * 3/4 = 30 GiB.
        XCTAssertEqual(AutotuneModelContextCap.usableKVBytes(hardwareMemoryGB: 64, catalogMinRAMGB: 1, verifiedArtifactSizesBytes: [20 * gib]),
                       UInt64(30 * gib))
        XCTAssertEqual(AutotuneModelContextCap.usableKVBytes(hardwareMemoryGB: 64, catalogMinRAMGB: 1, verifiedArtifactSizesBytes: [12 * gib, 8 * gib]),
                       UInt64(30 * gib), "two artifacts are summed with one margin")
        XCTAssertEqual(AutotuneModelContextCap.usableKVBytes(hardwareMemoryGB: 64, catalogMinRAMGB: 16, verifiedArtifactSizesBytes: [12 * gib, 0]),
                       UInt64((64 - 16 - 4) * gib * 3 / 4), "an unknown size falls back to the catalog RAM")
    }
}
