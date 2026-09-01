import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderEarningsClientTests: XCTestCase {
    func testEarningsURLReplacesCoordinatorWebSocketPathAndEscapesProviderID() {
        let url = ProviderEarningsClient.earningsURL(
            from: "wss://coordinator.malibu.tech/v2/provider?ignored=true",
            providerID: "provider/a"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://coordinator.malibu.tech/providers/provider%2Fa/earnings"
        )
    }

    func testFetchUsesCLIOwnedBearerAndDecodesReadModel() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderEarningsMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ProviderEarningsMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data("""
            {
              "wallet_bound": true,
              "trust_tier": "trusted",
              "unpaid_ledger_backlog_usdc": 1.25,
              "unpaid_ledger_backlog_malibu": 2.5,
              "usdc_today": 3,
              "usdc_week": 8,
              "usdc_pending": 1,
              "usdc_lifetime": 100,
              "malibu_today": 4,
              "malibu_all_time": 200,
              "trust_criteria_met": 4,
              "trust_criteria_required": 4,
              "malibu_withdrawable": 3.5,
              "malibu_held": 0.5,
              "malibu_hold_reasons": ["per_wallet_daily_cap"],
              "malibu_daily_cap": 25,
              "malibu_wallet_daily_cap": 100,
              "idle_prewarm": {
                "events_last_1h": {"idle_prewarm_started": 6, "idle_prewarm_completed": 5},
                "skips_by_reason_last_1h": {"on_battery": 2}
              }
            }
            """.utf8)
            return (response, body)
        }
        defer { ProviderEarningsMockURLProtocol.requestHandler = nil }

        let client = ProviderEarningsClient(
            earningsURL: URL(string: "https://coordinator.malibu.tech/providers/p/earnings")!,
            session: session
        )
        let summary = try await client.fetch(bearerToken: "cli-token")

        XCTAssertTrue(summary.walletBound)
        XCTAssertEqual(summary.trustTier, "trusted")
        XCTAssertEqual(summary.usdcToday, 3)
        XCTAssertEqual(summary.malibuAllTime, 200)
        XCTAssertEqual(summary.malibuWithdrawable, 3.5)
        XCTAssertEqual(summary.malibuHeld, 0.5)
        XCTAssertEqual(summary.malibuHoldReasons, ["per_wallet_daily_cap"])
        XCTAssertEqual(summary.malibuDailyCap, 25)
        XCTAssertEqual(summary.malibuWalletDailyCap, 100)
        XCTAssertEqual(summary.idlePrewarm.eventsLast1h["idle_prewarm_started"], 6)
        XCTAssertEqual(summary.idlePrewarm.skipsByReasonLast1h["on_battery"], 2)
        XCTAssertTrue(summary.earningsProjectionFresh)
        XCTAssertFalse(summary.malibuProjectionFresh)
    }

    func testCurrentCoordinatorPayloadDefaultsAbsentPresentationFields() throws {
        let summary = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: Data("""
            {
              "provider_id": "p-current",
              "total_credits": "17.5",
              "unpaid_ledger_backlog_usdc": 1.25
            }
            """.utf8)
        )

        XCTAssertFalse(summary.walletBound)
        XCTAssertEqual(summary.trustTier, "provisional")
        XCTAssertEqual(summary.unpaidLedgerBacklogUSDC, 1.25)
        XCTAssertNil(summary.usdcToday)
        XCTAssertNil(summary.malibuAllTime)
        XCTAssertEqual(summary.idlePrewarm, .empty)
        XCTAssertFalse(summary.earningsProjectionFresh)
        XCTAssertFalse(summary.malibuProjectionFresh)
    }

    func testFreshMalibuProjectionWithoutRewardEligibilityNormalizesUnavailable() throws {
        let summary = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: Data("""
            {
              "wallet_bound": false,
              "trust_tier": "trusted",
              "unpaid_ledger_backlog_usdc": 0,
              "unpaid_ledger_backlog_malibu": 8,
              "malibu_withdrawable": 8,
              "malibu_held": 0,
              "malibu_projection_fresh": true
            }
            """.utf8)
        )

        XCTAssertTrue(summary.malibuProjectionFresh)
        XCTAssertEqual(summary.malibuRewardEligibility?.schemaVersion, "malibu_reward_eligibility.v1")
        XCTAssertEqual(summary.malibuRewardEligibility?.earningState, "unavailable")
        XCTAssertEqual(summary.malibuRewardEligibility?.withdrawalState, "unavailable")
        XCTAssertEqual(summary.malibuRewardEligibility?.primaryReason, "telemetry_unavailable")
        XCTAssertEqual(summary.malibuRewardEligibility?.reasons, ["telemetry_unavailable"])
    }

    func testAccrualProjectionFillsTrustAndMalibuWithoutInventingUSDC() throws {
        let earnings = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: Data("""
            {
              "unpaid_ledger_backlog_usdc": 2,
              "idle_prewarm": {
                "events_last_1h": {},
                "skips_by_reason_last_1h": {"model_not_loaded": 3}
              }
            }
            """.utf8)
        )
        let accrual = try JSONDecoder().decode(
            MalibuAccrualSummary.self,
            from: Data("""
            {
              "accrued_malibu": "12.5",
              "withdrawable_malibu": "0",
              "held_malibu": "12.5",
              "trust_tier": "provisional",
              "trust_criteria_met": 2,
              "trust_criteria_required": 4,
              "wallet_bound": true,
              "daily_cap_malibu": "25",
              "wallet_daily_cap_malibu": "100",
              "withdrawal_hold_reasons": ["trust_tier_provisional"],
              "reward_eligibility": {
                "schema_version": "malibu_reward_eligibility.v1",
                "earning_state": "held",
                "withdrawal_state": "held",
                "primary_reason": "held_provisional_trust_tier",
                "reasons": ["held_provisional_trust_tier"]
              }
            }
            """.utf8)
        )

        let merged = earnings.merging(accrual: accrual)
        XCTAssertTrue(merged.walletBound)
        XCTAssertEqual(merged.malibuAllTime, 12.5)
        XCTAssertEqual(merged.trustCriteriaMet, 2)
        XCTAssertNil(merged.usdcToday)
        XCTAssertEqual(merged.malibuWithdrawable, 0)
        XCTAssertEqual(merged.malibuHeld, 12.5)
        XCTAssertEqual(merged.malibuHoldReasons, ["trust_tier_provisional"])
        XCTAssertEqual(merged.malibuDailyCap, 25)
        XCTAssertEqual(merged.malibuWalletDailyCap, 100)
        XCTAssertEqual(merged.malibuRewardEligibility?.primaryReason, "held_provisional_trust_tier")
        XCTAssertEqual(merged.idlePrewarm.skipsByReasonLast1h["model_not_loaded"], 3)
        XCTAssertTrue(merged.malibuProjectionFresh)
        XCTAssertFalse(merged.earningsProjectionFresh)
    }

    // P1.5: the wallet-status eligibility inputs carry the granular trust
    // criteria; merging must forward them, and the control-frame JSON encode
    // must round-trip the new keys so Malibu can render criteria by name.
    func testWalletStatusMergeForwardsAndEncodesTrustCriteria() throws {
        let walletStatus = try JSONDecoder().decode(
            ProviderWalletStatusSummary.self,
            from: Data("""
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
                "withdrawable_malibu": "0",
                "held_malibu": "10",
                "provider_daily_cap_malibu": 25,
                "provider_day_malibu": "10",
                "provider_daily_capped": false,
                "wallet_daily_cap_malibu": 100,
                "wallet_day_malibu": "10",
                "wallet_daily_capped": false
              },
              "eligibility_inputs": {
                "trust_tier": "provisional",
                "quarantined": false,
                "receipt_quality": "sufficient_verified_receipts",
                "verified_receipt_count": 137,
                "required_receipt_count": 100,
                "compute_integrity_state": "unknown",
                "attestation_tier": "app_attested",
                "app_attested": true,
                "criteria_met": 1,
                "criteria_required": 2,
                "economic_criteria": ["E1"],
                "additional_criteria": [],
                "wallet_balance_ok": false,
                "uptime_ok": false
              },
              "reward_eligibility": {
                "schema_version": "malibu_reward_eligibility.v1",
                "earning_state": "held",
                "withdrawal_state": "held",
                "primary_reason": "held_provisional_trust_tier",
                "reasons": ["held_provisional_trust_tier"]
              },
              "audit": { "events": [] }
            }
            """.utf8)
        )
        let base = try JSONDecoder().decode(ProviderEarningsSummary.self, from: Data("{}".utf8))
        let merged = base.merging(walletStatus: walletStatus)
        XCTAssertEqual(merged.economicCriteria, ["E1"])
        XCTAssertEqual(merged.additionalCriteria, [])
        XCTAssertEqual(merged.verifiedReceiptCount, 137)
        XCTAssertEqual(merged.appAttested, true)

        let encoded = try JSONEncoder().encode(merged)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(obj["economic_criteria"] as? [String], ["E1"])
        XCTAssertEqual(obj["additional_criteria"] as? [String], [])
        XCTAssertEqual(obj["verified_receipt_count"] as? Int, 137)
        XCTAssertEqual(obj["app_attested"] as? Bool, true)
    }

    // MED-3: the accrual endpoint also emits the granular trust criteria; the
    // accrual-only producer path must forward them, not erase them.
    func testAccrualPathForwardsTrustCriteriaFields() throws {
        let accrual = try JSONDecoder().decode(
            MalibuAccrualSummary.self,
            from: Data("""
            {
              "accrued_malibu": "3",
              "withdrawable_malibu": "0",
              "held_malibu": "3",
              "trust_tier": "provisional",
              "trust_criteria_met": 1,
              "trust_criteria_required": 2,
              "economic_criteria": ["E1"],
              "additional_criteria": [],
              "verified_receipt_count": 137,
              "app_attested": false,
              "wallet_bound": true,
              "withdrawal_hold_reasons": ["trust_tier_provisional"],
              "reward_eligibility": {
                "schema_version": "malibu_reward_eligibility.v1",
                "earning_state": "held",
                "withdrawal_state": "held",
                "primary_reason": "held_provisional_trust_tier",
                "reasons": ["held_provisional_trust_tier"]
              }
            }
            """.utf8)
        )
        XCTAssertEqual(accrual.economicCriteria, ["E1"])
        XCTAssertEqual(accrual.additionalCriteria, [])
        XCTAssertEqual(accrual.verifiedReceiptCount, 137)
        XCTAssertEqual(accrual.appAttested, false)

        let fromAccrual = ProviderEarningsSummary.from(accrual: accrual)
        XCTAssertEqual(fromAccrual.economicCriteria, ["E1"])
        XCTAssertEqual(fromAccrual.verifiedReceiptCount, 137)

        let base = try JSONDecoder().decode(ProviderEarningsSummary.self, from: Data("{}".utf8))
        let merged = base.merging(accrual: accrual)
        XCTAssertEqual(merged.economicCriteria, ["E1"])
        XCTAssertEqual(merged.verifiedReceiptCount, 137)
        XCTAssertEqual(merged.appAttested, false)
    }

    // HIGH-2: a wallet-status telemetry failure preserves the earnings-frame
    // walletBound and marks the MALIBU projection NOT fresh (no fabricated
    // walletBound=false, no fresh telemetry_unavailable eligibility).
    func testMarkingWalletStatusUnavailablePreservesWalletAndMarksNotFresh() throws {
        let base = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: Data("""
            {"wallet_bound": true, "trust_tier": "trusted",
             "unpaid_ledger_backlog_usdc": 0, "unpaid_ledger_backlog_malibu": 0,
             "usdc_today": 0.03}
            """.utf8)
        )
        let unavailable = base.markingWalletStatusUnavailable()
        XCTAssertTrue(unavailable.walletBound)
        XCTAssertFalse(unavailable.malibuProjectionFresh)
        XCTAssertNil(unavailable.malibuRewardEligibility)
        XCTAssertNil(unavailable.malibuWithdrawable)
        XCTAssertEqual(unavailable.usdcToday, 0.03)
        // Re-audit HIGH: the outage is signalled explicitly (not left
        // indistinguishable from a benign first-run absence) and survives the
        // control-socket wire so the app can surface it honestly.
        XCTAssertTrue(unavailable.rewardTelemetryUnavailable)
        let roundTripped = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: JSONEncoder().encode(unavailable)
        )
        XCTAssertTrue(roundTripped.rewardTelemetryUnavailable)
        // A normal fresh frame never sets the outage flag.
        XCTAssertFalse(base.markingEarningsProjectionFresh().rewardTelemetryUnavailable)
    }

    // Re-audit HIGH: the no-base wallet-status outage factory (used when there
    // is neither an earnings nor an accrual frame to preserve) must ALSO signal
    // the outage, or the app softens it into calm first-run "warming up".
    func testUnavailableWalletStatusFactorySignalsOutage() throws {
        let outage = ProviderEarningsSummary.unavailableWalletStatus()
        XCTAssertTrue(outage.rewardTelemetryUnavailable)
        XCTAssertFalse(outage.malibuProjectionFresh)
        let roundTripped = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: JSONEncoder().encode(outage)
        )
        XCTAssertTrue(roundTripped.rewardTelemetryUnavailable)
    }

    // LOW-7: every coordinator reward reason (incl. epoch-disposition) survives
    // decode; an unknown future reason still fails closed to unavailable.
    func testEveryCoordinatorRewardReasonRoundTrips() throws {
        let reasons = [
            "earning_verified_work", "eligible_idle_no_work", "held_provisional_trust_tier",
            "held_provider_daily_cap", "held_wallet_daily_cap", "held_demotion_cooldown",
            "held_epoch_disposition", "excluded_epoch_disposition",
            "burned_or_retired_epoch_disposition", "withdrawable_balance_available",
            "withdrawable_no_balance", "missing_wallet_binding", "insufficient_verified_receipts",
            "app_attestation_missing", "hardware_evidence_unavailable",
            "hardware_evidence_missing_or_expired", "compute_integrity_unavailable",
            "compute_integrity_pending", "compute_integrity_blocked", "provider_token_untrusted",
            "local_on_battery", "local_thermal_pressure", "model_not_ready", "telemetry_unavailable",
        ]
        for reason in reasons {
            let json = """
            {"schema_version":"malibu_reward_eligibility.v1","earning_state":"held",
             "withdrawal_state":"held","primary_reason":"\(reason)","reasons":["\(reason)"]}
            """
            let decoded = try JSONDecoder().decode(MalibuRewardEligibility.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.primaryReason, reason, "reason \(reason) should round-trip")
        }
        let unknown = """
        {"schema_version":"malibu_reward_eligibility.v1","earning_state":"held",
         "withdrawal_state":"held","primary_reason":"future_unknown_reason","reasons":["future_unknown_reason"]}
        """
        let decoded = try JSONDecoder().decode(MalibuRewardEligibility.self, from: Data(unknown.utf8))
        XCTAssertEqual(decoded.primaryReason, "telemetry_unavailable")
        XCTAssertEqual(decoded.withdrawalState, "unavailable")
    }
}

private final class ProviderEarningsMockURLProtocol: URLProtocol {
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
