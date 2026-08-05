import XCTest
@testable import Malibu

final class ReferralProjectionTests: XCTestCase {
    private let prohibitedPublicTerms = [
        "compatibility set",
        "admission identity",
        "watchdog",
        "buyer-serving",
        "spec-023",
        "migration token",
        "credential custody",
        "coordinator admission",
        "coordinator",
        "provider cli",
        "macprovider-cli",
        "cli-owned",
        "terminal path",
        "referral_bootstrap_v1",
    ]

    func testLockedStatusSuppressesUnexpectedInvite() throws {
        let status = try XCTUnwrap(makeStatus(
            socialState: ReferralStatusProjection.locked,
            firstServingSeen: false,
            inviteURL: URL(string: "https://malibu.tech/j#/CODE")
        ))

        XCTAssertNil(status.availableInviteURL)
        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: status),
            "Serve once to unlock your base invite"
        )
        XCTAssertTrue(
            ReferralPanelPresenter.detail(availability: .available, status: status)
                .contains("base invite")
        )
        XCTAssertTrue(ReferralPanelPresenter.pathChrome.contains("first paid serve"))
        XCTAssertTrue(ReferralPanelPresenter.pathChrome.contains("Each X"))
    }

    func testEligibleStatusUsesExactCoordinatorCapacity() throws {
        let status = try XCTUnwrap(makeStatus())

        XCTAssertEqual(status.availableInviteURL?.absoluteString, "https://malibu.tech/j#/CODE")
        XCTAssertEqual(
            ReferralPanelPresenter.capacity(status),
            "1 remaining · 0 redeemed · 1 base · X bonus available"
        )
        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: status),
            "Base invite ready"
        )
        XCTAssertTrue(
            ReferralPanelPresenter.detail(availability: .available, status: status)
                .contains("Optional: share on X")
        )
        XCTAssertTrue(status.canStartSocialChallenge)
    }

    func testExhaustedProviderCanStartXChallengeWithoutCopyableInvite() throws {
        let status = try XCTUnwrap(makeStatus(
            redemptions: 1,
            remaining: 0
        ))

        XCTAssertNil(status.availableInviteURL)
        XCTAssertEqual(status.socialChallengeInviteURL?.absoluteString, "https://malibu.tech/j#/CODE")
        XCTAssertTrue(status.canStartSocialChallenge)
    }

    func testMaturedStatusShowsBaseAndXBonusSplitAndCanStartAgain() throws {
        let status = try XCTUnwrap(makeStatus(
            socialState: ReferralStatusProjection.matured,
            remaining: 3,
            bonusCapacity: 2
        ))

        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: status),
            "Base invite unlocked · X bonus awarded"
        )
        let detail = ReferralPanelPresenter.detail(availability: .available, status: status)
        XCTAssertTrue(detail.contains("1 base from serving"))
        XCTAssertTrue(detail.contains("2 from X bonus"))
        XCTAssertTrue(detail.contains("share another X post"))
        XCTAssertEqual(
            ReferralPanelPresenter.capacity(status),
            "3 remaining · 0 redeemed · 1 base + 2 X bonus (3 total)"
        )
        XCTAssertTrue(status.canStartSocialChallenge)
        XCTAssertNotNil(status.availableInviteURL)
    }

    func testMaturedLegacyStatusWithoutGrantCapCannotStartAgain() throws {
        let status = try XCTUnwrap(makeStatus(
            socialState: ReferralStatusProjection.matured,
            remaining: 3,
            bonusCapacity: 2,
            socialBonusGrantsRemaining: nil
        ))

        XCTAssertFalse(status.canStartSocialChallenge)
        XCTAssertFalse(
            ReferralPanelPresenter.detail(availability: .available, status: status)
                .contains("share another X post")
        )
    }

    func testCapacityDoesNotAdvertiseXBonusOutsideActionableStates() throws {
        let locked = try XCTUnwrap(makeStatus(
            socialState: ReferralStatusProjection.locked,
            firstServingSeen: false
        ))
        XCTAssertFalse(locked.canStartSocialChallenge)
        XCTAssertEqual(
            ReferralPanelPresenter.capacity(locked),
            "1 remaining · 0 redeemed · 1 total"
        )

        let pending = try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.pending))
        XCTAssertEqual(
            ReferralPanelPresenter.capacity(pending),
            "1 remaining · 0 redeemed · 1 total"
        )
    }

    func testFailedHeadlineTracksInviteAvailability() throws {
        let ready = try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.failed))
        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: ready),
            "Base invite ready · X bonus not awarded"
        )

        let exhausted = try XCTUnwrap(makeStatus(
            socialState: ReferralStatusProjection.failed,
            redemptions: 1,
            remaining: 0
        ))
        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: exhausted),
            "Invite capacity used · X bonus not awarded"
        )

        let unlockedNoLink = try XCTUnwrap(ReferralStatusProjection(
            campaign: "prebeta",
            joinBaseURL: URL(string: "https://malibu.tech/j")!,
            socialState: ReferralStatusProjection.failed,
            baseCapacity: 1,
            configuredBonusCapacity: 2,
            bonusCapacity: 0,
            redemptions: 0,
            remaining: 1,
            firstServingSeen: true,
            joinLinksEnabled: true,
            socialBonusEnabled: true,
            socialBonusGrantsRemaining: 5,
            inviteCode: nil,
            inviteURL: nil,
            observedAt: Date(),
            pendingChallenge: nil
        ))
        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: unlockedNoLink),
            "Base invite unlocked · X bonus not awarded"
        )
    }

    func testEligibleCopyClaimsInviteOnlyWhenURLPresent() throws {
        let withInvite = try XCTUnwrap(makeStatus())
        XCTAssertTrue(
            ReferralPanelPresenter.detail(availability: .available, status: withInvite)
                .contains("Copy your private invite anytime")
        )

        let withoutInvite = try XCTUnwrap(ReferralStatusProjection(
            campaign: "prebeta",
            joinBaseURL: URL(string: "https://malibu.tech/j")!,
            socialState: ReferralStatusProjection.eligible,
            baseCapacity: 1,
            configuredBonusCapacity: 2,
            bonusCapacity: 0,
            redemptions: 0,
            remaining: 1,
            firstServingSeen: true,
            joinLinksEnabled: true,
            socialBonusEnabled: true,
            socialBonusGrantsRemaining: 5,
            inviteCode: nil,
            inviteURL: nil,
            observedAt: Date(),
            pendingChallenge: nil
        ))
        XCTAssertNil(withoutInvite.availableInviteURL)
        XCTAssertEqual(
            ReferralPanelPresenter.detail(availability: .available, status: withoutInvite),
            "1 invite use remaining · 0 redeemed."
        )
        XCTAssertFalse(
            ReferralPanelPresenter.detail(availability: .available, status: withoutInvite)
                .contains("Copy your private invite")
        )
    }

    func testInviteMayUseCoordinatorDeclaredPublicJoinDomain() throws {
        let joinBaseURL = try XCTUnwrap(URL(string: "https://malibu.tech/j"))
        let inviteURL = try XCTUnwrap(URL(string: "https://malibu.tech/j#/CODE"))
        let status = try XCTUnwrap(makeStatus(
            joinBaseURL: joinBaseURL,
            inviteURL: inviteURL
        ))

        XCTAssertEqual(status.availableInviteURL, inviteURL)
    }

    func testJoinLinkRollbackPreservesStatusButSuppressesInviteAndAdvocacy() throws {
        let status = try XCTUnwrap(makeStatus(joinLinksEnabled: false, inviteURL: nil))

        XCTAssertEqual(status.remaining, 1)
        XCTAssertEqual(status.inviteCode, "CODE")
        XCTAssertNil(status.availableInviteURL)
        XCTAssertFalse(status.canStartSocialChallenge)
        XCTAssertEqual(
            ReferralPanelPresenter.headline(availability: .available, status: status),
            "Invite links temporarily unavailable"
        )
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
        XCTAssertNil(makeStatus(inviteURL: URL(string: "https://other.example/j/OTHER")))
    }

    func testPendingCopyNeverClaimsBonusWasEarned() throws {
        let status = try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.pending))
        let detail = ReferralPanelPresenter.detail(availability: .available, status: status)
        XCTAssertTrue(detail.contains("base invite is already unlocked"))
        XCTAssertTrue(detail.contains("No X bonus is earned until the public post is verified"))
        XCTAssertFalse(detail.lowercased().contains("earned from the x"))
    }

    func testReferralPublicCopyDoesNotExposeInternalTerms() throws {
        let cases: [(ReferralAvailability, ReferralStatusProjection?)] = [
            (.unsupported, nil),
            (.disabled, nil),
            (.unavailable, nil),
            (.available, nil),
            (.available, try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.locked, firstServingSeen: false))),
            (.available, try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.eligible))),
            (.available, try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.pending))),
            (.available, try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.matured, remaining: 3, bonusCapacity: 2))),
            (.available, try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.failed))),
            (.available, try XCTUnwrap(makeStatus(socialState: ReferralStatusProjection.revoked))),
            (.available, try XCTUnwrap(makeStatus(joinLinksEnabled: false, inviteURL: nil))),
        ]

        let publicCopy = cases.flatMap { availability, status in
            [
                ReferralPanelPresenter.headline(availability: availability, status: status),
                ReferralPanelPresenter.detail(availability: availability, status: status),
            ]
        }.joined(separator: "\n").lowercased()

        for term in prohibitedPublicTerms {
            XCTAssertFalse(publicCopy.contains(term), "\(term) leaked in:\n\(publicCopy)")
        }
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

    @MainActor
    func testReferralActionWatchdogTimesOutAndCanBeCancelled() async {
        XCTAssertGreaterThan(
            ReferralRefreshPolicy.actionResponseTimeout,
            2 * 20,
            "challenge watchdog must exceed both sequential coordinator resource budgets"
        )
        let fired = expectation(description: "watchdog fired")
        let watchdog = ReferralActionWatchdog(timeout: 0.01)
        watchdog.arm { fired.fulfill() }
        await fulfillment(of: [fired], timeout: 1)

        let cancelled = expectation(description: "cancelled watchdog stayed quiet")
        cancelled.isInverted = true
        watchdog.arm { cancelled.fulfill() }
        watchdog.cancel()
        await fulfillment(of: [cancelled], timeout: 0.05)
    }

    @MainActor
    func testReferralActionWatchdogAllowsAValidDelayedResponse() async {
        let timedOut = expectation(description: "valid delayed response stayed inside watchdog")
        timedOut.isInverted = true
        let watchdog = ReferralActionWatchdog(timeout: 0.1)
        watchdog.arm { timedOut.fulfill() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        watchdog.cancel()
        await fulfillment(of: [timedOut], timeout: 0.15)
    }

    @MainActor
    func testNearExpiryStatusDoesNotInvalidateDelayedChallengeResponse() async throws {
        let agent = MalibuAgent(initialSnapshot: trustedReferralSnapshot())
        let status = try XCTUnwrap(makeStatus(
            observedAt: Date().addingTimeInterval(-ReferralRefreshPolicy.statusLifetime + 0.02)
        ))
        agent.consume(.referralStatusResponse(status))
        agent.beginReferralAction()

        try await Task.sleep(nanoseconds: 50_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        agent.consume(.referralChallengeResponse(
            expiresAt: formatter.string(from: Date().addingTimeInterval(600))
        ))

        XCTAssertEqual(agent.snapshot.referralStatus?.pendingChallenge?.expiresAt.timeIntervalSinceNow ?? 0, 600, accuracy: 1)
        XCTAssertEqual(agent.snapshot.referralAvailability, .available)
        XCTAssertFalse(agent.snapshot.referralActionInProgress)
    }

    @MainActor
    func testStaleStatusRateLimitStopsAutomaticRefreshLoop() async throws {
        let agent = MalibuAgent(initialSnapshot: trustedReferralSnapshot())
        let status = try XCTUnwrap(makeStatus(
            observedAt: Date().addingTimeInterval(-ReferralRefreshPolicy.statusLifetime + 0.02)
        ))
        agent.consume(.referralStatusResponse(status))
        agent.beginReferralAction()
        try await Task.sleep(nanoseconds: 50_000_000)

        for _ in 0..<2 {
            agent.consume(.referralError(
                operation: .status,
                code: .rateLimited,
                retryAfterSeconds: 30
            ))
        }

        XCTAssertNil(agent.snapshot.referralStatus)
        XCTAssertEqual(agent.snapshot.referralAvailability, .unavailable)
        XCTAssertFalse(agent.snapshot.referralActionInProgress)
        XCTAssertEqual(agent.snapshot.referralLastError, "Too many referral requests. Retry in 30 seconds.")
    }

    @MainActor
    func testStaleStatusFeatureRollbackRemainsDisabled() async throws {
        let agent = MalibuAgent(initialSnapshot: trustedReferralSnapshot())
        let status = try XCTUnwrap(makeStatus(
            observedAt: Date().addingTimeInterval(-ReferralRefreshPolicy.statusLifetime + 0.02)
        ))
        agent.consume(.referralStatusResponse(status))
        agent.beginReferralAction()
        try await Task.sleep(nanoseconds: 50_000_000)

        agent.consume(.referralError(
            operation: .status,
            code: .featureUnavailable,
            retryAfterSeconds: nil
        ))

        XCTAssertNil(agent.snapshot.referralStatus)
        XCTAssertEqual(agent.snapshot.referralAvailability, .disabled)
        XCTAssertFalse(agent.snapshot.referralActionInProgress)
        XCTAssertEqual(agent.snapshot.referralLastError, "Invite actions are not enabled yet.")
    }

    func testSocialRollbackSuppressesOnlyAdvocacyActions() throws {
        let status = try XCTUnwrap(makeStatus())
        let rolledBack = try XCTUnwrap(status.withSocialBonusEnabled(false))
        XCTAssertEqual(rolledBack.availableInviteURL, status.availableInviteURL)
        XCTAssertFalse(rolledBack.canStartSocialChallenge)
    }

    func testSocialGrantCapSuppressesAdvocacyActions() throws {
        let status = try XCTUnwrap(makeStatus(socialBonusGrantsRemaining: 0))

        XCTAssertNotNil(status.socialChallengeInviteURL)
        XCTAssertFalse(status.canStartSocialChallenge)
    }

    func testReferralBoundaryNegotiatesByCapabilityNotMarketingVersion() {
        var snapshot = AgentSnapshot.empty
        snapshot.cliVersion = "99.1"
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusLifecycleOwner = "macprovider_cli"
        snapshot.localStatusCapabilities = ["referral_status_v1", "referral_fragment_links_v1", "service_instance_v1", "status_observation_v1"]
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
        snapshot.localStatusCapabilities.insert("referral_status_v1")
        snapshot.localStatusCapabilities.remove("referral_fragment_links_v1")
        XCTAssertFalse(snapshot.hasTrustedReferralBoundary())
    }

    private func trustedReferralSnapshot() -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusLifecycleOwner = "macprovider_cli"
        snapshot.localStatusCapabilities = [
            "referral_status_v1",
            "referral_advocacy_v1",
            "referral_repeatable_advocacy_v1",
            "referral_fragment_links_v1",
            "service_instance_v1",
            "status_observation_v1",
        ]
        snapshot.localProviderID = "provider-1"
        snapshot.serviceRole = "serve"
        snapshot.statusObservationID = "obs-1"
        return snapshot
    }

    private func makeStatus(
        socialState: String = ReferralStatusProjection.eligible,
        firstServingSeen: Bool = true,
        redemptions: Int = 0,
        remaining: Int = 1,
        bonusCapacity: Int = 0,
        joinBaseURL: URL = URL(string: "https://malibu.tech/j")!,
        joinLinksEnabled: Bool = true,
        socialBonusGrantsRemaining: Int? = 5,
        inviteURL: URL? = URL(string: "https://malibu.tech/j#/CODE"),
        observedAt: Date = Date()
    ) -> ReferralStatusProjection? {
        ReferralStatusProjection(
            campaign: "prebeta",
            joinBaseURL: joinBaseURL,
            socialState: socialState,
            baseCapacity: 1,
            configuredBonusCapacity: 2,
            bonusCapacity: bonusCapacity,
            redemptions: redemptions,
            remaining: remaining,
            firstServingSeen: firstServingSeen,
            joinLinksEnabled: joinLinksEnabled,
            socialBonusEnabled: true,
            socialBonusGrantsRemaining: socialBonusGrantsRemaining,
            inviteCode: "CODE",
            inviteURL: inviteURL,
            observedAt: observedAt,
            pendingChallenge: nil
        )
    }
}
