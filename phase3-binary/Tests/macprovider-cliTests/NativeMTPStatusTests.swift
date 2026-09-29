import Foundation
import MLX
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

    func testRoundProfileDeltaPublishesEveryPhaseAndCounts() throws {
        let before = NativeMTPRoundProfileSnapshot(
            phaseNanoseconds: [NativeMTPRoundProfilePhase.tokenDelivery.rawValue: 1_000_000],
            roundCount: 2,
            rows: 4,
            proposals: 2,
            targetForwardCalls: 2,
            drafterForwardCalls: 4,
            perRowModelCallLoops: 4
        )
        let after = NativeMTPRoundProfileSnapshot(
            phaseNanoseconds: [
                NativeMTPRoundProfilePhase.targetVerificationForward.rawValue: 5_000_000,
                NativeMTPRoundProfilePhase.tokenDelivery.rawValue: 3_000_000,
            ],
            roundCount: 4,
            rows: 8,
            proposals: 4,
            targetForwardCalls: 4,
            drafterForwardCalls: 8,
            perRowModelCallLoops: 8
        )

        let delta = after.delta(since: before)
        XCTAssertEqual(delta.roundCount, 2)
        XCTAssertEqual(delta.rows, 4)
        XCTAssertEqual(delta.proposals, 2)
        XCTAssertEqual(delta.targetForwardCalls, 2)
        XCTAssertEqual(delta.drafterForwardCalls, 4)
        XCTAssertEqual(delta.perRowModelCallLoops, 4)

        let totals = try XCTUnwrap(delta.record["phase_total_ms"] as? [String: Double])
        XCTAssertEqual(Set(totals.keys), Set(NativeMTPRoundProfilePhase.allCases.map(\.rawValue)))
        XCTAssertEqual(totals[NativeMTPRoundProfilePhase.targetVerificationForward.rawValue], 5.0)
        XCTAssertEqual(totals[NativeMTPRoundProfilePhase.tokenDelivery.rawValue], 2.0)
    }

    func testNativeMTPParityClassifierCountsBoundedOwnRowRunnerUp() {
        let result = NativeMTPParityClassifier.classify(positions: [
            NativeMTPParityPosition(
                nativeToken: 9,
                ordinaryTop1: 5,
                ordinaryTop2: 9,
                ordinaryTop1Logit: 16.0,
                ordinaryTop2Logit: 15.75,
                maxAbsTargetLogitDifference: 0.05,
                otherRowArgmaxes: [42]
            )
        ])
        XCTAssertFalse(result.hardMismatch)
        XCTAssertEqual(result.toleratedTies, 1)
    }

    func testNativeMTPParityClassifierRejectsBeyondTwoBF16ULPs() {
        let result = NativeMTPParityClassifier.classify(positions: [
            NativeMTPParityPosition(
                nativeToken: 9,
                ordinaryTop1: 5,
                ordinaryTop2: 9,
                ordinaryTop1Logit: 2.0,
                ordinaryTop2Logit: 1.96875,
                maxAbsTargetLogitDifference: 0.031_251,
                otherRowArgmaxes: [42]
            )
        ])
        XCTAssertTrue(result.hardMismatch)
    }

    func testNativeMTPParityClassifierEnforcesGlobalLogitBoundOnExactArgmax() {
        let result = NativeMTPParityClassifier.classify(positions: [
            NativeMTPParityPosition(
                nativeToken: 5,
                ordinaryTop1: 5,
                ordinaryTop2: 9,
                ordinaryTop1Logit: 16.0,
                ordinaryTop2Logit: 15.0,
                maxAbsTargetLogitDifference: 0.050_001,
                otherRowArgmaxes: [42]
            )
        ])
        XCTAssertTrue(result.hardMismatch)
    }

    func testNativeMTPParityClassifierRejectsCrossRowArgmax() {
        let result = NativeMTPParityClassifier.classify(positions: [
            NativeMTPParityPosition(
                nativeToken: 9,
                ordinaryTop1: 5,
                ordinaryTop2: 9,
                ordinaryTop1Logit: 16.0,
                ordinaryTop2Logit: 15.75,
                maxAbsTargetLogitDifference: 0.05,
                otherRowArgmaxes: [9]
            )
        ])
        XCTAssertTrue(result.hardMismatch)
    }

    func testNativeMTPParityClassifierRejectsWrongRank() {
        let result = NativeMTPParityClassifier.classify(positions: [
            NativeMTPParityPosition(
                nativeToken: 11,
                ordinaryTop1: 5,
                ordinaryTop2: 9,
                ordinaryTop1Logit: 16.0,
                ordinaryTop2Logit: 15.875,
                maxAbsTargetLogitDifference: 0.05,
                otherRowArgmaxes: [42]
            )
        ])
        XCTAssertTrue(result.hardMismatch)
    }

    func testNativeMTPParityCrossRowGuardUsesPackedRoundCoordinate() {
        let round1Column0 = NativeMTPParityCoordinate(packedRoundID: 10, verificationColumn: 0)
        let round1Column1 = NativeMTPParityCoordinate(packedRoundID: 10, verificationColumn: 1)
        let round2Column0 = NativeMTPParityCoordinate(packedRoundID: 11, verificationColumn: 0)
        let observations = [
            [
                NativeMTPParityArgmaxObservation(coordinate: round1Column0, ordinaryTop1: 5),
                NativeMTPParityArgmaxObservation(coordinate: round2Column0, ordinaryTop1: 6),
            ],
            [
                NativeMTPParityArgmaxObservation(coordinate: round1Column0, ordinaryTop1: 40),
                NativeMTPParityArgmaxObservation(coordinate: round1Column1, ordinaryTop1: 41),
                NativeMTPParityArgmaxObservation(coordinate: round2Column0, ordinaryTop1: 77),
            ],
        ]

        XCTAssertEqual(
            NativeMTPParityClassifier.otherRowArgmaxes(
                observations: observations,
                requestIndex: 0,
                positionIndex: 1
            ),
            [77]
        )
    }

    func testNativeMTPParityCollectorRetainsOtherRowUncommittedSuffixArgmax() throws {
        let collector = NativeMTPParityTraceCollector.shared
        let requestA = "parity-packed-a-\(UUID().uuidString)"
        let requestB = "parity-packed-b-\(UUID().uuidString)"
        collector.begin(requestID: requestA)
        collector.begin(requestID: requestB)
        collector.recordPrompt(requestID: requestA, tokens: [1])
        collector.recordPrompt(requestID: requestB, tokens: [1])
        let roundID = collector.allocatePackedRoundID()
        collector.stageVerification(
            requestID: requestA,
            packedRoundID: roundID,
            targetLogits: [
                MLXArray([3, 1, 0] as [Float]).reshaped([1, 3]),
                MLXArray([0, 1, 3] as [Float]).reshaped([1, 3]),
            ],
            targetArgmaxes: [0, 2]
        )
        collector.stageVerification(
            requestID: requestB,
            packedRoundID: roundID,
            targetLogits: [
                MLXArray([1, 3, 0] as [Float]).reshaped([1, 3]),
                MLXArray([0, 1, 4] as [Float]).reshaped([1, 3]),
            ],
            targetArgmaxes: [1, 2]
        )
        collector.commitVerification(requestID: requestA, tokens: [0, 2])
        collector.commitVerification(requestID: requestB, tokens: [1])

        let traceA = try XCTUnwrap(collector.take(requestID: requestA))
        _ = collector.take(requestID: requestB)
        XCTAssertEqual(traceA.positions[1].otherRowPackedArgmaxes, [2])
    }

    func testNativeMTPParityCollectorSealsFirstPositionCrossRowArgmaxes() throws {
        let collector = NativeMTPParityTraceCollector.shared
        let requestA = "parity-prefill-a-\(UUID().uuidString)"
        let requestB = "parity-prefill-b-\(UUID().uuidString)"
        collector.begin(requestID: requestA)
        collector.begin(requestID: requestB)
        collector.recordPrompt(requestID: requestA, tokens: [1])
        collector.recordPrompt(requestID: requestB, tokens: [1])
        let roundID = collector.allocatePackedRoundID()
        collector.recordPrefillToken(
            requestID: requestA,
            token: 1,
            targetLogits: MLXArray([0, 3, 1] as [Float]).reshaped([1, 3]),
            packedRoundID: roundID
        )
        collector.recordPrefillToken(
            requestID: requestB,
            token: 2,
            targetLogits: MLXArray([0, 1, 3] as [Float]).reshaped([1, 3]),
            packedRoundID: roundID
        )
        collector.sealPackedCoordinates([
            NativeMTPParityCoordinate(packedRoundID: roundID, verificationColumn: 0)
        ])

        let traceA = try XCTUnwrap(collector.take(requestID: requestA))
        _ = collector.take(requestID: requestB)
        XCTAssertEqual(traceA.positions[0].otherRowPackedArgmaxes, [2])
    }
}
