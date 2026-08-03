import Foundation
import XCTest
@testable import macprovider_cli

final class PayoutAddressClientTests: XCTestCase {
    func testEndpointsFromWSSCoordinatorURL() {
        let urls = PayoutAddressClient.endpoints(
            from: "wss://coordinator.streamvc.live/v2/provider?x=1",
            providerID: "prov-1"
        )
        XCTAssertEqual(
            urls?.challenge.absoluteString,
            "https://coordinator.streamvc.live/providers/prov-1/payout-address/challenge"
        )
        XCTAssertEqual(
            urls?.register.absoluteString,
            "https://coordinator.streamvc.live/providers/prov-1/payout-address"
        )
    }

    func testPlaintextCoordinatorURLRejected() {
        // http:// and ws:// bases (which would carry the bearer token
        // over cleartext) must not produce endpoints at all.
        XCTAssertNil(PayoutAddressClient.endpoints(
            from: "http://coordinator.streamvc.live/v2/provider",
            providerID: "prov-1"
        ))
        XCTAssertNil(PayoutAddressClient.endpoints(
            from: "ws://coordinator.streamvc.live/v2/provider",
            providerID: "prov-1"
        ))
        // https:// and wss:// remain valid.
        XCTAssertNotNil(PayoutAddressClient.endpoints(
            from: "https://coordinator.streamvc.live",
            providerID: "prov-1"
        ))
        // Constructing via the throwing initializer surfaces the
        // rejection as invalidCoordinatorURL.
        XCTAssertThrowsError(
            try PayoutAddressClient(coordinatorURL: "http://c.example", providerID: "p")
        ) { error in
            XCTAssertEqual(error as? PayoutAddressClientError, .invalidCoordinatorURL)
        }
    }

    func testHTTPBaseRejectedBeforeTokenSent() async {
        // A client constructed directly with a plaintext http URL must
        // reject before any request (and therefore any bearer token)
        // reaches the network. The mock protocol asserts it is never
        // invoked.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayoutAddressMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        PayoutAddressMockURLProtocol.requestHandler = { _ in
            XCTFail("network must not be reached for a plaintext base URL")
            throw URLError(.badURL)
        }
        defer { PayoutAddressMockURLProtocol.requestHandler = nil }

        let client = PayoutAddressClient(
            challengeURL: URL(string: "http://c.example/providers/p/payout-address/challenge")!,
            registerURL: URL(string: "http://c.example/providers/p/payout-address")!,
            providerID: "p",
            session: session
        )
        do {
            _ = try await client.fetchPayoutChallenge(bearerToken: "secret-token")
            XCTFail("expected invalidCoordinatorURL")
        } catch {
            XCTAssertEqual(error as? PayoutAddressClientError, .invalidCoordinatorURL)
        }
        do {
            _ = try await client.registerPayoutAddress(
                bearerToken: "secret-token",
                chain: "base-mainnet",
                address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                nonce: "0x" + String(repeating: "01", count: 32),
                tsUtc: 1,
                signature: "0x" + String(repeating: "ab", count: 65)
            )
            XCTFail("expected invalidCoordinatorURL")
        } catch {
            XCTAssertEqual(error as? PayoutAddressClientError, .invalidCoordinatorURL)
        }
    }

    func testFetchChallengeDecodesDomainFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayoutAddressMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        PayoutAddressMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data("""
            {
              "verifying_contract": "0x52908400098527886E0F7030069857D2E4169EE7",
              "chain_id": 8453,
              "domain_name": "macprovider-payout",
              "domain_version": "1",
              "chain": "base-mainnet",
              "server_ts_utc": 1719234896,
              "registered_address": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
              "pending_until_utc": "2026-01-09T00:00:00Z",
              "payout_allowed": true
            }
            """.utf8)
            return (response, body)
        }
        defer { PayoutAddressMockURLProtocol.requestHandler = nil }

        let client = PayoutAddressClient(
            challengeURL: URL(string: "https://c.example/providers/p/payout-address/challenge")!,
            registerURL: URL(string: "https://c.example/providers/p/payout-address")!,
            providerID: "p",
            session: session
        )
        let challenge = try await client.fetchPayoutChallenge(bearerToken: "tok")
        XCTAssertEqual(challenge.verifyingContract, "0x52908400098527886E0F7030069857D2E4169EE7")
        XCTAssertEqual(challenge.chainID, 8453)
        XCTAssertEqual(challenge.domainName, "macprovider-payout")
        XCTAssertEqual(challenge.serverTsUTC, 1_719_234_896)
        XCTAssertEqual(challenge.registeredAddress, "0x70997970C51812dc3A010C7d01b50e0d17dc79C8")
        XCTAssertEqual(challenge.payoutAllowed, true)
    }

    func testRegisterMapsCreatedAndErrorCodes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayoutAddressMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        // Success path.
        PayoutAddressMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data("""
            {"chain":"base-mainnet","pending_until_utc":"2026-01-09T00:00:00Z","status":"created"}
            """.utf8)
            return (response, body)
        }
        let client = PayoutAddressClient(
            challengeURL: URL(string: "https://c.example/providers/p/payout-address/challenge")!,
            registerURL: URL(string: "https://c.example/providers/p/payout-address")!,
            providerID: "p",
            session: session
        )
        let result = try await client.registerPayoutAddress(
            bearerToken: "tok",
            chain: "base-mainnet",
            address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
            nonce: "0x" + String(repeating: "01", count: 32),
            tsUtc: 1_719_234_896,
            signature: "0x" + String(repeating: "ab", count: 65)
        )
        XCTAssertEqual(result.httpStatus, 201)
        XCTAssertEqual(result.status, "created")

        // Error mapping.
        PayoutAddressMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://c.example/x")!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"signature_mismatch"}"#.utf8))
        }
        do {
            _ = try await client.registerPayoutAddress(
                bearerToken: "tok",
                chain: "base-mainnet",
                address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
                nonce: "0x" + String(repeating: "02", count: 32),
                tsUtc: 1,
                signature: "0x" + String(repeating: "cd", count: 65)
            )
            XCTFail("expected error")
        } catch let PayoutAddressClientError.httpStatus(code, errorCode) {
            XCTAssertEqual(code, 400)
            XCTAssertEqual(errorCode, "signature_mismatch")
            XCTAssertTrue(
                PayoutAddressClient.userMessage(
                    for: .httpStatus(400, errorCode: "signature_mismatch")
                ).contains("Signature")
            )
        }

        // 409 payout_not_allowed
        XCTAssertTrue(
            PayoutAddressClient.userMessage(for: .httpStatus(409, errorCode: "payout_not_allowed"))
                .contains("not yet enabled")
        )
        // 503 rotation
        XCTAssertTrue(
            PayoutAddressClient.userMessage(for: .httpStatus(503, errorCode: "rotation_in_progress"))
                .contains("rotation")
        )
        PayoutAddressMockURLProtocol.requestHandler = nil
    }
}

private final class PayoutAddressMockURLProtocol: URLProtocol {
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
