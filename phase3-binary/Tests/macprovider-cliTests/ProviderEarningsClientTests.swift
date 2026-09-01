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

    func testLegacyTrustCriteriaPresenceSurvivesCLIControlFrameEncode() throws {
        let legacy = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: Data("""
            {
              "wallet_bound": true,
              "trust_tier": "provisional",
              "unpaid_ledger_backlog_usdc": 0,
              "unpaid_ledger_backlog_malibu": 0,
              "trust_criteria_met": 1,
              "trust_criteria_required": 2,
              "malibu_projection_fresh": true,
              "earnings_projection_fresh": true
            }
            """.utf8)
        )

        XCTAssertNil(legacy.economicCriteria)
        XCTAssertNil(legacy.additionalCriteria)
        let providerEarnings = try encodedProviderEarningsObject(legacy)
        XCTAssertNil(providerEarnings["economic_criteria"])
        XCTAssertNil(providerEarnings["additional_criteria"])
        XCTAssertEqual(providerEarnings["trust_criteria_met"] as? Int, 1)
        XCTAssertEqual(providerEarnings["trust_criteria_required"] as? Int, 2)
    }

    func testEmptyGranularTrustCriteriaPresenceSurvivesCLIControlFrameEncode() throws {
        let modernEmpty = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: Data("""
            {
              "wallet_bound": true,
              "trust_tier": "provisional",
              "unpaid_ledger_backlog_usdc": 0,
              "unpaid_ledger_backlog_malibu": 0,
              "trust_criteria_met": 1,
              "trust_criteria_required": 2,
              "economic_criteria": [],
              "additional_criteria": [],
              "malibu_projection_fresh": true,
              "earnings_projection_fresh": true
            }
            """.utf8)
        )

        XCTAssertEqual(modernEmpty.economicCriteria, [])
        XCTAssertEqual(modernEmpty.additionalCriteria, [])
        let providerEarnings = try encodedProviderEarningsObject(modernEmpty)
        XCTAssertEqual(providerEarnings["economic_criteria"] as? [String], [])
        XCTAssertEqual(providerEarnings["additional_criteria"] as? [String], [])
    }

    func testWalletStatusGranularTrustCriteriaSurvivesCLIControlFrameEncode() throws {
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
                "verified_receipt_count": 3,
                "required_receipt_count": 3,
                "compute_integrity_state": "unknown",
                "attestation_tier": "app_attested",
                "app_attested": true,
                "criteria_met": 2,
                "criteria_required": 2,
                "economic_criteria": ["E2"],
                "additional_criteria": ["A3"],
                "wallet_balance_ok": true,
                "uptime_ok": true
              },
              "reward_eligibility": {
                "schema_version": "malibu_reward_eligibility.v1",
                "earning_state": "held",
                "withdrawal_state": "held",
                "primary_reason": "held_provisional_trust_tier",
                "reasons": ["held_provisional_trust_tier"]
              },
              "audit": {"events": []}
            }
            """.utf8)
        )
        let summary = ProviderEarningsSummary.unavailableWalletStatus().merging(walletStatus: walletStatus)

        let providerEarnings = try encodedProviderEarningsObject(summary)
        XCTAssertEqual(providerEarnings["economic_criteria"] as? [String], ["E2"])
        XCTAssertEqual(providerEarnings["additional_criteria"] as? [String], ["A3"])
        XCTAssertEqual(providerEarnings["trust_criteria_met"] as? Int, 2)
        XCTAssertEqual(providerEarnings["trust_criteria_required"] as? Int, 2)
    }

    func testControlFrameBridgeFixturesMatchCLIEncoder() throws {
        let cases: [(String, ProviderEarningsSummary)] = [
            ("legacy-trust-counters.jsonl", try providerEarningsSummary("""
            {
              "wallet_bound": true,
              "trust_tier": "provisional",
              "unpaid_ledger_backlog_usdc": 0,
              "unpaid_ledger_backlog_malibu": 0,
              "trust_criteria_met": 1,
              "trust_criteria_required": 2,
              "malibu_projection_fresh": true,
              "earnings_projection_fresh": true,
              "malibu_reward_eligibility": {
                "schema_version": "malibu_reward_eligibility.v1",
                "earning_state": "held",
                "withdrawal_state": "held",
                "primary_reason": "held_provisional_trust_tier",
                "reasons": ["held_provisional_trust_tier"]
              }
            }
            """)),
            ("empty-granular-criteria.jsonl", try providerEarningsSummary("""
            {
              "wallet_bound": true,
              "trust_tier": "provisional",
              "unpaid_ledger_backlog_usdc": 0,
              "unpaid_ledger_backlog_malibu": 0,
              "trust_criteria_met": 1,
              "trust_criteria_required": 2,
              "economic_criteria": [],
              "additional_criteria": [],
              "malibu_projection_fresh": true,
              "earnings_projection_fresh": true,
              "malibu_reward_eligibility": {
                "schema_version": "malibu_reward_eligibility.v1",
                "earning_state": "held",
                "withdrawal_state": "held",
                "primary_reason": "held_provisional_trust_tier",
                "reasons": ["held_provisional_trust_tier"]
              }
            }
            """)),
            ("overlapping-granular-criteria.jsonl", try providerEarningsSummary("""
            {
              "wallet_bound": true,
              "trust_tier": "provisional",
              "unpaid_ledger_backlog_usdc": 0,
              "unpaid_ledger_backlog_malibu": 0,
              "trust_criteria_met": 2,
              "trust_criteria_required": 2,
              "economic_criteria": ["E2"],
              "additional_criteria": ["A3"],
              "malibu_projection_fresh": true,
              "earnings_projection_fresh": true,
              "malibu_reward_eligibility": {
                "schema_version": "malibu_reward_eligibility.v1",
                "earning_state": "held",
                "withdrawal_state": "held",
                "primary_reason": "held_provisional_trust_tier",
                "reasons": ["held_provisional_trust_tier"]
              }
            }
            """)),
        ]

        for (fixtureName, providerEarnings) in cases {
            let encoded = try ControlSocketCodec.encode(.metricsResponse(ControlMetricsSnapshot(
                providerEarnings: providerEarnings
            )))
            let fixture = try Self.controlFrameBridgeFixture(named: fixtureName)
            XCTAssertEqual(encoded.last, 0x0A, fixtureName)
            XCTAssertEqual(fixture.last, 0x0A, fixtureName)
            XCTAssertEqual(
                try Self.normalizedJSONData(encoded),
                try Self.normalizedJSONData(fixture),
                fixtureName
            )
        }
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
              "economic_criteria": ["E2"],
              "additional_criteria": ["A3"],
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
        XCTAssertEqual(merged.economicCriteria, ["E2"])
        XCTAssertEqual(merged.additionalCriteria, ["A3"])
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

    private func encodedProviderEarningsObject(
        _ providerEarnings: ProviderEarningsSummary
    ) throws -> [String: Any] {
        let frameData = try ControlSocketCodec.encode(.metricsResponse(ControlMetricsSnapshot(
            providerEarnings: providerEarnings
        )))
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: frameData) as? [String: Any])
        return try XCTUnwrap(frame["provider_earnings"] as? [String: Any])
    }

    private func providerEarningsSummary(_ json: String) throws -> ProviderEarningsSummary {
        try JSONDecoder().decode(ProviderEarningsSummary.self, from: Data(json.utf8))
    }

    private static func controlFrameBridgeFixture(named name: String) throws -> Data {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: testsRoot
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("ControlFrameBridge")
            .appendingPathComponent(name))
    }

    private static func normalizedJSONData(_ data: Data) throws -> Data {
        let trimmed = data.last == 0x0A ? data.dropLast() : data[...]
        let object = try JSONSerialization.jsonObject(with: Data(trimmed))
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
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
