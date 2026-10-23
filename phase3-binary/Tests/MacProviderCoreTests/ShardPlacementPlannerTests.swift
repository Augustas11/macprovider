import XCTest
@testable import MacProviderCore

/// Issue #2084 slice 3: contiguous layer placement across shard-group members.
final class ShardPlacementPlannerTests: XCTestCase {
    private static let gb: Int64 = 1_000_000_000

    /// DeepSeek-V3 at 4-bit (group 64): 61 layers, the first 3 dense (~0.33 GB), 58
    /// MoE (~6.47 GB: 256 routed experts x 3 x 7168 x 2048 plus MLA attention),
    /// embedding and LM head 129280 x 7168 (~0.52 GB each). KV is what the stage
    /// runtime allocates: 128 heads x (192 key + 128 value) x bf16 = 81,920 B per
    /// token per layer.
    private static let deepseekV3 = ShardPlacementModel(
        layerWeightBytes: Array(repeating: 330_000_000, count: 3) + Array(repeating: 6_470_000_000, count: 58),
        embeddingBytes: 520_000_000, headBytes: 520_000_000, kvBytesPerTokenPerLayer: 81_920)

    /// Kimi K2 at 4-bit: 61 layers, 1 dense, 60 MoE with 384 experts (~9.59 GB),
    /// vocab 163840 (~0.66 GB embedding and head), 64 MLA heads (40,960 B KV).
    private static let kimiK2 = ShardPlacementModel(
        layerWeightBytes: [280_000_000] + Array(repeating: 9_590_000_000, count: 60),
        embeddingBytes: 660_000_000, headBytes: 660_000_000, kvBytesPerTokenPerLayer: 40_960)

    private func members(_ gigabytes: [Double], weights: [Double]? = nil) -> [ShardPlacementMember] {
        gigabytes.enumerated().map { index, size in
            ShardPlacementMember(id: "mac\(index)", usableMemoryBytes: Int64(size * 1e9), computeWeight: weights?[index])
        }
    }

    private func assertCoversContiguously(_ plan: ShardPlacementPlan, layers: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.stages.first?.layerStart, 0, file: file, line: line)
        XCTAssertEqual(plan.stages.last?.layerEnd, layers, file: file, line: line)
        for (left, right) in zip(plan.stages, plan.stages.dropFirst()) {
            XCTAssertEqual(left.layerEnd, right.layerStart, file: file, line: line)
        }
        for stage in plan.stages {
            XCTAssertGreaterThan(stage.layerCount, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(stage.totalBytes, stage.usableMemoryBytes, file: file, line: line)
            XCTAssertEqual(stage.headroomBytes, stage.usableMemoryBytes - stage.totalBytes, file: file, line: line)
        }
    }

    // MARK: DeepSeek-V3

    func testDeepseekV3OnTwo256GBMacsWithRoomFitsEvenly() throws {
        let plan = try ShardPlacementPlanner.plan(members: members([230, 230]), model: Self.deepseekV3, contextTokens: 4096)
        assertCoversContiguously(plan, layers: 61)
        XCTAssertEqual(plan.stages.map(\.layerCount), [32, 29], "the LM-head stage takes fewer layers; the dense layers are cheap")
        XCTAssertEqual(plan.totalDemandBytes, 397_758_203_520)
        XCTAssertFalse(plan.isTight)
        XCTAssertEqual(plan.stages[0].extraBytes, 520_000_000)
        XCTAssertEqual(plan.stages[1].extraBytes, 520_000_000)
        XCTAssertEqual(plan.stages[0].kvBytes, 81_920 * 4096 * 32)
    }

    func testDeepseekV3OnTwo256GBMacsWithLittleHeadroomIsTight() throws {
        let plan = try ShardPlacementPlanner.plan(members: members([205, 205]), model: Self.deepseekV3, contextTokens: 4096)
        assertCoversContiguously(plan, layers: 61)
        XCTAssertTrue(plan.isTight)
        XCTAssertLessThan(plan.minimumHeadroomFraction, 0.05)
        XCTAssertGreaterThan(plan.minimumHeadroomFraction, 0)
    }

    func testDeepseekV3OnTwo256GBMacsWithALongContextFailsWithTheShortfall() {
        XCTAssertThrowsError(try ShardPlacementPlanner.plan(members: members([200, 200]), model: Self.deepseekV3, contextTokens: 8192)) { error in
            XCTAssertEqual(error as? ShardPlacementError, .insufficientMemory(
                demandBytes: 418_226_407_040, usableBytes: 400 * Self.gb, shortfallBytes: 18_226_407_040))
        }
    }

    func testDeepseekV3ThatFitsInTotalButNotInAnyContiguousSplitIsRefused() {
        // 397.76 GB of demand on 398 GB, but MoE layers come in 6.8 GB steps and no
        // boundary leaves both stages under 199 GB.
        XCTAssertThrowsError(try ShardPlacementPlanner.plan(members: members([199, 199]), model: Self.deepseekV3, contextTokens: 4096)) { error in
            guard case .stageDoesNotFit(_, let shortfall) = error as? ShardPlacementError else {
                return XCTFail("expected stageDoesNotFit, got \(error)")
            }
            XCTAssertEqual(shortfall, 877_418_240)
        }
    }

    func testDeepseekV3On512And256GBSplitsByMemory() throws {
        let plan = try ShardPlacementPlanner.plan(members: members([480, 230]), model: Self.deepseekV3, contextTokens: 4096)
        assertCoversContiguously(plan, layers: 61)
        XCTAssertEqual(plan.stages.map(\.layerCount), [42, 19])
        XCTAssertFalse(plan.isTight)
    }

    // MARK: Kimi K2

    func testKimiK2On512And256GBFits() throws {
        let plan = try ShardPlacementPlanner.plan(members: members([480, 230]), model: Self.kimiK2, contextTokens: 8192)
        assertCoversContiguously(plan, layers: 61)
        XCTAssertEqual(plan.stages.map(\.layerCount), [42, 19])
        XCTAssertEqual(plan.totalDemandBytes, 597_468_203_520)
        XCTAssertFalse(plan.isTight)
    }

    func testKimiK2OnTwo256GBMacsDoesNotFit() {
        XCTAssertThrowsError(try ShardPlacementPlanner.plan(members: members([230, 230]), model: Self.kimiK2, contextTokens: 8192)) { error in
            guard case .insufficientMemory(_, _, let shortfall) = error as? ShardPlacementError else {
                return XCTFail("expected insufficientMemory, got \(error)")
            }
            XCTAssertEqual(shortfall, 137_468_203_520)
        }
    }

    // MARK: Rules

    func testLMHeadStageGetsFewerLayersAndEmbeddingCountsOnlyForMemory() throws {
        let model = ShardPlacementModel(
            layerWeightBytes: Array(repeating: 10, count: 8), embeddingBytes: 15, headBytes: 15, kvBytesPerTokenPerLayer: 0)
        let plan = try ShardPlacementPlanner.plan(
            members: [ShardPlacementMember(id: "a", usableMemoryBytes: 100), ShardPlacementMember(id: "b", usableMemoryBytes: 100)],
            model: model, contextTokens: 0)
        XCTAssertEqual(plan.stages.map(\.layerCount), [5, 3])
        XCTAssertEqual(plan.stages.map(\.totalBytes), [65, 45])
    }

    func testComputeWeightsOverrideMemoryShares() throws {
        let model = ShardPlacementModel(
            layerWeightBytes: Array(repeating: 10, count: 8), embeddingBytes: 0, headBytes: 0, kvBytesPerTokenPerLayer: 0)
        let weighted = [ShardPlacementMember(id: "big", usableMemoryBytes: 300, computeWeight: 1),
                        ShardPlacementMember(id: "small", usableMemoryBytes: 100, computeWeight: 1)]
        XCTAssertEqual(try ShardPlacementPlanner.plan(members: weighted, model: model, contextTokens: 0).stages.map(\.layerCount), [4, 4])
        let byMemory = weighted.map { ShardPlacementMember(id: $0.id, usableMemoryBytes: $0.usableMemoryBytes) }
        XCTAssertEqual(try ShardPlacementPlanner.plan(members: byMemory, model: model, contextTokens: 0).stages.map(\.layerCount), [6, 2])
    }

    func testRepairMovesLayersOffAnOverfullStage() throws {
        // Compute weights ask for an even split, but the second member cannot hold 4
        // layers; the repair moves one to the first member.
        let model = ShardPlacementModel(
            layerWeightBytes: Array(repeating: 10, count: 8), embeddingBytes: 0, headBytes: 0, kvBytesPerTokenPerLayer: 0)
        let plan = try ShardPlacementPlanner.plan(
            members: [ShardPlacementMember(id: "a", usableMemoryBytes: 100, computeWeight: 1),
                      ShardPlacementMember(id: "b", usableMemoryBytes: 35, computeWeight: 1)],
            model: model, contextTokens: 0)
        XCTAssertEqual(plan.stages.map(\.layerCount), [5, 3])
    }

    func testThreeMembersWithUnevenLayers() throws {
        let model = ShardPlacementModel(
            layerWeightBytes: [1, 1, 1] + Array(repeating: 20, count: 9), embeddingBytes: 2, headBytes: 2, kvBytesPerTokenPerLayer: 1)
        let plan = try ShardPlacementPlanner.plan(members: members([0.0000001, 0.0000001, 0.0000001]), model: model, contextTokens: 3)
        assertCoversContiguously(plan, layers: 12)
        // The cheap dense layers sit in front, so the head stage carries the most layers.
        XCTAssertEqual(plan.stages.map(\.layerCount), [6, 3, 3])
    }

    func testInvalidInputsAreRefused() {
        let model = ShardPlacementModel(layerWeightBytes: [1, 1], embeddingBytes: 0, headBytes: 0, kvBytesPerTokenPerLayer: 0)
        XCTAssertThrowsError(try ShardPlacementPlanner.plan(members: members([1]), model: model, contextTokens: 0)) { error in
            XCTAssertEqual(error as? ShardPlacementError, .tooFewMembers(1))
        }
        XCTAssertThrowsError(try ShardPlacementPlanner.plan(members: members([1, 1, 1]), model: model, contextTokens: 0)) { error in
            XCTAssertEqual(error as? ShardPlacementError, .moreStagesThanLayers(stages: 3, layers: 2))
        }
        XCTAssertThrowsError(try ShardPlacementPlanner.plan(
            members: [ShardPlacementMember(id: "a", usableMemoryBytes: 10, computeWeight: 1), ShardPlacementMember(id: "b", usableMemoryBytes: 10)],
            model: model, contextTokens: 0))
        XCTAssertThrowsError(try ShardPlacementPlanner.plan(
            members: [ShardPlacementMember(id: "a", usableMemoryBytes: 10), ShardPlacementMember(id: "a", usableMemoryBytes: 10)],
            model: model, contextTokens: 0))
    }
}
