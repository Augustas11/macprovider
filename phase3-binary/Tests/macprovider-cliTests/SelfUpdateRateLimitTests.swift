import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// #2036: the anonymous api.github.com budget (60 requests per hour per IP,
/// shared by every Mac behind one NAT) must never block an update check. A
/// spent budget is classified, never retried before its reset, and the check
/// falls back to the coordinator-advertised release whose mirrored
/// checksums.txt must verify under the release key.
final class SelfUpdateRateLimitTests: XCTestCase {
    private let latest = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
    private let listing = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases?per_page=100&page=1")!
    private let vTag = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/tags/v1.9.0")!
    private let healthz = URL(string: "https://coordinator.example/healthz")!
    private let mirrorIndex = URL(string: "https://download.malibu.tech/releases/index/v1.9.0.json")!
    private let mirrorChecksums = URL(string: "https://download.malibu.tech/releases/v1.9.0/checksums.txt")!
    private let mirrorSignature = URL(string: "https://download.malibu.tech/releases/v1.9.0/checksums.txt.sig")!
    private let gitHubChecksums = URL(string: "https://github.com/Augustas11/macprovider/releases/download/v1.9.0/checksums.txt")!
    private let gitHubSignature = URL(string: "https://github.com/Augustas11/macprovider/releases/download/v1.9.0/checksums.txt.sig")!
    private let resetEpoch: TimeInterval = 1_790_000_000
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("selfupdate-ratelimit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        RateLimitMockURLProtocol.reset()
        try? FileManager.default.removeItem(at: home)
    }

    private var rateLimited: RateLimitMockURLProtocol.Response { rateLimited(resetEpoch: resetEpoch) }

    private func rateLimited(resetEpoch: TimeInterval) -> RateLimitMockURLProtocol.Response {
        (403, Data(#"{"message":"API rate limit exceeded"}"#.utf8), [
            "x-ratelimit-limit": "60",
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": String(Int(resetEpoch)),
        ])
    }

    private func update(
        coordinator: Bool,
        gate: GitHubAPIRateLimit = GitHubAPIRateLimit(),
        currentVersion: String = "1.8.0"
    ) -> SelfUpdate {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitMockURLProtocol.self]
        return SelfUpdate(
            currentVersion: currentVersion,
            releasesAPIURL: latest.absoluteString,
            releaseMirrorEnabled: true,
            coordinatorURL: coordinator ? "wss://coordinator.example/ws/provider" : nil,
            session: URLSession(configuration: configuration),
            markerStore: AutoUpdateMarkerStore(homeDirectory: home),
            gitHubRateLimit: gate
        )
    }

    private func signedChecksums(signWith key: P256.Signing.PrivateKey) throws -> (Data, Data) {
        let checksums = Data("abc  macprovider-cli-v1.9.0-darwin-arm64.tar.gz\n".utf8)
        let signature = try key.signature(for: SHA256.hash(data: checksums)).derRepresentation
        return (checksums, signature)
    }

    // MARK: - classification

    func testOnlyASpentBudgetIsClassifiedAsRateLimited() throws {
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: listing, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        let now = Date(timeIntervalSince1970: 1_000)
        guard case .gitHubRateLimited(let reset)? = GitHubAPIRateLimit.error(
            for: response(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790000000"]),
            now: now
        ) else {
            return XCTFail("403 with remaining 0 is the rate limit")
        }
        XCTAssertEqual(reset, Date(timeIntervalSince1970: resetEpoch))
        guard case .gitHubRateLimited(let fallbackReset)? = GitHubAPIRateLimit.error(
            for: response(429, ["x-ratelimit-remaining": "0"]),
            now: now
        ) else {
            return XCTFail("429 with remaining 0 is the rate limit")
        }
        XCTAssertEqual(fallbackReset, now.addingTimeInterval(GitHubAPIRateLimit.defaultDeferral))
        XCTAssertNil(GitHubAPIRateLimit.error(for: response(403, ["x-ratelimit-remaining": "12"]), now: now))
        XCTAssertNil(GitHubAPIRateLimit.error(for: response(403, [:]), now: now))
        XCTAssertNil(GitHubAPIRateLimit.error(for: response(200, ["x-ratelimit-remaining": "0"]), now: now))
        XCTAssertTrue(SelfUpdate.discoveryFailureAllowsCoordinatorFallback(UpdateError.gitHubRateLimited(resetAt: nil)))
        XCTAssertTrue(
            UpdateError.gitHubRateLimited(resetAt: Date(timeIntervalSince1970: resetEpoch)).description
                .hasPrefix("Update check deferred until 2026-09-21T14:13:20Z")
        )
    }

    func testSpentBudgetIsNotRequestedAgainBeforeReset() async throws {
        let futureReset = (Date().timeIntervalSince1970 + 1_800).rounded(.down)
        RateLimitMockURLProtocol.responses = [listing: rateLimited(resetEpoch: futureReset)]
        let gate = GitHubAPIRateLimit()
        let update = update(coordinator: false, gate: gate)

        for _ in 0 ..< 3 {
            do {
                _ = try await update.discoverSignedReleaseHead()
                XCTFail("discovery succeeded on a spent budget")
            } catch UpdateError.gitHubRateLimited(let reset) {
                XCTAssertEqual(reset, Date(timeIntervalSince1970: futureReset))
            }
        }
        XCTAssertEqual(RateLimitMockURLProtocol.requested, [listing], "one request, no retry before reset")
        XCTAssertEqual(gate.deferral(now: Date(timeIntervalSince1970: futureReset - 1)), Date(timeIntervalSince1970: futureReset))
        XCTAssertNil(gate.deferral(now: Date(timeIntervalSince1970: futureReset + 1)))
    }

    // MARK: - update check

    func testRateLimitedCheckWithoutCoordinatorIsDeferredNotFailed() async throws {
        RateLimitMockURLProtocol.responses = [listing: rateLimited]

        try await update(coordinator: false).run(checkOnly: true)

        XCTAssertEqual(RateLimitMockURLProtocol.requested, [listing])
    }

    func testRateLimitedMutatingUpdateWithoutCoordinatorFailsWithTheDeferral() async throws {
        RateLimitMockURLProtocol.responses = [listing: rateLimited]

        do {
            try await update(coordinator: false).run(checkOnly: false)
            XCTFail("a mutating update proceeded without a release")
        } catch UpdateError.gitHubRateLimited(let reset) {
            XCTAssertEqual(reset, Date(timeIntervalSince1970: resetEpoch))
        }
    }

    func testRateLimitedCheckUsesTheCoordinatorAdvertisedRelease() async throws {
        RateLimitMockURLProtocol.responses = [
            listing: rateLimited,
            healthz: (200, Data(#"{"status":"ok","recommended_binary_version":"1.8.0"}"#.utf8), [:]),
        ]

        try await update(coordinator: true).run(checkOnly: true)

        XCTAssertEqual(RateLimitMockURLProtocol.requested, [listing, healthz])
    }

    func testRateLimitedCheckFailsClosedOnABadMirrorSignature() async throws {
        let (checksums, _) = try signedChecksums(signWith: P256.Signing.PrivateKey())
        RateLimitMockURLProtocol.responses = [
            listing: rateLimited,
            healthz: (200, Data(#"{"recommended_binary_version":"1.9.0"}"#.utf8), [:]),
            mirrorChecksums: (200, checksums, [:]),
            mirrorSignature: (200, Data(repeating: 0x30, count: 70), [:]),
            gitHubChecksums: (200, checksums, [:]),
            gitHubSignature: (200, Data(repeating: 0x30, count: 70), [:]),
        ]

        do {
            try await update(coordinator: true).run(checkOnly: true)
            XCTFail("an unverifiable advertised release was reported")
        } catch UpdateError.checksumSignatureInvalid {
        }
        XCTAssertFalse(RateLimitMockURLProtocol.requested.contains(gitHubChecksums), "a bad signature is not retried elsewhere")
    }

    // MARK: - mirrored checksum signature

    func testMirroredChecksumsVerifyUnderTheReleaseKey() async throws {
        let key = P256.Signing.PrivateKey()
        let (checksums, signature) = try signedChecksums(signWith: key)
        RateLimitMockURLProtocol.responses = [
            mirrorChecksums: (200, checksums, [:]),
            mirrorSignature: (200, signature, [:]),
        ]

        try await update(coordinator: true).verifyMirroredChecksumSignature(
            tag: "v1.9.0",
            publicKeyPEM: key.publicKey.pemRepresentation
        )

        XCTAssertEqual(RateLimitMockURLProtocol.requested, [mirrorChecksums, mirrorSignature])
    }

    func testMirrorDownFallsBackToGitHubReleaseDownloads() async throws {
        let key = P256.Signing.PrivateKey()
        let (checksums, signature) = try signedChecksums(signWith: key)
        RateLimitMockURLProtocol.failures = [mirrorChecksums: URLError(.cannotConnectToHost)]
        RateLimitMockURLProtocol.responses = [
            gitHubChecksums: (200, checksums, [:]),
            gitHubSignature: (200, signature, [:]),
        ]

        try await update(coordinator: true).verifyMirroredChecksumSignature(
            tag: "v1.9.0",
            publicKeyPEM: key.publicKey.pemRepresentation
        )

        XCTAssertFalse(RateLimitMockURLProtocol.requested.contains { $0.host == "api.github.com" })
    }

    func testMirroredChecksumsSignedByAnotherKeyFailClosed() async throws {
        let (checksums, signature) = try signedChecksums(signWith: P256.Signing.PrivateKey())
        RateLimitMockURLProtocol.responses = [
            mirrorChecksums: (200, checksums, [:]),
            mirrorSignature: (200, signature, [:]),
        ]

        do {
            try await update(coordinator: true).verifyMirroredChecksumSignature(
                tag: "v1.9.0",
                publicKeyPEM: P256.Signing.PrivateKey().publicKey.pemRepresentation
            )
            XCTFail("a foreign signature verified")
        } catch UpdateError.checksumSignatureInvalid {
        }
        XCTAssertEqual(RateLimitMockURLProtocol.requested, [mirrorChecksums, mirrorSignature])
    }

    // MARK: - tag resolution and status

    func testRateLimitedTagLookupReadsTheMirror() async throws {
        RateLimitMockURLProtocol.responses = [
            vTag: rateLimited,
            mirrorIndex: (200, Data(#"{"tag_name":"v1.9.0","draft":false,"prerelease":false,"assets":[{"name":"checksums.txt","browser_download_url":"https://download.malibu.tech/releases/v1.9.0/checksums.txt"}]}"#.utf8), [:]),
        ]

        let release = try await update(coordinator: false).resolveReleaseByTags(normalizedTarget: "1.9.0")

        XCTAssertEqual(release.tagName, "v1.9.0")
        XCTAssertEqual(RateLimitMockURLProtocol.requested, [vTag, mirrorIndex])
    }

    func testStatusLatestVersionCachesTheDeferral() async throws {
        RateLimitMockURLProtocol.responses = [latest: rateLimited]
        let cache = home.appendingPathComponent("latest-release.json")
        let now = Date(timeIntervalSince1970: resetEpoch - 600)
        let first = update(coordinator: false)
        let second = update(coordinator: false)

        for update in [first, second] {
            do {
                _ = try await update.latestVersionCached(cacheURL: cache, now: now)
                XCTFail("a spent budget produced a version")
            } catch UpdateError.gitHubRateLimited(let reset) {
                XCTAssertEqual(reset, Date(timeIntervalSince1970: resetEpoch))
            }
        }
        XCTAssertEqual(RateLimitMockURLProtocol.requested, [latest], "a second status call does not spend the budget")
    }

    func testStatusLatestVersionPrefersTheCoordinatorAdvertisement() async throws {
        RateLimitMockURLProtocol.responses = [
            healthz: (200, Data(#"{"recommended_binary_version":"1.9.0"}"#.utf8), [:]),
        ]
        let cache = home.appendingPathComponent("latest-release.json")

        let version = try await update(coordinator: true).latestVersionCached(cacheURL: cache)

        XCTAssertEqual(version, "1.9.0")
        XCTAssertEqual(RateLimitMockURLProtocol.requested, [healthz])
    }
}

private final class RateLimitMockURLProtocol: URLProtocol {
    typealias Response = (status: Int, body: Data, headers: [String: String])
    nonisolated(unsafe) static var responses: [URL: Response] = [:]
    nonisolated(unsafe) static var failures: [URL: URLError] = [:]
    nonisolated(unsafe) static var requested: [URL] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        responses = [:]
        failures = [:]
        requested = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requested.append(url)
        let failure = Self.failures[url]
        let response = Self.responses[url]
        Self.lock.unlock()
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
