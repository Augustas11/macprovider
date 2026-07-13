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

/// PROD-M2 / PROD-M3: the dashboard renders the referral status envelope. These
/// pin the new cross-lane fields (`configured_bonus_uses`, the
/// `pending_social_review`/`social_review_failed` advocacy states, and
/// `review_due_at`) and the corrected pre-verification bonus copy.
final class ProviderReferralStatusDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> ProviderReferralStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProviderReferralStatus.self, from: Data(json.utf8))
    }

    // PROD-M2: the "share to unlock N" copy uses configured_bonus_uses, NOT the
    // awarded bonus_uses (0 until promotion). The explicit 0 must not become 2.
    func testShareIncentiveUsesConfiguredBonusNotAwardedZero() throws {
        let status = try decode("""
        {"advocacy_status":"eligible","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":"https://malibu.tech/abc","bonus_uses":0,"configured_bonus_uses":2}
        """)
        XCTAssertEqual(status.bonusUses, 0)
        XCTAssertEqual(status.configuredBonusUses, 2)
        XCTAssertEqual(status.shareIncentiveBonusUses, 2)
        XCTAssertEqual(status.shareIncentivePhrase, "two more invite uses")
    }

    func testShareIncentiveHonoursNonDefaultConfiguredBonus() throws {
        let status = try decode("""
        {"advocacy_status":"eligible","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null,"bonus_uses":0,"configured_bonus_uses":1}
        """)
        XCTAssertEqual(status.shareIncentiveBonusUses, 1)
        XCTAssertEqual(status.shareIncentivePhrase, "one more invite use")
    }

    // L2(prod): an older/zero-bonus coordinator advertising neither field must
    // NOT be rendered as the historical "two uses" — the incentive size is
    // unavailable and the copy is non-numeric so a zero award is never promised
    // as a specific count.
    func testShareIncentiveUsesNonNumericCopyWhenFieldsAbsent() throws {
        let status = try decode("""
        {"advocacy_status":"eligible","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null}
        """)
        XCTAssertNil(status.configuredBonusUses)
        XCTAssertNil(status.bonusUses)
        XCTAssertNil(status.shareIncentiveBonusUses)
        XCTAssertEqual(status.shareIncentivePhrase, "bonus invite uses")
    }

    // L2(prod): an explicit zero configured bonus is also unavailable, not two.
    func testShareIncentiveIsUnavailableWhenConfiguredBonusIsZero() throws {
        let status = try decode("""
        {"advocacy_status":"eligible","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null,"bonus_uses":0,"configured_bonus_uses":0}
        """)
        XCTAssertNil(status.shareIncentiveBonusUses)
        XCTAssertEqual(status.shareIncentivePhrase, "bonus invite uses")
    }

    // PROD-M3: pending review decodes advocacy_status + review_due_at.
    func testPendingSocialReviewDecodesReviewDueAt() throws {
        let status = try decode("""
        {"advocacy_status":"pending_social_review","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null,"bonus_uses":0,"configured_bonus_uses":2,
         "review_due_at":"2026-07-12T18:30:00Z"}
        """)
        XCTAssertTrue(status.isPendingSocialReview)
        XCTAssertEqual(status.advocacyStatus, ProviderReferralStatus.pendingSocialReview)
        XCTAssertEqual(status.reviewDueAt, ISO8601DateFormatter().date(from: "2026-07-12T18:30:00Z"))
    }

    // PROD-M3: the terminal failed state decodes with no review_due_at.
    func testFailedReviewStateDecodesWithoutReviewDueAt() throws {
        let status = try decode("""
        {"advocacy_status":"social_review_failed","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null}
        """)
        XCTAssertFalse(status.isPendingSocialReview)
        XCTAssertTrue(status.isSocialReviewFailed)
        XCTAssertNil(status.reviewDueAt)
        XCTAssertEqual(status.advocacyStatus, ProviderReferralStatus.socialReviewFailed)
    }

    // PROD-M3: optional last/next attempt observability decodes when present
    // and stays absent (nil, not a crash) when the coordinator omits it.
    func testPendingReviewDecodesOptionalAttemptTimestamps() throws {
        let status = try decode("""
        {"advocacy_status":"pending_social_review","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null,"review_due_at":"2026-07-12T18:30:00Z",
         "review_last_attempt_at":"2026-07-12T18:35:00Z",
         "review_next_attempt_at":"2026-07-12T18:40:00Z"}
        """)
        XCTAssertEqual(status.reviewLastAttemptAt, ISO8601DateFormatter().date(from: "2026-07-12T18:35:00Z"))
        XCTAssertEqual(status.reviewNextAttemptAt, ISO8601DateFormatter().date(from: "2026-07-12T18:40:00Z"))
    }

    func testPendingReviewToleratesAbsentAttemptTimestamps() throws {
        let status = try decode("""
        {"advocacy_status":"pending_social_review","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null,"review_due_at":"2026-07-12T18:30:00Z"}
        """)
        XCTAssertNil(status.reviewLastAttemptAt)
        XCTAssertNil(status.reviewNextAttemptAt)
    }

    // PROD-M4: a known failure reason yields a specific corrective action; an
    // unknown/absent reason degrades to generic guidance rather than misleading.
    func testFailedReviewReasonMapsToCorrectiveAction() throws {
        let deleted = try decode("""
        {"advocacy_status":"social_review_failed","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null,"review_failure_reason":"deleted","review_retry_allowed":true}
        """)
        XCTAssertEqual(deleted.reviewFailureReason, "deleted")
        XCTAssertEqual(deleted.reviewRetryAllowed, true)
        XCTAssertTrue(deleted.reviewFailureCorrectiveAction.contains("deleted"))

        let unknown = try decode("""
        {"advocacy_status":"social_review_failed","invite_code":"abc","remaining":1,
         "social_verified":false,"first_serving_seen":true,"social_bonus_enabled":true,
         "invite_url":null,"review_failure_reason":"some_new_code"}
        """)
        XCTAssertNil(unknown.reviewRetryAllowed)
        XCTAssertEqual(
            unknown.reviewFailureCorrectiveAction,
            "This can happen if the post was edited, made private, or removed before review finished."
        )
    }
}
