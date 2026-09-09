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
            resolveEndpoint: { _ in "8.8.8.8" },
            fetch: { url, endpoint in
                XCTAssertEqual(endpoint, "8.8.8.8")
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
            resolveEndpoint: { _ in "8.8.8.8" },
            fetch: { _, _ in throw ConsumeTrustedPricingError(.fetchFailed) },
            trustedPublicKeys: fixture.trustedPublicKeys,
            expectedPolicyVersion: fixture.policyVersion,
            now: { SignedRateCardFixture.date("2026-08-29T00:00:00Z") }
        )
        let failed = await failingLoader.load(from: "https://api.example.test")
        XCTAssertEqual(failed, .unavailable(reason: .fetchFailed))
    }

    func testPinnedMetadataRequestIsCredentialFreeAndHeadersRemainBounded() throws {
        let request = String(decoding: ConsumePinnedUpstreamClient.trustedMetadataRequestBytesForTesting(
            host: "api.example.test",
            port: 443,
            path: "/v1/rate-card.sig"
        ), as: UTF8.self)
        XCTAssertEqual(request, [
            "GET /v1/rate-card.sig HTTP/1.1",
            "Host: api.example.test",
            "Accept: application/json",
            "Accept-Encoding: identity",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n"))
        XCTAssertFalse(request.localizedCaseInsensitiveContains("Authorization:"))
        XCTAssertFalse(request.localizedCaseInsensitiveContains("Cookie:"))
        XCTAssertFalse(request.localizedCaseInsensitiveContains("Proxy-Authorization:"))

        let tooManyHeaders = (0...ConsumeTrustedPricingLoader.maxResponseHeaderCount).map { ("X-Test-\($0)", "v") }
        XCTAssertFalse(ConsumeTrustedPricingLoader.responseHeadersAreBounded(tooManyHeaders))
        XCTAssertFalse(ConsumeTrustedPricingLoader.responseHeadersAreBounded([
            ("X-Test", String(repeating: "x", count: ConsumeTrustedPricingLoader.maxResponseHeaderBytes + 1)),
        ]))
    }

    func testPinnedMetadataTransportRejectsNonGlobalEndpointBeforeConnecting() async throws {
        do {
            _ = try await ConsumePinnedUpstreamClient.fetchTrustedMetadata(
                url: URL(string: "https://api.example.test/v1/rate-card")!,
                endpoint: "127.0.0.1",
                timeouts: .default
            )
            XCTFail("private endpoint unexpectedly reached the transport")
        } catch let error as ConsumeTrustedPricingError {
            XCTAssertEqual(error.reason, .fetchFailed)
        }
    }

    func testPinnedMetadataReadDeadlineIsAbsoluteUnderSlowDripProgress() {
        let policy = ConsumePinnedUpstreamClient.trustedMetadataReadDeadline(for: .default)
        XCTAssertEqual(policy.timeoutNanoseconds, 10_000_000_000)
        XCTAssertFalse(policy.refreshOnProgress)

        var expiryNanoseconds = policy.timeoutNanoseconds
        let slowDripProgress: [UInt64] = [1_000_000_000, 9_000_000_000, 9_999_999_999]
        for progressNanoseconds in slowDripProgress where policy.refreshOnProgress {
            expiryNanoseconds = progressNanoseconds + policy.timeoutNanoseconds
        }
        XCTAssertEqual(expiryNanoseconds, 10_000_000_000)
    }

    func testPricingFetchRejectsPrivateResolutionBeforeRateCardRequest() async throws {
        let fixture = try SignedRateCardFixture(generatedAt: "2026-09-02T12:00:00Z")
        let recorder = PricingTransportRecorder(endpoints: ["127.0.0.1"], fixture: fixture)
        let loader = fixture.loader(now: "2026-09-03T00:00:00Z", recorder: recorder)

        let result = await loader.load(from: "https://api.example.test")
        let resolvedHosts = await recorder.resolvedHosts()
        let fetchedPaths = await recorder.fetchedPaths()
        XCTAssertEqual(result, .unavailable(reason: .fetchFailed))
        XCTAssertEqual(resolvedHosts, ["api.example.test"])
        XCTAssertEqual(fetchedPaths, [])
    }

    func testPricingFetchRepeatsResolutionAndRejectsPrivateSidecarRebinding() async throws {
        let fixture = try SignedRateCardFixture(generatedAt: "2026-09-02T12:00:00Z")
        let recorder = PricingTransportRecorder(endpoints: ["8.8.8.8", "127.0.0.1"], fixture: fixture)
        let loader = fixture.loader(now: "2026-09-03T00:00:00Z", recorder: recorder)

        let result = await loader.load(from: "https://api.example.test")
        let resolvedHosts = await recorder.resolvedHosts()
        let fetchedPaths = await recorder.fetchedPaths()
        XCTAssertEqual(result, .unavailable(reason: .fetchFailed))
        XCTAssertEqual(resolvedHosts, ["api.example.test", "api.example.test"])
        XCTAssertEqual(fetchedPaths, ["/v1/rate-card@8.8.8.8"])
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
        minimumGeneratedAt: Date = .distantPast,
        recorder: PricingTransportRecorder? = nil
    ) -> ConsumeTrustedPricingLoader {
        ConsumeTrustedPricingLoader(
            resolveEndpoint: { host in
                if let recorder {
                    return await recorder.resolve(host)
                }
                return "8.8.8.8"
            },
            fetch: { url, endpoint in
                guard let recorder else {
                    throw ConsumeTrustedPricingError(.fetchFailed)
                }
                return await recorder.fetch(url, endpoint: endpoint)
            },
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

private actor PricingTransportRecorder {
    private var endpoints: [String]
    private let fixture: SignedRateCardFixture
    private var hosts: [String] = []
    private var paths: [String] = []

    init(endpoints: [String], fixture: SignedRateCardFixture) {
        self.endpoints = endpoints
        self.fixture = fixture
    }

    func resolve(_ host: String) -> String {
        hosts.append(host)
        return endpoints.removeFirst()
    }

    func fetch(_ url: URL, endpoint: String) -> Data {
        paths.append("\(url.path)@\(endpoint)")
        return url.path.hasSuffix(".sig") ? fixture.sidecar : fixture.body
    }

    func resolvedHosts() -> [String] { hosts }
    func fetchedPaths() -> [String] { paths }
}
