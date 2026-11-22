import CryptoKit
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-038 FR-CB9 (#2335): the small-row route decision, the batching
/// refusal on a serial-only process and the disk-cache identity split.
final class SmallMRouteTests: XCTestCase {
    private func inputs(
        mode: ContinuousBatchingMode = .off,
        explicit: Bool = true,
        nativeMTP: NativeMTPMode = .off,
        admission: SmallMRoute.NativeMTPAdmission = .none,
        draft: Bool = false,
        shard: Bool = false,
        autotune: Bool = false,
        switchTargets: Bool = false,
        verdict: SmallMRoute.SelfCheckVerdict = .absent,
        fallback: String? = nil,
        operatorRowInvariant: Bool = false
    ) -> SmallMRoute.Inputs {
        SmallMRoute.Inputs(
            continuousBatching: mode,
            continuousBatchingExplicitlyConfigured: explicit,
            nativeMTPMode: nativeMTP,
            nativeMTPAdmission: admission,
            draftConfigured: draft,
            shardGroupRole: shard,
            autotuneCandidate: autotune,
            otherSwitchTargets: switchTargets,
            selfCheckVerdict: verdict,
            stockOrderFallback: fallback,
            operatorForcesRowInvariant: operatorRowInvariant
        )
    }

    /// Every combination of every input against the rule written out once.
    func testDecisionTableCoversEveryCombination() {
        var serialCount = 0
        var stockOrderCount = 0
        var operatorCount = 0
        var mixedCount = 0
        for mode in [ContinuousBatchingMode.off, .canary, .on] {
            for explicit in [false, true] {
                for nativeMTP in [NativeMTPMode.off, .auto] {
                    for admission in SmallMRoute.NativeMTPAdmission.allCases {
                        for draft in [false, true] {
                            for shard in [false, true] {
                                for autotune in [false, true] {
                                    for switchTargets in [false, true] {
                                        for verdict in SmallMRoute.SelfCheckVerdict.allCases {
                                            for fallback in [nil, SmallMRoute.stockOrderDivergence] {
                                                for operatorRowInvariant in [false, true] {
                                                    let value = inputs(
                                                        mode: mode, explicit: explicit, nativeMTP: nativeMTP,
                                                        admission: admission, draft: draft, shard: shard,
                                                        autotune: autotune, switchTargets: switchTargets, verdict: verdict,
                                                        fallback: fallback, operatorRowInvariant: operatorRowInvariant
                                                    )
                                                    let mtpInactive = nativeMTP == .off
                                                        || admission == .none || admission == .noEntryForModel
                                                    let cbCannotActivate = (explicit && mode == .off) || verdict == .grantsNoBatching
                                                    let expected = mtpInactive && cbCannotActivate
                                                        && !draft && !shard && !autotune && !switchTargets
                                                    let decision = SmallMRoute.decide(value)
                                                    XCTAssertEqual(decision.route == .serialOnly, expected, "\(value.logFields) -> \(decision.reason)")
                                                    if expected { serialCount += 1 }
                                                    // Anything that needs the row-invariant pair process-wide
                                                    // keeps it; native MTP alone takes `mixed` (v0.3.61) when
                                                    // batching can activate with no fallback or operator key;
                                                    // a stock order fallback or the operator key sends a
                                                    // batching process to the pair; every other one takes
                                                    // stock order.
                                                    let otherInvariant = draft || shard || autotune || switchTargets
                                                    let expectedMixed = !mtpInactive && !otherInvariant && !cbCannotActivate
                                                        && fallback == nil && !operatorRowInvariant
                                                    let needsInvariant = otherInvariant || (!mtpInactive && !expectedMixed)
                                                    let expectedRoute: SmallMRoute = needsInvariant
                                                        ? .rowInvariant
                                                        : (expected ? .serialOnly : (fallback != nil || operatorRowInvariant ? .rowInvariant : .stockOrder))
                                                    XCTAssertEqual(decision.route, expectedRoute, "\(value.logFields) -> \(decision.reason)")
                                                    XCTAssertEqual(decision.mixed, expectedMixed, "\(value.logFields) -> \(decision.reason)")
                                                    if expectedMixed { mixedCount += 1 }
                                                    if expectedRoute == .stockOrder { stockOrderCount += 1 }
                                                    // The operator key only ever replaces a stock order decision.
                                                    var withoutOperator = value
                                                    withoutOperator.operatorForcesRowInvariant = false
                                                    let undecided = SmallMRoute.decide(withoutOperator)
                                                    if operatorRowInvariant, undecided.route == .stockOrder {
                                                        XCTAssertEqual(decision, SmallMRoute.Decision(route: .rowInvariant, reason: "operator_row_invariant"), value.logFields)
                                                        operatorCount += 1
                                                    } else {
                                                        XCTAssertEqual(decision, undecided, value.logFields)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(serialCount, 0)
        XCTAssertGreaterThan(stockOrderCount, 0)
        XCTAssertEqual(operatorCount, stockOrderCount)
        XCTAssertGreaterThan(mixedCount, 0)
    }

    /// SPEC-038 FR-CB9 (v0.3.56): config `small_m_route: row_invariant` turns
    /// a stock order decision into the row-invariant route and leaves every
    /// serial-only and row-invariant decision, reason included, as it was.
    /// SPEC-038 FR-CB9 (v0.3.57): a configured further model keeps the
    /// process on the row-invariant route, like another switch target.
    func testConfiguredFurtherModelCountsAsAnotherModel() {
        let startup: Set<String> = ["org/main"]
        XCTAssertFalse(SmallMRoute.servesOtherModels(switchTargets: ["Org/Main"], startupModelIDs: startup, warmModels: []))
        XCTAssertTrue(SmallMRoute.servesOtherModels(switchTargets: ["org/other"], startupModelIDs: startup, warmModels: []))
        XCTAssertTrue(SmallMRoute.servesOtherModels(switchTargets: [String](), startupModelIDs: startup, warmModels: ["org/second"]))
        XCTAssertTrue(SmallMRoute.servesOtherModels(switchTargets: ["org/main"], startupModelIDs: startup, warmModels: ["org/second"]))
    }

    func testOperatorRowInvariantOnlyReplacesStockOrder() {
        let cases: [(SmallMRoute.Inputs, SmallMRoute.Decision)] = [
            (inputs(explicit: false, nativeMTP: .auto, verdict: .absent), .init(route: .rowInvariant, reason: "operator_row_invariant")),
            (inputs(explicit: false, verdict: .staleKey), .init(route: .rowInvariant, reason: "operator_row_invariant")),
            (inputs(explicit: false, verdict: .recheckPending), .init(route: .rowInvariant, reason: "operator_row_invariant")),
            (inputs(mode: .on, verdict: .grantsBatching), .init(route: .rowInvariant, reason: "operator_row_invariant")),
            // v0.3.61: the override replaces `mixed` too.
            (inputs(explicit: false, nativeMTP: .auto, admission: .entryForModel, verdict: .grantsBatching), .init(route: .rowInvariant, reason: "operator_row_invariant")),
            // Serial-only stays serial-only.
            (inputs(), .init(route: .serialOnly, reason: "continuous_batching_off_by_configuration")),
            (inputs(explicit: false, verdict: .grantsNoBatching), .init(route: .serialOnly, reason: "self_check_no_batching")),
            // Row-invariant decisions keep their own reason.
            (inputs(explicit: false, verdict: .grantsBatching, fallback: SmallMRoute.stockOrderCrash), .init(route: .rowInvariant, reason: "stock_order_crash")),
            (inputs(explicit: false, nativeMTP: .auto, admission: .entryForModel, switchTargets: true, verdict: .grantsBatching), .init(route: .rowInvariant, reason: "native_mtp_entry_for_model")),
            (inputs(explicit: false, draft: true), .init(route: .rowInvariant, reason: "draft_model")),
            (inputs(explicit: false, shard: true), .init(route: .rowInvariant, reason: "shard_group")),
            (inputs(explicit: false, autotune: true), .init(route: .rowInvariant, reason: "autotune_candidate")),
            (inputs(explicit: false, switchTargets: true), .init(route: .rowInvariant, reason: "switch_targets")),
        ]
        for (value, unforced) in cases {
            var forced = value
            forced.operatorForcesRowInvariant = true
            XCTAssertEqual(SmallMRoute.decide(value).route == .stockOrder, unforced.reason == "operator_row_invariant", value.logFields)
            XCTAssertEqual(SmallMRoute.decide(forced), unforced, forced.logFields)
            XCTAssertNotEqual(SmallMRoute.decide(forced).route, .stockOrder, forced.logFields)
        }
        // Batching stays possible: the key never makes a process serial-only.
        let forced = inputs(explicit: false, verdict: .grantsBatching, operatorRowInvariant: true)
        XCTAssertNil(SmallMRoute.batchingRefusal(route: SmallMRoute.decide(forced).route, entry: "serve"))
        XCTAssertTrue(forced.logFields.hasSuffix(" operator_small_m_route=row_invariant"))
        XCTAssertFalse(inputs(explicit: false).logFields.contains("operator_small_m_route"))
    }

    /// Native MTP's verify window (depth + 1 rows of one request) must equal
    /// that request's one-row decode (SPEC-048 R015/R016), which only the
    /// row-invariant pair gives from three rows: a native request never runs
    /// stock order. A process whose native MTP may activate takes the
    /// row-invariant route or `mixed` (v0.3.61), where every native request
    /// runs the row-invariant route; a plain stock order process refuses the
    /// drafter, a `mixed` one loads it.
    func testNativeMTPThatMayActivateNeverRunsStockOrder() {
        for admission in SmallMRoute.NativeMTPAdmission.allCases where admission.mayActivate {
            for mode in [ContinuousBatchingMode.off, .canary, .on] {
                for explicit in [false, true] {
                    for verdict in SmallMRoute.SelfCheckVerdict.allCases {
                        let value = inputs(mode: mode, explicit: explicit, nativeMTP: .auto, admission: admission, verdict: verdict)
                        let decision = SmallMRoute.decide(value)
                        if decision.mixed {
                            XCTAssertEqual(decision.route, .stockOrder, value.logFields)
                            XCTAssertEqual(decision.reason, "native_mtp_per_request", value.logFields)
                        } else {
                            XCTAssertEqual(decision.route, .rowInvariant, value.logFields)
                        }
                        let nativeRoute = SmallMRoute.requestRoute(
                            nativeAdmitted: true, processRoute: decision.route, mixed: decision.mixed)
                        XCTAssertEqual(nativeRoute, .rowInvariant, value.logFields)
                    }
                }
            }
        }
        XCTAssertEqual(ModelRuntime.nativeMTPActivationRefusal(mode: .auto, route: .stockOrder, mixed: false), "small_m_route_stock_order")
        XCTAssertNil(ModelRuntime.nativeMTPActivationRefusal(mode: .auto, route: .stockOrder, mixed: true))
        XCTAssertEqual(ModelRuntime.nativeMTPActivationRefusal(mode: .auto, route: .serialOnly, mixed: true), "small_m_route_serial_only")
        XCTAssertNil(ModelRuntime.nativeMTPActivationRefusal(mode: .auto, route: .rowInvariant, mixed: false))
    }

    func testDecisionReasons() {
        let cases: [(SmallMRoute.Inputs, SmallMRoute, String)] = [
            (inputs(), .serialOnly, "continuous_batching_off_by_configuration"),
            // Native MTP auto with no admission set for the model stays inactive.
            (inputs(nativeMTP: .auto), .serialOnly, "continuous_batching_off_by_configuration"),
            (inputs(nativeMTP: .auto, admission: .noEntryForModel), .serialOnly, "continuous_batching_off_by_configuration"),
            (inputs(nativeMTP: .auto, admission: .entryForModel), .rowInvariant, "native_mtp_entry_for_model"),
            (inputs(nativeMTP: .auto, admission: .unverifiable), .rowInvariant, "native_mtp_unverifiable"),
            (inputs(nativeMTP: .off, admission: .entryForModel), .serialOnly, "continuous_batching_off_by_configuration"),
            // The ordinary install: implicit CB default, native MTP auto.
            (inputs(explicit: false, nativeMTP: .auto, verdict: .absent), .stockOrder, "self_check_verdict_absent"),
            (inputs(explicit: false, nativeMTP: .auto, verdict: .grantsNoBatching), .serialOnly, "self_check_no_batching"),
            (inputs(explicit: false, verdict: .staleKey), .stockOrder, "self_check_key_changed"),
            (inputs(explicit: false, verdict: .recheckPending), .stockOrder, "self_check_recheck_pending"),
            (inputs(explicit: false, verdict: .grantsBatching), .stockOrder, "self_check_grants_batching"),
            (inputs(mode: .on, verdict: .grantsNoBatching), .serialOnly, "self_check_no_batching"),
            // An 8 GB Mac whose probe shape does not fit (#2325): default
            // config, stored `probe_shape_unavailable`.
            (
                inputs(explicit: false, nativeMTP: .auto, verdict: SmallMRouteVerdictStore.verdict(record: Self.record(
                    Self.key(), decision: .init(slots: 1, reason: "probe_shape_unavailable", verifiedSlots: 1)
                ))),
                .serialOnly, "self_check_no_batching"
            ),
            (inputs(mode: .canary, verdict: .absent), .stockOrder, "self_check_verdict_absent"),
            (inputs(draft: true), .rowInvariant, "draft_model"),
            (inputs(shard: true), .rowInvariant, "shard_group"),
            (inputs(autotune: true), .rowInvariant, "autotune_candidate"),
            (inputs(switchTargets: true), .rowInvariant, "switch_targets"),
            // Batching is possible, but another need keeps the pair.
            (inputs(explicit: false, nativeMTP: .auto, admission: .entryForModel, switchTargets: true, verdict: .grantsBatching), .rowInvariant, "native_mtp_entry_for_model"),
            (inputs(explicit: false, draft: true, verdict: .grantsBatching), .rowInvariant, "draft_model"),
            (inputs(explicit: false, switchTargets: true, verdict: .grantsBatching), .rowInvariant, "switch_targets"),
        ]
        for (value, route, reason) in cases {
            XCTAssertEqual(SmallMRoute.decide(value), SmallMRoute.Decision(route: route, reason: reason), value.logFields)
        }
    }

    func testOnlyAVerdictCanMoveTheNextStart() {
        XCTAssertTrue(SmallMRoute.verdictDecidesNextStart(inputs(explicit: false, nativeMTP: .auto)))
        // Explicit off is already serial; no verdict is needed.
        XCTAssertFalse(SmallMRoute.verdictDecidesNextStart(inputs()))
        XCTAssertTrue(SmallMRoute.verdictDecidesNextStart(inputs(explicit: false, nativeMTP: .auto, admission: .noEntryForModel)))
        XCTAssertFalse(SmallMRoute.verdictDecidesNextStart(inputs(explicit: false, nativeMTP: .auto, admission: .entryForModel)))
        XCTAssertFalse(SmallMRoute.verdictDecidesNextStart(inputs(explicit: false, autotune: true)))
    }

    func testStartupEventNamesEveryCondition() {
        let value = inputs(explicit: false, nativeMTP: .auto, verdict: .grantsNoBatching)
        XCTAssertEqual(
            SmallMRoute.event(SmallMRoute.decide(value), fields: value.logFields),
            "event=small_m_route mode=serial_only reason=self_check_no_batching cb=off/implicit native_mtp=auto mtp_admission=none draft=false shard=false autotune_candidate=false switch_targets=false self_check=grants_no_batching\n"
        )
    }

    private static let bakedFeed = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("dist/static/native-mtp-admission.json")

    /// The baked static feed every ordinary install fetches names only its
    /// admitted models; any other loaded model resolves to no entry.
    func testBakedFeedResolvesPerLoadedModel() throws {
        let data = try Data(contentsOf: Self.bakedFeed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let glm = try XCTUnwrap(entries.first { $0["model_key"] as? String == "zai-org/glm-5.3-flash" })
        let glmHash = try XCTUnwrap(glm["artifact_hash"] as? String)
        XCTAssertEqual(
            SmallMRoute.nativeMTPAdmission(sidecarURL: Self.bakedFeed, modelID: "zai-org/glm-5.3-flash", modelRevision: glmHash),
            .entryForModel
        )
        XCTAssertEqual(
            SmallMRoute.nativeMTPAdmission(
                sidecarURL: Self.bakedFeed, modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                modelRevision: String(repeating: "c", count: 64)
            ),
            .noEntryForModel
        )
        // The admitted model under another artifact digest has no entry either.
        XCTAssertEqual(
            SmallMRoute.nativeMTPAdmission(
                sidecarURL: Self.bakedFeed, modelID: "zai-org/glm-5.3-flash",
                modelRevision: String(repeating: "c", count: 64)
            ),
            .noEntryForModel
        )
    }

    func testAdmissionSetRowsFailTowardsTheInvariantRoute() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-m-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("native-mtp-admission.json")
        let signature = directory.appendingPathComponent("native-mtp-admission.json.sig")
        let key = Curve25519.Signing.PrivateKey()
        let keyring = NativeMTPAdmissionSidecar.TrustedKeyring(
            publicKeysByKeyID: ["test-key": key.publicKey.rawRepresentation.base64EncodedString()],
            requiredKeyID: "test-key"
        )
        let hash = String(repeating: "a", count: 64)
        func write(_ body: String, signedBy signer: Curve25519.Signing.PrivateKey? = nil) throws {
            let bytes = Data(body.utf8)
            try bytes.write(to: sidecar)
            let signatureBytes = try (signer ?? key).signature(for: bytes).base64EncodedString()
            try Data(#"{"key_id":"test-key","alg":"ed25519","signature":"\#(signatureBytes)"}"#.utf8).write(to: signature)
        }
        func resolve(_ model: String = "org/model") -> SmallMRoute.NativeMTPAdmission {
            SmallMRoute.nativeMTPAdmission(sidecarURL: sidecar, modelID: model, modelRevision: hash, trustedKeyring: keyring)
        }
        XCTAssertEqual(resolve(), .none)
        try write(#"{"entries":[{"model_key":"org/other","artifact_hash":"\#(hash)"}]}"#)
        XCTAssertEqual(resolve(), .noEntryForModel)
        XCTAssertEqual(resolve("org/other"), .entryForModel)
        // An entry the loader could not be ruled out for counts as a match.
        try write(#"{"entries":[{"model_key":"org/other"}]}"#)
        XCTAssertEqual(resolve(), .entryForModel)
        try write(#"{"entries":[{"model_key":"org/other","artifact_hash":"\#(hash)"}]}"#, signedBy: Curve25519.Signing.PrivateKey())
        XCTAssertEqual(resolve(), .unverifiable)
        try write("not json")
        XCTAssertEqual(resolve(), .unverifiable)
        try write(#"{"entries":{}}"#)
        XCTAssertEqual(resolve(), .unverifiable)
        try write(#"{"entries":[{"model_key":"org/other","artifact_hash":"\#(hash)"}]}"#)
        try FileManager.default.removeItem(at: signature)
        XCTAssertEqual(resolve(), .unverifiable)
    }

    func testSerialOnlyProcessRefusesNativeMTPActivation() {
        XCTAssertEqual(ModelRuntime.nativeMTPActivationRefusal(mode: .auto, route: .serialOnly), "small_m_route_serial_only")
        XCTAssertNil(ModelRuntime.nativeMTPActivationRefusal(mode: .auto, route: .rowInvariant))
        XCTAssertEqual(ModelRuntime.nativeMTPActivationRefusal(mode: .off, route: .rowInvariant), "mode_not_auto")
        XCTAssertEqual(ModelRuntime.nativeMTPActivationRefusal(mode: .auto, route: .stockOrder), "small_m_route_stock_order")
        XCTAssertEqual(ModelRuntime.nativeMTPActivationRefusal(mode: .off, route: .stockOrder), "mode_not_auto")
    }

    private static func key(_ model: String = String(repeating: "a", count: 64)) -> ContinuousBatchingSelfCheckKey {
        ContinuousBatchingSelfCheckKey(
            modelSHA256: model, metallibSHA256: String(repeating: "b", count: 64),
            kernelIdentifier: "k", hardwareClass: "apple-test", osBuild: "os"
        )
    }

    private static func record(
        _ key: ContinuousBatchingSelfCheckKey,
        decision: ContinuousBatchingSelfCheckDecision?,
        remeasureAfter: String? = nil,
        inProgressSlots: Int? = nil
    ) -> ContinuousBatchingSelfCheckStore.Record {
        ContinuousBatchingSelfCheckStore.Record(
            key: key, decision: decision, serialTPS: 10, measurements: [], aloneOutputs: [],
            inProgressSlots: inProgressSlots, decidedAt: nil, remeasureAfter: remeasureAfter
        )
    }

    func testVerdictFromTheSelfCheckRecord() {
        let noGain = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "no_net_gain", verifiedSlots: 4)
        let granted = ContinuousBatchingSelfCheckDecision(slots: 4, reason: "granted", verifiedSlots: 4)
        XCTAssertEqual(SmallMRouteVerdictStore.verdict(record: nil), .staleKey)
        XCTAssertEqual(SmallMRouteVerdictStore.verdict(record: Self.record(Self.key(), decision: noGain)), .grantsNoBatching)
        XCTAssertEqual(SmallMRouteVerdictStore.verdict(record: Self.record(Self.key(), decision: granted)), .grantsBatching)
        XCTAssertEqual(SmallMRouteVerdictStore.verdict(record: Self.record(Self.key(), decision: nil)), .recheckPending)
        XCTAssertEqual(
            SmallMRouteVerdictStore.verdict(record: Self.record(Self.key(), decision: noGain, remeasureAfter: "2026-11-14T00:00:00Z")),
            .recheckPending
        )
        XCTAssertEqual(
            SmallMRouteVerdictStore.verdict(record: Self.record(Self.key(), decision: noGain, inProgressSlots: 2)),
            .recheckPending
        )
    }

    /// Only a one-row decision that settles the key moves a start to the
    /// serial route; one that re-runs on bound growth keeps the invariant
    /// route, the only one where the self-check can run.
    func testOnlySettledOneRowReasonsGrantNoBatching() {
        let table: [(String, SmallMRoute.SelfCheckVerdict)] = [
            ("no_net_gain", .grantsNoBatching),
            ("row_divergence_at_2", .grantsNoBatching),
            ("row_divergence_at_4", .grantsNoBatching),
            ("crashed_at_3", .grantsNoBatching),
            ("single_row", .grantsNoBatching),
            ("serial_baseline_unavailable", .recheckPending),
            ("probe_shape_unmet_at_2", .recheckPending),
            // Its bound is fixed by identity-keyed quantities (#2325).
            ("probe_shape_unavailable", .grantsNoBatching),
            ("kept_prior_grant_no_net_gain", .recheckPending),
        ]
        for (reason, expected) in table {
            let decision = ContinuousBatchingSelfCheckDecision(slots: 1, reason: reason, verifiedSlots: 1)
            XCTAssertEqual(SmallMRouteVerdictStore.verdict(record: Self.record(Self.key(), decision: decision)), expected, reason)
        }
    }

    func testOneRowDecisionBehindTheVerdict() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("small-m-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let selfCheck = ContinuousBatchingSelfCheckStore(url: directory.appendingPathComponent("cb-self-check.json"))
        let store = SmallMRouteVerdictStore(selfCheckStore: selfCheck)
        let identity = SmallMRouteVerdictStore.startupIdentity(["model": "m"])
        let divergence = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "row_divergence_at_2", verifiedSlots: 1)
        XCTAssertNil(store.oneRowDecision(startupIdentity: identity, selfCheckStore: selfCheck))
        try selfCheck.store(Self.record(Self.key(), decision: divergence))
        XCTAssertTrue(store.record(startupIdentity: identity, key: Self.key(), decision: divergence))
        let stored = try XCTUnwrap(store.oneRowDecision(startupIdentity: identity, selfCheckStore: selfCheck))
        XCTAssertEqual(stored.key, Self.key())
        XCTAssertEqual(stored.decision, divergence)
        // A key that re-checks gives no decision to report.
        let unmet = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "probe_shape_unmet_at_2", verifiedSlots: 1)
        try selfCheck.store(Self.record(Self.key(), decision: unmet))
        XCTAssertNil(store.oneRowDecision(startupIdentity: identity, selfCheckStore: selfCheck))
    }

    func testVerdictStoreAcrossStarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("small-m-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let selfCheck = ContinuousBatchingSelfCheckStore(url: directory.appendingPathComponent("cb-self-check.json"))
        let store = SmallMRouteVerdictStore(selfCheckStore: selfCheck)
        let identity = SmallMRouteVerdictStore.startupIdentity(["model": "m", "load_sha256": "a"])
        XCTAssertNotEqual(identity, SmallMRouteVerdictStore.startupIdentity(["model": "m", "load_sha256": "b"]))
        let noGain = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "no_net_gain", verifiedSlots: 3)

        // First start: nothing recorded.
        XCTAssertEqual(store.verdict(startupIdentity: identity, selfCheckStore: selfCheck), .absent)
        try selfCheck.store(Self.record(Self.key(), decision: noGain))
        let lines = LockedLines()
        let recorder = SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: identity, log: { lines.append($0) }
        )
        recorder.applied(key: Self.key(), decision: noGain)
        XCTAssertEqual(lines.all, ["event=small_m_route action=verdict_recorded decision=no_net_gain slots=1 next_start=serial_only"])
        // A warm-swapped model never writes under the startup identity.
        recorder.applied(key: Self.key(String(repeating: "c", count: 64)), decision: noGain)
        XCTAssertEqual(lines.all.count, 1)

        // Second start: the verdict holds.
        XCTAssertEqual(store.verdict(startupIdentity: identity, selfCheckStore: selfCheck), .grantsNoBatching)
        XCTAssertEqual(store.verdict(startupIdentity: "other", selfCheckStore: selfCheck), .absent)

        // A re-measurement scheduled on the key sends the next start back.
        try selfCheck.store(Self.record(Self.key(), decision: noGain, remeasureAfter: "2026-11-14T00:00:00Z"))
        XCTAssertEqual(store.verdict(startupIdentity: identity, selfCheckStore: selfCheck), .recheckPending)

        // The key's record is gone (key changed): stale.
        let other = ContinuousBatchingSelfCheckStore(url: directory.appendingPathComponent("other.json"))
        XCTAssertEqual(store.verdict(startupIdentity: identity, selfCheckStore: other), .staleKey)

        // A grant forgets the entry.
        let granted = ContinuousBatchingSelfCheckDecision(slots: 2, reason: "granted", verifiedSlots: 2)
        XCTAssertFalse(store.record(startupIdentity: identity, key: Self.key(), decision: granted))
        XCTAssertEqual(store.verdict(startupIdentity: identity, selfCheckStore: selfCheck), .absent)
    }

    /// The recorder runs only where every other serial condition holds, so a
    /// start without a one-row verdict takes the stock order route.
    func testRecordedGrantLogsTheStockOrderNextStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("small-m-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let selfCheck = ContinuousBatchingSelfCheckStore(url: directory.appendingPathComponent("cb-self-check.json"))
        let store = SmallMRouteVerdictStore(selfCheckStore: selfCheck)
        let granted = ContinuousBatchingSelfCheckDecision(slots: 2, reason: "granted", verifiedSlots: 2)
        try selfCheck.store(Self.record(Self.key(), decision: granted))
        let lines = LockedLines()
        let recorder = SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: SmallMRouteVerdictStore.startupIdentity(["model": "m"]),
            log: { lines.append($0) }
        )
        recorder.applied(key: Self.key(), decision: granted)
        XCTAssertEqual(lines.all, ["event=small_m_route action=verdict_recorded decision=granted slots=2 next_start=stock_order"])
    }

    /// The MLX core parses a set value with C `atoi`; 0 is the serial route,
    /// 2 stock order.
    func testEnvironmentValueMapsToTheCoreRoute() {
        let table: [(String?, SmallMRoute)] = [
            (nil, .rowInvariant),
            ("0", .serialOnly), ("", .serialOnly), ("false", .serialOnly), ("off", .serialOnly),
            ("00", .serialOnly), ("-0", .serialOnly), ("+0", .serialOnly), (" 0", .serialOnly),
            ("\t\n0", .serialOnly), ("0x1", .serialOnly), ("0abc", .serialOnly), (" ", .serialOnly),
            ("-", .serialOnly), ("true", .serialOnly), ("x1", .serialOnly),
            ("1", .rowInvariant), ("2", .stockOrder), ("-1", .rowInvariant), (" 1", .rowInvariant),
            ("+1", .rowInvariant), ("01", .rowInvariant), ("1abc", .rowInvariant), ("10", .rowInvariant),
            ("02", .stockOrder), (" 2", .stockOrder), ("+2", .stockOrder), ("2abc", .stockOrder),
            ("-2", .rowInvariant), ("3", .rowInvariant), ("12", .rowInvariant), ("20", .rowInvariant),
            // Darwin's atoi wraps these to 0, so the core takes the serial route.
            ("4294967296", .serialOnly), ("8589934592", .serialOnly),
            // ... and this one to 2.
            ("4294967298", .stockOrder),
        ]
        for (value, expected) in table {
            XCTAssertEqual(SmallMRoute.route(environmentValue: value), expected, String(describing: value))
            if let value {
                let parsed = value.withCString { atoi($0) }
                let core: SmallMRoute = parsed == 0 ? .serialOnly : (parsed == 2 ? .stockOrder : .rowInvariant)
                XCTAssertEqual(SmallMRoute.route(environmentValue: value), core, value)
            }
        }
    }

    /// A serial-only process serves and reports what the row-invariant route
    /// serves for the same Mac: the self-check's served count under a stored
    /// one-row decision, the planned count (the owner pin) with batching off
    /// by configuration.
    func testSerialOnlyServedSlotsMatchTheInvariantRoute() {
        let divergence = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "row_divergence_at_2", verifiedSlots: 1)
        let noGain = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "no_net_gain", verifiedSlots: 3)
        for (decision, pin, servedNow) in [(divergence, 4, 4), (noGain, 4, 4), (noGain, nil, 1), (divergence, nil, 1)] as [(ContinuousBatchingSelfCheckDecision, Int?, Int)] {
            XCTAssertEqual(
                SmallMRoute.serialOnlyServedSlots(stored: decision, ownerPinned: pin, servedNow: servedNow),
                ContinuousBatchingSelfCheck.servedSlots(decision: decision, ownerPinned: pin, maxRows: servedNow)
            )
        }
        XCTAssertEqual(SmallMRoute.serialOnlyServedSlots(stored: divergence, ownerPinned: 4, servedNow: 4), 1)
        XCTAssertEqual(SmallMRoute.serialOnlyServedSlots(stored: noGain, ownerPinned: 4, servedNow: 4), 3)
        XCTAssertEqual(SmallMRoute.serialOnlyServedSlots(stored: nil, ownerPinned: 4, servedNow: 4), 4)
        XCTAssertEqual(SmallMRoute.serialOnlyServedSlots(stored: nil, ownerPinned: nil, servedNow: 1), 1)
        // Configured slots >= 2 but no probe shape fits: one row, as the
        // invariant route serves it, whatever the owner pin.
        let unavailable = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "probe_shape_unavailable", verifiedSlots: 1)
        XCTAssertEqual(SmallMRoute.serialOnlyServedSlots(stored: unavailable, ownerPinned: 4, servedNow: 4), 1)
        XCTAssertEqual(SmallMRoute.serialOnlyServedSlots(stored: unavailable, ownerPinned: nil, servedNow: 2), 1)
    }

    /// The paged-KV pool bounds the exactness probe, so a changed pool is a
    /// new startup identity that re-measures (#2325).
    func testPagedKVPoolKeysTheStartupIdentity() {
        let base = PagedKVConfig(enabled: true)
        let explicitPool = PagedKVConfig(enabled: true, maxPhysicalBlocks: 64, maxPhysicalBlocksExplicit: true)
        let explicitBlock = PagedKVConfig(enabled: true, blockSizeTokens: 32, blockSizeTokensExplicit: true)
        XCTAssertEqual(SmallMRouteVerdictStore.pagedKVPool(base), "16x1024")
        XCTAssertEqual(SmallMRouteVerdictStore.pagedKVPool(explicitPool), "16x64")
        XCTAssertEqual(SmallMRouteVerdictStore.pagedKVPool(base.withFamilyDefaults(modelFamily: "glm5_next")), "256x1024")
        func identity(_ config: PagedKVConfig) -> String {
            SmallMRouteVerdictStore.startupIdentity([
                "model": "m", "paged_kv": "true", "paged_kv_pool": SmallMRouteVerdictStore.pagedKVPool(config),
            ])
        }
        XCTAssertEqual(identity(base), identity(PagedKVConfig(enabled: true)))
        XCTAssertNotEqual(identity(base), identity(explicitPool))
        XCTAssertNotEqual(identity(base), identity(explicitBlock))
        XCTAssertNotEqual(identity(base), identity(base.sizedToCover(contextTokens: 32_768)))
    }

    func testSerialOnlyProcessRefusesEveryBatchingEntry() {
        for entry in ["continuous_batch_scheduler", "ContinuousBatchScheduler", "msb-throughput",
                      "native-mtp-bench", "native-mtp-hardware-e2e", "relay-blind-fixture"] {
            XCTAssertNil(SmallMRoute.batchingRefusal(route: .rowInvariant, entry: entry))
            XCTAssertNil(SmallMRoute.batchingRefusal(route: .stockOrder, entry: entry))
            let refusal = SmallMRoute.batchingRefusal(route: .serialOnly, entry: entry)
            XCTAssertEqual(
                refusal,
                "small_m_route_serial_only: \(entry) batches decode rows, but this process runs the serial-only small-row route (MLX_METAL_SMALL_M_ROW_INVARIANT=0), which is not row-invariant"
            )
        }
    }

    func testTestProcessRunsTheRowInvariantRoute() {
        // The scheduler initialiser asserts this; every scheduler test relies on it.
        XCTAssertEqual(SmallMRoute.processRoute, .rowInvariant)
    }

    func testStartupEventAndStatusField() {
        XCTAssertEqual(
            SmallMRoute.event(.init(route: .serialOnly, reason: "continuous_batching_off_by_configuration")),
            "event=small_m_route mode=serial_only reason=continuous_batching_off_by_configuration\n"
        )
        let fields = RouterHandler.continuousBatchingStatusFields(
            nil, smallMRoute: .serialOnly, smallMRouteReason: "self_check_no_batching"
        )
        XCTAssertEqual(fields["small_m_route"] as? String, "serial_only")
        XCTAssertEqual(fields["small_m_route_reason"] as? String, "self_check_no_batching")
        XCTAssertEqual(RouterHandler.continuousBatchingStatusFields(nil)["small_m_route"] as? String, "row_invariant")
        XCTAssertEqual(
            SmallMRoute.event(.init(route: .stockOrder, reason: "self_check_grants_batching")),
            "event=small_m_route mode=stock_order reason=self_check_grants_batching\n"
        )
        let stock = RouterHandler.continuousBatchingStatusFields(
            nil, smallMRoute: .stockOrder, smallMRouteReason: "self_check_verdict_absent"
        )
        XCTAssertEqual(stock["small_m_route"] as? String, "stock_order")
        XCTAssertEqual(stock["small_m_route_reason"] as? String, "self_check_verdict_absent")
    }

    func testDecodeBenchRouteOption() {
        XCTAssertEqual(decodeBenchSmallMRoute("row-invariant"), .rowInvariant)
        XCTAssertEqual(decodeBenchSmallMRoute("serial-only"), .serialOnly)
        XCTAssertEqual(decodeBenchSmallMRoute("stock-order"), .stockOrder)
        XCTAssertNil(decodeBenchSmallMRoute("serial_only"))
        XCTAssertNil(decodeBenchSmallMRoute("stock_order"))
        XCTAssertNil(decodeBenchSmallMRoute(""))
    }

    func testDiskCacheWrittenOnOneRouteMissesOnTheOther() {
        XCTAssertEqual(SmallMRoute.rowInvariant.kvDecodePath, "ordinary")
        XCTAssertNotEqual(SmallMRoute.serialOnly.kvDecodePath, SmallMRoute.rowInvariant.kvDecodePath)
        // Stock order writes batch-kernel KV from 3+-row forwards, which
        // neither other route produces: its own class.
        XCTAssertEqual(SmallMRoute.stockOrder.kvDecodePath, "ordinary+stock_order_small_m")
        XCTAssertNotEqual(SmallMRoute.stockOrder.kvDecodePath, SmallMRoute.serialOnly.kvDecodePath)
        XCTAssertNotEqual(SmallMRoute.stockOrder.kvDecodePath, SmallMRoute.rowInvariant.kvDecodePath)
        let (reference, runtime) = KVDiskCacheFormatTests.validPair()
        for written in [SmallMRoute.rowInvariant, .serialOnly, .stockOrder] {
            let manifest = KVDiskCacheFormatTests.mutate(reference) { $0.decodePath = written.kvDecodePath }
            for reading in [SmallMRoute.rowInvariant, .serialOnly, .stockOrder] {
                let result = KVEnvelopeValidator.validate(
                    manifest, runtime: Self.runtime(runtime, decodePath: reading.kvDecodePath), nowMillis: 1_000_500
                )
                switch (written == reading, result) {
                case (true, .ok):
                    break
                case (false, .miss(let code, _)):
                    XCTAssertEqual(code, .diskMissEnvelope)
                default:
                    XCTFail("written on \(written.rawValue), read on \(reading.rawValue): \(result)")
                }
            }
        }
    }

    private static func runtime(_ r: KVRuntimeIdentity, decodePath: String) -> KVRuntimeIdentity {
        KVRuntimeIdentity(
            namespaceID: r.namespaceID, keyEpoch: r.keyEpoch, indexHMAC: r.indexHMAC,
            requestModel: r.requestModel, servedModelID: r.servedModelID, modelSHA256: r.modelSHA256,
            catalogRevision: r.catalogRevision, tokenizerID: r.tokenizerID,
            tokenizerConfigSHA256: r.tokenizerConfigSHA256, chatTemplateSHA256: r.chatTemplateSHA256,
            abiEpoch: r.abiEpoch, mlxSwiftLMRevision: r.mlxSwiftLMRevision, mlxVersion: r.mlxVersion,
            cacheClass: r.cacheClass, layerCount: r.layerCount, layers: r.layers,
            kvBits: r.kvBits, kvGroupSize: r.kvGroupSize, kvQuantMode: r.kvQuantMode,
            kvQuantPolicy: r.kvQuantPolicy, decodePath: decodePath, liveHighWatermark: r.liveHighWatermark)
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// SPEC-038 FR-CB9 (v0.3.56, Related: #2389): a failure measured on stock
/// order sends the next start of the same startup identity to the
/// row-invariant route, never to the serial route; a failure measured on the
/// row-invariant route keeps the existing rule.
extension SmallMRouteTests {
    private static func stockKey() -> ContinuousBatchingSelfCheckKey {
        var key = Self.key()
        key.runtimeBuild = ContinuousBatchingSelfCheckKey.currentRuntimeBuild + "+small_m_stock_order"
        return key
    }

    private static func decidedInputs(
        _ store: SmallMRouteVerdictStore,
        _ selfCheck: ContinuousBatchingSelfCheckStore,
        _ identity: String
    ) -> SmallMRoute.Inputs {
        var value = SmallMRoute.Inputs(
            continuousBatching: .off, continuousBatchingExplicitlyConfigured: false, nativeMTPMode: .auto,
            nativeMTPAdmission: .none, draftConfigured: false, shardGroupRole: false, autotuneCandidate: false,
            otherSwitchTargets: false,
            selfCheckVerdict: store.verdict(startupIdentity: identity, selfCheckStore: selfCheck),
            operatorForcesRowInvariant: false
        )
        value.stockOrderFallback = store.stockOrderFallback(startupIdentity: identity)
        return value
    }

    private static func temporaryStores() -> (URL, ContinuousBatchingSelfCheckStore, SmallMRouteVerdictStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("small-m-route-\(UUID().uuidString)")
        let selfCheck = ContinuousBatchingSelfCheckStore(url: directory.appendingPathComponent("cb-self-check.json"))
        return (directory, selfCheck, SmallMRouteVerdictStore(selfCheckStore: selfCheck))
    }

    func testStockOrderDivergenceSendsTheNextStartToRowInvariantAndKeepsThePriorGrant() throws {
        let (directory, selfCheck, store) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = SmallMRouteVerdictStore.startupIdentity(["model": "m", "runtime_build": "r1"])
        // The row-invariant grant this Mac served before the stock order start.
        let prior = ContinuousBatchingSelfCheckDecision(slots: 4, reason: "granted", verifiedSlots: 4)
        try selfCheck.store(Self.record(Self.key(), decision: prior))
        // Stock order: two rows diverged.
        let divergence = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "row_divergence_at_2", verifiedSlots: 1)
        var measured = Self.record(Self.stockKey(), decision: divergence)
        measured.measurements = [.init(slots: 2, conformant: false, aggregateTPS: 0, throughputMeasured: false)]
        try selfCheck.store(measured)
        let lines = LockedLines()
        let recorder = SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: identity, route: .stockOrder, log: { lines.append($0) }
        )
        recorder.applied(key: Self.stockKey(), decision: divergence)
        XCTAssertEqual(lines.all, [
            "event=small_m_route action=verdict_recorded decision=row_divergence_at_2 slots=1 next_start=row_invariant fallback=stock_order_divergence",
        ])
        // No one-row verdict: the next start is row-invariant, not serial-only.
        XCTAssertEqual(store.verdict(startupIdentity: identity, selfCheckStore: selfCheck), .absent)
        XCTAssertNil(store.oneRowDecision(startupIdentity: identity, selfCheckStore: selfCheck))
        let next = SmallMRoute.decide(Self.decidedInputs(store, selfCheck, identity))
        XCTAssertEqual(next, SmallMRoute.Decision(route: .rowInvariant, reason: "stock_order_divergence"))
        XCTAssertTrue(SmallMRoute.verdictDecidesNextStart(Self.decidedInputs(store, selfCheck, identity)))
        // The row-invariant key's grant is untouched and serves until that
        // route re-checks.
        XCTAssertEqual(selfCheck.decision(for: Self.key()), prior)
        XCTAssertEqual(
            ContinuousBatchingSelfCheckResolution.resolve(
                store: selfCheck,
                target: ContinuousBatchingSelfCheckTarget(key: Self.key(), maxRows: 4),
                ownerPinned: nil, provisional: nil
            )?.servedSlots,
            4
        )

        // A divergence above a granted width on stock order falls back too.
        let (other, otherSelfCheck, otherStore) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: other) }
        let granted = ContinuousBatchingSelfCheckDecision(slots: 2, reason: "granted", verifiedSlots: 2)
        var wider = Self.record(Self.stockKey(), decision: granted)
        wider.measurements = [
            .init(slots: 2, conformant: true, aggregateTPS: 30, throughputMeasured: true),
            .init(slots: 3, conformant: false, aggregateTPS: 0, throughputMeasured: false),
        ]
        try otherSelfCheck.store(wider)
        SmallMRouteVerdictRecorder(
            store: otherStore, selfCheckStore: otherSelfCheck, startupIdentity: identity, route: .stockOrder, log: { _ in }
        ).applied(key: Self.stockKey(), decision: granted)
        XCTAssertEqual(otherStore.stockOrderFallback(startupIdentity: identity), "stock_order_divergence")
        // So does a crash; no net gain on stock order is not a stock order failure.
        XCTAssertEqual(
            SmallMRoute.stockOrderFallbackReason(
                decision: .init(slots: 1, reason: "crashed_at_3", verifiedSlots: 2), anyWidthDiverged: false, crashed: true
            ),
            "stock_order_crash"
        )
        XCTAssertNil(SmallMRoute.stockOrderFallbackReason(
            decision: .init(slots: 1, reason: "no_net_gain", verifiedSlots: 4), anyWidthDiverged: false, crashed: false
        ))
    }

    func testAttachFailureOnStockOrderSendsTheNextStartToRowInvariant() {
        let (directory, selfCheck, store) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = SmallMRouteVerdictStore.startupIdentity(["model": "m"])
        let lines = LockedLines()
        // A row-invariant process never records a stock order fallback.
        SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: identity, route: .rowInvariant, log: { lines.append($0) }
        ).stockOrderFailed(reason: SmallMRoute.stockOrderAttachFailed)
        XCTAssertNil(store.stockOrderFallback(startupIdentity: identity))
        let recorder = SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: identity, route: .stockOrder, log: { lines.append($0) }
        )
        recorder.stockOrderFailed(reason: SmallMRoute.stockOrderAttachFailed)
        recorder.stockOrderFailed(reason: SmallMRoute.stockOrderReferenceUnfit)
        XCTAssertEqual(lines.all, [
            "event=small_m_route action=stock_order_fallback_recorded reason=stock_order_attach_failed next_start=row_invariant",
        ])
        XCTAssertEqual(store.stockOrderFallback(startupIdentity: identity), "stock_order_attach_failed", "the first reason stays")
        XCTAssertEqual(
            SmallMRoute.decide(Self.decidedInputs(store, selfCheck, identity)),
            SmallMRoute.Decision(route: .rowInvariant, reason: "stock_order_attach_failed")
        )

        // Which probe results are attach failures.
        func parity(_ established: Bool) -> PagedKVRuntimeParityProbeResult {
            .init(established: established, nLayers: 2, nNew: 4, gatherKernelCalls: 16, maxLogicalBlocks: 3, nonIdentityPermutation: true)
        }
        func isolation(
            proven: Bool, failures: Int = 0, divergences: Int = 0, sharedParity: Bool, distinguishing: Bool
        ) -> PagedKVRuntimeMoEProbeResult {
            .init(
                proven: proven, rowsDecodedInSharedForward: 2, rowFailures: failures, crossRowDivergences: divergences,
                sharedForwardParityProven: sharedParity, parityTokensCompared: 32, challengeDistinguishing: distinguishing
            )
        }
        let passing = isolation(proven: true, sharedParity: true, distinguishing: true)
        XCTAssertFalse(SmallMRoute.attachProbeFailed(parity: nil, isolation: nil), "not run")
        XCTAssertFalse(SmallMRoute.attachProbeFailed(parity: parity(true), isolation: nil), "not run")
        XCTAssertFalse(SmallMRoute.attachProbeFailed(parity: parity(true), isolation: passing))
        XCTAssertTrue(SmallMRoute.attachProbeFailed(parity: parity(false), isolation: passing))
        XCTAssertTrue(SmallMRoute.attachProbeFailed(
            parity: parity(true), isolation: isolation(proven: false, divergences: 1, sharedParity: false, distinguishing: true)
        ))
        XCTAssertTrue(SmallMRoute.attachProbeFailed(
            parity: parity(true), isolation: isolation(proven: false, failures: 1, sharedParity: false, distinguishing: true)
        ))
        XCTAssertTrue(SmallMRoute.attachProbeFailed(
            parity: parity(true), isolation: isolation(proven: false, sharedParity: false, distinguishing: true)
        ))
        XCTAssertFalse(
            SmallMRoute.attachProbeFailed(
                parity: parity(true), isolation: isolation(proven: false, sharedParity: false, distinguishing: false)
            ),
            "a challenge that cannot distinguish its rows proves nothing either way"
        )
    }

    func testStockOrderFallbackIsStickyAcrossStartsAndNeverLoops() throws {
        let (directory, selfCheck, store) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = SmallMRouteVerdictStore.startupIdentity(["model": "m", "runtime_build": "r1"])
        XCTAssertTrue(store.recordStockOrderFallback(startupIdentity: identity, reason: SmallMRoute.stockOrderDivergence))
        let granted = ContinuousBatchingSelfCheckDecision(slots: 4, reason: "granted", verifiedSlots: 4)
        let noGain = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "no_net_gain", verifiedSlots: 4)
        try selfCheck.store(Self.record(Self.key(), decision: granted))
        // Start 2 and 3 run row-invariant; their grants keep the fallback.
        for _ in 0 ..< 2 {
            XCTAssertEqual(SmallMRoute.decide(Self.decidedInputs(store, selfCheck, identity)).route, .rowInvariant)
            let lines = LockedLines()
            SmallMRouteVerdictRecorder(
                store: store, selfCheckStore: selfCheck, startupIdentity: identity, route: .rowInvariant, log: { lines.append($0) }
            ).applied(key: Self.key(), decision: granted)
            XCTAssertEqual(lines.all, ["event=small_m_route action=verdict_recorded decision=granted slots=4 next_start=row_invariant"])
            XCTAssertEqual(store.stockOrderFallback(startupIdentity: identity), "stock_order_divergence")
        }
        // A one-row verdict measured on the row-invariant route then decides
        // as it always did: serial-only, which never measures again.
        try selfCheck.store(Self.record(Self.key(), decision: noGain))
        SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: identity, route: .rowInvariant, log: { _ in }
        ).applied(key: Self.key(), decision: noGain)
        XCTAssertEqual(SmallMRoute.decide(Self.decidedInputs(store, selfCheck, identity)).route, .serialOnly)
        // A re-check scheduled on that key returns to row-invariant, never to stock order.
        try selfCheck.store(Self.record(Self.key(), decision: noGain, remeasureAfter: "2026-11-16T00:00:00Z"))
        XCTAssertEqual(
            SmallMRoute.decide(Self.decidedInputs(store, selfCheck, identity)),
            SmallMRoute.Decision(route: .rowInvariant, reason: "stock_order_divergence")
        )
        // A stock-order-measured one-row verdict recorded before the fallback
        // is dropped with it, so a stock order failure never ends serial-only.
        let (other, otherSelfCheck, otherStore) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: other) }
        try otherSelfCheck.store(Self.record(Self.stockKey(), decision: noGain))
        XCTAssertTrue(otherStore.record(startupIdentity: identity, key: Self.stockKey(), decision: noGain, route: .stockOrder))
        XCTAssertEqual(otherStore.verdict(startupIdentity: identity, selfCheckStore: otherSelfCheck), .grantsNoBatching)
        otherStore.recordStockOrderFallback(startupIdentity: identity, reason: SmallMRoute.stockOrderReferenceUnfit)
        XCTAssertEqual(otherStore.verdict(startupIdentity: identity, selfCheckStore: otherSelfCheck), .absent)
        XCTAssertEqual(SmallMRoute.decide(Self.decidedInputs(otherStore, otherSelfCheck, identity)).route, .rowInvariant)
    }

    func testNewRuntimeBuildReDecidesTheRoute() {
        let (directory, selfCheck, store) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = SmallMRouteVerdictStore.startupIdentity(["model": "m", "runtime_build": "r1"])
        let new = SmallMRouteVerdictStore.startupIdentity(["model": "m", "runtime_build": "r2"])
        XCTAssertNotEqual(old, new)
        store.recordStockOrderFallback(startupIdentity: old, reason: SmallMRoute.stockOrderAttachFailed)
        XCTAssertEqual(SmallMRoute.decide(Self.decidedInputs(store, selfCheck, old)).route, .rowInvariant)
        XCTAssertEqual(
            SmallMRoute.decide(Self.decidedInputs(store, selfCheck, new)),
            SmallMRoute.Decision(route: .stockOrder, reason: "self_check_verdict_absent")
        )
    }

    func testDivergenceOnRowInvariantKeepsTheSerialRule() throws {
        let (directory, selfCheck, store) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = SmallMRouteVerdictStore.startupIdentity(["model": "m"])
        let divergence = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "row_divergence_at_2", verifiedSlots: 1)
        var measured = Self.record(Self.key(), decision: divergence)
        measured.measurements = [.init(slots: 2, conformant: false, aggregateTPS: 0, throughputMeasured: false)]
        try selfCheck.store(measured)
        let lines = LockedLines()
        SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: identity, route: .rowInvariant, log: { lines.append($0) }
        ).applied(key: Self.key(), decision: divergence)
        XCTAssertEqual(lines.all, ["event=small_m_route action=verdict_recorded decision=row_divergence_at_2 slots=1 next_start=serial_only"])
        XCTAssertNil(store.stockOrderFallback(startupIdentity: identity))
        XCTAssertEqual(
            SmallMRoute.decide(Self.decidedInputs(store, selfCheck, identity)),
            SmallMRoute.Decision(route: .serialOnly, reason: "self_check_no_batching")
        )
        // No net gain measured on stock order also keeps the serial rule.
        let (other, otherSelfCheck, otherStore) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: other) }
        let noGain = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "no_net_gain", verifiedSlots: 4)
        try otherSelfCheck.store(Self.record(Self.stockKey(), decision: noGain))
        SmallMRouteVerdictRecorder(
            store: otherStore, selfCheckStore: otherSelfCheck, startupIdentity: identity, route: .stockOrder, log: { _ in }
        ).applied(key: Self.stockKey(), decision: noGain)
        XCTAssertEqual(SmallMRoute.decide(Self.decidedInputs(otherStore, otherSelfCheck, identity)).route, .serialOnly)
    }

    /// LOW-7: the core's partial-sum count is never inherited outside lab
    /// builds, so a row-invariant or native-MTP process keeps its bits.
    func testInheritedPartialSumCountIsRemoved() {
        setenv(SmallMRoute.partialSumsEnvironmentKey, "8", 1)
        defer { unsetenv(SmallMRoute.partialSumsEnvironmentKey) }
        #if MACPROVIDER_LAB_HARNESS
        XCTAssertFalse(SmallMRoute.removeInheritedPartialSums())
        XCTAssertNotNil(getenv(SmallMRoute.partialSumsEnvironmentKey))
        #else
        XCTAssertTrue(SmallMRoute.removeInheritedPartialSums())
        XCTAssertNil(getenv(SmallMRoute.partialSumsEnvironmentKey))
        XCTAssertFalse(SmallMRoute.removeInheritedPartialSums())
        // `apply` and `requireRowInvariant` (which calls `apply`) remove it
        // even when this process already applied its route.
        setenv(SmallMRoute.partialSumsEnvironmentKey, "8", 1)
        SmallMRoute.apply(.rowInvariant, reason: "test")
        XCTAssertNil(getenv(SmallMRoute.partialSumsEnvironmentKey))
        #endif
        XCTAssertEqual(SmallMRoute.partialSumsEnvironmentKey, "MLX_METAL_QMV_MMA_WK")
    }
}

/// SPEC-038 FR-CB9 (v0.3.61, Related: #2462): `mixed` runs each native request
/// on the row-invariant route and every other request on stock order.
extension SmallMRouteTests {
    func testNativeMTPWithNoOtherNeedDecidesMixed() {
        for admission in [SmallMRoute.NativeMTPAdmission.entryForModel, .unverifiable] {
            for verdict in [SmallMRoute.SelfCheckVerdict.absent, .grantsBatching, .recheckPending, .staleKey] {
                let value = inputs(explicit: false, nativeMTP: .auto, admission: admission, verdict: verdict)
                XCTAssertEqual(
                    SmallMRoute.decide(value),
                    SmallMRoute.Decision(route: .stockOrder, reason: "native_mtp_per_request", mixed: true),
                    value.logFields
                )
                XCTAssertEqual(SmallMRoute.decide(value).mode, "mixed")
            }
        }
        let explicitOn = inputs(mode: .on, nativeMTP: .auto, admission: .entryForModel, verdict: .grantsBatching)
        XCTAssertTrue(SmallMRoute.decide(explicitOn).mixed)
    }

    func testMixedFallsBackToProcessWideRowInvariant() {
        let admitted = { (value: SmallMRoute.Inputs) -> SmallMRoute.Inputs in
            var value = value
            value.nativeMTPMode = .auto
            value.nativeMTPAdmission = .entryForModel
            return value
        }
        let cases: [(SmallMRoute.Inputs, String)] = [
            // E4: another need keeps the pair process-wide.
            (admitted(inputs(explicit: false, switchTargets: true)), "native_mtp_entry_for_model"),
            (admitted(inputs(explicit: false, draft: true)), "draft_model"),
            (admitted(inputs(explicit: false, shard: true)), "shard_group"),
            (admitted(inputs(explicit: false, autotune: true)), "autotune_candidate"),
            // No batching: no row ever shares a forward on another route.
            (admitted(inputs(mode: .off, explicit: true)), "native_mtp_entry_for_model"),
            (admitted(inputs(explicit: false, verdict: .grantsNoBatching)), "native_mtp_entry_for_model"),
            // A measured stock order failure disables mixed.
            (admitted(inputs(explicit: false, fallback: "stock_order_row_divergence_at_3")), "stock_order_row_divergence_at_3"),
            (admitted(inputs(explicit: false, operatorRowInvariant: true)), "operator_row_invariant"),
        ]
        for (value, reason) in cases {
            let decision = SmallMRoute.decide(value)
            XCTAssertEqual(decision, SmallMRoute.Decision(route: .rowInvariant, reason: reason), value.logFields)
            XCTAssertFalse(decision.mixed, value.logFields)
            XCTAssertEqual(decision.mode, "row_invariant", value.logFields)
        }
        // Native MTP that cannot activate never takes mixed.
        for admission in [SmallMRoute.NativeMTPAdmission.none, .noEntryForModel] {
            XCTAssertFalse(SmallMRoute.decide(inputs(explicit: false, nativeMTP: .auto, admission: admission)).mixed)
        }
        XCTAssertFalse(SmallMRoute.decide(inputs(explicit: false, nativeMTP: .off, admission: .entryForModel)).mixed)
    }

    func testRequestRouteFollowsAdmissionOnlyInMixed() {
        XCTAssertEqual(SmallMRoute.requestRoute(nativeAdmitted: true, processRoute: .stockOrder, mixed: true), .rowInvariant)
        XCTAssertEqual(SmallMRoute.requestRoute(nativeAdmitted: false, processRoute: .stockOrder, mixed: true), .stockOrder)
        for route in [SmallMRoute.rowInvariant, .stockOrder, .serialOnly] {
            for native in [false, true] {
                XCTAssertEqual(SmallMRoute.requestRoute(nativeAdmitted: native, processRoute: route, mixed: false), route)
            }
        }
        // The test process is not mixed: every request takes the process route.
        XCTAssertFalse(SmallMRoute.processMixed)
        XCTAssertEqual(SmallMRoute.requestRoute(nativeAdmitted: true), SmallMRoute.processRoute)
        XCTAssertEqual(SmallMRoute.requestRoute(nativeAdmitted: false), SmallMRoute.processRoute)
    }

    func testMixedStartupEventAndStatusFields() {
        XCTAssertEqual(
            SmallMRoute.event(.init(route: .stockOrder, reason: "native_mtp_per_request", mixed: true)),
            "event=small_m_route mode=mixed reason=native_mtp_per_request\n"
        )
        let mixed = RouterHandler.continuousBatchingStatusFields(
            nil, smallMRoute: .stockOrder, smallMRouteReason: "native_mtp_per_request",
            smallMRouteMixed: true, smallMRouteRequests: ["stock_order": 3, "row_invariant": 1],
            smallMRouteAdmissions: ["native_admitted": 1, "native_active": 2, "idle": 3]
        )
        XCTAssertEqual(mixed["small_m_route"] as? String, "mixed")
        XCTAssertEqual(mixed["small_m_route_reason"] as? String, "native_mtp_per_request")
        XCTAssertEqual(mixed["small_m_route_requests"] as? [String: Int], ["stock_order": 3, "row_invariant": 1])
        XCTAssertEqual(mixed["small_m_route_admissions"] as? [String: Int], ["native_admitted": 1, "native_active": 2, "idle": 3])
        let plain = RouterHandler.continuousBatchingStatusFields(
            nil, smallMRoute: .stockOrder, smallMRouteReason: "self_check_grants_batching", smallMRouteMixed: false
        )
        XCTAssertEqual(plain["small_m_route"] as? String, "stock_order")
        XCTAssertNil(plain["small_m_route_requests"])
        XCTAssertNil(plain["small_m_route_admissions"])
    }

    func testRequestCounterTracksInFlightRequestsPerRoute() async {
        let counter = SmallMRouteRequestCounter()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
        counter.begin(.rowInvariant)
        counter.begin(.stockOrder)
        counter.begin(.stockOrder)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 2, "row_invariant": 1])
        let inside = await counter.tracking(.rowInvariant) { counter.snapshot() }
        XCTAssertEqual(inside, ["stock_order": 2, "row_invariant": 2])
        counter.end(.stockOrder)
        counter.end(.rowInvariant)
        counter.end(.rowInvariant)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 1, "row_invariant": 0])
    }

    func testAdmissionRouteJoinsRowInvariantWhileOneIsInFlight() {
        func route(_ native: Bool, _ inFlight: Int, mixed: Bool = true, process: SmallMRoute = .stockOrder)
            -> (SmallMRoute, SmallMRoute.AdmissionReason)
        {
            let r = SmallMRoute.admissionRoute(
                nativeAdmitted: native, rowInvariantInFlight: inFlight, processRoute: process, mixed: mixed)
            return (r.route, r.reason)
        }
        XCTAssertTrue(route(true, 0) == (.rowInvariant, .nativeAdmitted))
        XCTAssertTrue(route(true, 2) == (.rowInvariant, .nativeAdmitted))
        XCTAssertTrue(route(false, 0) == (.stockOrder, .idle))
        XCTAssertTrue(route(false, 1) == (.rowInvariant, .nativeActive))
        XCTAssertTrue(route(false, 3) == (.rowInvariant, .nativeActive))
        // v0.3.64: a reusable stored conversation-cache entry decides ahead of the
        // requests in flight; v0.3.65: a stock order entry beside row-invariant ones
        // only when the reused prefill costs more than the split.
        func stored(
            _ inFlight: Int, _ entry: SmallMRoute?, cached: Int = 1_384, own: Int? = 64, remaining: Int? = 900
        ) -> (SmallMRoute, SmallMRoute.AdmissionReason) {
            let r = SmallMRoute.admissionRoute(
                nativeAdmitted: false, rowInvariantInFlight: inFlight, storedRoute: entry,
                reusableCachedTokens: cached, maxOutputTokens: own, rowInvariantRemainingTokens: remaining,
                processRoute: .stockOrder, mixed: true)
            return (r.route, r.reason)
        }
        XCTAssertTrue(stored(0, .rowInvariant) == (.rowInvariant, .conversationCache))
        XCTAssertTrue(stored(0, .stockOrder) == (.stockOrder, .conversationCache))
        XCTAssertTrue(stored(0, .stockOrder, own: 1_024) == (.stockOrder, .conversationCache))
        XCTAssertTrue(stored(0, .serialOnly) == (.stockOrder, .idle))
        // Nothing reusable: as if no entry.
        XCTAssertTrue(stored(0, .rowInvariant, cached: 0) == (.stockOrder, .idle))
        XCTAssertTrue(stored(1, .stockOrder, cached: 0) == (.rowInvariant, .nativeActive))
        // Split chosen: 1384 cached > min(64, 900) x 8 = 512.
        XCTAssertTrue(stored(1, .stockOrder) == (.stockOrder, .conversationCache))
        // Join chosen: 1384 cached <= min(1024, 900) x 8 = 7200.
        XCTAssertTrue(stored(1, .stockOrder, own: 1_024) == (.rowInvariant, .conversationCacheJoin))
        // The shorter budget decides the overlap: min(1024, 100) x 8 = 800 < 1384.
        XCTAssertTrue(stored(1, .stockOrder, own: 1_024, remaining: 100) == (.stockOrder, .conversationCache))
        // Unknown overlap joins.
        XCTAssertTrue(stored(1, .stockOrder, own: nil, remaining: nil) == (.rowInvariant, .conversationCacheJoin))
        // A row-invariant entry beside row-invariant requests keeps its route.
        XCTAssertTrue(stored(2, .rowInvariant, own: 1_024) == (.rowInvariant, .conversationCache))
        XCTAssertTrue(stored(1, .serialOnly) == (.rowInvariant, .nativeActive))
        XCTAssertTrue(stored(1, nil) == (.rowInvariant, .nativeActive))
        XCTAssertEqual(SmallMRoute.splitStepPrefillTokens, 8)
        XCTAssertEqual(SmallMRoute.expectedOverlapTokens(maxOutputTokens: 64, rowInvariantRemainingTokens: 900), 64)
        XCTAssertNil(SmallMRoute.expectedOverlapTokens(maxOutputTokens: nil, rowInvariantRemainingTokens: nil))
        XCTAssertFalse(SmallMRoute.keepsStoredRouteBesideRowInvariant(reusableCachedTokens: .max, overlapTokens: .max))
        XCTAssertTrue(SmallMRoute.admissionRoute(
            nativeAdmitted: true, rowInvariantInFlight: 0, storedRoute: .stockOrder, reusableCachedTokens: 100,
            processRoute: .stockOrder, mixed: true
        ) == (.rowInvariant, .nativeAdmitted))
        // Outside mixed every request takes the process route.
        for process in [SmallMRoute.rowInvariant, .stockOrder, .serialOnly] {
            for native in [false, true] {
                for inFlight in [0, 1] {
                    XCTAssertTrue(route(native, inFlight, mixed: false, process: process) == (process, .processRoute))
                }
            }
        }
    }

    func testOrdinaryAdmittedWhenIdleGetsStockOrder() {
        let counter = SmallMRouteRequestCounter()
        let lines = AdmissionLogLines()
        let a = counter.admit(nativeAdmitted: false, processRoute: .stockOrder, mixed: true, log: lines.append)
        XCTAssertEqual(a.route, .stockOrder)
        XCTAssertEqual(a.reason, .idle)
        // Stock order rows in flight do not move the next ordinary request.
        let b = counter.admit(nativeAdmitted: false, processRoute: .stockOrder, mixed: true, log: lines.append)
        XCTAssertEqual(b.route, .stockOrder)
        XCTAssertEqual(b.reason, .idle)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 2, "row_invariant": 0])
        XCTAssertEqual(lines.all, [
            "event=small_m_route_admission route=stock_order reason=idle in_flight_row_invariant=0 in_flight_stock_order=0 joinable_row_invariant=0\n",
            "event=small_m_route_admission route=stock_order reason=idle in_flight_row_invariant=0 in_flight_stock_order=1 joinable_row_invariant=0\n",
        ])
        a.end()
        b.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
        XCTAssertEqual(counter.admissionSnapshot(), ["native_admitted": 0, "native_active": 0, "conversation_cache": 0, "conversation_cache_join": 0, "idle": 2])
        // Not mixed: the process route, counted, and no admission line.
        let quiet = AdmissionLogLines()
        let c = counter.admit(nativeAdmitted: true, processRoute: .rowInvariant, mixed: false, log: quiet.append)
        XCTAssertEqual(c.route, .rowInvariant)
        XCTAssertEqual(c.reason, .processRoute)
        XCTAssertTrue(quiet.all.isEmpty)
        c.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
    }

    func testOrdinaryAdmittedWithANativeRowActiveStaysRowInvariantAfterItFinishes() {
        let counter = SmallMRouteRequestCounter()
        let lines = AdmissionLogLines()
        func admit(_ native: Bool) -> SmallMRouteRequestCounter.Ticket {
            counter.admit(nativeAdmitted: native, processRoute: .stockOrder, mixed: true, log: lines.append)
        }
        let native = admit(true)
        XCTAssertEqual(native.route, .rowInvariant)
        XCTAssertEqual(native.reason, .nativeAdmitted)
        let ordinary = admit(false)
        XCTAssertEqual(ordinary.route, .rowInvariant)
        XCTAssertEqual(ordinary.reason, .nativeActive)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 2])

        // The native row finishes (ended twice: `end` is idempotent). The
        // ordinary row keeps its route, and while it is in flight a new
        // ordinary arrival joins it.
        native.end()
        native.end()
        XCTAssertEqual(ordinary.route, .rowInvariant)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 1])
        let joiner = admit(false)
        XCTAssertEqual(joiner.route, .rowInvariant)
        XCTAssertEqual(joiner.reason, .nativeActive)

        // Once no row-invariant request is in flight the next one is idle.
        ordinary.end()
        joiner.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
        let later = admit(false)
        XCTAssertEqual(later.route, .stockOrder)
        XCTAssertEqual(later.reason, .idle)
        later.end()
        XCTAssertEqual(counter.admissionSnapshot(), ["native_admitted": 1, "native_active": 2, "conversation_cache": 0, "conversation_cache_join": 0, "idle": 1])
        XCTAssertEqual(lines.all.map { $0.split(separator: " ").prefix(3).joined(separator: " ") }, [
            "event=small_m_route_admission route=row_invariant reason=native_admitted",
            "event=small_m_route_admission route=row_invariant reason=native_active",
            "event=small_m_route_admission route=row_invariant reason=native_active",
            "event=small_m_route_admission route=stock_order reason=idle",
        ])
    }

    func testNativeAdmittedDuringStockOrderRowsTakesRowInvariantAndLaterArrivalsJoinIt() {
        let counter = SmallMRouteRequestCounter()
        func admit(_ native: Bool) -> SmallMRouteRequestCounter.Ticket {
            counter.admit(nativeAdmitted: native, processRoute: .stockOrder, mixed: true, log: { _ in })
        }
        let stock = [admit(false), admit(false)]
        XCTAssertEqual(stock.map(\.route), [.stockOrder, .stockOrder])
        let native = admit(true)
        XCTAssertEqual(native.route, .rowInvariant)
        // Transient split: both routes in flight; the stock rows keep theirs.
        XCTAssertEqual(counter.snapshot(), ["stock_order": 2, "row_invariant": 1])
        XCTAssertEqual(stock.map(\.route), [.stockOrder, .stockOrder])
        // A new ordinary arrival joins row-invariant, so the stock set drains.
        let arrival = admit(false)
        XCTAssertEqual(arrival.route, .rowInvariant)
        stock.forEach { $0.end() }
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 2])
        native.end()
        arrival.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
    }

    /// M1: a request decided native at registration counts before it reaches
    /// admission, so an ordinary request admitted in between joins it.
    func testNativeDecidedAtRegistrationCountsBeforeItIsAdmitted() throws {
        let counter = SmallMRouteRequestCounter()
        let lines = AdmissionLogLines()
        XCTAssertNil(counter.reserveNative(mixed: false))
        let reservation = try XCTUnwrap(counter.reserveNative(mixed: true))
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 1])
        // The ordinary request finishes prepare first.
        let ordinary = counter.admit(nativeAdmitted: false, processRoute: .stockOrder, mixed: true, log: lines.append)
        XCTAssertEqual(ordinary.route, .rowInvariant)
        XCTAssertEqual(ordinary.reason, .nativeActive)
        // The native request then takes its reservation over: counted once.
        let native = counter.admit(
            nativeAdmitted: true, reservation: reservation, processRoute: .stockOrder, mixed: true, log: lines.append)
        XCTAssertTrue(native === reservation)
        XCTAssertEqual(native.reason, .nativeAdmitted)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 2])
        XCTAssertEqual(lines.all.last, "event=small_m_route_admission route=row_invariant reason=native_admitted "
            + "in_flight_row_invariant=1 in_flight_stock_order=0 joinable_row_invariant=1\n")
        // Both exit paths end the same ticket; the count drops once.
        native.end()
        reservation.end()
        ordinary.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
        XCTAssertEqual(counter.admissionSnapshot(), ["native_admitted": 1, "native_active": 1, "conversation_cache": 0, "conversation_cache_join": 0, "idle": 0])
    }

    /// M1: a reservation released on early rejection, and one whose request
    /// turned ordinary before admission, leave no row-invariant count behind.
    func testNativeReservationIsReleasedOnRejectionAndOnTurningOrdinary() throws {
        let counter = SmallMRouteRequestCounter()
        let rejected = try XCTUnwrap(counter.reserveNative(mixed: true))
        rejected.end()
        rejected.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])

        let downgraded = try XCTUnwrap(counter.reserveNative(mixed: true))
        // Token bounds sent it ordinary: it does not count as its own
        // row-invariant request in flight, so it is admitted idle.
        let ticket = counter.admit(
            nativeAdmitted: false, reservation: downgraded, processRoute: .stockOrder, mixed: true, log: { _ in })
        XCTAssertFalse(ticket === downgraded)
        XCTAssertEqual(ticket.route, .stockOrder)
        XCTAssertEqual(ticket.reason, .idle)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 1, "row_invariant": 0])
        downgraded.end()
        ticket.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
    }

    /// v0.3.64: a stored row-invariant entry takes row-invariant while idle,
    /// and that request is joinable: an unkeyed ordinary request beside it
    /// joins row-invariant (one forward), while a keyed request whose entry is
    /// stock order keeps stock order (transient split, its KV hits).
    func testConversationCacheRowInvariantPullsUnkeyedRequests() {
        let counter = SmallMRouteRequestCounter()
        let lines = AdmissionLogLines()
        func admit(_ stored: SmallMRoute?, native: Bool = false) -> SmallMRouteRequestCounter.Ticket {
            counter.admit(nativeAdmitted: native, storedRoute: stored, reusableCachedTokens: stored == nil ? 0 : 1_000,
                          maxOutputTokens: 64, processRoute: .stockOrder, mixed: true, log: lines.append)
        }
        let keyedRI = admit(.rowInvariant)
        XCTAssertEqual(keyedRI.route, .rowInvariant)
        XCTAssertEqual(keyedRI.reason, .conversationCache)
        XCTAssertTrue(keyedRI.joinable)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 1])
        let unkeyed = admit(nil)
        XCTAssertEqual(unkeyed.route, .rowInvariant)
        XCTAssertEqual(unkeyed.reason, .nativeActive)
        XCTAssertEqual(lines.all.last, "event=small_m_route_admission route=row_invariant reason=native_active "
            + "in_flight_row_invariant=1 in_flight_stock_order=0 joinable_row_invariant=1\n")
        // Split chosen: 1000 cached > min(64, 64) x 8.
        let keyedStock = admit(.stockOrder)
        XCTAssertEqual(keyedStock.route, .stockOrder)
        XCTAssertEqual(keyedStock.reason, .conversationCache)
        XCTAssertFalse(keyedStock.joinable)
        XCTAssertEqual(lines.all.last, "event=small_m_route_admission route=stock_order reason=conversation_cache "
            + "in_flight_row_invariant=2 in_flight_stock_order=0 joinable_row_invariant=2 "
            + "stored_route=stock_order cached_tokens=1000 overlap_tokens=64\n")
        let secondKeyedRI = admit(.rowInvariant)
        XCTAssertEqual(secondKeyedRI.route, .rowInvariant)
        XCTAssertEqual(secondKeyedRI.reason, .conversationCache)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 1, "row_invariant": 3])
        keyedRI.end()
        unkeyed.end()
        // The second keyed row-invariant request still pulls an unkeyed one.
        let stillUnkeyed = admit(nil)
        XCTAssertEqual(stillUnkeyed.route, .rowInvariant)
        XCTAssertEqual(stillUnkeyed.reason, .nativeActive)
        [keyedStock, secondKeyedRI, stillUnkeyed].forEach { $0.end() }
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
        let idle = admit(nil)
        XCTAssertEqual(idle.route, .stockOrder)
        XCTAssertEqual(idle.reason, .idle)
        idle.end()
        XCTAssertEqual(counter.admissionSnapshot(),
                       ["native_admitted": 0, "native_active": 2, "conversation_cache": 3, "conversation_cache_join": 0, "idle": 1])
    }

    /// v0.3.64/v0.3.65: beside an in-flight native row a keyed request whose
    /// stored entry is stock order keeps stock order when the reused prefill
    /// costs more than the split (its KV hits), while unkeyed ordinary
    /// requests join row-invariant and are joinable themselves.
    func testStoredStockOrderEntryKeepsStockOrderBesideANativeRow() {
        let counter = SmallMRouteRequestCounter()
        func admit(_ stored: SmallMRoute?, native: Bool = false, maxOut: Int = 64) -> SmallMRouteRequestCounter.Ticket {
            counter.admit(nativeAdmitted: native, storedRoute: stored, reusableCachedTokens: stored == nil ? 0 : 1_384,
                          maxOutputTokens: maxOut, processRoute: .stockOrder, mixed: true, log: { _ in })
        }
        let native = admit(nil, native: true, maxOut: 1_024)
        XCTAssertTrue(native.joinable)
        XCTAssertEqual(native.remainingOutputTokens, 1_024)
        let keyedStock = admit(.stockOrder)
        XCTAssertEqual(keyedStock.route, .stockOrder)
        XCTAssertEqual(keyedStock.reason, .conversationCache)
        XCTAssertFalse(keyedStock.joinable)
        XCTAssertEqual(counter.snapshot(), ["stock_order": 1, "row_invariant": 1])
        let unkeyed = admit(nil)
        XCTAssertEqual(unkeyed.route, .rowInvariant)
        XCTAssertEqual(unkeyed.reason, .nativeActive)
        XCTAssertTrue(unkeyed.joinable)
        native.end()
        // The joined unkeyed row keeps later unkeyed arrivals on row-invariant.
        let later = admit(nil)
        XCTAssertEqual(later.route, .rowInvariant)
        XCTAssertEqual(later.reason, .nativeActive)
        [keyedStock, unkeyed, later].forEach { $0.end() }
        let idle = admit(.stockOrder)
        XCTAssertEqual(idle.route, .stockOrder)
        XCTAssertEqual(idle.reason, .conversationCache)
        idle.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
    }

    /// v0.3.65: a long stock order turn beside a native row with a long
    /// remaining budget joins row-invariant and re-prefills; once the native
    /// row has produced most of its budget the same turn keeps stock order.
    func testStoredStockOrderEntryJoinsWhenTheSplitCostsMore() {
        let counter = SmallMRouteRequestCounter()
        let lines = AdmissionLogLines()
        let native = counter.admit(nativeAdmitted: true, maxOutputTokens: 1_024, processRoute: .stockOrder, mixed: true,
                                   log: { _ in })
        func keyed() -> SmallMRouteRequestCounter.Ticket {
            counter.admit(nativeAdmitted: false, storedRoute: .stockOrder, reusableCachedTokens: 1_384,
                          maxOutputTokens: 1_024, processRoute: .stockOrder, mixed: true, log: lines.append)
        }
        // 1384 <= min(1024, 1024) x 8: join.
        let joining = keyed()
        XCTAssertEqual(joining.route, .rowInvariant)
        XCTAssertEqual(joining.reason, .conversationCacheJoin)
        XCTAssertTrue(joining.joinable)
        XCTAssertEqual(lines.all.last, "event=small_m_route_admission route=row_invariant reason=conversation_cache_join "
            + "in_flight_row_invariant=1 in_flight_stock_order=0 joinable_row_invariant=1 "
            + "stored_route=stock_order cached_tokens=1384 overlap_tokens=1024\n")
        joining.end()
        // The native row has produced 1000 of its 1024 tokens: 1384 > 24 x 8, split.
        native.noteOutputToken(index: 999)
        XCTAssertEqual(native.remainingOutputTokens, 24)
        let splitting = keyed()
        XCTAssertEqual(splitting.route, .stockOrder)
        XCTAssertEqual(splitting.reason, .conversationCache)
        splitting.end()
        native.end()
        XCTAssertEqual(counter.admissionSnapshot(),
                       ["native_admitted": 1, "native_active": 0, "conversation_cache": 1, "conversation_cache_join": 1,
                        "idle": 0])
        // A reservation's budget is unknown until admission: the overlap is the turn's own budget.
        let reservation = counter.reserveNative(mixed: true)
        XCTAssertNil(reservation?.remainingOutputTokens)
        let besideReservation = keyed()
        XCTAssertEqual(besideReservation.reason, .conversationCacheJoin)
        besideReservation.end()
        reservation?.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
    }

    /// v0.3.65: admission reads the stored route only for an ordinary request
    /// that may take a conversation-cache lease.
    func testStoredRouteIsReadOnlyWhenTheLeaseIsAllowed() {
        XCTAssertTrue(ModelRuntime.admissionReadsStoredSmallMRoute(conversationCacheAllowed: true, nativeAdmitted: false))
        XCTAssertFalse(ModelRuntime.admissionReadsStoredSmallMRoute(conversationCacheAllowed: false, nativeAdmitted: false))
        XCTAssertFalse(ModelRuntime.admissionReadsStoredSmallMRoute(conversationCacheAllowed: true, nativeAdmitted: true))
    }

    func testConcurrentAdmissionsBesideANativeRowAllJoinRowInvariant() async {
        let counter = SmallMRouteRequestCounter()
        let native = counter.admit(nativeAdmitted: true, processRoute: .stockOrder, mixed: true, log: { _ in })
        let routes = await withTaskGroup(of: SmallMRoute.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    let ticket = counter.admit(nativeAdmitted: false, processRoute: .stockOrder, mixed: true, log: { _ in })
                    defer { ticket.end() }
                    return ticket.route
                }
            }
            var out: [SmallMRoute] = []
            for await route in group { out.append(route) }
            return out
        }
        XCTAssertEqual(routes.count, 32)
        XCTAssertTrue(routes.allSatisfy { $0 == .rowInvariant })
        native.end()
        XCTAssertEqual(counter.snapshot(), ["stock_order": 0, "row_invariant": 0])
    }

    func testScopeCarriesTheRequestRouteAndGroupsRows() async {
        XCTAssertNil(SmallMRouteScope.current)
        let seen = await SmallMRouteScope.run(.rowInvariant) {
            await Task.yield()
            return SmallMRouteScope.current
        }
        XCTAssertEqual(seen, .rowInvariant)
        XCTAssertNil(SmallMRouteScope.current)
        XCTAssertEqual(SmallMRoute.rowInvariant.mlxRoute, .rowInvariant)
        XCTAssertEqual(SmallMRoute.stockOrder.mlxRoute, .stockOrder)
        XCTAssertNil(SmallMRoute.serialOnly.mlxRoute)

        let rows: [(String, SmallMRoute)] = [("a", .stockOrder), ("b", .rowInvariant), ("c", .stockOrder), ("d", .rowInvariant)]
        let groups = SmallMRouteScope.groups(rows) { $0.1 }.map { $0.map(\.0) }
        XCTAssertEqual(groups, [["a", "c"], ["b", "d"]])
    }

    func testColdTierIdentityTakesTheRequestRoute() {
        let context = ConversationColdContext(
            eligible: true,
            identity: KVIdentityCore(
                requestModel: "m", servedModelID: "m", modelSHA256: String(repeating: "b", count: 64),
                catalogRevision: "r", tokenizerID: "m", tokenizerConfigSHA256: String(repeating: "c", count: 64),
                chatTemplateSHA256: String(repeating: "d", count: 64),
                kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil
            )
        )
        XCTAssertEqual(context.identity.decodePath, SmallMRoute.processRoute.kvDecodePath)
        let native = context.onSmallMRoute(.rowInvariant)
        let ordinary = context.onSmallMRoute(.stockOrder)
        XCTAssertEqual(native.identity.decodePath, "ordinary")
        XCTAssertEqual(ordinary.identity.decodePath, "ordinary+stock_order_small_m")
        XCTAssertNotEqual(native.identity, ordinary.identity)
        XCTAssertEqual(native.eligible, context.eligible)
    }

    /// v0.3.62: on a NAX GPU both routes run the same kernels, so the process
    /// keeps row_invariant process-wide.
    func testNAXGPUKeepsNativeMTPOnProcessWideRowInvariant() {
        for admission in [SmallMRoute.NativeMTPAdmission.entryForModel, .unverifiable] {
            var value = inputs(explicit: false, nativeMTP: .auto, admission: admission, verdict: .grantsBatching)
            XCTAssertTrue(SmallMRoute.decide(value).mixed)
            value.naxGPU = true
            XCTAssertEqual(
                SmallMRoute.decide(value),
                SmallMRoute.Decision(route: .rowInvariant, reason: "native_mtp_\(admission.rawValue)"),
                value.logFields
            )
            XCTAssertTrue(value.logFields.hasSuffix(" nax=true"))
            // NAX is checked first: the native reason, not the fallback's or
            // the operator's.
            var fallback = value
            fallback.stockOrderFallback = "stock_order_row_divergence_at_3"
            XCTAssertEqual(SmallMRoute.decide(fallback).reason, "native_mtp_\(admission.rawValue)")
            var forced = value
            forced.operatorForcesRowInvariant = true
            XCTAssertEqual(SmallMRoute.decide(forced).reason, "native_mtp_\(admission.rawValue)")
        }
        // NAX changes nothing without native MTP.
        var plain = inputs(explicit: false, verdict: .grantsBatching)
        let before = SmallMRoute.decide(plain)
        plain.naxGPU = true
        XCTAssertEqual(SmallMRoute.decide(plain), before)
    }

    /// v0.3.62: a one-row verdict recorded by a `mixed` start logs the next
    /// start that `decide` gives it, native-MTP row_invariant, not serial-only.
    func testMixedRecorderLogsTheNextStartFromDecide() throws {
        let (directory, selfCheck, store) = Self.temporaryStores()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startInputs = inputs(explicit: false, nativeMTP: .auto, admission: .entryForModel, verdict: .absent)
        XCTAssertTrue(SmallMRoute.decide(startInputs).mixed)
        let noGain = ContinuousBatchingSelfCheckDecision(slots: 1, reason: "no_net_gain", verifiedSlots: 3)
        try selfCheck.store(Self.record(Self.stockKey(), decision: noGain))
        let identity = SmallMRouteVerdictStore.startupIdentity(["model": "m", "mixed": "1"])
        let lines = LockedLines()
        let recorder = SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: identity, route: .stockOrder,
            inputs: startInputs, log: { lines.append($0) }
        )
        recorder.applied(key: Self.stockKey(), decision: noGain)
        XCTAssertEqual(lines.all, ["event=small_m_route action=verdict_recorded decision=no_net_gain slots=1 next_start=row_invariant"])
        XCTAssertEqual(store.nextStartDecision(startupIdentity: identity, selfCheckStore: selfCheck, inputs: startInputs),
                       SmallMRoute.Decision(route: .rowInvariant, reason: "native_mtp_entry_for_model"))

        // A grant keeps the next start mixed.
        let grantIdentity = SmallMRouteVerdictStore.startupIdentity(["model": "m", "mixed": "2"])
        let granted = ContinuousBatchingSelfCheckDecision(slots: 2, reason: "granted", verifiedSlots: 2)
        let grantLines = LockedLines()
        SmallMRouteVerdictRecorder(
            store: store, selfCheckStore: selfCheck, startupIdentity: grantIdentity, route: .stockOrder,
            inputs: startInputs, log: { grantLines.append($0) }
        ).applied(key: Self.stockKey(), decision: granted)
        XCTAssertEqual(grantLines.all, ["event=small_m_route action=verdict_recorded decision=granted slots=2 next_start=mixed"])
    }

    /// SPEC-048 R003 (0.1.121): the MTP-16 self-check's ordinary reference
    /// runs on the route its native probe runs.
    func testNativeMTPOrdinaryReferenceRunsOnTheNativeRoute() {
        let mixed = ModelRuntime.nativeMTPOrdinaryReferenceRequest(
            id: "ref", promptTokens: [1, 2], maxOutputTokens: 4, processRoute: .stockOrder, mixed: true)
        XCTAssertEqual(mixed.smallMRoute, .rowInvariant)
        XCTAssertEqual(mixed.decodePath, .ordinary)
        XCTAssertEqual(mixed.promptTokens, [1, 2])
        XCTAssertEqual(mixed.maxOutputTokens, 4)
        let probe = ContinuousBatchSchedulerRequest(
            id: "probe", conversationKey: "", promptTokens: [1, 2], maxOutputTokens: 4, decodePath: .nativeMTP)
        XCTAssertEqual(
            ModelRuntime.nativeMTPOrdinaryReferenceRequest(id: "ref", promptTokens: [1, 2], maxOutputTokens: 4).smallMRoute,
            probe.smallMRoute
        )
        for route in [SmallMRoute.rowInvariant, .stockOrder] {
            XCTAssertEqual(ModelRuntime.nativeMTPOrdinaryReferenceRequest(
                id: "ref", promptTokens: [1], maxOutputTokens: 1, processRoute: route, mixed: false).smallMRoute, route)
        }
    }

    /// v0.3.62: a lab process that kept an inherited `MLX_METAL_QMV_MMA_WK`
    /// keeps row_invariant process-wide, with its own reason.
    func testInheritedPartialSumsKeepNativeMTPOnProcessWideRowInvariant() {
        var value = inputs(explicit: false, nativeMTP: .auto, admission: .entryForModel, verdict: .grantsBatching)
        XCTAssertTrue(SmallMRoute.decide(value).mixed)
        value.inheritedPartialSums = true
        XCTAssertEqual(
            SmallMRoute.decide(value),
            SmallMRoute.Decision(route: .rowInvariant, reason: "native_mtp_qmv_mma_wk_inherited")
        )
        XCTAssertTrue(value.logFields.hasSuffix(" qmv_mma_wk=inherited"))
        // Before the fallback and the operator override, after NAX.
        var fallback = value
        fallback.stockOrderFallback = "stock_order_row_divergence_at_3"
        XCTAssertEqual(SmallMRoute.decide(fallback).reason, "native_mtp_qmv_mma_wk_inherited")
        var nax = value
        nax.naxGPU = true
        XCTAssertEqual(SmallMRoute.decide(nax).reason, "native_mtp_entry_for_model")
        // Without native MTP it changes nothing.
        var plain = inputs(explicit: false, verdict: .grantsBatching)
        let before = SmallMRoute.decide(plain)
        plain.inheritedPartialSums = true
        XCTAssertEqual(SmallMRoute.decide(plain), before)
        // Non-lab builds remove the variable, so they never keep it.
        #if !MACPROVIDER_LAB_HARNESS
        XCTAssertFalse(SmallMRoute.keepsInheritedPartialSums)
        #endif
    }
}

private final class AdmissionLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
