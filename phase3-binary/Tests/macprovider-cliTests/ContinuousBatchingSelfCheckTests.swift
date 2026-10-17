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
        // A record from before the decode window was keyed reads as window 0.
        let legacy = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o", runtimeBuild: "r", decodeWindow: 0)
        let record = try XCTUnwrap(store.record(for: legacy))
        XCTAssertEqual(record.inProgressSlots, 5)
        XCTAssertEqual(record.decision?.slots, 4)
    }

    /// SPEC-038 v0.3.16: a result measured at another decode window (or before
    /// the window was keyed) never qualifies the live window. The check re-runs
    /// for it, and the older grant only carries the Mac through the re-run.
    func testResultFromAnotherDecodeWindowDoesNotQualifyThisOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ContinuousBatchingSelfCheckStore.fileName)
        let v6 = """
        {"records":[{"alone_outputs":[],"decided_at":"2026-10-10T00:00:00Z","decision":{"reason":"granted","slots":6,"verified_slots":6},"in_progress_slots":null,"key":{"hardware_class":"h","kernel_identifier":"k","metallib_sha256":"x","model_sha256":"m","os_build":"o","runtime_build":"r"},"measurements":[],"no_gain_streak":0,"remeasure_after":null,"serial_tps":1}],"schema_version":"macprovider.cb-self-check.v6"}
        """
        FileManager.default.createFile(atPath: url.path, contents: Data(v6.utf8), attributes: [.posixPermissions: 0o600])
        let store = ContinuousBatchingSelfCheckStore(url: url)
        let key = ContinuousBatchingSelfCheckKey(modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o", runtimeBuild: "r", decodeWindow: 16)
        XCTAssertNil(store.record(for: key))
        XCTAssertNil(store.decision(for: key))
        XCTAssertEqual(store.priorGrant(for: key), 6)

        var windowOne = key
        windowOne.decodeWindow = 1
        try store.store(.init(
            key: windowOne, decision: .init(slots: 8, reason: "granted", verifiedSlots: 8), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-10T00:00:00Z"
        ))
        XCTAssertNil(store.record(for: key))
        XCTAssertEqual(store.record(for: windowOne)?.decision?.slots, 8)
        let resolution = try XCTUnwrap(ContinuousBatchingSelfCheckResolution.resolve(
            store: store, target: .init(key: key, maxRows: 16), ownerPinned: nil, provisional: nil
        ))
        XCTAssertEqual(resolution.servedSlots, 8)

        // A stored record round-trips its window.
        try store.store(.init(
            key: key, decision: .init(slots: 4, reason: "granted", verifiedSlots: 4), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-10T00:00:00Z"
        ))
        XCTAssertEqual(store.record(for: key)?.key.decodeWindow, 16)
        XCTAssertEqual(store.decision(for: key)?.slots, 4)
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

    /// #1958: a probe submits all k rows at once, so the ladder stops at the
    /// scheduler queue limit instead of probing widths the scheduler refuses
    /// with backpressure (which used to back off for minutes and never grant
    /// above the limit).
    func testQueueLimitBelowThePlannedRowsGrantsUpToTheQueueLimit() {
        let bound = ContinuousBatchingSelfCheck.ladderUpperBound(
            maxRows: 32, ownerPinned: nil, crashedSlots: nil, queueLimit: 16
        )
        XCTAssertEqual(bound, 16)
        let ladder = ContinuousBatchingSelfCheck.ladder(maxRows: bound)
        XCTAssertEqual(ladder.last, 16)
        let measurements = (2...bound).map { m($0, tps: 40 * Double($0)) }
        let decision = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: measurements)
        XCTAssertEqual(decision.reason, "granted")
        XCTAssertEqual(decision.verifiedSlots, 16)
        XCTAssertGreaterThan(decision.slots, 8)
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.servedSlots(decision: decision, ownerPinned: nil, maxRows: 32), decision.slots
        )
        // An owner pin above the queue limit is clamped to what was verified.
        XCTAssertEqual(ContinuousBatchingSelfCheck.servedSlots(decision: decision, ownerPinned: 32, maxRows: 32), 16)

        // The default queue limit (2 x rows) never narrows the ladder.
        let defaultLimit = ContinuousBatchingPolicy.queueLimit(configured: nil, maxActiveRows: 32)
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.ladderUpperBound(maxRows: 32, ownerPinned: nil, crashedSlots: nil, queueLimit: defaultLimit),
            32
        )
        // The other bounds still apply: owner pin, rows, and the crashed width.
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.ladderUpperBound(maxRows: 32, ownerPinned: 8, crashedSlots: nil, queueLimit: 16), 8
        )
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.ladderUpperBound(maxRows: 12, ownerPinned: 32, crashedSlots: nil, queueLimit: 16), 12
        )
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.ladderUpperBound(maxRows: 32, ownerPinned: nil, crashedSlots: 10, queueLimit: 16), 9
        )
    }

    /// #1958: a backpressure refusal of the check's own probe stops the
    /// ladder at that width after one quick retry, without a correctness
    /// result: it never lowers a prior grant and never grows the deferral
    /// backoff once a width is verified.
    func testBackpressureRefusalEndsTheLadderAtThatWidth() {
        typealias Outcome = ContinuousBatchingSelfCheck.BackpressureOutcome
        func outcome(_ prefix: Int, _ slots: Int, _ previous: Int?, prior: Int? = nil) -> Outcome {
            ContinuousBatchingSelfCheck.backpressureOutcome(
                verifiedPrefix: prefix, slots: slots, previousRefusalAt: previous, priorGrant: prior
            )
        }
        XCTAssertEqual(outcome(12, 13, nil), .retrySoon)
        XCTAssertEqual(outcome(12, 13, 13), .endLadder)
        // A refusal at another width is a fresh one.
        XCTAssertEqual(outcome(13, 14, 13), .retrySoon)
        // Nothing verified yet: never a decision, an ordinary deferral.
        XCTAssertEqual(outcome(1, 2, 2), .deferStep)
        // A Mac already serving a wider grant keeps it and resumes later.
        XCTAssertEqual(outcome(12, 13, 13, prior: 16), .pause)
        XCTAssertEqual(outcome(12, 13, nil, prior: 16), .retrySoon)
        XCTAssertEqual(outcome(12, 13, 13, prior: 12), .endLadder)
        // The current served count counts as a prior grant: an owner pin of 32
        // served under a decision of 8 slots verified to 32 is kept.
        XCTAssertEqual(outcome(12, 13, 13, prior: max(32, 8)), .pause)
        XCTAssertEqual(ContinuousBatchingSelfCheck.backpressureResumeSeconds, 3_600)

        // A ladder ended at 13 decides on 2...12, which all passed: neither a
        // divergence nor a crash.
        let measurements = (2...12).map { m($0, tps: 40 * Double($0)) }
        let decision = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: measurements)
        XCTAssertEqual(decision.reason, "granted")
        XCTAssertEqual(decision.verifiedSlots, 12)
    }

    /// #1958: a decision stores the ladder bound it was measured under and
    /// re-runs when the bound grows, unless the ladder stopped below it.
    func testDecisionReachingItsLadderBoundRerunsWhenTheBoundGrows() throws {
        var record = ContinuousBatchingSelfCheckStore.Record(
            key: .init(modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o"),
            decision: .init(slots: 12, reason: "granted", verifiedSlots: 16), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: nil
        )
        // Legacy records carry no bound: unchanged behaviour.
        XCTAssertFalse(ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: 32))
        record.ladderBound = 16
        XCTAssertTrue(ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: 32))
        XCTAssertFalse(ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: 16))
        XCTAssertFalse(ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: 8))
        // Stopped by divergence, crash or backpressure below the bound: no re-run.
        record.decision = .init(slots: 8, reason: "granted", verifiedSlots: 12)
        XCTAssertFalse(ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: 32))
        // A single-row decision under a queue limit of 1 re-runs once it is raised.
        record.decision = .init(slots: 1, reason: "single_row", verifiedSlots: 1)
        record.ladderBound = 1
        XCTAssertTrue(ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: 32))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousBatchingSelfCheckStore(url: directory.appendingPathComponent(ContinuousBatchingSelfCheckStore.fileName))
        try store.store(record)
        XCTAssertEqual(store.record(for: record.key)?.ladderBound, 1)
    }

    // MARK: - Exactness probe (#1971, SPEC-038 v0.3.19)

    /// The Studio near-ties main's self-check accepted (k=8 and k=14, margin
    /// 0.125) were real qmv-to-qmm divergences. The old 1.0-logit rule
    /// excuses them; the v0.3.19 rule excuses only an exact tie.
    func testNearTieToleranceExcusesOnlyAnExactTie() {
        func reference(gap: Float) -> PagedKVRuntimeParityProbe.SerialReference {
            var logits = [Float](repeating: 0, count: 16)
            logits[3] = 24
            logits[7] = 24 - gap
            return .init(top1: 3, top2: 7, logits: logits)
        }
        let studio = reference(gap: 0.125)
        let old = ContinuousBatchingSelfCheck.divergenceVerdict(
            reference: studio, aloneToken: 3, batchedToken: 7, otherRowsAloneTokens: [],
            tolerance: PagedKVRuntimeParityProbe.batchedArgmaxLogitTolerance
        )
        XCTAssertTrue(old.nearTie, "the old rule accepted the Studio flip")
        let new = ContinuousBatchingSelfCheck.divergenceVerdict(
            reference: studio, aloneToken: 3, batchedToken: 7, otherRowsAloneTokens: []
        )
        XCTAssertFalse(new.nearTie)
        XCTAssertEqual(new.margin, 0.125)
        XCTAssertEqual(new.reason, "batched_outside_serial_top2")
        // Smallest bfloat16 step at a logit of 2-4 (1/64) is still a divergence.
        XCTAssertFalse(ContinuousBatchingSelfCheck.divergenceVerdict(
            reference: reference(gap: 1.0 / 64), aloneToken: 3, batchedToken: 7, otherRowsAloneTokens: []
        ).nearTie)
        let tie = ContinuousBatchingSelfCheck.divergenceVerdict(
            reference: reference(gap: 0), aloneToken: 3, batchedToken: 7, otherRowsAloneTokens: []
        )
        XCTAssertTrue(tie.nearTie, "an exact tie may break either way")
        XCTAssertEqual(tie.reason, "near_tie")
        // An exact tie on another row's token is still a leak.
        XCTAssertEqual(ContinuousBatchingSelfCheck.divergenceVerdict(
            reference: reference(gap: 0), aloneToken: 3, batchedToken: 7, otherRowsAloneTokens: [7]
        ).reason, "other_row_token")
        XCTAssertLessThan(ContinuousBatchingSelfCheck.nearTieLogitTolerance, 1.0 / 512)
    }

    /// The route boundary the probe straddles comes from the FR-CB2 vector
    /// attention route table for the device.
    func testProbeStraddlesTheDevicesVectorAttentionRouteBoundary() {
        XCTAssertEqual(ContinuousBatchingSelfCheck.routeKeyBoundary(architecture: "applegpu_g15d"), 1024) // M3 Ultra
        XCTAssertEqual(ContinuousBatchingSelfCheck.routeKeyBoundary(architecture: "applegpu_g16s"), 1024) // M4 Pro/Max
        XCTAssertEqual(ContinuousBatchingSelfCheck.routeKeyBoundary(architecture: "applegpu_g13g"), 4096) // M1
        XCTAssertEqual(ContinuousBatchingSelfCheck.routeKeyBoundary(architecture: "applegpu_g15g"), 4096) // M3
    }

    /// Every width from 2 has rows on both sides of the route boundary, a
    /// row that crosses it mid-completion from 3, unequal lengths, and at
    /// least a serve window of decode tokens per row.
    func testProbeShapeCrossesTheBoundaryWithUnequalRowsAtEveryWidth() {
        for window in [1, 16, 32] {
            let output = ContinuousBatchingSelfCheck.exactnessOutputTokens(decodeWindow: window)
            let required = ContinuousBatchingSelfCheck.requiredCohortDecodeTokens(decodeWindow: window)
            XCTAssertGreaterThanOrEqual(required, 16)
            XCTAssertGreaterThanOrEqual(required, window)
            XCTAssertGreaterThan(output, required, "the first token comes from prefill")
            for boundary in [1024, 4096] {
                for k in 2 ... 32 {
                    let lengths = ContinuousBatchingSelfCheck.exactnessPromptLengths(
                        count: k, keyBoundary: boundary, outputTokens: output
                    )
                    XCTAssertEqual(Set(lengths).count, k, "unequal rows: \(lengths)")
                    XCTAssertTrue(lengths.contains { $0 + output < boundary }, "a row stays below \(boundary)")
                    XCTAssertTrue(lengths.contains { $0 >= boundary }, "a row starts past \(boundary)")
                    if k >= 3 {
                        XCTAssertTrue(
                            lengths.contains { $0 < boundary && $0 + output > boundary },
                            "a row crosses \(boundary) while decoding: \(lengths)"
                        )
                    }
                    XCTAssertTrue(lengths.allSatisfy { $0 < 16_384 })
                }
            }
        }
    }

    /// Fail closed: the ladder never goes past the widest probe shape the
    /// Mac's pool and per-request cap hold, so no wider width is verified.
    func testProbeShapeBoundCapsTheLadderOnSmallPools() throws {
        let key = ContinuousBatchingSelfCheckKey(
            modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o", decodeWindow: 16
        )
        var target = ContinuousBatchingSelfCheckTarget(key: key, maxRows: 16)
        XCTAssertEqual(ContinuousBatchingSelfCheck.ladderUpperBound(target: target, ownerPinned: nil, crashedSlots: nil), 16)
        // Studio class, 16k-token pool: all 16 rows fit.
        target.poolTokens = 16_384
        XCTAssertEqual(ContinuousBatchingSelfCheck.ladderUpperBound(target: target, ownerPinned: nil, crashedSlots: nil), 16)
        // An 8 GB Mac with the 4096 boundary and a 16k pool stops below 16.
        target.probeKeyBoundary = 4096
        let small = ContinuousBatchingSelfCheck.ladderUpperBound(target: target, ownerPinned: nil, crashedSlots: nil)
        XCTAssertGreaterThanOrEqual(small, 5, "an M1/M2 8 GB Mac still probes its 5-row bound")
        XCTAssertLessThan(small, 16)
        let output = ContinuousBatchingSelfCheck.exactnessOutputTokens(decodeWindow: 16)
        let cost = ContinuousBatchingSelfCheck.exactnessPromptLengths(count: small + 1, keyBoundary: 4096, outputTokens: output)
            .compactMap { ContinuousBatchingSelfCheck.exactnessRowCost(promptTokens: $0, outputTokens: output) }
        XCTAssertLessThanOrEqual(cost.prefix(small).reduce(0, +), 16_384)
        XCTAssertGreaterThan(cost.reduce(0, +), 16_384)
        // Rows reserve whole blocks: a larger block size fits fewer rows.
        var coarse = target
        coarse.blockSizeTokens = 1024
        XCTAssertLessThan(ContinuousBatchingSelfCheck.ladderUpperBound(target: coarse, ownerPinned: nil, crashedSlots: nil), small)
        XCTAssertEqual(ContinuousBatchingSelfCheck.exactnessRowCost(promptTokens: 1000, outputTokens: 48, blockSizeTokens: 16), 1184)
        XCTAssertEqual(ContinuousBatchingSelfCheck.exactnessRowCost(promptTokens: 1000, outputTokens: 48, blockSizeTokens: 1024), 2048)
        XCTAssertNil(ContinuousBatchingSelfCheck.exactnessRowCost(promptTokens: .max, outputTokens: 48))
        // A stored grant wider than the shape the Mac holds now is served only
        // up to it, like one above the scheduler rows.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-probe-shape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousBatchingSelfCheckStore(configPath: directory.appendingPathComponent("config.yaml").path)
        try store.store(.init(
            key: key, decision: .init(slots: 16, reason: "granted", verifiedSlots: 16), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-13T00:00:00Z"
        ))
        XCTAssertEqual(target.grantableRows, small)
        var queued = target
        queued.queueLimit = 4
        XCTAssertEqual(queued.grantableRows, 4, "a grant never serves above the queue limit either")
        XCTAssertEqual(
            ContinuousBatchingSelfCheckResolution.resolve(store: store, target: target, ownerPinned: nil, provisional: nil)?
                .servedSlots,
            small
        )
        XCTAssertEqual(
            ContinuousBatchingSelfCheckResolution.resolve(
                store: store, target: target, ownerPinned: nil,
                provisional: .init(modelSHA256: "other", slots: 16)
            )?.servedSlots,
            small
        )
        // A served context too short for a row past the boundary verifies nothing.
        target.maxRequestTokens = 4096
        XCTAssertEqual(ContinuousBatchingSelfCheck.ladderUpperBound(target: target, ownerPinned: nil, crashedSlots: nil), 1)
        XCTAssertEqual(target.grantableRows, 1)
        // The configured bounds still apply below the shape bound.
        target.maxRequestTokens = .max
        target.poolTokens = .max
        XCTAssertEqual(ContinuousBatchingSelfCheck.ladderUpperBound(target: target, ownerPinned: 8, crashedSlots: nil), 8)
    }

    /// A width whose probe rows never all decoded together is not verified:
    /// the decision uses the widths below it, and a prior grant above them is
    /// lowered to them.
    func testUnmetProbeShapeGrantsNoWidthItDidNotVerify() {
        let none = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: [], probeShapeUnmetAt: 2)
        XCTAssertEqual(none, .init(slots: 1, reason: "probe_shape_unmet_at_2", verifiedSlots: 1))
        let reconciledNone = ContinuousBatchingSelfCheck.reconcile(
            fresh: none, priorGrant: 8, serialTPS: 50, measurements: [], previousStreak: 0
        )
        XCTAssertEqual(reconciledNone.decision.slots, 1, "a prior grant is not kept above what was verified")

        let measurements = (2...11).map { m($0, tps: 40 * Double($0)) }
        let partial = ContinuousBatchingSelfCheck.decide(serialTPS: 50, measurements: measurements, probeShapeUnmetAt: 12)
        XCTAssertEqual(partial.reason, "granted")
        XCTAssertEqual(partial.verifiedSlots, 11)
        let reconciled = ContinuousBatchingSelfCheck.reconcile(
            fresh: partial, priorGrant: 16, serialTPS: 50, measurements: measurements, previousStreak: 0
        )
        XCTAssertLessThanOrEqual(reconciled.decision.slots, 11)
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.servedSlots(decision: reconciled.decision, ownerPinned: 16, maxRows: 16), 11
        )
    }

    /// Probe prompts are cut to exact token lengths and keep the chat
    /// template's closing tokens.
    func testProbePromptsAreCutToExactLengthsKeepingTheTemplateClose() {
        let close = [900, 901, 902]
        let a = [1, 2] + Array(10 ..< 2_000) + close
        let b = [1, 2] + Array(5_000 ..< 5_100) + close
        let tail = ContinuousBatchingSelfCheck.commonSuffixLength(a, b)
        XCTAssertEqual(tail, 3)
        let fitted = ContinuousBatchingSelfCheck.fitPrompt(a, tail: tail, length: 1_030)
        XCTAssertEqual(fitted?.count, 1_030)
        XCTAssertEqual(Array(fitted?.suffix(3) ?? []), close)
        XCTAssertEqual(Array(fitted?.prefix(4) ?? []), [1, 2, 10, 11])
        XCTAssertNil(ContinuousBatchingSelfCheck.fitPrompt(b, tail: tail, length: 1_030), "too short to cut")
        XCTAssertNil(ContinuousBatchingSelfCheck.fitPrompt(a, tail: 5, length: 5))
        let lengths = ContinuousBatchingSelfCheck.exactnessPromptLengths(count: 8, keyBoundary: 4096, outputTokens: 48)
        let texts = ContinuousBatchingSelfCheck.exactnessTexts(lengths: lengths)
        XCTAssertEqual(texts.count, 8)
        XCTAssertEqual(Set(texts).count, 8)
        for (text, length) in zip(texts, lengths) {
            XCTAssertTrue(text.hasPrefix("Answer this: "))
            // Generous: each note paragraph is far more than 50 tokens' text.
            XCTAssertGreaterThan(text.count, length * 3)
        }
    }

    /// SPEC-038 FR-CB10 v0.3.21: the batched rate is the cohort's decode
    /// tokens over the common span (the longest row's), never a sum of
    /// per-row spans; no decode beside the whole cohort is no rate.
    func testCohortDecodeRateIsTotalTokensOverTheCommonSpan() {
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.cohortDecodeTPS(tokens: [47, 47, 47, 47], seconds: [1.0, 1.0, 0.98, 0.99]),
            188, accuracy: 1e-9
        )
        XCTAssertEqual(ContinuousBatchingSelfCheck.cohortDecodeTPS(tokens: [0, 0], seconds: [0, 0]), 0)
        XCTAssertEqual(ContinuousBatchingSelfCheck.cohortDecodeTPS(tokens: [16, 16], seconds: [0, 0]), 0)
        XCTAssertEqual(ContinuousBatchingSelfCheck.cohortDecodeTPS(tokens: [16, 16], seconds: []), 0)
        XCTAssertEqual(ContinuousBatchingSelfCheck.cohortDecodeTPS(tokens: [16, 16], seconds: [.nan, 0.5]), 64, accuracy: 1e-9)
    }

    /// The throughput passes time decode only on both sides (v0.3.21): the
    /// batch runs as a cohort and its rate comes from the cohort span, the
    /// serial side from the stock decode rate.
    func testThroughputPassesCompareDecodeRatesOnly() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("idPrefix: \"cb-self-check-\\(attempt)-k\\(slots)-p\\(pass)\",\n                            cohort: true"))
        XCTAssertTrue(source.contains("let serial = serialRate.decodeTPS"))
        XCTAssertTrue(source.contains("let aggregate = ContinuousBatchingSelfCheck.cohortDecodeTPS("))
    }

    /// Changing the probe changes what a stored result means: the key moves,
    /// a stored refusal re-runs, and a stored grant keeps the Mac serving
    /// through the re-run.
    func testProbeVersionBumpRerunsTheCheckAndKeepsAStoredGrantMeanwhile() throws {
        let live = ModelRuntime.continuousBatchingSelfCheckRuntimeBuild(forwardBound: 11, routeKeyBoundary: 1024)
        XCTAssertTrue(live.hasSuffix("+\(ContinuousBatchingSelfCheck.probeVersion)/route1024"), live)
        XCTAssertNotEqual(live, ModelRuntime.continuousBatchingSelfCheckRuntimeBuild(forwardBound: 11, routeKeyBoundary: 4096))
        XCTAssertEqual(ContinuousBatchingSelfCheck.probeVersion, "cb-probe-v3")
        let v1 = "\(ContinuousBatchingSelfCheckKey.currentRuntimeBuild)+cb-isolation-v1/decode11/verify11"
        XCTAssertNotEqual(live, v1)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-probe-v2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContinuousBatchingSelfCheckStore(configPath: directory.appendingPathComponent("config.yaml").path)
        var before = ContinuousBatchingSelfCheckKey(
            modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o", decodeWindow: 16
        )
        before.runtimeBuild = v1
        var after = before
        after.runtimeBuild = live
        let target = ContinuousBatchingSelfCheckTarget(key: after, maxRows: 16)
        try store.store(.init(
            key: before, decision: .init(slots: 1, reason: "row_divergence_at_12", verifiedSlots: 11), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-12T00:00:00Z"
        ))
        XCTAssertNil(store.decision(for: after))
        XCTAssertNil(ContinuousBatchingSelfCheckResolution.resolve(store: store, target: target, ownerPinned: nil, provisional: nil))
        try store.store(.init(
            key: before, decision: .init(slots: 16, reason: "granted", verifiedSlots: 16), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: "2026-10-12T00:00:00Z"
        ))
        XCTAssertNil(store.decision(for: after))
        let resolution = ContinuousBatchingSelfCheckResolution.resolve(store: store, target: target, ownerPinned: nil, provisional: nil)
        XCTAssertEqual(resolution?.servedSlots, 16)
        XCTAssertEqual(resolution?.report.decision, "prior_grant_pending_recheck")
        // The probe's lone outputs persist with the record (a deferred ladder resumes).
        var record = ContinuousBatchingSelfCheckStore.Record(
            key: after, decision: nil, serialTPS: 0, measurements: [], aloneOutputs: [], inProgressSlots: 3, decidedAt: nil
        )
        record.probeAloneOutputs = [[1, 2], [3, 4]]
        try store.store(record)
        XCTAssertEqual(store.record(for: after)?.probeAloneOutputs, [[1, 2], [3, 4]])
    }

    /// A crash before any width or serial baseline exists (the first probe,
    /// or a re-measure that reset the baseline) is a correctness result, so
    /// it does not keep a prior grant as a throughput result would.
    func testCrashBeforeAnySerialBaselineRevokesAPriorGrant() {
        let crashed = ContinuousBatchingSelfCheck.decide(serialTPS: 0, measurements: [], crashedAt: 2)
        XCTAssertEqual(crashed, .init(slots: 1, reason: "crashed_at_2", verifiedSlots: 1))
        let reconciled = ContinuousBatchingSelfCheck.reconcile(
            fresh: crashed, priorGrant: 16, serialTPS: 0, measurements: [], previousStreak: 0
        )
        XCTAssertEqual(reconciled.decision.slots, 1)
        let unmet = ContinuousBatchingSelfCheck.decide(serialTPS: 0, measurements: [], probeShapeUnmetAt: 2)
        XCTAssertEqual(unmet.reason, "probe_shape_unmet_at_2")
        // A first-width probe divergence leaves no serial baseline either.
        let diverged = ContinuousBatchingSelfCheck.decide(serialTPS: 0, measurements: [m(2, exact: false, tps: 0)])
        XCTAssertEqual(diverged, .init(slots: 1, reason: "row_divergence_at_2", verifiedSlots: 1))
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.reconcile(
                fresh: diverged, priorGrant: 16, serialTPS: 0, measurements: [m(2, exact: false, tps: 0)], previousStreak: 0
            ).decision.reason,
            "row_divergence_at_2"
        )
    }

    /// Stored lone outputs are reused only for the prompt they were generated
    /// from, at the probe's completion length.
    func testStoredProbeLoneOutputsAreReusedOnlyForTheirOwnPrompts() {
        let prompts = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
        let digests = prompts.map(ContinuousBatchingSelfCheck.promptSHA256)
        XCTAssertEqual(Set(digests).count, 3)
        let outputs = [[10, 11], [12, 13], [14, 15]]
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.reusableLoneOutputs(outputs, digests: digests, prompts: prompts, outputTokens: 2),
            outputs
        )
        var changed = prompts
        changed[1] = [4, 5, 7]
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.reusableLoneOutputs(outputs, digests: digests, prompts: changed, outputTokens: 2),
            [[10, 11]]
        )
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.reusableLoneOutputs(outputs, digests: digests, prompts: prompts, outputTokens: 3), []
        )
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.reusableLoneOutputs(outputs, digests: [], prompts: prompts, outputTokens: 2), []
        )
        XCTAssertEqual(
            ContinuousBatchingSelfCheck.reusableLoneOutputs([[10, -1]], digests: digests, prompts: prompts, outputTokens: 2), []
        )
    }

    /// A Mac that could not hold two probe rows re-runs once its bound grows.
    func testProbeShapeUnavailableRerunsWhenTheShapeFits() {
        var record = ContinuousBatchingSelfCheckStore.Record(
            key: .init(modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o"),
            decision: .init(slots: 1, reason: "probe_shape_unavailable", verifiedSlots: 1), serialTPS: 0,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: nil
        )
        record.ladderBound = 1
        XCTAssertFalse(ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: 1))
        XCTAssertTrue(ContinuousBatchingSelfCheck.ladderBoundGrew(record: record, currentBound: 2))
    }

    /// The store is owner-only: a file other users can read is ignored.
    func testStoreIgnoresAFileReadableByOtherUsers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-self-check-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ContinuousBatchingSelfCheckStore.fileName)
        let store = ContinuousBatchingSelfCheckStore(url: url)
        let key = ContinuousBatchingSelfCheckKey(
            modelSHA256: "m", metallibSHA256: "x", kernelIdentifier: "k", hardwareClass: "h", osBuild: "o"
        )
        try store.store(.init(
            key: key, decision: .init(slots: 4, reason: "granted", verifiedSlots: 4), serialTPS: 1,
            measurements: [], aloneOutputs: [], inProgressSlots: nil, decidedAt: nil
        ))
        XCTAssertNotNil(store.record(for: key))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertNil(store.record(for: key))
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
