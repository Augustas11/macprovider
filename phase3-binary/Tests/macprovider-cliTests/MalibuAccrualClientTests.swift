import Foundation
import XCTest
@testable import macprovider_cli

final class MalibuAccrualClientTests: XCTestCase {
    func testAccrualURLFromWSSCoordinator() {
        let url = MalibuAccrualClient.accrualURL(from: "wss://coordinator.malibu.tech/v2/provider")
        XCTAssertEqual(url?.absoluteString, "https://coordinator.malibu.tech/v1/provider/malibu-accrual")
    }

    func testAccrualURLFromHTTPSCoordinator() {
        let url = MalibuAccrualClient.accrualURL(from: "https://coordinator.malibu.tech")
        XCTAssertEqual(url?.absoluteString, "https://coordinator.malibu.tech/v1/provider/malibu-accrual")
    }

    func testDecodeAccrualSummaryStringDecimals() throws {
        let json = """
        {
          "accrued_malibu": "12.5",
          "withdrawable_malibu": "0",
          "held_malibu": "12.5",
          "trust_tier": "provisional",
          "trust_criteria_met": 2,
          "trust_criteria_required": 4,
          "wallet_bound": true,
          "daily_cap_malibu": "25",
          "wallet_daily_cap_malibu": 100,
          "withdrawal_hold_reasons": ["trust_tier_provisional"],
          "reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v1",
            "earning_state": "held",
            "withdrawal_state": "held",
            "primary_reason": "held_provisional_trust_tier",
            "reasons": ["held_provisional_trust_tier"]
          }
        }
        """.data(using: .utf8)!
        let summary = try JSONDecoder().decode(MalibuAccrualSummary.self, from: json)
        XCTAssertEqual(summary.accruedMALIBU, 12.5)
        XCTAssertEqual(summary.withdrawableMALIBU, 0)
        XCTAssertEqual(summary.heldMALIBU, 12.5)
        XCTAssertEqual(summary.trustTier, "provisional")
        XCTAssertEqual(summary.trustCriteriaMet, 2)
        XCTAssertEqual(summary.trustCriteriaRequired, 4)
        XCTAssertEqual(summary.walletBound, true)
        XCTAssertEqual(summary.dailyCapMALIBU, 25)
        XCTAssertEqual(summary.walletDailyCapMALIBU, 100)
        XCTAssertEqual(summary.withdrawalHoldReasons, ["trust_tier_provisional"])
        XCTAssertEqual(summary.rewardEligibility?.schemaVersion, "malibu_reward_eligibility.v1")
        XCTAssertEqual(summary.rewardEligibility?.primaryReason, "held_provisional_trust_tier")
    }

    func testRewardEligibilityUnknownSchemaNormalizesUnavailable() throws {
        let json = """
        {
          "accrued_malibu": "0",
          "withdrawable_malibu": "0",
          "held_malibu": "0",
          "trust_tier": "trusted",
          "reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v2",
            "earning_state": "earning",
            "withdrawal_state": "withdrawable",
            "primary_reason": "future_reason",
            "reasons": ["future_reason"]
          }
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(MalibuAccrualSummary.self, from: json)
        XCTAssertEqual(summary.rewardEligibility?.schemaVersion, "malibu_reward_eligibility.v2")
        XCTAssertEqual(summary.rewardEligibility?.earningState, "unavailable")
        XCTAssertEqual(summary.rewardEligibility?.withdrawalState, "unavailable")
        XCTAssertEqual(summary.rewardEligibility?.primaryReason, "telemetry_unavailable")
        XCTAssertEqual(summary.rewardEligibility?.reasons, ["telemetry_unavailable"])
    }

    func testRewardEligibilityUnknownV1ReasonNormalizesUnavailable() throws {
        let json = """
        {
          "accrued_malibu": "0",
          "withdrawable_malibu": "0",
          "held_malibu": "0",
          "trust_tier": "trusted",
          "reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v1",
            "earning_state": "earning",
            "withdrawal_state": "withdrawable",
            "primary_reason": "future_reason",
            "reasons": ["future_reason"]
          }
        }
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(MalibuAccrualSummary.self, from: json)
        XCTAssertEqual(summary.rewardEligibility?.schemaVersion, "malibu_reward_eligibility.v1")
        XCTAssertEqual(summary.rewardEligibility?.earningState, "unavailable")
        XCTAssertEqual(summary.rewardEligibility?.withdrawalState, "unavailable")
        XCTAssertEqual(summary.rewardEligibility?.primaryReason, "telemetry_unavailable")
        XCTAssertEqual(summary.rewardEligibility?.reasons, ["telemetry_unavailable"])
    }

    func testMissingRequiredAmountFailsClosed() {
        let json = Data(#"{"accrued_malibu":1.25,"withdrawable_malibu":0,"trust_tier":"provisional"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MalibuAccrualSummary.self, from: json))
    }

    func testMissingTrustTierFailsClosed() {
        let json = Data(#"{"accrued_malibu":1.25,"withdrawable_malibu":0,"held_malibu":1.25}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MalibuAccrualSummary.self, from: json))
    }

    func testNonFiniteAmountFailsClosed() {
        let json = Data(#"{"accrued_malibu":1.25,"withdrawable_malibu":0,"held_malibu":"NaN","trust_tier":"provisional"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MalibuAccrualSummary.self, from: json))
    }

    func testNonFiniteOptionalCapFailsClosed() throws {
        let json = Data(#"{"accrued_malibu":1.25,"withdrawable_malibu":0,"held_malibu":1.25,"trust_tier":"provisional","daily_cap_malibu":"NaN"}"#.utf8)
        let summary = try JSONDecoder().decode(MalibuAccrualSummary.self, from: json)
        XCTAssertNil(summary.dailyCapMALIBU)
    }

    func testFetchUsesBearerToken() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {"accrued_malibu":1.25,"withdrawable_malibu":0,"held_malibu":1.25,"trust_tier":"provisional"}
            """.data(using: .utf8)!
            return (response, body)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = MalibuAccrualClient(
            accrualURL: URL(string: "https://coordinator.malibu.tech/v1/provider/malibu-accrual")!,
            session: session
        )
        let summary = try await client.fetch(bearerToken: "test-token")
        XCTAssertEqual(summary.accruedMALIBU, 1.25)
    }
}

private final class MockURLProtocol: URLProtocol {
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
