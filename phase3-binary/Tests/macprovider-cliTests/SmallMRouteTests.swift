import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-038 FR-CB9 (#2335): the small-row route decision, the batching
/// refusal on a serial-only process and the disk-cache identity split.
final class SmallMRouteTests: XCTestCase {
    private func decide(
        mode: ContinuousBatchingMode = .off,
        explicit: Bool = true,
        nativeMTP: NativeMTPMode = .off,
        draft: Bool = false,
        shard: Bool = false,
        autotune: Bool = false
    ) -> SmallMRoute.Decision {
        SmallMRoute.decide(
            continuousBatching: mode,
            continuousBatchingExplicitlyConfigured: explicit,
            nativeMTPMode: nativeMTP,
            draftConfigured: draft,
            shardGroupRole: shard,
            autotuneCandidate: autotune
        )
    }

    func testOnlyExplicitCBOffWithNoOtherBatchingRoleIsSerialOnly() {
        let cases: [(SmallMRoute.Decision, SmallMRoute, String)] = [
            (decide(), .serialOnly, "continuous_batching_off_by_configuration"),
            // Implicit default off: the signed policy or self-check can still grant CB.
            (decide(explicit: false), .rowInvariant, "continuous_batching_not_configured_off"),
            (decide(mode: .canary), .rowInvariant, "continuous_batching_not_configured_off"),
            (decide(mode: .on), .rowInvariant, "continuous_batching_not_configured_off"),
            (decide(mode: .canary, explicit: false), .rowInvariant, "continuous_batching_not_configured_off"),
            (decide(nativeMTP: .auto), .rowInvariant, "native_mtp_auto"),
            (decide(draft: true), .rowInvariant, "draft_model"),
            (decide(shard: true), .rowInvariant, "shard_group"),
            (decide(autotune: true), .rowInvariant, "autotune_candidate"),
            (decide(explicit: false, nativeMTP: .auto, draft: true, shard: true, autotune: true),
             .rowInvariant, "continuous_batching_not_configured_off"),
        ]
        for (decision, route, reason) in cases {
            XCTAssertEqual(decision, SmallMRoute.Decision(route: route, reason: reason))
        }
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
        XCTAssertEqual(
            RouterHandler.continuousBatchingStatusFields(nil, smallMRoute: .serialOnly)["small_m_route"] as? String,
            "serial_only"
        )
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
