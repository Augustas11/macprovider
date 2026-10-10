import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-038 v0.3.15 on-device continuous-batching self-check.
final class ContinuousBatchingSelfCheckTests: XCTestCase {
    private func m(_ slots: Int, exact: Bool = true, tps: Double) -> ContinuousBatchingSelfCheckMeasurement {
        .init(slots: slots, conformant: exact, aggregateTPS: tps)
    }

    // MARK: - Decision

    func testIdenticalRowsWithAGainEnableBatching() {
        let decision = ContinuousBatchingSelfCheck.decide(
            serialTPS: 50,
            measurements: [m(2, tps: 90), m(3, tps: 125), m(4, tps: 160)]
        )
        XCTAssertEqual(decision, .init(slots: 4, reason: "granted", verifiedSlots: 4))
        XCTAssertEqual(decision.state, .granted(slots: 4))
    }

    func testRowDivergenceAtTwoServesSerially() {
        let decision = ContinuousBatchingSelfCheck.decide(
            serialTPS: 50,
            measurements: [m(2, exact: false, tps: 95)]
        )
        XCTAssertEqual(decision, .init(slots: 1, reason: "row_divergence_at_2", verifiedSlots: 1))
        XCTAssertEqual(decision.state, .refused(reason: "row_divergence_at_2"))
    }

    func testDivergenceAboveAKernelSwitchCapsTheGrantBelowIt() {
        // M1/M2: MLX switches quantized matmul kernels at 6 rows.
        let decision = ContinuousBatchingSelfCheck.decide(
            serialTPS: 40,
            measurements: [m(2, tps: 70), m(3, tps: 95), m(4, tps: 120), m(5, tps: 140), m(6, exact: false, tps: 170)]
        )
        XCTAssertEqual(decision.slots, 5)
    }

    /// Review: an owner pin may lower the served count, never raise it past
    /// the highest slot count the isolation check verified.
    func testOwnerPinIsClampedToTheVerifiedSlots() {
        // M1: rows 6+ diverge; verified up to 5, granted 5.
        let m1 = ContinuousBatchingSelfCheck.decide(
            serialTPS: 40,
            measurements: [m(2, tps: 70), m(3, tps: 95), m(4, tps: 120), m(5, tps: 140), m(6, exact: false, tps: 170)]
        )
        XCTAssertEqual(m1.verifiedSlots, 5)
        XCTAssertEqual(ContinuousBatchingSelfCheck.servedSlots(decision: m1, ownerPinned: 8, maxRows: 8), 5)
        XCTAssertEqual(ContinuousBatchingSelfCheck.servedSlots(decision: m1, ownerPinned: 3, maxRows: 8), 3)
        XCTAssertEqual(ContinuousBatchingSelfCheck.servedSlots(decision: m1, ownerPinned: nil, maxRows: 8), 5)
        let refused = ContinuousBatchingSelfCheck.decide(serialTPS: 40, measurements: [m(2, exact: false, tps: 70)])
        XCTAssertEqual(ContinuousBatchingSelfCheck.servedSlots(decision: refused, ownerPinned: 8, maxRows: 8), 1)
    }

    /// Review: a step that crashed the process (e.g. Metal OOM) keeps what
    /// passed below it and is never measured again.
    func testCrashedStepKeepsTheVerifiedPrefix() {
        let partial = ContinuousBatchingSelfCheck.decide(
            serialTPS: 50, measurements: [m(2, tps: 90), m(3, tps: 125)], crashedAt: 4
        )
        XCTAssertEqual(partial, .init(slots: 3, reason: "granted", verifiedSlots: 3))
        let none = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: [], crashedAt: 2)
        XCTAssertEqual(none, .init(slots: 1, reason: "crashed_at_2", verifiedSlots: 1))
    }

    // MARK: - Throughput noise never switches a batching Mac off

    func testProvisionalEightWithNoisyNoGainKeepsEight() {
        // Exact rows, gain 1.1x: below 1.2 but not a clear loss.
        let measurements = [m(2, tps: 50), m(4, tps: 55), m(8, tps: 55)]
        let fresh = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: measurements)
        XCTAssertEqual(fresh.reason, "no_net_gain")
        let kept = ContinuousBatchingSelfCheck.reconcile(
            fresh: fresh, priorGrant: 8, serialTPS: 50, measurements: measurements, previousStreak: 0
        )
        XCTAssertEqual(kept.decision.slots, 8)
        XCTAssertEqual(kept.decision.state, .granted(slots: 8))
        XCTAssertEqual(kept.streak, 0, "noise is not a clear loss")
        XCTAssertNotNil(kept.remeasureAfterSeconds)
        XCTAssertEqual(ContinuousBatchingSelfCheck.servedSlots(decision: kept.decision, ownerPinned: nil, maxRows: 16), 8)
    }

    func testRepeatedClearLossesNeverLowerOrRemoveAPriorGrant() {
        let losing = [m(2, tps: 30), m(4, tps: 35)]
        let fresh = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: losing)
        var streak = 0
        var intervals: [Double] = []
        for round in 1...(ContinuousBatchingSelfCheck.confirmedNoGainStreak + 2) {
            let result = ContinuousBatchingSelfCheck.reconcile(
                fresh: fresh, priorGrant: 4, serialTPS: 50, measurements: losing, previousStreak: streak
            )
            streak = result.streak
            XCTAssertEqual(result.decision.slots, 4, "round \(round): throughput alone never lowers a grant")
            XCTAssertEqual(result.decision.state, .granted(slots: 4))
            intervals.append(try! XCTUnwrap(result.remeasureAfterSeconds))
        }
        XCTAssertEqual(streak, ContinuousBatchingSelfCheck.confirmedNoGainStreak + 2)
        XCTAssertEqual(intervals, intervals.sorted(), "re-measure interval stretches with the streak")
    }

    /// Isolation-only widths between rungs verify rows but are not picked.
    func testIsolationOnlyWidthsVerifyButAreNotGranted() {
        var nine = m(9, tps: 400)
        nine.throughputMeasured = false
        let decision = ContinuousBatchingSelfCheck.decide(
            serialTPS: 50,
            measurements: [m(2, tps: 90), m(8, tps: 150), nine, m(10, exact: false, tps: 50)]
        )
        XCTAssertEqual(decision.verifiedSlots, 9)
        XCTAssertEqual(decision.slots, 8)
    }

    func testCorrectnessStillRevokesOrLowersAPriorGrant() {
        let divergent = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: [m(2, exact: false, tps: 90)])
        XCTAssertEqual(ContinuousBatchingSelfCheck.reconcile(
            fresh: divergent, priorGrant: 8, serialTPS: 50, measurements: [m(2, exact: false, tps: 90)], previousStreak: 0
        ).decision.slots, 1)
        // Verified only to 5: a prior 8 is lowered to 5, not kept at 8.
        let capped = [m(2, tps: 90), m(3, tps: 100), m(4, tps: 110), m(5, tps: 120), m(6, exact: false, tps: 130)]
        let fresh = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: capped)
        let result = ContinuousBatchingSelfCheck.reconcile(
            fresh: fresh, priorGrant: 8, serialTPS: 50, measurements: capped, previousStreak: 0
        )
        XCTAssertEqual(ContinuousBatchingSelfCheck.servedSlots(decision: result.decision, ownerPinned: nil, maxRows: 16), 5)
    }

    func testThroughputCannotLowerAPriorGrantBelowWhatWasVerified() {
        // Fresh pick is 2 by the tie band, prior grant 8, verified to 8: keep 8.
        let flat = [m(2, tps: 100), m(4, tps: 101), m(8, tps: 102)]
        let fresh = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: flat)
        XCTAssertEqual(fresh.slots, 2)
        let result = ContinuousBatchingSelfCheck.reconcile(
            fresh: fresh, priorGrant: 8, serialTPS: 50, measurements: flat, previousStreak: 0
        )
        XCTAssertEqual(result.decision.slots, 8)
        // A fresh Mac with no prior grant keeps the 1.2x rule.
        XCTAssertEqual(ContinuousBatchingSelfCheck.reconcile(
            fresh: fresh, priorGrant: nil, serialTPS: 50, measurements: flat, previousStreak: 0
        ).decision, fresh)
    }

    func testPriorGrantComesFromAnOlderRuntimeIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-prior-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousBatchingSelfCheckStore(configPath: directory.appendingPathComponent("config.yaml").path)
        let old = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "old", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o")
        let new = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "new", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o")
        let otherMac = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "new", kernelIdentifier: "k", hardwareClass: "x", osBuild: "o")
        try store.store(.init(
            key: old, decision: .init(slots: 8, reason: "granted", verifiedSlots: 8), serialTPS: 50,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-10T00:00:00Z"
        ))
        XCTAssertEqual(store.priorGrant(for: new), 8)
        XCTAssertNil(store.priorGrant(for: otherMac))
        XCTAssertNil(store.priorGrant(for: old))
    }

    /// Startup and every swap: a stored decision, else an older-runtime or
    /// signed provisional grant for the same model, else nothing.
    func testResolutionPrefersStoredThenPriorAndBindsProvisionalToItsModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousBatchingSelfCheckStore(configPath: directory.appendingPathComponent("config.yaml").path)
        let key = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "new", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o")
        let target = ContinuousBatchingSelfCheckTarget(key: key, maxRows: 16)
        XCTAssertNil(ContinuousBatchingSelfCheckResolution.resolve(store: store, target: target, ownerPinned: nil, provisional: nil))
        // Provisional grant for another model does not apply.
        XCTAssertNil(ContinuousBatchingSelfCheckResolution.resolve(
            store: store, target: target, ownerPinned: nil, provisional: .init(modelSHA256: "other", slots: 8)
        ))
        let provisional = try XCTUnwrap(ContinuousBatchingSelfCheckResolution.resolve(
            store: store, target: target, ownerPinned: nil, provisional: .init(modelSHA256: "m", slots: 8)
        ))
        XCTAssertEqual(provisional.servedSlots, 8)
        XCTAssertEqual(provisional.state, .granted(slots: 8))
        // An older-runtime grant for the same model keeps batching.
        var older = key
        older.runtimeBuild = "old-pin"
        try store.store(.init(
            key: older, decision: .init(slots: 6, reason: "granted", verifiedSlots: 6), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-10T00:00:00Z"
        ))
        XCTAssertEqual(ContinuousBatchingSelfCheckResolution.resolve(
            store: store, target: target, ownerPinned: nil, provisional: nil
        )?.servedSlots, 6)
        // This key's own decision wins, clamped to verified and rows.
        try store.store(.init(
            key: key, decision: .init(slots: 1, reason: "row_divergence_at_2", verifiedSlots: 1), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-10T00:00:00Z"
        ))
        let stored = try XCTUnwrap(ContinuousBatchingSelfCheckResolution.resolve(
            store: store, target: target, ownerPinned: nil, provisional: .init(modelSHA256: "m", slots: 8)
        ))
        XCTAssertEqual(stored.servedSlots, 1)
        XCTAssertEqual(stored.state, .refused(reason: "row_divergence_at_2"))
    }

    /// An owner-pinned provider with a signed positive entry keeps its pin
    /// while its self-check runs (never off from noise).
    func testOwnerPinnedProviderKeepsItsProvisionalGrant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousBatchingSelfCheckStore(configPath: directory.appendingPathComponent("config.yaml").path)
        let key = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o")
        let resolution = try XCTUnwrap(ContinuousBatchingSelfCheckResolution.resolve(
            store: store,
            target: .init(key: key, maxRows: 16),
            ownerPinned: 6,
            provisional: .init(modelSHA256: "m", slots: 6)
        ))
        XCTAssertEqual(resolution.servedSlots, 6)
        XCTAssertEqual(resolution.state, .granted(slots: 6))
    }

    /// An owner pin above an older-runtime grant never widens it before the
    /// new runtime is verified.
    func testOwnerPinDoesNotWidenAnOlderRuntimeGrant() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-pin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousBatchingSelfCheckStore(configPath: directory.appendingPathComponent("config.yaml").path)
        let key = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "new", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o")
        var older = key
        older.runtimeBuild = "old-pin"
        try store.store(.init(
            key: older, decision: .init(slots: 4, reason: "granted", verifiedSlots: 4), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-10T00:00:00Z"
        ))
        let resolution = try XCTUnwrap(ContinuousBatchingSelfCheckResolution.resolve(
            store: store, target: .init(key: key, maxRows: 8), ownerPinned: 8, provisional: nil
        ))
        XCTAssertEqual(resolution.servedSlots, 4)
    }

    /// Records from the earlier v5 candidate still load, crash marker included.
    func testV5StoreRecordsStillLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-v5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ContinuousBatchingSelfCheckStore.fileName)
        let v5 = """
        {"records":[{"alone_outputs":[[1]],"decided_at":null,"decision":{"reason":"granted","slots":4,"verified_slots":4},"in_progress_slots":5,"key":{"hardware_class":"h","kernel_identifier":"k","metallib_sha256":"x","model_sha256":"m","os_build":"o","runtime_build":"r"},"measurements":[],"no_gain_streak":0,"remeasure_after":null,"serial_tps":1}],"schema_version":"macprovider.cb-self-check.v5"}
        """
        FileManager.default.createFile(atPath: url.path, contents: Data(v5.utf8), attributes: [.posixPermissions: 0o600])
        let store = ContinuousBatchingSelfCheckStore(url: url)
        let key = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o", runtimeBuild: "r")
        let record = try XCTUnwrap(store.record(for: key))
        XCTAssertEqual(record.inProgressSlots, 5)
        XCTAssertEqual(record.decision?.slots, 4)
    }

    func testDeferralsBackOffToAtMostFifteenMinutes() {
        XCTAssertEqual(ContinuousBatchingSelfCheck.deferralBackoffSeconds(deferrals: 0, base: 5), 0)
        XCTAssertEqual(ContinuousBatchingSelfCheck.deferralBackoffSeconds(deferrals: 1, base: 5), 10)
        XCTAssertEqual(ContinuousBatchingSelfCheck.deferralBackoffSeconds(deferrals: 3, base: 5), 40)
        XCTAssertEqual(ContinuousBatchingSelfCheck.deferralBackoffSeconds(deferrals: 40, base: 5), 900)
    }

    func testReportCarriesDecisionVerifiedKAndRuntimeIdentity() {
        let key = ContinuousBatchingSelfCheckKey(
            modelSHA256: "a", metallibSHA256: "b", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o"
        )
        let json = ContinuousBatchingSelfCheckReport(
            decision: "granted", servedSlots: 5, verifiedSlots: 6, deferrals: 2, key: key
        ).jsonObject
        XCTAssertEqual(json["decision"] as? String, "granted")
        XCTAssertEqual(json["served_slots"] as? Int, 5)
        XCTAssertEqual(json["verified_k"] as? Int, 6)
        XCTAssertEqual(json["deferrals"] as? Int, 2)
        XCTAssertEqual(json["metallib_sha256"] as? String, "b")
        XCTAssertEqual(json["os_build"] as? String, "o")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    func testNoClearGainServesSerially() {
        let decision = ContinuousBatchingSelfCheck.decide(
            serialTPS: 100,
            measurements: [m(2, tps: 105), m(3, tps: 110), m(4, tps: 118)]
        )
        XCTAssertEqual(decision, .init(slots: 1, reason: "no_net_gain", verifiedSlots: 4))
    }

    func testTiesGoToTheLowerSlotCount() {
        let decision = ContinuousBatchingSelfCheck.decide(
            serialTPS: 50,
            measurements: [m(2, tps: 90), m(3, tps: 120), m(4, tps: 130)]
        )
        XCTAssertEqual(decision.slots, 3)
    }

    func testMissingSerialBaselineServesSerially() {
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.decide(serialTPS: 0, measurements: [m(2, tps: 90)]).reason,
            "serial_baseline_unavailable"
        )
    }

    func testLadderMeasuresEveryCountUpToTheRows() {
        XCTAssertEqual(ContinuousBatchingSelfCheck.ladder(maxRows: 5), [2, 3, 4, 5])
        XCTAssertEqual(ContinuousBatchingSelfCheck.ladder(maxRows: 16), [2, 3, 4, 5, 6, 7, 8, 12, 16])
        XCTAssertEqual(ContinuousBatchingSelfCheck.ladder(maxRows: 1), [])
        let prompts = ContinuousBatchingSelfCheck.promptTexts(count: 32)
        XCTAssertEqual(Set(prompts).count, 32)
        // Unequal prompt lengths in every ladder step from k=4 up.
        let lengths = Set(prompts.prefix(4).map(\.count))
        XCTAssertEqual(lengths.count, 4)
        XCTAssertGreaterThan(prompts[3].count, prompts[0].count * 20)
    }

    // MARK: - Revocation

    func testRevokedTupleIsNeitherCoveredNorSelfChecked() {
        let tuple = Self.studioTuple(metallib: Self.studioMetallib)
        let coverage = ContinuousBatchingAcceptanceCoverage.defaultOn(revocations: [
            ContinuousBatchingRevocation(
                modelKey: "qwen/qwen3.6-35b-a3b",
                modelSHA256: tuple.modelSHA256,
                metallibSHA256: tuple.metallibSHA256,
                kernelIdentifier: tuple.kernelIdentifier
            ),
        ])
        XCTAssertTrue(coverage.isRevoked(tuple))
        XCTAssertFalse(coverage.covers(tuple))
    }

    // MARK: - Store

    func testStoredDecisionIsKeyedOnModelRuntimeAndHardware() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousBatchingSelfCheckStore(configPath: directory.appendingPathComponent("config.yaml").path)
        let key = ContinuousBatchingSelfCheckKey(
            modelSHA256: "a", metallibSHA256: "b", kernelIdentifier: "k", hardwareClass: "h", osBuild: "26.5 (25F71)"
        )
        XCTAssertNil(store.decision(for: key))
        // A step in progress is stored without a decision; on reload that
        // marks a crash at that slot count.
        try store.store(.init(
            key: key, decision: nil, serialTPS: 50, measurements: [m(2, tps: 90)],
            aloneOutputs: [[1, 2], [3, 4]], inProgressSlots: 3, decidedAt: nil
        ))
        XCTAssertNil(store.decision(for: key))
        XCTAssertEqual(store.record(for: key)?.inProgressSlots, 3)
        XCTAssertEqual(store.record(for: key)?.aloneOutputs, [[1, 2], [3, 4]])
        try store.store(.init(
            key: key, decision: .init(slots: 4, reason: "granted", verifiedSlots: 4), serialTPS: 50,
            measurements: [m(2, tps: 90)], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-10T00:00:00Z"
        ))
        XCTAssertEqual(store.decision(for: key), .init(slots: 4, reason: "granted", verifiedSlots: 4))
        let newRuntime = ContinuousBatchingSelfCheckKey(
            modelSHA256: "a", metallibSHA256: "c", kernelIdentifier: "k", hardwareClass: "h", osBuild: "26.5 (25F71)"
        )
        XCTAssertNil(store.decision(for: newRuntime))
        let newOS = ContinuousBatchingSelfCheckKey(
            modelSHA256: "a", metallibSHA256: "b", kernelIdentifier: "k", hardwareClass: "h", osBuild: "26.6 (25G5)"
        )
        XCTAssertNil(store.decision(for: newOS), "evidence from before an OS upgrade is not reused")
        var newRuntime2 = key
        newRuntime2.runtimeBuild = "other-fork-revision/0.32.3+other"
        XCTAssertNil(store.decision(for: newRuntime2), "evidence from an older MLX fork pin is not reused")
        XCTAssertEqual(key.runtimeBuild, ContinuousBatchingSelfCheckKey.currentRuntimeBuild)
        var st = stat()
        XCTAssertEqual(lstat(store.url.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    // MARK: - Studio Qwen3.6 regression: batching never goes off

    static let studioMetallib = "84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf"

    static func studioTuple(metallib: String) -> ContinuousBatchingRequestedTuple {
        ContinuousBatchingRequestedTuple(
            modelID: "qwen/qwen3.6-35b-a3b",
            modelSHA256: "3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1",
            tokenizerSHA256: "eec97aac7c5f9ba9159d4784222300eccf5ff2e6b4aeb193c8c939c912633510",
            chatTemplateSHA256: "9cf4f46deaa06769f3240ada331ac0f348694db48ec2e8b51068935f77bb18f9",
            cacheClass: "mixed",
            kvDType: .fp16,
            requiresMoE: true,
            hardwareClass: "apple-silicon:Apple M3 Ultra:ram-256gb",
            metallibSHA256: metallib,
            kernelIdentifier: "macprovider_paged_kv_gather_v1",
            parityLabel: "",
            poolEpoch: 1
        )
    }

    func testShippedPolicyKeepsTheStudioQwenTupleBatching() throws {
        let data = try XCTUnwrap(Data(base64Encoded: AutotuneStaticInputs.bakedContinuousBatchingPolicyBase64))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        let studio = try XCTUnwrap(entries.first { $0["model_key"] as? String == "qwen/qwen3.6-35b-a3b" })
        XCTAssertNotEqual(studio["rollout"] as? String, "off", "the shipped policy must not revoke the live Studio tuple")

        // No revocation in the shipped policy, so default-on coverage holds on
        // the current runtime and on the next build's Metal library alike.
        let coverage = ContinuousBatchingAcceptanceCoverage.defaultOn(revocations: [])
        XCTAssertTrue(coverage.covers(Self.studioTuple(metallib: Self.studioMetallib)))
        XCTAssertTrue(coverage.covers(Self.studioTuple(metallib: String(repeating: "f", count: 64))))

        // Before its self-check decides, the Studio keeps its configured slots
        // (provisional grant), so a restart on a new build never drops it to one.
        let plan = AutoServedSlots.plan(
            configuredSlots: 8, source: nil, draftConfigured: false, emergencyOff: false,
            provisionalPolicyEntry: true, recommendedSlots: { 16 }
        )
        XCTAssertEqual(plan.initialServed, 8)
        XCTAssertGreaterThanOrEqual(plan.rows, 8)

        // Studio-shaped measurements (exact rows, aggregate gain) grant batching.
        let decision = ContinuousBatchingSelfCheck.decide(
            serialTPS: 95,
            measurements: [m(2, tps: 150), m(3, tps: 190), m(4, tps: 225), m(5, tps: 250),
                           m(6, tps: 270), m(7, tps: 285), m(8, tps: 300)]
        )
        XCTAssertEqual(decision.state, .granted(slots: decision.slots))
        XCTAssertGreaterThan(decision.slots, 1)
    }
}

/// SPEC-048-R016 (v0.1.32) on-device native-MTP qualification.
final class NativeMTPOnDeviceSelfCheckTests: XCTestCase {
    func testIdenticalOutputWithAGainPasses() {
        let verdict = NativeMTPOnDeviceSelfCheck.decide(
            mtpTokens: [1, 2, 3], mtpSeconds: 0.5, ordinaryTokens: [1, 2, 3], ordinarySeconds: 0.8
        )
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.reason, "passed")
    }

    func testTokenMismatchKeepsNativeMTPOff() {
        let verdict = NativeMTPOnDeviceSelfCheck.decide(
            mtpTokens: [1, 2, 4], mtpSeconds: 0.3, ordinaryTokens: [1, 2, 3], ordinarySeconds: 0.8
        )
        XCTAssertEqual(verdict, .init(passed: false, reason: "token_mismatch", speedup: 0))
    }

    func testNoNetGainKeepsNativeMTPOff() {
        let verdict = NativeMTPOnDeviceSelfCheck.decide(
            mtpTokens: [1, 2, 3], mtpSeconds: 0.75, ordinaryTokens: [1, 2, 3], ordinarySeconds: 0.8
        )
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.reason, "no_net_gain")
    }

    func testEmptyReferenceKeepsNativeMTPOff() {
        XCTAssertEqual(
            NativeMTPOnDeviceSelfCheck.decide(mtpTokens: [], mtpSeconds: 0.1, ordinaryTokens: [], ordinarySeconds: 1).reason,
            "empty_output"
        )
    }

    /// The ordinary reference is claimed in the durable replay store and never
    /// released, so a restarted process must not reuse the previous run's
    /// request ids: a replayed id throws and keeps native MTP unadmitted.
    func testOrdinaryReferenceIDsDoNotReplayAcrossProcessRestart() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-mtp-selfcheck-\(UUID().uuidString)")
            .appendingPathComponent("claims", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let fingerprint = Data(repeating: 0x07, count: 32)
        func claimRun(_ authority: ContinuousBatchRuntimeReplayAuthority, nonce: String) throws -> [ContinuousBatchSchedulerReplayClaim] {
            try (0..<NativeMTPOnDeviceSelfCheck.repetitions).map { attempt in
                try authority.claim(ContinuousBatchSchedulerReplayKey(
                    requestID: NativeMTPOnDeviceSelfCheck.ordinaryReferenceRequestID(
                        challengeID: "native-mtp-selftest-journey-0001",
                        runNonce: nonce,
                        attempt: attempt
                    ),
                    fingerprintSHA256: fingerprint
                ))
            }
        }
        let firstProcess = ContinuousBatchRuntimeReplayAuthority(storeURL: storeURL)
        XCTAssertTrue(firstProcess.durableAvailable)
        XCTAssertEqual(try claimRun(firstProcess, nonce: "aaaaaaaa"), [.claimed, .claimed])

        let restarted = ContinuousBatchRuntimeReplayAuthority(storeURL: storeURL)
        // The 1.8.238 failure: same ids after a restart are a durable replay.
        XCTAssertEqual(try claimRun(restarted, nonce: "aaaaaaaa"), [.duplicateSameRequest, .duplicateSameRequest])
        XCTAssertEqual(try claimRun(restarted, nonce: "bbbbbbbb"), [.claimed, .claimed])
        XCTAssertNotEqual(
            NativeMTPOnDeviceSelfCheck.ordinaryReferenceRequestID(challengeID: "c", runNonce: "aaaaaaaa", attempt: 0),
            NativeMTPOnDeviceSelfCheck.ordinaryReferenceRequestID(challengeID: "c", runNonce: "aaaaaaaa", attempt: 1)
        )
    }
}
