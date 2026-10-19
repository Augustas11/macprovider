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

    func testProvisionalGrantStaysWithinAComputableMemoryFit() {
        let bounded = AutoServedSlots.plan(
            configuredSlots: 8, source: nil, draftConfigured: false, emergencyOff: false,
            provisionalPolicyEntry: true, recommendedSlots: { 4 }, memoryFitKnown: true
        )
        XCTAssertEqual(bounded.rows, 4)
        XCTAssertEqual(bounded.initialServed, 4)
        let unknown = AutoServedSlots.plan(
            configuredSlots: 8, source: nil, draftConfigured: false, emergencyOff: false,
            provisionalPolicyEntry: true, recommendedSlots: { 4 }, memoryFitKnown: false
        )
        XCTAssertEqual(unknown.rows, 8)
        XCTAssertEqual(unknown.initialServed, 8)
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

    // MARK: - Signed served-slot ceiling (SPEC-038 FR-CB11 v0.3.22)

    func testPolicyCeilingCapsEveryPlanAndNeverRaisesOne() {
        func capped(
            configured: Int?, source: MaxConcurrencySource?, provisional: Bool,
            recommended: Int, memoryFitKnown: Bool = false, ceiling: Int?
        ) -> AutoServedSlots.Plan {
            AutoServedSlots.plan(
                configuredSlots: configured, source: source, draftConfigured: false, emergencyOff: false,
                provisionalPolicyEntry: provisional, recommendedSlots: { recommended },
                memoryFitKnown: memoryFitKnown, policyCeiling: ceiling
            )
        }
        // Self-check pending: the ladder's rows stop at the ceiling.
        XCTAssertEqual(
            capped(configured: nil, source: nil, provisional: false, recommended: 16, ceiling: 4),
            .init(rows: 4, initialServed: 1, ownerPinned: nil, reason: "self_check_pending")
        )
        // Provisional grant, with and without a computable memory fit.
        XCTAssertEqual(
            capped(configured: 16, source: nil, provisional: true, recommended: 16, memoryFitKnown: true, ceiling: 4),
            .init(rows: 4, initialServed: 4, ownerPinned: nil, reason: "provisional_policy_entry")
        )
        XCTAssertEqual(
            capped(configured: 16, source: nil, provisional: true, recommended: 8, ceiling: 4),
            .init(rows: 4, initialServed: 4, ownerPinned: nil, reason: "provisional_policy_entry")
        )
        // An owner pin above the ceiling is served at the ceiling; the pin
        // itself is kept for a warm swap to another model.
        XCTAssertEqual(
            capped(configured: 8, source: .owner, provisional: false, recommended: 16, ceiling: 4),
            .init(rows: 4, initialServed: 4, ownerPinned: 8, reason: "owner_pinned")
        )
        // A ceiling above the other caps changes nothing.
        XCTAssertEqual(
            capped(configured: nil, source: nil, provisional: false, recommended: 2, ceiling: 4),
            .init(rows: 2, initialServed: 1, ownerPinned: nil, reason: "self_check_pending")
        )
        XCTAssertEqual(
            capped(configured: 2, source: .owner, provisional: false, recommended: 16, ceiling: 4),
            .init(rows: 2, initialServed: 2, ownerPinned: 2, reason: "owner_pinned")
        )
        XCTAssertEqual(
            capped(configured: 2, source: nil, provisional: true, recommended: 3, memoryFitKnown: true, ceiling: 4),
            .init(rows: 3, initialServed: 2, ownerPinned: nil, reason: "provisional_policy_entry")
        )
    }

    func testAbsentPolicyCeilingKeepsEveryPlanUnchanged() {
        let inputs: [(Int?, MaxConcurrencySource?, Bool, Bool, Bool, Int, Bool)] = [
            (nil, nil, false, false, false, 16, false),
            (8, .autotune, false, false, false, 4, false),
            (8, nil, false, false, true, 4, false),
            (8, nil, false, false, true, 4, true),
            (3, .owner, false, false, false, 16, false),
            (4, nil, true, false, true, 8, false),
            (4, nil, false, true, false, 8, false),
        ]
        for (configured, source, draft, off, provisional, recommended, fit) in inputs {
            let before = AutoServedSlots.plan(
                configuredSlots: configured, source: source, draftConfigured: draft, emergencyOff: off,
                provisionalPolicyEntry: provisional, recommendedSlots: { recommended }, memoryFitKnown: fit
            )
            let after = AutoServedSlots.plan(
                configuredSlots: configured, source: source, draftConfigured: draft, emergencyOff: off,
                provisionalPolicyEntry: provisional, recommendedSlots: { recommended }, memoryFitKnown: fit,
                policyCeiling: nil
            )
            XCTAssertEqual(before, after)
        }
    }

    func testPolicyServedSlotCeilingIsTheLowestForTheServedModel() {
        var capped = Self.entry(modelKey: "zai-org/glm-5.3-flash", rollout: .on)
        capped.maxServedSlots = 4
        var tighter = Self.entry(modelKey: "zai-org/glm-5.3-flash", rollout: .canary)
        tighter.maxServedSlots = 2
        var revoked = Self.entry(modelKey: "zai-org/glm-5.3-flash", rollout: .off)
        revoked.maxServedSlots = 1
        let unbounded = Self.entry(modelKey: "zai-org/glm-5.3-flash", rollout: .on)
        func load(_ entries: [ContinuousBatchingPolicyEntry], status: ContinuousBatchingPolicyLoadStatus = .liveVerified) -> ContinuousBatchingPolicyLoadResult {
            ContinuousBatchingPolicyLoadResult(
                selection: ContinuousBatchingPolicySelection(
                    releaseID: "r", policyVersion: "v", generatedAt: .distantPast, expiresAt: .distantFuture,
                    candidateCatalogSHA256: "", signerKeyID: "k", source: "coordinator", entries: entries
                ),
                status: status, policySHA256: "p", signerKeyID: "k"
            )
        }
        let keys: Set<String> = ["zai-org/glm-5.3-flash"]
        XCTAssertEqual(AutoServedSlots.policyServedSlotCeiling(load([capped, unbounded]), modelKeys: keys), 4)
        XCTAssertEqual(AutoServedSlots.policyServedSlotCeiling(load([capped, tighter]), modelKeys: keys), 2)
        // A revocation carries no ceiling; an unverified policy none either.
        XCTAssertEqual(AutoServedSlots.policyServedSlotCeiling(load([capped, revoked]), modelKeys: keys), 4)
        XCTAssertNil(AutoServedSlots.policyServedSlotCeiling(load([unbounded]), modelKeys: keys))
        XCTAssertNil(AutoServedSlots.policyServedSlotCeiling(load([capped], status: .integrityFailureFallback), modelKeys: keys))
        XCTAssertNil(AutoServedSlots.policyServedSlotCeiling(load([capped]), modelKeys: ["qwen/qwen3.6-35b-a3b"]))
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
