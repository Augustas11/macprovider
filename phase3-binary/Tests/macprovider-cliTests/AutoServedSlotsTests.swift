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

    // MARK: - Plan precedence

    private func plan(
        configured: Int? = nil,
        source: MaxConcurrencySource? = nil,
        draft: Bool = false,
        emergencyOff: Bool = false,
        provisional: Bool = false,
        recommended: Int = 4
    ) -> AutoServedSlots.Plan {
        AutoServedSlots.plan(
            configuredSlots: configured, source: source, draftConfigured: draft,
            emergencyOff: emergencyOff, provisionalPolicyEntry: provisional,
            recommendedSlots: { recommended }
        )
    }

    func testOwnerPinnedIsKept() {
        let pinned = plan(configured: 2, source: .owner, recommended: 8)
        XCTAssertEqual(pinned, .init(rows: 2, initialServed: 2, ownerPinned: 2, reason: "owner_pinned"))
        XCTAssertTrue(pinned.selfChecked)
    }

    func testAutotuneDerivedStartsAtOneWithRecommendedRows() {
        let pending = plan(configured: 8, source: .autotune, recommended: 4)
        XCTAssertEqual(pending, .init(rows: 4, initialServed: 1, ownerPinned: nil, reason: "self_check_pending"))
    }

    func testProvisionalPolicyEntryKeepsTheConfiguredCount() {
        let provisional = plan(configured: 8, provisional: true, recommended: 4)
        XCTAssertEqual(provisional, .init(rows: 8, initialServed: 8, ownerPinned: nil, reason: "provisional_policy_entry"))
    }

    func testDraftModelAndEmergencyOffForceOneSlotWithoutSelfCheck() {
        let draft = plan(configured: 4, draft: true, provisional: true, recommended: 8)
        XCTAssertEqual(draft.rows, 1)
        XCTAssertEqual(draft.initialServed, 1)
        XCTAssertFalse(draft.selfChecked)
        let off = plan(configured: 4, emergencyOff: true, recommended: 8)
        XCTAssertEqual(off.initialServed, 1)
        XCTAssertFalse(off.selfChecked)
    }

    func testRowsNeverExceedTheServedHardCap() {
        XCTAssertEqual(plan(recommended: 500).rows, ProviderCapacity.maxConcurrencyOverrideLimit)
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

    // MARK: - Provisional grant from the signed policy

    func testPositiveEntryForTheServedModelIsAProvisionalGrant() {
        let keys: Set<String> = ["qwen3.6-35b-a3b"]
        let empty = ContinuousBatchingPolicyLoadResult(
            selection: .emptyOff, status: .absentFallback, policySHA256: nil, signerKeyID: nil
        )
        let live = ContinuousBatchingPolicyLoadResult(
            selection: ContinuousBatchingPolicySelection(
                releaseID: "r", policyVersion: "v", generatedAt: .distantPast, expiresAt: .distantFuture,
                candidateCatalogSHA256: "", signerKeyID: "k", source: "coordinator",
                entries: [Self.entry(modelKey: "qwen3.6-35b-a3b", rollout: .canary)]
            ),
            status: .liveVerified, policySHA256: "p", signerKeyID: "k"
        )
        XCTAssertFalse(AutoServedSlots.policyAuthorizesServedModel(empty, modelKeys: keys, emergencyOff: false))
        XCTAssertTrue(AutoServedSlots.policyAuthorizesServedModel(live, modelKeys: keys, emergencyOff: false))
        XCTAssertFalse(AutoServedSlots.policyAuthorizesServedModel(live, modelKeys: keys, emergencyOff: true))
        XCTAssertFalse(AutoServedSlots.policyAuthorizesServedModel(live, modelKeys: ["llama"], emergencyOff: false))
    }

    // MARK: - Helpers

    private func load(file: String, environment: [String: String] = [:], cli: CLIOverrides = CLIOverrides()) throws -> AppConfig {
        try ConfigLoader.load(cli: cli, environment: environment, fileExists: { _ in true }, readFile: { _ in file })
    }

    static func entry(modelKey: String, rollout: ContinuousBatchingMode) -> ContinuousBatchingPolicyEntry {
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
