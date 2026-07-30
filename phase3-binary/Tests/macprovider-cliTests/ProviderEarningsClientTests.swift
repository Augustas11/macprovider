import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderEarningsClientTests: XCTestCase {
    func testEarningsURLReplacesCoordinatorWebSocketPathAndEscapesProviderID() {
        let url = ProviderEarningsClient.earningsURL(
            from: "wss://coordinator.streamvc.live/v2/provider?ignored=true",
            providerID: "provider/a"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://coordinator.streamvc.live/providers/provider%2Fa/earnings"
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
              "trust_criteria_required": 4
            }
            """.utf8)
            return (response, body)
        }
        defer { ProviderEarningsMockURLProtocol.requestHandler = nil }

        let client = ProviderEarningsClient(
            earningsURL: URL(string: "https://coordinator.streamvc.live/providers/p/earnings")!,
            session: session
        )
        let summary = try await client.fetch(bearerToken: "cli-token")

        XCTAssertTrue(summary.walletBound)
        XCTAssertEqual(summary.trustTier, "trusted")
        XCTAssertEqual(summary.usdcToday, 3)
        XCTAssertEqual(summary.malibuAllTime, 200)
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
    }

    func testAccrualProjectionFillsTrustAndMalibuWithoutInventingUSDC() throws {
        let earnings = try JSONDecoder().decode(
            ProviderEarningsSummary.self,
            from: Data("{\"unpaid_ledger_backlog_usdc\":2}".utf8)
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
              "wallet_bound": true
            }
            """.utf8)
        )

        let merged = earnings.merging(accrual: accrual)
        XCTAssertTrue(merged.walletBound)
        XCTAssertEqual(merged.malibuAllTime, 12.5)
        XCTAssertEqual(merged.trustCriteriaMet, 2)
        XCTAssertNil(merged.usdcToday)
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
