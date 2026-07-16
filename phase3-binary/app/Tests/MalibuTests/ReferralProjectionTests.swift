import XCTest
@testable import Malibu

final class ReferralProjectionTests: XCTestCase {
    func testLockedStatusSuppressesUnexpectedInvite() throws {
        let status = try XCTUnwrap(makeStatus(
            socialState: ReferralStatusProjection.locked,
            firstServingSeen: false,
            inviteURL: URL(string: "https://coordinator.streamvc.live/j/CODE")
        ))

        XCTAssertNil(status.availableInviteURL)
        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: status),
            "Serve once to unlock invites"
        )
    }

    func testEligibleStatusUsesExactCoordinatorCapacity() throws {
        let status = try XCTUnwrap(makeStatus())

        XCTAssertEqual(status.availableInviteURL?.absoluteString, "https://coordinator.streamvc.live/j/CODE")
        XCTAssertEqual(ReferralPanelPresenter.capacity(status), "1 remaining · 0 redeemed · 1 total")
        XCTAssertTrue(status.canStartSocialChallenge)
    }

    func testInviteMayUseCoordinatorDeclaredPublicJoinDomain() throws {
        let joinBaseURL = try XCTUnwrap(URL(string: "https://malibu.tech/j"))
        let inviteURL = try XCTUnwrap(URL(string: "https://malibu.tech/j/CODE"))
        let status = try XCTUnwrap(makeStatus(
            joinBaseURL: joinBaseURL,
            inviteURL: inviteURL
        ))

        XCTAssertEqual(status.availableInviteURL, inviteURL)
    }

    func testExhaustedStatusCannotCopyInvite() throws {
        let status = try XCTUnwrap(makeStatus(redemptions: 1, remaining: 0))

        XCTAssertNil(status.availableInviteURL)
        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: status),
            "Invite capacity used"
        )
    }

    func testMalformedOrUnknownProjectionFailsClosed() {
        XCTAssertNil(makeStatus(socialState: "future_state"))
        XCTAssertNil(makeStatus(remaining: 2))
        XCTAssertNil(makeStatus(inviteURL: URL(string: "https://evil.example/not-j/CODE")))
        XCTAssertNil(makeStatus(inviteURL: URL(string: "https://evil.example/j/CODE")))
        XCTAssertNil(makeStatus(inviteURL: URL(string: "https://coordinator.streamvc.live/j/OTHER")))
    }

    func testPendingCopyNeverClaimsBonusWasEarned() throws {
        let status = try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.pending))
        XCTAssertEqual(
            ReferralPanelPresenter.detail(availability: .available, status: status),
            "No bonus is earned until the coordinator verifies the public post."
        )
    }

    func testCoordinatorProjectionExpiresBeforeItCanBePresentedAsCurrent() throws {
        let status = try XCTUnwrap(makeStatus(observedAt: Date().addingTimeInterval(-91)))
        XCTAssertFalse(status.isCurrent())
        XCTAssertTrue(status.isCurrent(at: status.observedAt.addingTimeInterval(89)))
    }

    func testRefreshPolicyEnforcesSingleSixtySecondGate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ReferralRefreshPolicy.shouldRequest(now: now, lastRequestedAt: nil))
        XCTAssertFalse(ReferralRefreshPolicy.shouldRequest(
            now: now,
            lastRequestedAt: now.addingTimeInterval(-59.999)
        ))
        XCTAssertTrue(ReferralRefreshPolicy.shouldRequest(
            now: now,
            lastRequestedAt: now.addingTimeInterval(-60)
        ))
    }

    func testSocialRollbackSuppressesOnlyAdvocacyActions() throws {
        let status = try XCTUnwrap(makeStatus())
        let rolledBack = try XCTUnwrap(status.withSocialBonusEnabled(false))
        XCTAssertEqual(rolledBack.availableInviteURL, status.availableInviteURL)
        XCTAssertFalse(rolledBack.canStartSocialChallenge)
    }

    func testReferralBoundaryNegotiatesByCapabilityNotMarketingVersion() {
        var snapshot = AgentSnapshot.empty
        snapshot.cliVersion = "99.1"
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusLifecycleOwner = "macprovider_cli"
        snapshot.localStatusCapabilities = ["referral_status_v1", "service_instance_v1", "status_observation_v1"]
        snapshot.localProviderID = "provider-1"
        snapshot.serviceRole = "serve"
        snapshot.statusObservationID = "obs"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true

        XCTAssertTrue(snapshot.hasTrustedReferralBoundary())
        snapshot.statusObservedAt = Date().addingTimeInterval(-30)
        XCTAssertTrue(snapshot.hasTrustedReferralBoundary())
        snapshot.localStatusCapabilities.remove("referral_status_v1")
        XCTAssertFalse(snapshot.hasTrustedReferralBoundary())
    }

    private func makeStatus(
        socialState: String = ReferralStatusProjection.eligible,
        firstServingSeen: Bool = true,
        redemptions: Int = 0,
        remaining: Int = 1,
        joinBaseURL: URL = URL(string: "https://coordinator.streamvc.live/j")!,
        inviteURL: URL? = URL(string: "https://coordinator.streamvc.live/j/CODE"),
        observedAt: Date = Date()
    ) -> ReferralStatusProjection? {
        ReferralStatusProjection(
            campaign: "prebeta",
            joinBaseURL: joinBaseURL,
            socialState: socialState,
            baseCapacity: 1,
            configuredBonusCapacity: 2,
            bonusCapacity: 0,
            redemptions: redemptions,
            remaining: remaining,
            firstServingSeen: firstServingSeen,
            socialBonusEnabled: true,
            inviteCode: "CODE",
            inviteURL: inviteURL,
            observedAt: observedAt,
            pendingChallenge: nil
        )
    }
}
