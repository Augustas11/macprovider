import Foundation
import XCTest
@testable import macprovider_cli

final class ControlMetricsBuilderTests: XCTestCase {
    private func makeCapacity() -> ProviderCapacity {
        ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: 4)
    }

    // CS-3 regression: the control-socket metrics poll shares one ProviderStatus
    // instance with the coordinator heartbeat. The poll must READ the since-last
    // window without RESETTING it, so the next heartbeat still reports the full
    // window. Before the fix, build() reset the window and the heartbeat saw 0.
    func testMetricsBuildDoesNotDrainHeartbeatWindow() async {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        await status.finishRequest(startedAt: Date(), completion: nil, failed: false)

        // A Malibu.app metrics poll lands between two heartbeats.
        _ = await ControlMetricsBuilder.build(
            providerStatus: status,
            providerEarningsClient: nil,
            malibuAccrualClient: nil,
            providerWalletStatusClient: nil,
            providerToken: nil
        )

        // The heartbeat (resetWindow: true) must still observe the request the
        // poll read — the poll did not steal it from the since-last window.
        let heartbeat = await status.snapshot(resetWindow: true)
        XCTAssertEqual(heartbeat.requestsServedSinceLast, 1)

        // And the heartbeat, which owns rollover, has now cleared the window.
        let afterHeartbeat = await status.snapshot(resetWindow: false)
        XCTAssertEqual(afterHeartbeat.requestsServedSinceLast, 0)
    }

    // Re-audit HIGH (reconciled): a malformed secondary /wallet response must NOT
    // wipe an authoritative, fresh MALIBU projection that a valid /accrual fetch
    // already provided — that would hide REAL earned rewards, the exact harm the
    // HIGH flagged. When accrual is fresh, its real eligibility is honest, not a
    // fabricated benign projection, so the malformed wallet-status is ignored and
    // the accrual projection is preserved (no fail-closed, no fabricated outage).
    func testMalformedWalletStatusPreservesFreshAccrualProjection() async throws {
        let snapshot = await buildSnapshot(walletJSON: Self.walletMalformedAuditJSON)

        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertTrue(earnings.malibuProjectionFresh)
        let eligibility = try XCTUnwrap(earnings.malibuRewardEligibility)
        XCTAssertEqual(eligibility.earningState, "eligible_idle")
        XCTAssertEqual(eligibility.withdrawalState, "withdrawable")
        XCTAssertEqual(earnings.malibuWithdrawable, 10)
        XCTAssertTrue(earnings.walletBound)
        XCTAssertFalse(earnings.rewardTelemetryUnavailable)
    }

    func testMissingWalletRewardEligibilityPreservesFreshAccrualProjection() async throws {
        let snapshot = await buildSnapshot(walletJSON: Self.walletMissingRewardEligibilityJSON)

        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertTrue(earnings.malibuProjectionFresh)
        let eligibility = try XCTUnwrap(earnings.malibuRewardEligibility)
        XCTAssertEqual(eligibility.earningState, "eligible_idle")
        XCTAssertEqual(eligibility.withdrawalState, "withdrawable")
        XCTAssertEqual(earnings.malibuWithdrawable, 10)
        XCTAssertTrue(earnings.walletBound)
        XCTAssertFalse(earnings.rewardTelemetryUnavailable)
    }

    // Re-audit HIGH (fail-closed side, schema-drift class): when the /wallet
    // response is malformed AND there is NO authoritative accrual projection (the
    // /accrual endpoint 5xx'd, so accrual == nil), there is nothing real to
    // preserve — the frame must fail closed and signal the outage rather than
    // fabricating a benign warming-up state.
    func testMalformedWalletStatusWithoutAccrualFailsClosed() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlMetricsMockURLProtocol.self]
        let session = URLSession(configuration: config)
        ControlMetricsMockURLProtocol.requestHandler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/json"])!
            let serverError = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                                              headerFields: ["Content-Type": "application/json"])!
            switch request.url?.path {
            case "/v1/provider/malibu-accrual":
                return (serverError, Data("{}".utf8))
            case "/v1/provider/wallet":
                return (ok, Data(Self.walletMalformedAuditJSON.utf8))
            default:
                return (ok, Data("{}".utf8))
            }
        }
        defer { ControlMetricsMockURLProtocol.requestHandler = nil }

        let snapshot = await ControlMetricsBuilder.build(
            providerStatus: status,
            providerEarningsClient: nil,
            malibuAccrualClient: MalibuAccrualClient(
                accrualURL: URL(string: "https://coordinator.test/v1/provider/malibu-accrual")!,
                session: session
            ),
            providerWalletStatusClient: ProviderWalletStatusClient(
                walletURL: URL(string: "https://coordinator.test/v1/provider/wallet")!,
                session: session
            ),
            providerToken: "provider-token"
        )
        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertTrue(earnings.rewardTelemetryUnavailable)
        XCTAssertFalse(earnings.malibuProjectionFresh)
    }

    // Re-audit HIGH: when accrual SUCCEEDS with real MALIBU amounts, a secondary
    // wallet-status 5xx must NOT wipe the authoritative reward projection. The
    // old behaviour marked the whole frame unavailable, hiding real earned
    // rewards ("MALIBU rewards not available yet"). The accrual projection is
    // authoritative, so it is preserved and no outage is fabricated.
    func testAccrualPreservedWhenOnlyWalletStatus503() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlMetricsMockURLProtocol.self]
        let session = URLSession(configuration: config)
        ControlMetricsMockURLProtocol.requestHandler = { request in
            let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/json"])!
            let serverError = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                                              headerFields: ["Content-Type": "application/json"])!
            switch request.url?.path {
            case "/v1/provider/malibu-accrual":
                return (ok, Data(Self.accrualEligibleJSON.utf8))
            case "/v1/provider/wallet":
                return (serverError, Data("{}".utf8))
            default:
                return (ok, Data("{}".utf8))
            }
        }
        defer { ControlMetricsMockURLProtocol.requestHandler = nil }

        let snapshot = await ControlMetricsBuilder.build(
            providerStatus: status,
            providerEarningsClient: nil,
            malibuAccrualClient: MalibuAccrualClient(
                accrualURL: URL(string: "https://coordinator.test/v1/provider/malibu-accrual")!,
                session: session
            ),
            providerWalletStatusClient: ProviderWalletStatusClient(
                walletURL: URL(string: "https://coordinator.test/v1/provider/wallet")!,
                session: session
            ),
            providerToken: "provider-token"
        )
        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        // Real accrual MALIBU is preserved, projection stays fresh, no false outage.
        XCTAssertFalse(earnings.rewardTelemetryUnavailable)
        XCTAssertTrue(earnings.malibuProjectionFresh)
        XCTAssertEqual(earnings.malibuWithdrawable, 10)
        XCTAssertEqual(earnings.malibuHeld, 0)
    }

    // Re-audit HIGH (fail-closed side): when there is NO authoritative reward
    // projection (accrual AND wallet-status both 5xx), the built frame must carry
    // rewardTelemetryUnavailable so the app never softens a genuine outage into
    // calm "warming up".
    func testOutageSignalledWhenNoAuthoritativeProjection() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlMetricsMockURLProtocol.self]
        let session = URLSession(configuration: config)
        ControlMetricsMockURLProtocol.requestHandler = { request in
            let serverError = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                                              headerFields: ["Content-Type": "application/json"])!
            return (serverError, Data("{}".utf8))
        }
        defer { ControlMetricsMockURLProtocol.requestHandler = nil }

        let snapshot = await ControlMetricsBuilder.build(
            providerStatus: status,
            providerEarningsClient: nil,
            malibuAccrualClient: MalibuAccrualClient(
                accrualURL: URL(string: "https://coordinator.test/v1/provider/malibu-accrual")!,
                session: session
            ),
            providerWalletStatusClient: ProviderWalletStatusClient(
                walletURL: URL(string: "https://coordinator.test/v1/provider/wallet")!,
                session: session
            ),
            providerToken: "provider-token"
        )
        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertTrue(earnings.rewardTelemetryUnavailable)
        XCTAssertFalse(earnings.malibuProjectionFresh)
    }

    // Re-audit MEDIUM: a 5xx on the /providers/{id}/earnings endpoint is a real
    // telemetry outage, not a benign empty first-run frame. A bare `try?` let a
    // 503 look identical to "no earnings yet"; the built frame must flag the
    // outage so the presenter does not take the calm warming-up branch.
    func testEarningsServerErrorSignalsRewardTelemetryOutage() async throws {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlMetricsMockURLProtocol.self]
        let session = URLSession(configuration: config)
        ControlMetricsMockURLProtocol.requestHandler = { request in
            let serverError = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                                              headerFields: ["Content-Type": "application/json"])!
            return (serverError, Data("{}".utf8))
        }
        defer { ControlMetricsMockURLProtocol.requestHandler = nil }

        let snapshot = await ControlMetricsBuilder.build(
            providerStatus: status,
            providerEarningsClient: ProviderEarningsClient(
                earningsURL: URL(string: "https://coordinator.test/v1/providers/mp-test/earnings")!,
                session: session
            ),
            malibuAccrualClient: nil,
            providerWalletStatusClient: nil,
            providerToken: "provider-token"
        )
        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertTrue(earnings.rewardTelemetryUnavailable)
        XCTAssertFalse(earnings.malibuProjectionFresh)
    }

    private func buildSnapshot(walletJSON: String) async -> ControlMetricsSnapshot {
        let status = ProviderStatus(modelID: "m", modelLoaded: true, capacity: makeCapacity())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlMetricsMockURLProtocol.self]
        let session = URLSession(configuration: config)
        ControlMetricsMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer provider-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            switch request.url?.path {
            case "/v1/provider/malibu-accrual":
                return (response, Data(Self.accrualEligibleJSON.utf8))
            case "/v1/provider/wallet":
                return (response, Data(walletJSON.utf8))
            default:
                XCTFail("unexpected path \(request.url?.path ?? "nil")")
                return (response, Data("{}".utf8))
            }
        }
        defer { ControlMetricsMockURLProtocol.requestHandler = nil }

        return await ControlMetricsBuilder.build(
            providerStatus: status,
            providerEarningsClient: nil,
            malibuAccrualClient: MalibuAccrualClient(
                accrualURL: URL(string: "https://coordinator.test/v1/provider/malibu-accrual")!,
                session: session
            ),
            providerWalletStatusClient: ProviderWalletStatusClient(
                walletURL: URL(string: "https://coordinator.test/v1/provider/wallet")!,
                session: session
            ),
            providerToken: "provider-token"
        )
    }

    private static let accrualEligibleJSON = """
    {
      "provider_id": "mp-test",
      "accrued_malibu": "10",
      "withdrawable_malibu": "10",
      "held_malibu": "0",
      "trust_tier": "trusted",
      "wallet_bound": true,
      "trust_criteria_met": 4,
      "trust_criteria_required": 4,
      "daily_cap_malibu": 25,
      "wallet_daily_cap_malibu": 100,
      "withdrawal_hold_reasons": [],
      "reward_eligibility": {
        "schema_version": "malibu_reward_eligibility.v1",
        "earning_state": "eligible_idle",
        "withdrawal_state": "withdrawable",
        "primary_reason": "withdrawable_balance_available",
        "reasons": ["withdrawable_balance_available"]
      }
    }
    """

    private static let walletMalformedAuditJSON = """
    {
      "schema_version": "provider_wallet_status.v1",
      "provider_id": "mp-test",
      "wallet_bound": true,
      "wallet_mismatch": false,
      "reward_wallet": {
        "address": "0xReward",
        "verification_source": "provider_emission_state",
        "cap_replay_pending": false
      },
      "reward_amounts": {
        "accrued_malibu": "10",
        "withdrawable_malibu": "10",
        "held_malibu": "0",
        "provider_daily_cap_malibu": 25,
        "provider_day_malibu": "10",
        "provider_daily_capped": false,
        "wallet_daily_cap_malibu": 100,
        "wallet_day_malibu": "10",
        "wallet_daily_capped": false
      },
      "eligibility_inputs": {
        "trust_tier": "trusted",
        "quarantined": false,
        "receipt_quality": "sufficient_verified_receipts",
        "verified_receipt_count": 100,
        "required_receipt_count": 100,
        "compute_integrity_state": "unknown",
        "attestation_tier": "app_attested",
        "app_attested": true,
        "criteria_met": 4,
        "criteria_required": 4,
        "economic_criteria": ["E1", "E2"],
        "additional_criteria": ["A1", "A4"],
        "wallet_balance_ok": true,
        "uptime_ok": true
      },
      "reward_eligibility": {
        "schema_version": "malibu_reward_eligibility.v1",
        "earning_state": "eligible_idle",
        "withdrawal_state": "withdrawable",
        "primary_reason": "withdrawable_balance_available",
        "reasons": ["withdrawable_balance_available"]
      },
      "audit": {
        "events": [{
          "id": "evt-1",
          "occurred_at": "2026-08-18T01:02:00Z",
          "event_type": "wallet_daily_cap_applied",
          "amount_malibu": "not-a-number",
          "summary": "Reward hit the per-wallet daily cap."
        }]
      }
    }
    """

    private static let walletMissingRewardEligibilityJSON = """
    {
      "schema_version": "provider_wallet_status.v1",
      "provider_id": "mp-test",
      "wallet_bound": true,
      "wallet_mismatch": false,
      "reward_wallet": {
        "address": "0xReward",
        "verification_source": "provider_emission_state",
        "cap_replay_pending": false
      },
      "reward_amounts": {
        "accrued_malibu": "10",
        "withdrawable_malibu": "10",
        "held_malibu": "0",
        "provider_daily_cap_malibu": 25,
        "provider_day_malibu": "10",
        "provider_daily_capped": false,
        "wallet_daily_cap_malibu": 100,
        "wallet_day_malibu": "10",
        "wallet_daily_capped": false
      },
      "eligibility_inputs": {
        "trust_tier": "trusted",
        "quarantined": false,
        "receipt_quality": "sufficient_verified_receipts",
        "verified_receipt_count": 100,
        "required_receipt_count": 100,
        "compute_integrity_state": "unknown",
        "attestation_tier": "app_attested",
        "app_attested": true,
        "criteria_met": 4,
        "criteria_required": 4,
        "economic_criteria": ["E1", "E2"],
        "additional_criteria": ["A1", "A4"],
        "wallet_balance_ok": true,
        "uptime_ok": true
      },
      "audit": {
        "events": [{
          "id": "evt-1",
          "occurred_at": "2026-08-18T01:02:00Z",
          "event_type": "wallet_daily_cap_applied",
          "amount_malibu": "10",
          "summary": "Reward earned."
        }]
      }
    }
    """
}

private final class ControlMetricsMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
