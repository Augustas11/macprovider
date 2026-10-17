import XCTest
@testable import Malibu

final class ProviderCLIVersionTests: XCTestCase {
    func testCompareSemverOrdering() {
        XCTAssertEqual(ProviderCLIVersion.compare("1.2.0", "1.2.1"), .ascending)
        XCTAssertEqual(ProviderCLIVersion.compare("v1.2.1", "1.2.1"), .same)
        XCTAssertEqual(ProviderCLIVersion.compare("1.3.0", "1.2.9"), .descending)
    }

    func testStrictVersionNormalizationRejectsOverflowAndLeadingZeroes() {
        XCTAssertEqual(ProviderCLIVersion.strictNormalize("v1.8.39"), "1.8.39")
        XCTAssertNil(ProviderCLIVersion.strictNormalize("999999999999999999999.0.0"))
        XCTAssertNil(ProviderCLIVersion.strictNormalize("01.8.39"))
        XCTAssertNil(ProviderCLIVersion.strictNormalize("1.08.39"))
        XCTAssertNil(ProviderCLIVersion.strictNormalize("1.8.039"))
    }

    func testUpdateTargetPrefersNewestCandidate() {
        XCTAssertEqual(
            ProviderCLIVersion.updateTarget(current: "1.8.0", recommended: "1.8.2", latestRelease: "1.8.5"),
            "1.8.5"
        )
        XCTAssertNil(
            ProviderCLIVersion.updateTarget(current: "1.8.5", recommended: "1.8.3", latestRelease: "1.8.4")
        )
    }
}

final class AgentSnapshotCLIVersionPresenterTests: XCTestCase {
    func testUpdateBadgeShowsWhenUpdateAvailable() {
        var snapshot = AgentSnapshot.empty
        snapshot.cliVersion = "1.8.0"
        snapshot.latestReleaseVersion = "1.8.5"
        XCTAssertEqual(AgentSnapshotPresenter.updateBadge(snapshot), "↑")
    }

    func testUpdateBadgeHiddenWhileUpdating() {
        var snapshot = AgentSnapshot.empty
        snapshot.cliVersion = "1.8.0"
        snapshot.latestReleaseVersion = "1.8.5"
        snapshot.cliUpdateInProgress = true
        XCTAssertNil(AgentSnapshotPresenter.updateBadge(snapshot))
    }

    func testCliVersionLineShowsTarget() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.cliVersion = "1.8.0"
        snapshot.coordinatorRecommendedVersion = "1.8.6"
        XCTAssertTrue(AgentSnapshotPresenter.cliVersionLine(snapshot).contains("→ v1.8.6 available"))
    }

    func testLatestBinaryWithMissingCompatibilitySetOffersRepair() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.cliVersion = "1.8.39"
        snapshot.latestReleaseVersion = "1.8.39"
        snapshot.statusObservationFresh = true
        snapshot.compatibilitySetID = nil

        XCTAssertNil(AgentSnapshotPresenter.updateTargetVersion(snapshot))
        XCTAssertTrue(AgentSnapshotPresenter.compatibilityRepairAvailable(snapshot))
        XCTAssertTrue(AgentSnapshotPresenter.updateAvailable(snapshot))
        XCTAssertEqual(AgentSnapshotPresenter.updateBadge(snapshot), "↑")
        XCTAssertEqual(
            AgentSnapshotPresenter.cliVersionLine(snapshot),
            "v1.8.39 · provider software update required"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.cliVersionMenuLine(snapshot),
            "Provider software v1.8.39 · update required"
        )
    }

    func testMissingCompatibilitySetDoesNotOfferRepairFromStaleObservation() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.cliVersion = "1.8.39"
        snapshot.latestReleaseVersion = "1.8.39"
        snapshot.statusObservationFresh = false
        snapshot.compatibilitySetID = nil

        XCTAssertFalse(AgentSnapshotPresenter.compatibilityRepairAvailable(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.updateAvailable(snapshot))
    }

    func testCurrentCompleteCompatibilitySetDoesNotOfferRepair() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.cliVersion = "1.8.39"
        snapshot.latestReleaseVersion = "1.8.39"
        snapshot.statusObservationFresh = true
        snapshot.compatibilitySetID = "Augustas11/macprovider:v1.8.39@abc123"

        XCTAssertFalse(AgentSnapshotPresenter.compatibilityRepairAvailable(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.updateAvailable(snapshot))
    }
}

/// #2036: the update badge's release source never depends on the anonymous
/// GitHub API budget, and a spent budget backs off until its reset.
final class LatestReleaseClientTests: XCTestCase {
    private let healthz = URL(string: "https://coordinator.example/healthz")!
    private let gitHub = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!

    override func tearDown() {
        LatestReleaseMockURLProtocol.reset()
        super.tearDown()
    }

    private func fetch(now: Date = Date(timeIntervalSince1970: 1_000)) async -> LatestReleaseClient.Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LatestReleaseMockURLProtocol.self]
        return await LatestReleaseClient.fetch(
            coordinatorHealthzURL: healthz,
            gitHubLatestURL: gitHub,
            session: URLSession(configuration: configuration),
            now: now
        )
    }

    func testCoordinatorAdvertisementNeedsNoGitHubRequest() async {
        LatestReleaseMockURLProtocol.responses = [
            healthz: (200, Data(#"{"status":"ok","recommended_binary_version":"1.8.250"}"#.utf8), [:]),
        ]
        let outcome = await fetch()
        XCTAssertEqual(outcome, .version("1.8.250"))
        XCTAssertEqual(LatestReleaseMockURLProtocol.requested, [healthz])
    }

    func testCoordinatorDownFallsBackToGitHub() async {
        LatestReleaseMockURLProtocol.responses = [
            gitHub: (200, Data(#"{"tag_name":"v1.8.251"}"#.utf8), [:]),
        ]
        let outcome = await fetch()
        XCTAssertEqual(outcome, .version("1.8.251"))
        XCTAssertEqual(LatestReleaseMockURLProtocol.requested, [healthz, gitHub])
    }

    func testSpentGitHubBudgetIsDeferredUntilReset() async {
        LatestReleaseMockURLProtocol.responses = [
            gitHub: (403, Data("{}".utf8), ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790000000"]),
        ]
        let outcome = await fetch()
        XCTAssertEqual(outcome, .deferred(until: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertEqual(
            LatestReleaseClient.retryAfter(outcome, now: Date(timeIntervalSince1970: 1_000)),
            Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    func testOtherFailuresBackOffAndNonReleaseTagsAreIgnored() async {
        LatestReleaseMockURLProtocol.responses = [
            gitHub: (200, Data(#"{"tag_name":"verify-v1.0.0"}"#.utf8), [:]),
        ]
        let now = Date(timeIntervalSince1970: 1_000)
        let outcome = await fetch(now: now)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(
            LatestReleaseClient.retryAfter(outcome, now: now),
            now.addingTimeInterval(LatestReleaseClient.failureBackoff)
        )
        XCTAssertNil(LatestReleaseClient.retryAfter(.version("1.8.250"), now: now))
    }

    func testForbiddenWithBudgetLeftIsNotARateLimit() async {
        LatestReleaseMockURLProtocol.responses = [
            gitHub: (403, Data("{}".utf8), ["x-ratelimit-remaining": "41"]),
        ]
        let outcome = await fetch()
        XCTAssertEqual(outcome, .unavailable)
    }
}

private final class LatestReleaseMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [URL: (status: Int, body: Data, headers: [String: String])] = [:]
    nonisolated(unsafe) static var requested: [URL] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        responses = [:]
        requested = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requested.append(url)
        let response = Self.responses[url]
        Self.lock.unlock()
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
