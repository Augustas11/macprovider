import Foundation
import XCTest
@testable import Malibu

final class MalibuAccrualClientTests: XCTestCase {
    func testDecodeAccrualSummary() throws {
        let json = """
        {
          "accrued_malibu": "3.75",
          "withdrawable_malibu": "0",
          "held_malibu": "3.75",
          "trust_tier": "trusted",
          "trust_criteria_met": 4,
          "trust_criteria_required": 4,
          "wallet_bound": true
        }
        """.data(using: .utf8)!
        let summary = try JSONDecoder().decode(MalibuAccrualSummary.self, from: json)
        XCTAssertEqual(summary.accruedMALIBU, 3.75)
        XCTAssertEqual(summary.trustTier, .trusted)
        XCTAssertEqual(summary.trustCriteriaMet, 4)
        XCTAssertEqual(summary.walletBound, true)
    }
}
