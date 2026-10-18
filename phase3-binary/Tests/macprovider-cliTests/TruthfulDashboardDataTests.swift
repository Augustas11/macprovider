import Foundation
import XCTest
@testable import macprovider_cli

/// #2029 Phase 1: data the Malibu dashboard needs to stay truthful.
final class TruthfulDashboardDataTests: XCTestCase {
    private struct FixedWorkloadTelemetryProvider: ProviderWorkloadTelemetryProviding {
        let value: ProviderWorkloadTelemetry
        func currentWorkloadTelemetry() -> ProviderWorkloadTelemetry { value }
    }

    func testAccrualDecodesLiveTrustEmissionAndRetainedHolds() throws {
        let json = """
        {
          "accrued_malibu": "257.03",
          "withdrawable_malibu": "43.49",
          "held_malibu": "213.54",
          "trust_tier": "provisional",
          "withdrawal_hold_reasons": ["demotion_cooldown", "trust_tier_provisional"],
          "retained_hold_reasons": ["demotion_cooldown"],
          "reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v1",
            "earning_state": "ineligible",
            "withdrawal_state": "held",
            "primary_reason": "hardware_evidence_missing_or_expired",
            "reasons": ["hardware_evidence_missing_or_expired", "held_provisional_trust_tier", "held_retained_trust_hold"]
          },
          "trust_progress": {
            "tier": "provisional",
            "demotion_cooldown_until": "2026-10-10T16:54:00Z",
            "demotion_cooldown_active": false,
            "requalification_required": true,
            "uptime_ok_since": "2026-10-16T03:52:00Z",
            "uptime_required_seconds": 259200,
            "requalification_window_seconds": 259200,
            "verified_receipt_count": 12587,
            "required_receipt_count": 100,
            "criteria_met": ["E1"],
            "earliest_promotion_at": "2026-10-22T03:52:00Z"
          },
          "emission": {"active": false, "last_accrual_at": "2026-08-18T03:05:00Z"}
        }
        """
        let summary = try JSONDecoder().decode(MalibuAccrualSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.rewardEligibility?.reasons.last, "held_retained_trust_hold")
        XCTAssertEqual(summary.retainedHoldReasons, ["demotion_cooldown"])
        XCTAssertEqual(summary.trustProgress?.earliestPromotionAt, "2026-10-22T03:52:00Z")
        XCTAssertEqual(summary.trustProgress?.verifiedReceiptCount, 12587)
        XCTAssertEqual(summary.emission, ProviderEmissionSummary(active: false, lastAccrualAt: "2026-08-18T03:05:00Z"))

        let merged = ProviderEarningsSummary(
            walletBound: true, trustTier: "provisional",
            unpaidLedgerBacklogUSDC: 0, unpaidLedgerBacklogMALIBU: 0,
            usdcToday: 0, usdcWeek: 0.0001, usdcPending: 0.15, usdcLifetime: 0.15,
            malibuToday: nil, malibuAllTime: nil,
            trustCriteriaMet: nil, trustCriteriaRequired: nil,
            earningsProjectionFresh: true,
            payoutsEnabled: false,
            lastPaidJobAtUTC: "2026-10-17T19:49:00Z"
        ).merging(accrual: summary)
        XCTAssertEqual(merged.payoutsEnabled, false)
        XCTAssertEqual(merged.lastPaidJobAtUTC, "2026-10-17T19:49:00Z")
        XCTAssertEqual(merged.trustProgress?.tier, "provisional")
        XCTAssertEqual(merged.emission?.active, false)

        // The control socket forwards the same keys the app decodes.
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(merged)) as? [String: Any]
        XCTAssertEqual(wire?["payouts_enabled"] as? Bool, false)
        XCTAssertEqual(wire?["last_paid_job_at_utc"] as? String, "2026-10-17T19:49:00Z")
        XCTAssertEqual(wire?["malibu_retained_hold_reasons"] as? [String], ["demotion_cooldown"])
        XCTAssertNotNil(wire?["trust_progress"] as? [String: Any])
        XCTAssertEqual((wire?["emission"] as? [String: Any])?["active"] as? Bool, false)
        // Dropping the reward projection keeps payout facts but not trust.
        let unavailable = merged.markingWalletStatusUnavailable()
        XCTAssertEqual(unavailable.payoutsEnabled, false)
        XCTAssertNil(unavailable.trustProgress)
        XCTAssertNil(unavailable.emission)
    }

    func testMalformedTrustBlockIsDroppedNotFatal() throws {
        let json = """
        {
          "accrued_malibu": "1", "withdrawable_malibu": "0", "held_malibu": "1",
          "trust_tier": "provisional",
          "trust_progress": {"tier": "superuser"},
          "emission": "on"
        }
        """
        let summary = try JSONDecoder().decode(MalibuAccrualSummary.self, from: Data(json.utf8))
        XCTAssertNil(summary.trustProgress)
        XCTAssertNil(summary.emission)
    }

    func testMetricsReportRequestsPerMinuteNotTokensAndGPUUtilisation() async throws {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 50_000, maxConcurrencyOverride: 4),
            workloadTelemetryProvider: FixedWorkloadTelemetryProvider(value: ProviderWorkloadTelemetry(
                cpuUtilizationPercent: 10,
                gpuUtilizationPercent: 42,
                gpuUtilizationScope: "host",
                powerSource: .external
            ))
        )
        for index in 0..<3 {
            let started = await status.beginRequest(requestID: "r-\(index)")
            await status.finishRequest(
                startedAt: started,
                completion: CompletionResult(content: "ok", finishReason: "stop", promptTokens: 10, completionTokens: 500, settlementDisposition: .eligibleOwner),
                failed: false,
                requestID: "r-\(index)"
            )
        }
        let metrics = await ControlMetricsBuilder.build(
            providerStatus: status,
            providerEarningsClient: nil,
            malibuAccrualClient: nil,
            providerToken: nil
        )
        // Three requests in a window shorter than a minute: 3 req/min, never
        // completion tokens/s x 60.
        XCTAssertEqual(try XCTUnwrap(metrics.requestsPerMinute), 3, accuracy: 0.01)
        XCTAssertEqual(metrics.gpuUtilizationPct, 42)
        let frame = try JSONSerialization.jsonObject(with: ControlSocketCodec.encodeMetrics(metrics)) as? [String: Any]
        XCTAssertEqual(frame?["gpu_utilization_pct"] as? Double, 42)
    }

    func testStatusAdvertisesCorrectedMetricsCapability() {
        XCTAssertTrue(RouterHandler.localStatusCapabilities.contains("metrics_request_rate_v1"))
    }

    func testRecentRestartCountKeepsOnlySevenDays() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ProviderStatsStore(fileURL: directory.appendingPathComponent("mac.json"))
        let now = Date()
        var record = ProviderStatsRecord.empty(providerID: "mac", now: now)
        record.restartCount = 2286
        record.recentRestartsAt = [now.addingTimeInterval(-8 * 86_400), now.addingTimeInterval(-2 * 86_400)]
        store.save(record)

        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 4_000, maxConcurrencyOverride: 1),
            providerID: "mac",
            statsStore: store
        )
        let snap = await status.snapshot()
        XCTAssertEqual(snap.restartCount, 2287, "lifetime count is unchanged")
        XCTAssertEqual(snap.restartCount7d, 2, "the 8-day-old boot is outside the window; this boot counts")
        XCTAssertEqual(store.load()?.recentRestartsAt?.count, 2)
    }

    func testStatsRecordWithoutRecentRestartsStillLoads() throws {
        let legacy = """
        {"version":1,"provider_id":"mac","requests_total":3,"requests_today":1,
         "requests_today_day_start":"2026-10-17T00:00:00Z","input_tokens_today":1,
         "output_tokens_today":2,"input_tokens_all_time":3,"output_tokens_all_time":4,
         "errors_total":0,"restart_count":5,"updated_at":"2026-10-17T01:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ProviderStatsRecord.self, from: Data(legacy.utf8))
        XCTAssertNil(record.recentRestartsAt)
        XCTAssertEqual(record.restartCount, 5)
    }

    func testTodayCountersUseTheUTCDay() {
        let calendar = ProviderStatus.utcCalendar
        let lateUTC = ISO8601DateFormatter().date(from: "2026-10-17T23:30:00Z")!
        XCTAssertEqual(
            ISO8601DateFormatter().string(from: calendar.startOfDay(for: lateUTC)),
            "2026-10-17T00:00:00Z"
        )
    }
}
