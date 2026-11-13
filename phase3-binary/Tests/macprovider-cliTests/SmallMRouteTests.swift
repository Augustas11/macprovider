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
        verdict: SmallMRoute.SelfCheckVerdict = .absent
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
            selfCheckVerdict: verdict
        )
    }

    /// Every combination of every input against the rule written out once.
    func testDecisionTableCoversEveryCombination() {
        var serialCount = 0
        for mode in [ContinuousBatchingMode.off, .canary, .on] {
            for explicit in [false, true] {
                for nativeMTP in [NativeMTPMode.off, .auto] {
                    for admission in SmallMRoute.NativeMTPAdmission.allCases {
                        for draft in [false, true] {
                            for shard in [false, true] {
                                for autotune in [false, true] {
                                    for switchTargets in [false, true] {
                                        for verdict in SmallMRoute.SelfCheckVerdict.allCases {
                                            let value = inputs(
                                                mode: mode, explicit: explicit, nativeMTP: nativeMTP,
                                                admission: admission, draft: draft, shard: shard,
                                                autotune: autotune, switchTargets: switchTargets, verdict: verdict
                                            )
                                            let mtpInactive = nativeMTP == .off
                                                || admission == .none || admission == .noEntryForModel
                                            let cbCannotActivate = (explicit && mode == .off) || verdict == .grantsNoBatching
                                            let expected = mtpInactive && cbCannotActivate
                                                && !draft && !shard && !autotune && !switchTargets
                                            let decision = SmallMRoute.decide(value)
                                            XCTAssertEqual(decision.route == .serialOnly, expected, "\(value.logFields) -> \(decision.reason)")
                                            if expected { serialCount += 1 }
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
            (inputs(explicit: false, nativeMTP: .auto, verdict: .absent), .rowInvariant, "self_check_verdict_absent"),
            (inputs(explicit: false, nativeMTP: .auto, verdict: .grantsNoBatching), .serialOnly, "self_check_no_batching"),
            (inputs(explicit: false, verdict: .staleKey), .rowInvariant, "self_check_key_changed"),
            (inputs(explicit: false, verdict: .recheckPending), .rowInvariant, "self_check_recheck_pending"),
            (inputs(explicit: false, verdict: .grantsBatching), .rowInvariant, "self_check_grants_batching"),
            (inputs(mode: .on, verdict: .grantsNoBatching), .serialOnly, "self_check_no_batching"),
            (inputs(mode: .canary, verdict: .absent), .rowInvariant, "self_check_verdict_absent"),
            (inputs(draft: true), .rowInvariant, "draft_model"),
            (inputs(shard: true), .rowInvariant, "shard_group"),
            (inputs(autotune: true), .rowInvariant, "autotune_candidate"),
            (inputs(switchTargets: true), .rowInvariant, "switch_targets"),
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

    func testEnvironmentValueMapsToTheCoreRoute() {
        XCTAssertEqual(SmallMRoute.route(environmentValue: nil), .rowInvariant)
        XCTAssertEqual(SmallMRoute.route(environmentValue: ""), .rowInvariant)
        XCTAssertEqual(SmallMRoute.route(environmentValue: "1"), .rowInvariant)
        XCTAssertEqual(SmallMRoute.route(environmentValue: "false"), .rowInvariant)
        XCTAssertEqual(SmallMRoute.route(environmentValue: "0"), .serialOnly)
    }

    func testSerialOnlyProcessRefusesEveryBatchingEntry() {
        for entry in ["continuous_batch_scheduler", "ContinuousBatchScheduler", "msb-throughput",
                      "native-mtp-bench", "native-mtp-hardware-e2e", "relay-blind-fixture"] {
            XCTAssertNil(SmallMRoute.batchingRefusal(route: .rowInvariant, entry: entry))
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
    }

    func testDecodeBenchRouteOption() {
        XCTAssertEqual(decodeBenchSmallMRoute("row-invariant"), .rowInvariant)
        XCTAssertEqual(decodeBenchSmallMRoute("serial-only"), .serialOnly)
        XCTAssertNil(decodeBenchSmallMRoute("serial_only"))
        XCTAssertNil(decodeBenchSmallMRoute(""))
    }

    func testDiskCacheWrittenOnOneRouteMissesOnTheOther() {
        XCTAssertEqual(SmallMRoute.rowInvariant.kvDecodePath, "ordinary")
        XCTAssertNotEqual(SmallMRoute.serialOnly.kvDecodePath, SmallMRoute.rowInvariant.kvDecodePath)
        let (reference, runtime) = KVDiskCacheFormatTests.validPair()
        for written in [SmallMRoute.rowInvariant, .serialOnly] {
            let manifest = KVDiskCacheFormatTests.mutate(reference) { $0.decodePath = written.kvDecodePath }
            for reading in [SmallMRoute.rowInvariant, .serialOnly] {
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
