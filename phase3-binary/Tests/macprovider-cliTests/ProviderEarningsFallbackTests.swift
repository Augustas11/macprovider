import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderEarningsFallbackTests: XCTestCase {
    func testAccrualOnlyFallbackPreservesCompleteEncodedProjection() throws {
        let eligibility = """
        {"schema_version":"malibu_reward_eligibility.v1","earning_state":"held",
         "withdrawal_state":"held","primary_reason":"held_provisional_trust_tier",
         "reasons":["held_provisional_trust_tier"]}
        """
        for criteria in ["", ",\"economic_criteria\":[],\"additional_criteria\":null",
                         ",\"economic_criteria\":[\"E2\"],\"additional_criteria\":[\"A3\"]"] {
            for walletBound in ["", ",\"wallet_bound\":true"] {
                let accrualJSON = """
                {"accrued_malibu":"12.5","withdrawable_malibu":"0","held_malibu":"12.5",
                 "trust_tier":"provisional","trust_criteria_met":2,"trust_criteria_required":4,
                 "daily_cap_malibu":"25","wallet_daily_cap_malibu":"100",
                 "withdrawal_hold_reasons":["trust_tier_provisional"],
                 "reward_eligibility":\(eligibility)\(criteria)\(walletBound)}
                """
                let accrual = try JSONDecoder().decode(MalibuAccrualSummary.self, from: Data(accrualJSON.utf8))
                let actual = try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(ProviderEarningsSummary.from(accrual: accrual))
                ) as! NSDictionary
                let expectedCriteria = criteria.replacingOccurrences(of: ":null", with: ":[]")
                let expectedJSON = """
                {"wallet_bound":\(!walletBound.isEmpty),"trust_tier":"provisional",
                 "unpaid_ledger_backlog_usdc":0,"unpaid_ledger_backlog_malibu":0,
                 "malibu_all_time":12.5,"trust_criteria_met":2,"trust_criteria_required":4,
                 "malibu_withdrawable":0,"malibu_held":12.5,
                 "malibu_hold_reasons":["trust_tier_provisional"],
                 "malibu_daily_cap":25,"malibu_wallet_daily_cap":100,
                 "malibu_reward_eligibility":\(eligibility),
                 "idle_prewarm":{"events_last_1h":{},"skips_by_reason_last_1h":{}},
                 "malibu_projection_fresh":true,"earnings_projection_fresh":false\(expectedCriteria)}
                """
                let expected = try JSONSerialization.jsonObject(with: Data(expectedJSON.utf8)) as! NSDictionary
                XCTAssertEqual(actual, expected, "criteria=\(criteria), wallet=\(walletBound)")
            }
        }
    }
}
