import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class ConsumeTrustedPricingTests: XCTestCase {
    func testValidSignedRateCardIsAdmittedAndMatchesExactNormalizedDefaultRows() throws {
        let fixture = try SignedRateCardFixture(generatedAt: "2026-08-01T00:00:00Z")
        let loader = fixture.loader(now: "2026-08-10T00:00:00Z")

        let trusted = try loader.verify(rateCardBytes: fixture.body, sidecarBytes: fixture.sidecar)

        XCTAssertEqual(trusted.policyVersion, fixture.policyVersion)
        XCTAssertEqual(trusted.signerKeyID, fixture.keyID)
        XCTAssertFalse(trusted.stale)
        XCTAssertEqual(trusted.match(model: "llama-test")?.source, .exact)
        XCTAssertEqual(trusted.match(model: "mlx-community/qwen3-32b")?.rateCardKey, "qwen3-32b")
        XCTAssertEqual(trusted.match(model: "unknown-model")?.source, .defaultFallback)
        XCTAssertEqual(trusted.warningCodes(match: trusted.match(model: "unknown-model")), ["default_pricing_tier_used"])
    }

    func testInvalidSidecarSignatureAndPolicyFailClosed() throws {
        let fixture = try SignedRateCardFixture(generatedAt: "2026-08-01T00:00:00Z")
        let loader = fixture.loader(now: "2026-08-10T00:00:00Z")

        let duplicateSidecar = Data("""
        {"key_id":"\(fixture.keyID)","key_id":"\(fixture.keyID)","alg":"ed25519","signature":"AAAA"}
        """.utf8)
        XCTAssertEqual(try verifyFailure(loader, body: fixture.body, sidecar: duplicateSidecar), .invalidSidecar)

        var tamperedBody = fixture.body
        tamperedBody.append(0x20)
        XCTAssertEqual(try verifyFailure(loader, body: tamperedBody, sidecar: fixture.sidecar), .invalidSignature)

        let policyMismatch = fixture.loader(now: "2026-08-10T00:00:00Z", expectedPolicyVersion: "other-policy")
        XCTAssertEqual(try verifyFailure(policyMismatch, body: fixture.body, sidecar: fixture.sidecar), .policyMismatch)
    }

    func testNestedSidecarShapeFailsClosedWithoutRecursiveParsing() throws {
        let fixture = try SignedRateCardFixture(generatedAt: "2026-08-01T00:00:00Z")
        let loader = fixture.loader(now: "2026-08-10T00:00:00Z")
        let nestedValue = String(repeating: "[", count: 256) + String(repeating: "]", count: 256)
        let nestedSidecar = Data("""
        {"key_id":\(nestedValue),"alg":"ed25519","signature":"AAAA"}
        """.utf8)

        XCTAssertEqual(try verifyFailure(loader, body: fixture.body, sidecar: nestedSidecar), .invalidSidecar)
    }

    func testSignedRateCardWithInvalidModelKeyFailsClosed() throws {
        let invalidRows = SignedRateCardFixture.defaultRows.merging([
            "Bad Key": RateCardProjection.Row(
                promptRatePerMtok: 1,
                promptCacheHitRatePerMtok: 1,
                completionRatePerMtok: 1,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
        ]) { current, _ in current }
        let fixture = try SignedRateCardFixture(generatedAt: "2026-08-01T00:00:00Z", rows: invalidRows)
        let loader = fixture.loader(now: "2026-08-10T00:00:00Z")

        XCTAssertEqual(try verifyFailure(loader, body: fixture.body, sidecar: fixture.sidecar), .invalidRateCard)
    }

    func testFreshnessBoundariesFailClosedOrWarnWhenStale() throws {
        let fresh = try SignedRateCardFixture(generatedAt: "2026-08-01T00:00:00Z")
        let staleLoader = fresh.loader(now: "2026-08-20T00:00:00Z")
        let stale = try staleLoader.verify(rateCardBytes: fresh.body, sidecarBytes: fresh.sidecar)
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.statusWarningCodes, ["stale_pricing"])

        let expiredLoader = fresh.loader(now: "2026-09-01T00:00:01Z")
        XCTAssertEqual(try verifyFailure(expiredLoader, body: fresh.body, sidecar: fresh.sidecar), .expired)

        let future = try SignedRateCardFixture(generatedAt: "2026-08-01T00:11:00Z")
        let futureLoader = future.loader(now: "2026-08-01T00:00:00Z")
        XCTAssertEqual(try verifyFailure(futureLoader, body: future.body, sidecar: future.sidecar), .futureSkew)

        let replayed = try SignedRateCardFixture(generatedAt: "2026-07-01T00:00:00Z")
        let replayedLoader = replayed.loader(
            now: "2026-07-10T00:00:00Z",
            minimumGeneratedAt: SignedRateCardFixture.date("2026-08-28T11:07:13Z")
        )
        XCTAssertEqual(try verifyFailure(replayedLoader, body: replayed.body, sidecar: replayed.sidecar), .olderThanBaked)
    }

    func testLoaderFetchesCanonicalEndpointsAndFailsClosedWithoutFallback() async throws {
        let fixture = try SignedRateCardFixture(generatedAt: "2026-09-02T12:00:00Z")
        let loader = ConsumeTrustedPricingLoader(
            fetch: { url in
                switch url.path {
                case "/v1/rate-card":
                    return fixture.body
                case "/v1/rate-card.sig":
                    return fixture.sidecar
                default:
                    throw ConsumeTrustedPricingError(.fetchFailed)
                }
            },
            trustedPublicKeys: fixture.trustedPublicKeys,
            expectedPolicyVersion: fixture.policyVersion,
            now: { SignedRateCardFixture.date("2026-09-03T00:00:00Z") }
        )

        let loaded = await loader.load(from: "https://api.example.test")
        XCTAssertEqual(loaded, .available(try loader.verify(rateCardBytes: fixture.body, sidecarBytes: fixture.sidecar)))

        let failingLoader = ConsumeTrustedPricingLoader(
            fetch: { _ in throw ConsumeTrustedPricingError(.fetchFailed) },
            trustedPublicKeys: fixture.trustedPublicKeys,
            expectedPolicyVersion: fixture.policyVersion,
            now: { SignedRateCardFixture.date("2026-08-29T00:00:00Z") }
        )
        let failed = await failingLoader.load(from: "https://api.example.test")
        XCTAssertEqual(failed, .unavailable(reason: .fetchFailed))
    }

    func testDefaultFetchRejectsUnboundedHeadersStatusAndOversizedMetadata() async throws {
        defer { ConsumeTrustedPricingMockURLProtocol.requestHandler = nil }
        let url = URL(string: "https://api.example.test/v1/rate-card.sig")!

        ConsumeTrustedPricingMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            var headers: [String: String] = [:]
            for index in 0 ... ConsumeTrustedPricingLoader.maxResponseHeaderCount {
                headers["X-Test-\(index)"] = "v"
            }
            return Self.response(for: request, status: 200, headers: headers, data: Data())
        }
        let headerFailure = try await fetchFailure(url)
        XCTAssertEqual(headerFailure, .fetchFailed)

        ConsumeTrustedPricingMockURLProtocol.requestHandler = { request in
            Self.response(
                for: request,
                status: 200,
                headers: ["Content-Length": "\(ConsumeTrustedPricingLoader.maxSidecarBytes + 1)"],
                data: Data()
            )
        }
        let sizeFailure = try await fetchFailure(url)
        XCTAssertEqual(sizeFailure, .oversizedSidecar)

        ConsumeTrustedPricingMockURLProtocol.requestHandler = { request in
            Self.response(for: request, status: 500, headers: [:], data: Data("nope".utf8))
        }
        let statusFailure = try await fetchFailure(url)
        XCTAssertEqual(statusFailure, .fetchFailed)
    }

    private func verifyFailure(
        _ loader: ConsumeTrustedPricingLoader,
        body: Data,
        sidecar: Data
    ) throws -> ConsumeTrustedPricingUnavailableReason {
        do {
            _ = try loader.verify(rateCardBytes: body, sidecarBytes: sidecar)
            XCTFail("verification unexpectedly succeeded")
            return .notLoaded
        } catch let error as ConsumeTrustedPricingError {
            return error.reason
        }
    }

    private func fetchFailure(_ url: URL) async throws -> ConsumeTrustedPricingUnavailableReason {
        do {
            let session = ConsumeTrustedPricingLoader.defaultURLSession(protocolClasses: [ConsumeTrustedPricingMockURLProtocol.self])
            _ = try await ConsumeTrustedPricingLoader.fetch(url, session: session)
            XCTFail("fetch unexpectedly succeeded")
            return .notLoaded
        } catch let error as ConsumeTrustedPricingError {
            return error.reason
        }
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        headers: [String: String],
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
            data
        )
    }
}

private final class ConsumeTrustedPricingMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct SignedRateCardFixture {
    let keyID = "consume-test-key"
    let policyVersion = "consume-test-policy"
    let body: Data
    let sidecar: Data
    let trustedPublicKeys: [String: String]

    init(generatedAt: String, rows: [String: RateCardProjection.Row]? = nil) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        trustedPublicKeys = [keyID: privateKey.publicKey.rawRepresentation.base64EncodedString()]
        body = Self.rateCardBody(generatedAt: generatedAt, policyVersion: policyVersion, rows: rows ?? Self.defaultRows)
        let signature = try privateKey.signature(for: body).base64EncodedString()
        sidecar = Data("""
        {"key_id":"\(keyID)","alg":"ed25519","signature":"\(signature)"}
        """.utf8)
    }

    func loader(
        now rawNow: String,
        expectedPolicyVersion: String? = nil,
        minimumGeneratedAt: Date = .distantPast
    ) -> ConsumeTrustedPricingLoader {
        ConsumeTrustedPricingLoader(
            trustedPublicKeys: trustedPublicKeys,
            expectedPolicyVersion: expectedPolicyVersion ?? policyVersion,
            minimumGeneratedAt: minimumGeneratedAt,
            now: { Self.date(rawNow) }
        )
    }

    static func date(_ raw: String) -> Date {
        ISO8601DateFormatter.autotuneInternet.date(from: raw)!
    }

    static var defaultRows: [String: RateCardProjection.Row] {
        [
            "default": RateCardProjection.Row(
                promptRatePerMtok: 500_000,
                promptCacheHitRatePerMtok: 125_000,
                completionRatePerMtok: 1_000_000,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
            "llama-test": RateCardProjection.Row(
                promptRatePerMtok: 10,
                promptCacheHitRatePerMtok: 5,
                completionRatePerMtok: 20,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
            "qwen3-32b": RateCardProjection.Row(
                promptRatePerMtok: 30,
                promptCacheHitRatePerMtok: 15,
                completionRatePerMtok: 60,
                providerShareBPS: 9_000,
                globalMultiplierPPM: 1_000_000
            ),
        ]
    }

    private static func rateCardBody(generatedAt: String, policyVersion: String, rows: [String: RateCardProjection.Row]) -> Data {
        let generatedDate = date(generatedAt)
        let projection = RateCardProjection(
            version: "",
            policyVersion: policyVersion,
            generatedAt: generatedDate,
            usdPerMillionCredits: 1.0,
            rows: rows
        )
        let rowsJSON = rows.keys.sorted().map { key -> String in
            let row = rows[key]!
            return """
            "\(key)":{"prompt_rate_per_mtok":\(row.promptRatePerMtok),"prompt_cache_hit_rate_per_mtok":\(row.promptCacheHitRatePerMtok),"completion_rate_per_mtok":\(row.completionRatePerMtok),"provider_share_bps":\(row.providerShareBPS),"global_multiplier_ppm":\(row.globalMultiplierPPM)}
            """
        }.joined(separator: ",")
        return Data("""
        {"version":"\(projection.projectionHash)","policy_version":"\(policyVersion)","generated_at":"\(generatedAt)","usd_per_million_credits":1.0,"rows":{\(rowsJSON)}}
        """.utf8)
    }
}
