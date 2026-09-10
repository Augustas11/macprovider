import Foundation
import XCTest
@testable import macprovider_cli

final class ProviderRewardAuditClientTests: XCTestCase {
    override func tearDown() {
        RewardAuditMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAuditURLUsesHTTPSAndDropsCoordinatorPathAndQuery() {
        XCTAssertEqual(
            ProviderRewardAuditClient.auditURL(
                from: "wss://coordinator.malibu.tech/v2/provider?secret=ignored"
            )?.absoluteString,
            "https://coordinator.malibu.tech/v1/provider/malibu-reward-audit"
        )
        XCTAssertNil(ProviderRewardAuditClient.auditURL(from: "http://coordinator.malibu.tech"))
    }

    func testFetchUsesBearerAndPaginationWithoutExposingProviderID() async throws {
        let session = makeSession()
        RewardAuditMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 10)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer provider-token")
            let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/v1/provider/malibu-reward-audit")
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) }),
                ["limit": "10", "before_id": "mra_42"]
            )
            return Self.response(
                request: request,
                status: 200,
                body: """
                {
                  "events": [{
                    "id":"mra_41",
                    "occurred_at":"2026-09-10T01:02:03.123Z",
                    "event_type":"malibu_accrual_inserted",
                    "amount_malibu":"2.50000000",
                    "source_reason":"malibu_verified_useful_work_v0_2",
                    "summary":"Verified useful work reward recorded.",
                    "future_field":"ignored"
                  }],
                  "next_before_id":"mra_40",
                  "future_page_field":true
                }
                """
            )
        }

        let page = try await ProviderRewardAuditClient(
            auditURL: URL(string: "https://coordinator.malibu.tech/v1/provider/malibu-reward-audit")!,
            session: session
        ).fetch(bearerToken: "provider-token", beforeID: "mra_42")

        XCTAssertEqual(page.events.map(\.id), ["mra_41"])
        XCTAssertEqual(page.events.first?.amountMALIBU, 2.5)
        XCTAssertEqual(page.events.first?.sourceReason, "malibu_verified_useful_work_v0_2")
        XCTAssertEqual(page.nextBeforeID, "mra_40")
    }

    func testFetchRejectsInvalidLocalCursorWithoutNetworkRequest() async {
        let session = makeSession()
        RewardAuditMockURLProtocol.requestHandler = { request in
            XCTFail("unexpected request: \(request)")
            return Self.response(request: request, status: 500, body: "{}")
        }

        do {
            _ = try await ProviderRewardAuditClient(
                auditURL: URL(string: "https://coordinator.malibu.tech/v1/provider/malibu-reward-audit")!,
                session: session
            ).fetch(bearerToken: "provider-token", beforeID: "mra_01")
            XCTFail("expected invalidPageRequest")
        } catch let error as ProviderRewardAuditClientError {
            XCTAssertEqual(error, .invalidPageRequest)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFetchRejectsMalformedResponseCursor() async {
        let session = makeSession()
        RewardAuditMockURLProtocol.requestHandler = { request in
            Self.response(
                request: request,
                status: 200,
                body: #"{"events":[],"next_before_id":"not-a-cursor"}"#
            )
        }

        do {
            _ = try await ProviderRewardAuditClient(
                auditURL: URL(string: "https://coordinator.malibu.tech/v1/provider/malibu-reward-audit")!,
                session: session
            ).fetch(bearerToken: "provider-token")
            XCTFail("expected invalidResponse")
        } catch let error as ProviderRewardAuditClientError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFetchPreservesRateLimitRetryAfter() async {
        let session = makeSession()
        RewardAuditMockURLProtocol.requestHandler = { request in
            Self.response(request: request, status: 429, body: "{}", headers: ["Retry-After": "17"])
        }

        do {
            _ = try await ProviderRewardAuditClient(
                auditURL: URL(string: "https://coordinator.malibu.tech/v1/provider/malibu-reward-audit")!,
                session: session
            ).fetch(bearerToken: "provider-token")
            XCTFail("expected rate limit")
        } catch let error as ProviderRewardAuditClientError {
            XCTAssertEqual(error, .httpStatus(429, retryAfterSeconds: 17))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFetchMapsTransportFailureToUnavailable() async {
        let session = makeSession()
        RewardAuditMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await ProviderRewardAuditClient(
                auditURL: URL(string: "https://coordinator.malibu.tech/v1/provider/malibu-reward-audit")!,
                session: session
            ).fetch(bearerToken: "provider-token")
            XCTFail("expected unavailable")
        } catch let error as ProviderRewardAuditClientError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RewardAuditMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        request: URLRequest,
        status: Int,
        body: String,
        headers: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!,
            Data(body.utf8)
        )
    }
}

private final class RewardAuditMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.requestHandler else {
                throw URLError(.badServerResponse)
            }
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
