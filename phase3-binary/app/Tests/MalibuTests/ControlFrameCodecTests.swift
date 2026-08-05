import XCTest
@testable import Malibu

// AUDIT R1 ARCHITECT A8: parity tests for the app-side ControlFrame codec.
// These lock the wire-format against silent drift from the CLI side. The
// duplicated definitions in phase3-binary/app/Sources/Malibu/Agent/
// ControlSocketFrame.swift and phase3-binary/Sources/macprovider-cli/
// ControlSocket.swift will be consolidated in a follow-up SPEC-025 §12
// conflict #9 PR; until then these tests catch divergence.

final class ControlFrameCodecTests: XCTestCase {
    private func roundTrip(_ frame: ControlFrame) throws -> ControlFrame {
        let encoded = try ControlCodec.encode(frame)
        return try ControlCodec.decode(encoded)
    }

    private func referralStatus(
        state: String = ReferralStatusProjection.eligible,
        pending: ReferralPendingChallengeProjection? = nil
    ) -> ReferralStatusProjection {
        let observedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 1)
        return ReferralStatusProjection(
            campaign: "launch",
            joinBaseURL: URL(string: "https://malibu.tech/j")!,
            socialState: state,
            baseCapacity: 1,
            configuredBonusCapacity: 2,
            bonusCapacity: 0,
            redemptions: 0,
            remaining: 1,
            firstServingSeen: true,
            joinLinksEnabled: true,
            socialBonusEnabled: true,
            socialBonusGrantsRemaining: 5,
            inviteCode: "invite-123",
            inviteURL: URL(string: "https://malibu.tech/j#/invite-123"),
            observedAt: observedAt,
            pendingChallenge: pending
        )!
    }

    func testMetricsResponseRoundTrip() throws {
        let f = ControlFrame.metricsResponse(
            earningsUsdc: 1.25,
            malibuAccrued: 3.5,
            providerEarnings: ProviderEarnings(
                walletBound: true,
                trustTier: .trusted,
                unpaidLedgerBacklogUSDC: 0.5,
                unpaidLedgerBacklogMALIBU: 1.5,
                usdcToday: 1.25,
                usdcWeek: 4.5,
                usdcPending: 0.75,
                usdcLifetime: 100,
                malibuToday: 3.5,
                malibuAllTime: 42,
                trustCriteriaMet: 4,
                trustCriteriaRequired: 4
            ),
            gpuC: 48.2,
            gpuUtilizationPct: 62,
            latencyP50Ms: 120,
            latencyP99Ms: 280,
            queueDepth: 3,
            requestsServedToday: 142,
            requestsServedAllTime: 8_204,
            requestsPerMinute: 3.1,
            inputTokensToday: 1_200_000,
            outputTokensToday: 3_800_000,
            inputTokensAllTime: 12_000_000,
            outputTokensAllTime: 38_000_000,
            uptimeSec: 3600
        )
        XCTAssertEqual(try roundTrip(f), f)
    }

    func testMetricsResponseOmitsOptionalNils() throws {
        let f = ControlFrame.metricsResponse(
            earningsUsdc: nil,
            malibuAccrued: nil,
            providerEarnings: nil,
            gpuC: nil,
            gpuUtilizationPct: nil,
            latencyP50Ms: nil,
            latencyP99Ms: nil,
            queueDepth: nil,
            requestsServedToday: nil,
            requestsServedAllTime: nil,
            requestsPerMinute: nil,
            inputTokensToday: nil,
            outputTokensToday: nil,
            inputTokensAllTime: nil,
            outputTokensAllTime: nil,
            uptimeSec: nil
        )
        let data = try ControlCodec.encode(f)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertNil(obj?["earnings_usdc"])
        XCTAssertNil(obj?["malibu_accrued"])
        XCTAssertNil(obj?["provider_earnings"])
        XCTAssertNil(obj?["gpu_c"])
        XCTAssertNil(obj?["gpu_utilization_pct"])
        XCTAssertNil(obj?["latency_p50_ms"])
        XCTAssertNil(obj?["latency_p99_ms"])
        XCTAssertNil(obj?["queue_depth"])
        XCTAssertNil(obj?["uptime_sec"])
    }

    func testMetricsResponseDecodesAbsentCoreMetricsAsNil() throws {
        let data = Data("""
        {
          "type": "metrics_response",
          "queue_depth": 3
        }
        """.utf8)
        let decoded = try ControlCodec.decode(data)
        if case let .metricsResponse(usdc, malibu, _, _, _, _, _, queue, _, _, _, _, _, _, _, uptime) = decoded {
            XCTAssertNil(usdc)
            XCTAssertNil(malibu)
            XCTAssertEqual(queue, 3)
            XCTAssertNil(uptime)
        } else {
            XCTFail("expected metricsResponse")
        }
    }

    func testMetricsResponseDecodesGpuLatencyAndQueueDepth() throws {
        let data = Data("""
        {
          "type": "metrics_response",
          "earnings_usdc": 1.0,
          "malibu_accrued": 2.0,
          "gpu_utilization_pct": 62,
          "latency_p50_ms": 42,
          "latency_p99_ms": 180,
          "queue_depth": 3,
          "requests_served_today": 4,
          "requests_served_all_time": 9,
          "requests_per_minute": 1.5,
          "input_tokens_today": 1200,
          "output_tokens_today": 2400,
          "input_tokens_all_time": 12000,
          "output_tokens_all_time": 24000,
          "uptime_sec": 30
        }
        """.utf8)
        let decoded = try ControlCodec.decode(data)
        if case let .metricsResponse(_, _, _, _, gpu, p50, p99, queue, today, allTime, rpm, inToday, outToday, inAll, outAll, _) = decoded {
            XCTAssertEqual(gpu, 62)
            XCTAssertEqual(p50, 42)
            XCTAssertEqual(p99, 180)
            XCTAssertEqual(queue, 3)
            XCTAssertEqual(today, 4)
            XCTAssertEqual(allTime, 9)
            XCTAssertEqual(rpm, 1.5)
            XCTAssertEqual(inToday, 1200)
            XCTAssertEqual(outToday, 2400)
            XCTAssertEqual(inAll, 12000)
            XCTAssertEqual(outAll, 24000)
        } else {
            XCTFail("expected metricsResponse")
        }
    }

    func testPauseAckAcceptedFalseCarriesReason() throws {
        let f = ControlFrame.pauseAck(accepted: false, reason: "lifecycle_control_unavailable")
        let decoded = try roundTrip(f)
        XCTAssertEqual(decoded, f)
    }

    func testShutdownRequestEncodesGraceField() throws {
        // The app is a control-socket CLIENT — it only encodes request
        // frames (never decodes them). Assert the wire shape rather than a
        // round-trip; attempting to decode a request type throws
        // unknownType, which is the correct asymmetry.
        let data = try ControlCodec.encode(.shutdownRequest(graceSeconds: 30))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "shutdown_request")
        XCTAssertEqual(obj?["grace_seconds"] as? Int, 30)
        XCTAssertThrowsError(try ControlCodec.decode(data))
    }

    func testUnknownTypeIsRejected() {
        let bogus = Data(#"{"type":"unknown_frame"}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(bogus))
    }

    func testStatusResponseWithEmptyStringsDoesNotCrash() throws {
        let obj: [String: Any] = ["type": "status_response"]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try ControlCodec.decode(data)
        if case .statusResponse(let model, let state) = decoded {
            XCTAssertEqual(model, "")
            XCTAssertEqual(state, "")
        } else {
            XCTFail("expected statusResponse")
        }
    }

    func testReferralStatusResponseRoundTripCarriesOnlySanitizedProjection() throws {
        let pending = ReferralPendingChallengeProjection(
            expiresAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 600)
        )
        let frame = ControlFrame.referralStatusResponse(
            referralStatus(state: ReferralStatusProjection.pending, pending: pending)
        )

        XCTAssertEqual(try roundTrip(frame), frame)

        let wire = String(decoding: try ControlCodec.encode(frame), as: UTF8.self)
        XCTAssertFalse(wire.localizedCaseInsensitiveContains("authorization"))
        XCTAssertFalse(wire.localizedCaseInsensitiveContains("provider_token"))
        XCTAssertFalse(wire.contains("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
    }

    func testReferralFramesDecodeCLIFractionalTimestamps() throws {
        let observedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 1)
        let expiresAt = observedAt.addingTimeInterval(600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let raw: [String: Any] = [
            "type": "referral_status_response",
            "campaign": "prebeta",
            "join_base_url": "https://malibu.tech/j",
            "social_state": "eligible",
            "base_capacity": 1,
            "configured_bonus_capacity": 2,
            "bonus_capacity": 0,
            "redemptions": 0,
            "remaining": 1,
            "first_serving_seen": true,
            "join_links_enabled": true,
            "social_bonus_enabled": true,
            "invite_code": "CODE",
            "invite_url": "https://malibu.tech/j#/CODE",
            "observed_at": formatter.string(from: observedAt),
            "pending_challenge": ["expires_at": formatter.string(from: expiresAt)],
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        guard case let .referralStatusResponse(status) = try ControlCodec.decode(data) else {
            return XCTFail("fractional CLI frame did not decode")
        }
        XCTAssertEqual(status.observedAt.timeIntervalSince1970, observedAt.timeIntervalSince1970, accuracy: 0.001)
        let expiry = try XCTUnwrap(status.pendingChallenge?.expiresAt)
        XCTAssertEqual(expiry.timeIntervalSince1970, expiresAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testReferralActionFramesUseTypedSanitizedWireShapes() throws {
        XCTAssertEqual(try roundTrip(.referralStatusRequest), .referralStatusRequest)
        XCTAssertEqual(try roundTrip(.referralChallengeRequest), .referralChallengeRequest)
        XCTAssertEqual(
            try roundTrip(.referralChallengeResponse(expiresAt: "2027-01-15T08:10:00Z")),
            .referralChallengeResponse(expiresAt: "2027-01-15T08:10:00Z")
        )
        XCTAssertEqual(try roundTrip(.referralChallengeReopenRequest), .referralChallengeReopenRequest)
        XCTAssertEqual(
            try roundTrip(.referralChallengeReopenAck(expiresAt: "2027-01-15T08:10:00Z")),
            .referralChallengeReopenAck(expiresAt: "2027-01-15T08:10:00Z")
        )
        XCTAssertEqual(
            try roundTrip(.referralVerifyRequest(postURL: "https://x.com/provider/status/123")),
            .referralVerifyRequest(postURL: "https://x.com/provider/status/123")
        )
        XCTAssertEqual(try roundTrip(.referralChallengeCancelRequest), .referralChallengeCancelRequest)
        XCTAssertEqual(
            try roundTrip(.referralChallengeCancelAck(status: referralStatus())),
            .referralChallengeCancelAck(status: referralStatus())
        )
        XCTAssertEqual(
            try roundTrip(.referralError(
                operation: .verify,
                code: .rateLimited,
                retryAfterSeconds: 30
            )),
            .referralError(operation: .verify, code: .rateLimited, retryAfterSeconds: 30)
        )
    }

    func testMalformedReferralStatusFailsClosed() throws {
        let negative = Data("""
        {
          "type": "referral_status_response",
          "campaign": "launch",
          "social_state": "eligible",
          "base_capacity": 1,
          "configured_bonus_capacity": 2,
          "bonus_capacity": 0,
          "redemptions": 0,
          "remaining": -1,
          "first_serving_seen": true,
          "social_bonus_enabled": true,
          "observed_at": "2027-01-15T08:00:00Z"
        }
        """.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(negative))

        let unknownState = Data("""
        {
          "type": "referral_status_response",
          "campaign": "launch",
          "social_state": "probably_eligible",
          "base_capacity": 1,
          "configured_bonus_capacity": 2,
          "bonus_capacity": 0,
          "redemptions": 0,
          "remaining": 1,
          "first_serving_seen": true,
          "social_bonus_enabled": true,
          "observed_at": "2027-01-15T08:00:00Z"
        }
        """.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(unknownState))
    }

}
