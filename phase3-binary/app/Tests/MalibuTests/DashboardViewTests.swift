import Foundation
import XCTest
@testable import Malibu

final class DashboardViewTests: XCTestCase {
    func testOptionalDashboardFieldsRenderFriendlyZerosWhenServing() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"

        XCTAssertEqual(AgentSnapshotPresenter.modelLine(snapshot), "Connected")
        XCTAssertTrue(AgentSnapshotPresenter.requestsLine(snapshot).contains("0 today"))
        XCTAssertTrue(AgentSnapshotPresenter.tokenLine(snapshot).contains("0 in / 0 out today"))
        XCTAssertTrue(AgentSnapshotPresenter.usdcFullLine(snapshot).contains("$0.00 today"))
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "$0.00")
        XCTAssertEqual(AgentSnapshotPresenter.queueChip(snapshot), "0 queued")
        XCTAssertEqual(AgentSnapshotPresenter.thermalChip(snapshot), "Thermal OK")
        XCTAssertEqual(AgentSnapshotPresenter.dashboardHeadline(snapshot), "Serving")
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Connected to coordinator · waiting for first paid job"
        )
    }

    func testLocalOnlyStateWhenCoordinatorDisconnected() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.coordinatorConnected = false
        snapshot.currentModelID = "qwen3-coder-30b-a3b-instruct"
        snapshot.lastError = "Model loaded locally · not connected to coordinator"

        XCTAssertEqual(AgentSnapshotPresenter.dashboardHeadline(snapshot), "Local only")
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Model loaded locally · not connected to coordinator"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.stateLine(snapshot),
            "Local only · qwen3-coder-30b-a3b-instruct"
        )
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot), "Sync")
    }

    func testPopulatedDashboardFieldsRenderValues() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "Llama-3.1-8B · Q4_K_M · 4.2GB"
        snapshot.requestsServedToday = 142
        snapshot.requestsServedAllTime = 8_204
        snapshot.requestsPerMinute = 3.1
        snapshot.inputTokensToday = 1_200_000
        snapshot.outputTokensToday = 3_800_000
        snapshot.earningsUsdcToday = 4.12
        snapshot.earningsUsdcWeek = 18.40
        snapshot.earningsUsdcPending = 6.90
        snapshot.earningsUsdcLifetime = 211
        snapshot.malibuAccruedToday = 12
        snapshot.malibuAccruedAllTime = 50
        snapshot.trustTier = .provisional
        snapshot.gpuUtilizationPct = 62
        snapshot.latencyP50Ms = 42
        snapshot.latencyP99Ms = 180
        snapshot.queueDepth = 3
        snapshot.thermalState = .serious

        XCTAssertEqual(AgentSnapshotPresenter.modelLine(snapshot), "Llama-3.1-8B · Q4_K_M · 4.2GB")
        XCTAssertEqual(AgentSnapshotPresenter.requestsLine(snapshot), "142 today · 8,204 all-time · 3.1 req/min")
        XCTAssertTrue(AgentSnapshotPresenter.tokenLine(snapshot).contains("1.2M in / 3.8M out today"))
        XCTAssertEqual(AgentSnapshotPresenter.usdcFullLine(snapshot), "$4.12 today · $18.40 wk · $6.90 pending · $211.00 life")
        XCTAssertTrue(AgentSnapshotPresenter.malibuFullLine(snapshot).contains("[locked] unlocks at Trusted"))
        XCTAssertEqual(AgentSnapshotPresenter.gpuChip(snapshot), "GPU 62%")
        XCTAssertEqual(AgentSnapshotPresenter.latencyChip(snapshot), "p50 42ms · p99 180ms")
        XCTAssertEqual(AgentSnapshotPresenter.queueChip(snapshot), "3 queued")
        XCTAssertEqual(AgentSnapshotPresenter.thermalChip(snapshot), "Serious")
    }
}

final class ProviderReferralStatusTests: XCTestCase {
    private func decode(_ json: String) throws -> ProviderReferralStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProviderReferralStatus.self, from: Data(json.utf8))
    }

    func testLockedStatusSuppressesUnexpectedInviteURLUntilAuthoritativeServing() throws {
        let status = try decode("""
        {
          "campaign":"prebeta", "social_state":"locked_until_first_serving",
          "base_capacity":0, "configured_bonus_capacity":2, "bonus_capacity":0,
          "redemptions":0, "remaining":0, "first_serving_seen":false,
          "social_bonus_enabled":true, "invite_code":"MAL1-P-unexpected",
          "invite_url":"https://malibu.tech/j/MAL1-P-unexpected"
        }
        """)

        XCTAssertNil(status.availableInviteURL)
        XCTAssertFalse(status.canStartSocialChallenge)
    }

    func testEligibleStatusDecodesAuthoritativeCapacityAndSocialOffer() throws {
        let status = try decode("""
        {
          "campaign":"prebeta", "social_state":"eligible",
          "base_capacity":1, "configured_bonus_capacity":2, "bonus_capacity":0,
          "redemptions":0, "remaining":1, "first_serving_seen":true,
          "social_bonus_enabled":true, "invite_code":"MAL1-P-ready",
          "invite_url":"https://malibu.tech/j/MAL1-P-ready"
        }
        """)

        XCTAssertEqual(status.availableInviteURL?.absoluteString, "https://malibu.tech/j/MAL1-P-ready")
        XCTAssertEqual(status.baseCapacity, 1)
        XCTAssertEqual(status.configuredBonusCapacity, 2)
        XCTAssertEqual(status.bonusCapacity, 0)
        XCTAssertEqual(status.redemptions, 0)
        XCTAssertEqual(status.remaining, 1)
        XCTAssertTrue(status.canStartSocialChallenge)
        XCTAssertEqual(status.configuredBonusPhrase, "2 invite uses")
    }

    func testEligibleStatusRejectsNonHTTPSOrMismatchedInviteURL() throws {
        for rawURL in [
            "http://malibu.tech/j/MAL1-P-ready",
            "https://user@malibu.tech/j/MAL1-P-ready",
            "https://malibu.tech/j/MAL1-P-other",
            "https://malibu.tech/j/MAL1-P-ready?redirect=1"
        ] {
            let status = try decode("""
            {
              "campaign":"prebeta", "social_state":"eligible",
              "base_capacity":1, "configured_bonus_capacity":2, "bonus_capacity":0,
              "redemptions":0, "remaining":1, "first_serving_seen":true,
              "social_bonus_enabled":true, "invite_code":"MAL1-P-ready",
              "invite_url":"\(rawURL)"
            }
            """)
            XCTAssertNil(status.availableInviteURL, "unexpected invite URL accepted: \(rawURL)")
            XCTAssertFalse(status.canStartSocialChallenge)
        }
    }

    func testShareChallengeAllowsOnlyHTTPSXComposerAndASCIIChallenge() {
        let challenge = String(repeating: "a", count: 64)
        let safe = ReferralShareChallenge(
            intentURL: URL(string: "https://twitter.com/intent/tweet?text=Malibu")!,
            shareURL: URL(string: "https://malibu.tech/j/MAL1-P-ready?c=\(challenge)")!,
            expiresAt: Date().addingTimeInterval(60)
        )
        XCTAssertTrue(safe.isSafeToOpen)

        let unsafe = ReferralShareChallenge(
            intentURL: URL(string: "https://attacker.example/intent?text=Malibu")!,
            shareURL: safe.shareURL,
            expiresAt: safe.expiresAt
        )
        XCTAssertFalse(unsafe.isSafeToOpen)
        XCTAssertFalse(ReferralShareChallenge.isASCIIChallenge(String(repeating: "Ａ", count: 64)))
    }

    func testPendingStatusKeepsConfiguredOfferSeparateFromUnearnedBonus() throws {
        let status = try decode("""
        {
          "campaign":"prebeta", "social_state":"pending",
          "base_capacity":1, "configured_bonus_capacity":2, "bonus_capacity":0,
          "redemptions":1, "remaining":0, "first_serving_seen":true,
          "social_bonus_enabled":true, "invite_code":"MAL1-P-pending",
          "invite_url":"https://malibu.tech/j/MAL1-P-pending",
          "review_due_at":"2026-07-13T10:30:00Z"
        }
        """)

        XCTAssertEqual(status.socialState, ProviderReferralStatus.pending)
        XCTAssertEqual(status.configuredBonusCapacity, 2)
        XCTAssertEqual(status.bonusCapacity, 0)
        XCTAssertEqual(status.earnedBonusPhrase, "0 invite uses")
        XCTAssertFalse(status.canStartSocialChallenge)
        XCTAssertEqual(status.reviewDueAt, ISO8601DateFormatter().date(from: "2026-07-13T10:30:00Z"))
    }

    func testFailedStatusCanStartFreshSocialChallenge() throws {
        let status = try decode("""
        {
          "campaign":"prebeta", "social_state":"failed",
          "base_capacity":1, "configured_bonus_capacity":2, "bonus_capacity":0,
          "redemptions":0, "remaining":1, "first_serving_seen":true,
          "social_bonus_enabled":true, "invite_code":"MAL1-P-retry",
          "invite_url":"https://malibu.tech/j/MAL1-P-retry"
        }
        """)

        XCTAssertTrue(status.canStartSocialChallenge)
        XCTAssertEqual(status.availableInviteURL?.absoluteString, "https://malibu.tech/j/MAL1-P-retry")
    }
}

final class ReferralInviteClientTests: XCTestCase {
    override func tearDown() {
        ReferralURLProtocol.handler = nil
        super.tearDown()
    }

    func testStatusFetchKeepsBearerOutOfURLAndBody() async throws {
        let secret = "provider-secret-that-must-not-leak"
        ReferralURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/provider/referrals")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")
            XCTAssertFalse(request.url?.absoluteString.contains(secret) ?? true)
            XCTAssertNil(request.httpBody)
            let body = """
            {
              "campaign":"prebeta", "social_state":"eligible",
              "base_capacity":1, "configured_bonus_capacity":2, "bonus_capacity":0,
              "redemptions":0, "remaining":1, "first_serving_seen":true,
              "social_bonus_enabled":true, "invite_code":"MAL1-P-ready",
              "invite_url":"https://malibu.tech/j/MAL1-P-ready"
            }
            """
            return (200, Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReferralURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let status = try await ReferralInviteClient(
            coordinatorBaseURL: URL(string: "https://coordinator.example")!,
            session: session
        ).fetchStatus(bearerToken: secret)

        XCTAssertEqual(status.socialState, ProviderReferralStatus.eligible)
    }

    @MainActor
    func testControllerUsesInjectedCredentialAndKeepsLockedInviteHidden() async {
        let locked = ProviderReferralStatus(
            campaign: "prebeta",
            socialState: ProviderReferralStatus.locked,
            baseCapacity: 0,
            configuredBonusCapacity: 2,
            bonusCapacity: 0,
            redemptions: 0,
            remaining: 0,
            firstServingSeen: false,
            socialBonusEnabled: true,
            inviteCode: nil,
            inviteURL: nil,
            reviewDueAt: nil
        )
        var receivedToken: String?
        let dependencies = ReferralInviteDependencies(
            credentials: {
                ReferralInviteCredentials(
                    providerID: "provider-test",
                    bearerToken: "keychain-token",
                    coordinatorBaseURL: URL(string: "https://coordinator.example")!
                )
            },
            fetchStatus: { _, token in receivedToken = token; return locked },
            createChallenge: { _, _ in throw ReferralInviteClientError.invalidResponse },
            verifyPost: { _, _, _, _ in throw ReferralInviteClientError.invalidResponse },
            loadChallenge: { _ in nil },
            saveChallenge: { _, _ in },
            deleteChallenge: { _ in },
            openURL: { _ in XCTFail("locked status must not open X") },
            copyText: { _ in XCTFail("locked status must not copy an invite") },
            now: { Date(timeIntervalSince1970: 0) }
        )
        let controller = ReferralInviteController(dependencies: dependencies)

        await controller.refresh()

        XCTAssertEqual(receivedToken, "keychain-token")
        XCTAssertEqual(controller.status, locked)
        XCTAssertFalse(controller.canCopyInvite)
        XCTAssertFalse(controller.canShareOnX)
    }
}

private final class ReferralURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: ReferralInviteClientError.invalidResponse)
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
