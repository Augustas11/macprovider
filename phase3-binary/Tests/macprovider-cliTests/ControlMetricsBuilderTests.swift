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

    func testMalformedWalletStatusPreservesFreshAccrualInMetricsPath() async throws {
        let snapshot = await buildSnapshot(walletJSON: Self.walletMalformedAuditJSON)

        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertTrue(earnings.walletBound)
        XCTAssertEqual(earnings.trustTier, "trusted")
        XCTAssertEqual(earnings.malibuAllTime, 10)
        XCTAssertEqual(earnings.malibuWithdrawable, 10)
        XCTAssertEqual(earnings.malibuHeld, 0)
        XCTAssertEqual(earnings.economicCriteria, ["E2"])
        XCTAssertEqual(earnings.additionalCriteria, ["A3"])
        XCTAssertEqual(earnings.malibuRewardEligibility?.primaryReason, "withdrawable_balance_available")
        XCTAssertTrue(earnings.malibuProjectionFresh)
    }

    func testMalformedWalletStatusWithoutFreshAccrualFailsClosedInMetricsPath() async throws {
        let snapshot = await buildSnapshot(
            walletJSON: Self.walletMalformedAuditJSON,
            includeAccrualClient: false
        )

        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertFalse(earnings.walletBound)
        XCTAssertNil(earnings.malibuWithdrawable)
        XCTAssertEqual(earnings.malibuRewardEligibility?.primaryReason, "telemetry_unavailable")
    }

    func testMissingWalletRewardEligibilityPreservesFreshAccrualInMetricsPath() async throws {
        let snapshot = await buildSnapshot(walletJSON: Self.walletMissingRewardEligibilityJSON)

        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertTrue(earnings.walletBound)
        XCTAssertEqual(earnings.trustTier, "trusted")
        XCTAssertEqual(earnings.malibuAllTime, 10)
        XCTAssertEqual(earnings.malibuWithdrawable, 10)
        XCTAssertEqual(earnings.malibuHeld, 0)
        XCTAssertEqual(earnings.economicCriteria, ["E2"])
        XCTAssertEqual(earnings.additionalCriteria, ["A3"])
        XCTAssertEqual(earnings.malibuRewardEligibility?.primaryReason, "withdrawable_balance_available")
        XCTAssertTrue(earnings.malibuProjectionFresh)
    }

    func testMissingWalletRewardEligibilityWithoutFreshAccrualFailsClosedInMetricsPath() async throws {
        let snapshot = await buildSnapshot(
            walletJSON: Self.walletMissingRewardEligibilityJSON,
            includeAccrualClient: false
        )

        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertFalse(earnings.walletBound)
        XCTAssertNil(earnings.malibuWithdrawable)
        XCTAssertEqual(earnings.malibuRewardEligibility?.primaryReason, "telemetry_unavailable")
    }

    func testWalletSchemaDriftPreservesFreshAccrualInMetricsPath() async throws {
        let snapshot = await buildSnapshot(
            walletJSON: Self.walletSchemaDriftJSON,
            includeAccrualClient: true
        )

        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertTrue(earnings.walletBound)
        XCTAssertEqual(earnings.trustTier, "trusted")
        XCTAssertEqual(earnings.malibuAllTime, 10)
        XCTAssertEqual(earnings.malibuWithdrawable, 10)
        XCTAssertEqual(earnings.malibuHeld, 0)
        XCTAssertEqual(earnings.malibuDailyCap, 25)
        XCTAssertEqual(earnings.malibuWalletDailyCap, 100)
        XCTAssertEqual(earnings.trustCriteriaMet, 4)
        XCTAssertEqual(earnings.trustCriteriaRequired, 4)
        XCTAssertEqual(earnings.economicCriteria, ["E2"])
        XCTAssertEqual(earnings.additionalCriteria, ["A3"])
        XCTAssertEqual(earnings.malibuRewardEligibility?.primaryReason, "withdrawable_balance_available")
        XCTAssertTrue(earnings.malibuProjectionFresh)
    }

    func testWalletSchemaDriftWithoutFreshAccrualFailsClosedInMetricsPath() async throws {
        let snapshot = await buildSnapshot(
            walletJSON: Self.walletSchemaDriftJSON,
            includeAccrualClient: false
        )

        let earnings = try XCTUnwrap(snapshot.providerEarnings)
        XCTAssertFalse(earnings.walletBound)
        XCTAssertNil(earnings.malibuAllTime)
        XCTAssertNil(earnings.malibuWithdrawable)
        XCTAssertNil(earnings.malibuHeld)
        XCTAssertNil(earnings.malibuDailyCap)
        XCTAssertNil(earnings.malibuWalletDailyCap)
        XCTAssertEqual(earnings.malibuRewardEligibility?.primaryReason, "telemetry_unavailable")
        XCTAssertTrue(earnings.malibuProjectionFresh)
    }

    private func buildSnapshot(
        walletJSON: String,
        includeAccrualClient: Bool = true
    ) async -> ControlMetricsSnapshot {
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
            malibuAccrualClient: includeAccrualClient ? MalibuAccrualClient(
                accrualURL: URL(string: "https://coordinator.test/v1/provider/malibu-accrual")!,
                session: session
            ) : nil,
            providerWalletStatusClient: ProviderWalletStatusClient(
                walletURL: URL(string: "https://coordinator.test/v1/provider/wallet")!,
                session: session
            ),
            providerToken: "provider-token"
        )
    }

    private static let walletSchemaDriftJSON = """
    {
      "schema_version": "provider_wallet_status.v2",
      "provider_id": "mp-test",
      "wallet_bound": true
    }
    """

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
      "economic_criteria": ["E2"],
      "additional_criteria": ["A3"],
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
