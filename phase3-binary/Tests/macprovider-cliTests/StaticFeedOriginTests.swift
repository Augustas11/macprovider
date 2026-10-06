import Foundation
import XCTest
@testable import macprovider_cli

/// Lab-only static-feed redirect (#1770 rehearsal): loopback only, all three
/// variables or none, never active unless set, and https-only otherwise.
final class StaticFeedOriginTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private func environment(origin: String = "http://127.0.0.1:19302", keyID: String = "lab-test-key", key: String? = nil) -> [String: String] {
        [
            labStaticFeedOriginKey: origin,
            labStaticFeedKeyIDKey: keyID,
            labStaticFeedPublicKeyKey: key ?? self.key,
        ]
    }

    func testValidLoopbackOverrideIsNormalized() throws {
        let override = try XCTUnwrap(readLabStaticFeedOverride(environment(origin: "http://127.0.0.1:19302/")))
        XCTAssertEqual(override.origin.absoluteString, "http://127.0.0.1:19302")
        XCTAssertEqual(override.keyID, "lab-test-key")
        XCTAssertEqual(override.publicKeyBase64, key)
    }

    func testOverrideRejectsRemoteHostsPathsPartialSetsAndBadKeys() {
        XCTAssertNil(readLabStaticFeedOverride([:]))
        for origin in [
            "https://coordinator.malibu.tech",
            "http://localhost:19302",
            "http://127.0.0.1",
            "http://127.0.0.1:19302/v1",
            "ftp://127.0.0.1:19302",
            "http://user@127.0.0.1:19302",
        ] {
            XCTAssertNil(readLabStaticFeedOverride(environment(origin: origin)), origin)
        }
        XCTAssertNil(readLabStaticFeedOverride(environment(key: Data(count: 16).base64EncodedString())))
        XCTAssertNil(readLabStaticFeedOverride(environment(keyID: "bad key")))
        var partial = environment()
        partial.removeValue(forKey: labStaticFeedPublicKeyKey)
        XCTAssertNil(readLabStaticFeedOverride(partial))
    }

    func testWithoutAnOverrideEveryFeedUsesTheProductionOriginOverHTTPS() throws {
        XCTAssertNil(StaticFeedOrigin.labOverride, "the test process sets no lab override")
        XCTAssertEqual(StaticFeedOrigin.base, StaticFeedOrigin.production)
        XCTAssertEqual(NativeMTPAdmissionFeed.productionBaseURL, StaticFeedOrigin.production)
        XCTAssertEqual(AutotuneStaticInputs.defaultTrustedPublicKeys, AutotuneStaticInputs.generatedTrustedPublicKeys)
        XCTAssertFalse(StaticFeedOrigin.isLabLoopback(URL(string: "http://127.0.0.1:19302")!))
        let urls = try NativeMTPRevocationFeedManager.feedURLs(pinnedSignerKeyID: "streamvc-autotune-static-v4")
        XCTAssertEqual(urls.feed.absoluteString, "https://coordinator.malibu.tech/v1/native-mtp-revocations.streamvc-autotune-static-v4.json")
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.feedURLs(
            pinnedSignerKeyID: "streamvc-autotune-static-v4",
            origin: URL(string: "http://127.0.0.1:19302/v1/")!
        ))
    }

    func testLabSourceCommitAcceptsOnlyAFullCommitID() {
        XCTAssertNil(ModelRuntime.labNativeMTPSourceCommit([:]))
        XCTAssertNil(ModelRuntime.labNativeMTPSourceCommit(["MACPROVIDER_LAB_NATIVE_MTP_SOURCE_COMMIT": "abc"]))
        XCTAssertNil(ModelRuntime.labNativeMTPSourceCommit(["MACPROVIDER_LAB_NATIVE_MTP_SOURCE_COMMIT": String(repeating: "A", count: 40)]))
        XCTAssertEqual(
            ModelRuntime.labNativeMTPSourceCommit(["MACPROVIDER_LAB_NATIVE_MTP_SOURCE_COMMIT": String(repeating: "a", count: 40)]),
            String(repeating: "a", count: 40)
        )
    }

    func testStaticFeedFetchRetriesRateLimitedResponsesThenGivesUp() async throws {
        let url = URL(string: "https://coordinator.malibu.tech/v1/continuous-batching-policy")!
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        var statuses = [429, 429, 200]
        var sleeps = 0
        let data = try await AutotuneStaticInputs.fetchHonoringRateLimit(
            url,
            load: { _ in (Data("ok".utf8), response(statuses.removeFirst())) },
            sleep: { _ in sleeps += 1 }
        )
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual(sleeps, 2)

        var loads = 0
        do {
            _ = try await AutotuneStaticInputs.fetchHonoringRateLimit(
                url,
                load: { _ in loads += 1; return (Data(), response(429)) },
                sleep: { _ in }
            )
            XCTFail("a feed that stays rate limited must fail")
        } catch {
            XCTAssertEqual(loads, AutotuneStaticInputs.rateLimitRetries + 1)
        }

        var once = 0
        do {
            _ = try await AutotuneStaticInputs.fetchHonoringRateLimit(
                url,
                load: { _ in once += 1; return (Data(), response(503)) },
                sleep: { _ in XCTFail("only a 429 is retried") }
            )
            XCTFail("a 503 must fail")
        } catch {
            XCTAssertEqual(once, 1)
        }
    }
}

