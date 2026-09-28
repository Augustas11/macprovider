import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPStatusTests: XCTestCase {
    func testStatusObjectUsesClosedR010FieldSetAndDerivedCounters() {
        let sink = NativeMTPStatusSink(
            supported: true,
            enabled: true,
            family: "Qwen3_5.MTP-v1",
            proposalDepth: 4,
            throughputDeltaPPM: 12_345,
            resetGeneration: 7,
            lastReason: .active
        )
        sink.recordNativeMTPAdmission(rowCount: 2)
        sink.beginRound(requestedDepths: [4, 2])
        XCTAssertEqual(sink.snapshot().mode, .active)
        sink.recordRound(NativeMTPStatusSink.Round(
            requestedDepths: [4, 2],
            proposedTokens: 6,
            acceptedTokens: 3,
            bonusTokens: 1,
            committedTokens: 4,
            acceptedProposalTokensByRow: [1, 2],
            verificationOverheadMS: 25
        ))
        sink.endRound()

        let snapshot = sink.snapshot()
        let object = snapshot.statusObject()
        XCTAssertEqual(Set(object.keys), NativeMTPStatusSnapshot.closedFieldNames)
        XCTAssertEqual(snapshot.mode, .eligible)
        XCTAssertEqual(object["supported"] as? Bool, true)
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["family"] as? String, "qwen3_5.mtp-v1")
        XCTAssertEqual(object["proposal_depth"] as? Int, 4)
        XCTAssertEqual((object["requests_since_reset"] as? NSNumber)?.uint64Value, 2)
        XCTAssertEqual((object["proposed_tokens"] as? NSNumber)?.uint64Value, 6)
        XCTAssertEqual((object["accepted_tokens"] as? NSNumber)?.uint64Value, 3)
        XCTAssertEqual((object["rejected_tokens"] as? NSNumber)?.uint64Value, 3)
        XCTAssertEqual((object["bonus_tokens"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual((object["committed_tokens"] as? NSNumber)?.uint64Value, 4)
        XCTAssertEqual((object["target_forwards"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual((object["mtp_forwards"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(object["throughput_delta_ppm"] as? Int, 12_345)
        XCTAssertEqual((object["reset_generation"] as? NSNumber)?.uint64Value, 7)
        XCTAssertEqual(object["last_reason"] as? String, "active")
        XCTAssertEqual(object["mean_accepted_length"] as? Double, 3.0)
        XCTAssertEqual(
            (object["accepted_by_position"] as? [NSNumber])?.map(\.uint64Value),
            [2, 1, 0, 0]
        )
    }

    func testRequestsSinceResetCountsNativeAdmissionOnceAcrossMultipleRounds() {
        let sink = NativeMTPStatusSink(
            supported: true,
            enabled: true,
            family: "qwen3_mtp_v1",
            proposalDepth: 2,
            throughputDeltaPPM: 0,
            resetGeneration: 1,
            lastReason: .active
        )

        sink.recordNativeMTPAdmission()
        for _ in 0..<3 {
            sink.beginRound(requestedDepths: [2])
            sink.recordRound(NativeMTPStatusSink.Round(
                requestedDepths: [2],
                proposedTokens: 2,
                acceptedTokens: 1,
                bonusTokens: 0,
                committedTokens: 1,
                acceptedProposalTokensByRow: [1],
                verificationOverheadMS: 1
            ))
            sink.endRound()
        }

        XCTAssertEqual(sink.snapshot().requestsSinceReset, 1)
        XCTAssertEqual(sink.snapshot().mtpForwards, 3)
    }

    func testRequestsSinceResetCountsMultiRowNativeAdmissionOnce() {
        let sink = NativeMTPStatusSink(
            supported: true,
            enabled: true,
            family: "qwen3_mtp_v1",
            proposalDepth: 2,
            throughputDeltaPPM: 0,
            resetGeneration: 1,
            lastReason: .active
        )

        sink.recordNativeMTPAdmission(rowCount: 3)
        sink.beginRound(requestedDepths: [2, 1, 0])
        sink.recordRound(NativeMTPStatusSink.Round(
            requestedDepths: [2, 1, 0],
            proposedTokens: 3,
            acceptedTokens: 1,
            bonusTokens: 0,
            committedTokens: 1,
            acceptedProposalTokensByRow: [1, 0, 0],
            verificationOverheadMS: 1
        ))
        sink.endRound()
        sink.beginRound(requestedDepths: [2, 1, 0])
        sink.recordRound(NativeMTPStatusSink.Round(
            requestedDepths: [2, 1, 0],
            proposedTokens: 3,
            acceptedTokens: 1,
            bonusTokens: 0,
            committedTokens: 1,
            acceptedProposalTokensByRow: [0, 1, 0],
            verificationOverheadMS: 1
        ))
        sink.endRound()

        XCTAssertEqual(sink.snapshot().requestsSinceReset, 3)
        XCTAssertEqual(sink.snapshot().mtpForwards, 2)
    }

    func testRoundAccountingDoesNotCountFallbackOnlyRowsAsRequests() {
        let sink = NativeMTPStatusSink(
            supported: true,
            enabled: true,
            family: "qwen3_mtp_v1",
            proposalDepth: 2,
            throughputDeltaPPM: 0,
            resetGeneration: 1,
            lastReason: .active
        )

        sink.recordRound(NativeMTPStatusSink.Round(
            requestedDepths: [2],
            proposedTokens: 2,
            acceptedTokens: 1,
            bonusTokens: 0,
            committedTokens: 1,
            acceptedProposalTokensByRow: [1],
            verificationOverheadMS: 1
        ))

        XCTAssertEqual(sink.snapshot().requestsSinceReset, 0)
        XCTAssertEqual(sink.snapshot().mtpForwards, 1)
    }

    func testDepthZeroRoundReportsDegradedModeWhileActive() {
        let sink = NativeMTPStatusSink(
            supported: true,
            enabled: true,
            family: "qwen3_mtp_v1",
            proposalDepth: 2,
            throughputDeltaPPM: 0,
            resetGeneration: 1,
            lastReason: .active
        )

        sink.beginRound(requestedDepths: [0, 0])
        let active = sink.snapshot()
        XCTAssertEqual(active.mode, .degradedDepthZero)
        XCTAssertEqual(active.statusObject()["mode"] as? String, "degraded_depth_zero")

        sink.endRound()
        XCTAssertEqual(sink.snapshot().mode, .eligible)
    }

    func testCounterSaturationDisablesNativeTupleUntilNewSinkGeneration() {
        let sink = NativeMTPStatusSink(
            supported: true,
            enabled: true,
            family: "qwen3_mtp_v1",
            proposalDepth: 1,
            throughputDeltaPPM: 0,
            resetGeneration: 3,
            lastReason: .active
        )
        let huge = Int.max
        sink.recordRound(NativeMTPStatusSink.Round(
            requestedDepths: [1],
            proposedTokens: huge,
            acceptedTokens: 0,
            bonusTokens: 0,
            committedTokens: 0,
            acceptedProposalTokensByRow: [0],
            verificationOverheadMS: 0
        ))
        sink.recordRound(NativeMTPStatusSink.Round(
            requestedDepths: [1],
            proposedTokens: huge,
            acceptedTokens: 0,
            bonusTokens: 0,
            committedTokens: 0,
            acceptedProposalTokensByRow: [0],
            verificationOverheadMS: 0
        ))
        sink.recordRound(NativeMTPStatusSink.Round(
            requestedDepths: [1],
            proposedTokens: huge,
            acceptedTokens: 0,
            bonusTokens: 0,
            committedTokens: 0,
            acceptedProposalTokensByRow: [0],
            verificationOverheadMS: 0
        ))

        let snapshot = sink.snapshot()
        XCTAssertFalse(snapshot.enabled)
        XCTAssertEqual(snapshot.mode, .off)
        XCTAssertEqual(snapshot.lastReason, .runtimeFailure)
        XCTAssertEqual(snapshot.proposedTokens, UInt64.max)
    }

    func testMetricsSamplesUseOnlyBoundedLabels() throws {
        let sink = NativeMTPStatusSink(
            supported: true,
            enabled: true,
            family: "../bad family",
            proposalDepth: 20,
            throughputDeltaPPM: 0,
            resetGeneration: 1,
            lastReason: .capacityUnavailable
        )
        sink.recordCapacityRejection()
        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.family, "unknown")
        XCTAssertEqual(snapshot.acceptedByPosition.count, NativeMTPStatusSnapshot.maximumProposalDepth)

        let allowedReasons = Set(NativeMTPStatusReason.allCases.map(\.rawValue))
        for sample in snapshot.metricsSamples() {
            XCTAssertTrue(sample.name.hasPrefix("native_mtp_"))
            XCTAssertTrue(sample.labels.keys.allSatisfy { $0 == "position" || $0 == "last_reason" })
            if let position = sample.labels["position"] {
                let value = try XCTUnwrap(Int(position))
                XCTAssertTrue((0..<NativeMTPStatusSnapshot.maximumProposalDepth).contains(value))
            }
            if let reason = sample.labels["last_reason"] {
                XCTAssertTrue(allowedReasons.contains(reason))
            }
        }
    }

    func testLocalStatusPublishesCapabilityAndExactlyOneNativeMTPObject() async throws {
        let providerStatus = ProviderStatus(
            modelID: "fixture-model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 4096, maxConcurrencyOverride: 1)
        )
        let providerSnapshot = await providerStatus.snapshot()
        let runtimeSnapshot = RuntimeSnapshot(
            state: .ready,
            container: nil,
            modelID: "fixture-model",
            modelHash: "hash",
            nativeMTPStatus: NativeMTPStatusSink(
                supported: true,
                enabled: true,
                family: "qwen3_mtp_v1",
                proposalDepth: 2,
                throughputDeltaPPM: -10,
                resetGeneration: 9,
                lastReason: .active
            ).snapshot()
        )

        let body = RouterHandler.statusResponse(
            providerSnapshot,
            providerID: nil,
            coordinatorURL: nil,
            runtimeSnapshot: runtimeSnapshot
        )
        let contract = try XCTUnwrap(body["local_status_contract"] as? [String: Any])
        let capabilities = try XCTUnwrap(contract["capabilities"] as? [String])
        XCTAssertTrue(capabilities.contains(NativeMTPStatusSnapshot.capability))

        let object = try XCTUnwrap(body["native_mtp"] as? [String: Any])
        XCTAssertEqual(Set(object.keys), NativeMTPStatusSnapshot.closedFieldNames)
        XCTAssertEqual(object["family"] as? String, "qwen3_mtp_v1")
        XCTAssertEqual(object["throughput_delta_ppm"] as? Int, -10)
        XCTAssertEqual((object["reset_generation"] as? NSNumber)?.uint64Value, 9)
    }
}
