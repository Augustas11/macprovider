import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-023-R009 / SPEC-038-R011 automatic served slots.
final class AutoServedSlotsTests: XCTestCase {
    // MARK: - Ownership recorded by the config loader

    func testConfigWithoutSourceIsAutotuneDerived() throws {
        let config = try load(file: "max_concurrency_override: 2\n")
        XCTAssertEqual(config.maxConcurrencyOverride, 2)
        XCTAssertNil(config.maxConcurrencySource)
    }

    func testConfigOwnerSourceIsPinned() throws {
        let config = try load(file: "max_concurrency_override: 3\nmax_concurrency_source: owner\n")
        XCTAssertEqual(config.maxConcurrencySource, .owner)
    }

    func testEnvironmentAndFlagAreOwnerValues() throws {
        let env = try load(file: "max_concurrency_override: 2\n", environment: ["MACPROVIDER_MAX_CONCURRENCY_OVERRIDE": "4"])
        XCTAssertEqual(env.maxConcurrencySource, .owner)
        let flag = try load(file: "max_concurrency_override: 2\nmax_concurrency_source: autotune\n", cli: CLIOverrides(maxBatch: 6))
        XCTAssertEqual(flag.maxConcurrencyOverride, 6)
        XCTAssertEqual(flag.maxConcurrencySource, .owner)
    }

    func testUnknownSourceFailsConfigLoad() {
        XCTAssertThrowsError(try load(file: "max_concurrency_source: me\n"))
    }

    // MARK: - Resolution precedence

    func testOwnerPinnedIsKeptEvenWhenBatchingIsAuthorized() {
        let decision = AutoServedSlots.resolve(
            configuredSlots: 2, source: .owner, draftConfigured: false,
            continuousBatchingAuthorized: true, recommendedSlots: { 8 }
        )
        XCTAssertEqual(decision, .init(slots: 2, reason: "owner_pinned"))
    }

    func testAutotuneDerivedIsRaisedWhenBatchingIsAuthorized() {
        let decision = AutoServedSlots.resolve(
            configuredSlots: 1, source: nil, draftConfigured: false,
            continuousBatchingAuthorized: true, recommendedSlots: { 4 }
        )
        XCTAssertEqual(decision, .init(slots: 4, reason: "cb_authorized"))
    }

    func testNotAuthorizedServesOneSlot() {
        let decision = AutoServedSlots.resolve(
            configuredSlots: 8, source: .autotune, draftConfigured: false,
            continuousBatchingAuthorized: false, recommendedSlots: { 8 }
        )
        XCTAssertEqual(decision, .init(slots: 1, reason: "cb_not_authorized"))
    }

    func testDraftModelForcesOneSlot() {
        let decision = AutoServedSlots.resolve(
            configuredSlots: nil, source: nil, draftConfigured: true,
            continuousBatchingAuthorized: true, recommendedSlots: { 8 }
        )
        XCTAssertEqual(decision, .init(slots: 1, reason: "draft_model"))
    }

    func testRecommendationNeverExceedsTheServedHardCap() {
        let decision = AutoServedSlots.resolve(
            configuredSlots: nil, source: nil, draftConfigured: false,
            continuousBatchingAuthorized: true, recommendedSlots: { 500 }
        )
        XCTAssertEqual(decision.slots, ProviderCapacity.maxConcurrencyOverrideLimit)
    }

    // MARK: - Recommendation for this Mac

    func testM1AndM2NonUltraCapAtFive() {
        for chip in ["Apple M1", "Apple M1 Pro", "Apple M2 Max", "Apple M2"] {
            XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: chip, memoryGB: 64, memoryFitCap: 12), 5, chip)
        }
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M1 Ultra", memoryGB: 128, memoryFitCap: 12), 12)
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M3 Max", memoryGB: 64, memoryFitCap: 12), 12)
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M2", memoryGB: 16, memoryFitCap: 3), 3)
    }

    func testUnknownMemoryFitFallsBackToTheTierConstant() {
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M3 Ultra", memoryGB: 256, memoryFitCap: nil), 8)
        XCTAssertEqual(AutoServedSlots.recommendedSlots(chip: "Apple M4", memoryGB: 16, memoryFitCap: nil), 1)
    }

    // MARK: - Policy load changes the advertised capacity

    func testPolicyChangeBetweenStartsChangesAdvertisedCapacity() {
        let keys: Set<String> = ["qwen3.6-35b-a3b"]
        let empty = ContinuousBatchingPolicyLoadResult(
            selection: .emptyOff, status: .absentFallback, policySHA256: nil, signerKeyID: nil
        )
        let live = ContinuousBatchingPolicyLoadResult(
            selection: ContinuousBatchingPolicySelection(
                releaseID: "r", policyVersion: "v", generatedAt: .distantPast, expiresAt: .distantFuture,
                candidateCatalogSHA256: "", signerKeyID: "k", source: "coordinator",
                entries: [Self.entry(modelKey: "qwen3.6-35b-a3b", rollout: .on)]
            ),
            status: .liveVerified, policySHA256: "p", signerKeyID: "k"
        )
        func advertised(_ policy: ContinuousBatchingPolicyLoadResult) -> Int {
            let decision = AutoServedSlots.resolve(
                configuredSlots: 1, source: nil, draftConfigured: false,
                continuousBatchingAuthorized: AutoServedSlots.policyAuthorizesServedModel(
                    policy, modelKeys: keys, emergencyOff: false
                ),
                recommendedSlots: { 4 }
            )
            return ProviderCapacity(maxContextOverride: 4_000, maxConcurrencyOverride: decision.slots).maxConcurrency
        }
        XCTAssertEqual(advertised(empty), 1)
        XCTAssertEqual(advertised(live), 4)
        XCTAssertFalse(AutoServedSlots.policyAuthorizesServedModel(live, modelKeys: keys, emergencyOff: true))
    }

    // MARK: - Helpers

    private func load(file: String, environment: [String: String] = [:], cli: CLIOverrides = CLIOverrides()) throws -> AppConfig {
        try ConfigLoader.load(cli: cli, environment: environment, fileExists: { _ in true }, readFile: { _ in file })
    }

    private static func entry(modelKey: String, rollout: ContinuousBatchingMode) -> ContinuousBatchingPolicyEntry {
        ContinuousBatchingPolicyEntry(
            tupleSHA256: String(repeating: "a", count: 64),
            modelKey: modelKey,
            rollout: rollout,
            tuple: ContinuousBatchingAcceptedTuple(
                modelID: modelKey, modelSHA256: "", cacheClass: "", kvDType: .fp16,
                requiresMoE: false, hardwareClass: "", metallibSHA256: "", kernelIdentifier: ""
            ),
            provenance: ContinuousBatchingPolicyProvenance(
                source: "", status: "", evidenceID: "", packageManifestSHA256: "",
                studioCampaignSHA256: "", providerCLIVersion: "", liveExecutableCDHash: ""
            )
        )
    }
}
