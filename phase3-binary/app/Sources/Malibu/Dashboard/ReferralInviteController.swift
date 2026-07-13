import AppKit
import Foundation

struct ProviderReferralStatus: Decodable, Equatable {
    // PROD-M3: durable advocacy status set by the coordinator once a valid X
    // post has been submitted and is awaiting review.
    static let pendingSocialReview = "pending_social_review"
    // PROD-M4: terminal advocacy status when the X post could not be verified.
    static let socialReviewFailed = "social_review_failed"

    let advocacyStatus: String
    let inviteCode: String
    let remaining: Int
    let socialVerified: Bool
    let firstServingSeen: Bool
    let socialBonusEnabled: Bool
    let inviteURL: URL?
    // Currently-AWARDED bonus capacity: 0 until the X post is verified and
    // promoted. Use this only for the post-grant state, never for the
    // pre-verification incentive copy (PROD-M2).
    let bonusUses: Int?
    // PROD-M2: the coordinator advertises the CONFIGURED X-share bonus size
    // independently of whether it has been awarded yet. This is what the user
    // unlocks BY sharing, so the "share to unlock N" copy must use it.
    let configuredBonusUses: Int?
    // PROD-M3: when a valid X post is under review the coordinator returns the
    // time it becomes ELIGIBLE for review (pending_since + dwell), not a
    // completion time. The reconciler runs on its own interval and may retry
    // past this instant on transient X failures. The post must stay public
    // until it is verified.
    let reviewDueAt: Date?
    // PROD-M3: optional cross-lane observability the coordinator MAY expose so
    // the dashboard can distinguish normal queueing from a stuck/retrying
    // review. Decoded defensively — absent on coordinators that don't emit
    // them, in which case the UI degrades to a generic "checking periodically".
    // The Go lane owns these field names; keep them in sync if it renames.
    let reviewLastAttemptAt: Date?
    let reviewNextAttemptAt: Date?
    // PROD-M4: optional coordinator-provided terminal-failure reason code so the
    // dashboard can show a specific corrective action instead of generic
    // speculation. Decoded defensively; unknown/absent codes fall back to
    // generic guidance. `reviewRetryAllowed` gates a re-challenge CTA only when
    // the coordinator says a fresh attempt is permitted after this failure.
    let reviewFailureReason: String?
    let reviewRetryAllowed: Bool?

    enum CodingKeys: String, CodingKey {
        case advocacyStatus = "advocacy_status"
        case inviteCode = "invite_code"
        case remaining
        case socialVerified = "social_verified"
        case firstServingSeen = "first_serving_seen"
        case socialBonusEnabled = "social_bonus_enabled"
        case inviteURL = "invite_url"
        case bonusUses = "bonus_uses"
        case configuredBonusUses = "configured_bonus_uses"
        case reviewDueAt = "review_due_at"
        case reviewLastAttemptAt = "review_last_attempt_at"
        case reviewNextAttemptAt = "review_next_attempt_at"
        case reviewFailureReason = "review_failure_reason"
        case reviewRetryAllowed = "review_retry_allowed"
    }

    /// True once a valid X post has been submitted and is awaiting review.
    var isPendingSocialReview: Bool {
        advocacyStatus == Self.pendingSocialReview
    }

    /// True when a submitted X post terminally failed verification.
    var isSocialReviewFailed: Bool {
        advocacyStatus == Self.socialReviewFailed
    }

    /// PROD-M4: reason-specific corrective action for a terminal review
    /// failure. The coordinator (Go lane) owns the reason-code vocabulary; this
    /// maps the codes we know and degrades to generic guidance for anything
    /// unrecognized or absent so a renamed/added code never crashes or misleads.
    var reviewFailureCorrectiveAction: String {
        switch reviewFailureReason?.lowercased() {
        case "deleted", "not_found", "missing_post":
            return "The post appears to have been deleted before it could be verified. Post again and keep it public until verification finishes."
        case "private", "not_public", "protected", "visibility":
            return "The post was not publicly visible during review. Make sure your X account and the post are public, then post again."
        case "author_mismatch", "wrong_author":
            return "The post was published by a different X account than the one linked to this provider. Post from your own account and try again."
        case "wrong_post", "content_mismatch", "missing_link", "no_challenge":
            return "The post didn't include the required Malibu verification link. Use the Share on X composer so the link is included, then try again."
        case "expired", "timed_out":
            return "The verification window elapsed before the post could be checked. Start a new share and verify it promptly."
        default:
            return "This can happen if the post was edited, made private, or removed before review finished."
        }
    }

    /// Configured X-share bonus size for the pre-verification incentive copy,
    /// or nil when the coordinator advertises no positive configured/awarded
    /// capacity. PROD-M2: reflects `configured_bonus_uses` (what sharing
    /// unlocks), never the awarded `bonus_uses` which is 0 until promotion.
    /// L2(prod): when the configured capacity is absent it returns nil rather
    /// than the historical default of 2 — a zero-bonus or mixed-version
    /// coordinator must never be advertised as a two-use promise inferred from
    /// a zero award.
    var shareIncentiveBonusUses: Int? {
        if let configuredBonusUses, configuredBonusUses > 0 { return configuredBonusUses }
        if let bonusUses, bonusUses > 0 { return bonusUses }
        return nil
    }

    /// "two more invite uses" / "one more invite use" when the bonus size is
    /// known. L2(prod): a non-numeric "bonus invite uses" fallback when the
    /// coordinator advertises no positive capacity, so a zero award is never
    /// rendered as a specific count.
    var shareIncentivePhrase: String {
        guard let count = shareIncentiveBonusUses else { return "bonus invite uses" }
        return Self.bonusPhrase(for: count)
    }

    static func bonusPhrase(for count: Int) -> String {
        let word: String
        switch count {
        case 1: word = "one"
        case 2: word = "two"
        case 3: word = "three"
        default: word = "\(count)"
        }
        return "\(word) more invite use\(count == 1 ? "" : "s")"
    }
}

struct ReferralShareChallenge: Codable, Equatable {
    let intentURL: URL
    let shareURL: URL
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case intentURL = "intent_url"
        case shareURL = "share_url"
        case expiresAt = "expires_at"
    }

    var challenge: String? {
        URLComponents(url: shareURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "c" })?
            .value
    }
}

enum ReferralInviteClientError: Error, LocalizedError, Equatable {
    case httpStatus(Int, String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .httpStatus(_, message):
            return message ?? "The invite service is temporarily unavailable."
        case .invalidResponse:
            return "The invite service returned an invalid response."
        }
    }
}

private struct ReferralAPIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String? }
    let error: APIError?
}

struct ReferralInviteClient {
    let coordinatorBaseURL: URL
    private let session: URLSession?

    init(coordinatorBaseURL: URL, session: URLSession? = nil) {
        self.coordinatorBaseURL = coordinatorBaseURL
        self.session = session
    }

    func fetchStatus(bearerToken: String) async throws -> ProviderReferralStatus {
        try await send(
            path: "v1/provider/referrals",
            method: "GET",
            bearerToken: bearerToken,
            body: Optional<String>.none,
            response: ProviderReferralStatus.self
        )
    }

    func createXChallenge(bearerToken: String) async throws -> ReferralShareChallenge {
        try await send(
            path: "v1/provider/referrals/x/challenge",
            method: "POST",
            bearerToken: bearerToken,
            body: Optional<String>.none,
            response: ReferralShareChallenge.self
        )
    }

    func verifyXPost(postURL: String, challenge: String, bearerToken: String) async throws -> ProviderReferralStatus {
        struct Body: Encodable {
            let postURL: String
            let challenge: String

            enum CodingKeys: String, CodingKey {
                case postURL = "post_url"
                case challenge
            }
        }
        return try await send(
            path: "v1/provider/referrals/x/verify",
            method: "POST",
            bearerToken: bearerToken,
            body: Body(postURL: postURL, challenge: challenge),
            response: ProviderReferralStatus.self
        )
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        bearerToken: String,
        body: Body?,
        response: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: coordinatorBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let urlResponse: URLResponse
        if let session {
            (data, urlResponse) = try await session.data(for: request)
        } else {
            let guarded = ProviderBearerURLSession.make()
            defer { guarded.finishTasksAndInvalidate() }
            (data, urlResponse) = try await guarded.data(for: request)
        }
        guard let http = urlResponse as? HTTPURLResponse else {
            throw ReferralInviteClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(ReferralAPIErrorEnvelope.self, from: data)
            throw ReferralInviteClientError.httpStatus(http.statusCode, envelope?.error?.message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(response, from: data)
    }
}

@MainActor
final class ReferralInviteController: ObservableObject {
    @Published private(set) var status: ProviderReferralStatus?
    @Published private(set) var isLoading = false
    @Published private(set) var pendingChallenge: ReferralShareChallenge?
    @Published private(set) var errorMessage: String?
    @Published var postURL = ""
    @Published var dismissed = false
    // ADV-M2: guard concurrent Share-on-X requests. `isSharing` disables the
    // control while a challenge request is in flight; `shareGeneration`
    // discards a response whose request was superseded (the coordinator
    // deletes the prior challenge when a new one is minted, so an out-of-order
    // reply would otherwise leave the UI holding a server-side-deleted one).
    @Published private(set) var isSharing = false
    private var shareGeneration = 0
    private var restoredProviderID: String?

    var isVisible: Bool {
        !dismissed && (isLoading || status != nil || errorMessage != nil)
    }

    /// PROD-M3: true while the status can still advance without user action, so
    /// the dashboard keeps polling — the pre-serving lock and a pending X
    /// review (which the coordinator's reconciler promotes or retries on its
    /// own interval) both resolve on their own.
    var autoRefreshes: Bool {
        switch status?.advocacyStatus {
        case "locked_until_first_serving", ProviderReferralStatus.pendingSocialReview:
            return true
        default:
            return false
        }
    }

    var canVerify: Bool {
        pendingChallenge?.challenge != nil && !postURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var pendingExpiryText: String? {
        guard let expiry = pendingChallenge?.expiresAt else { return nil }
        return "Verification link expires \(expiry.formatted(date: .omitted, time: .shortened))."
    }

    func refresh() async {
        guard !dismissed, let credentials = await credentials() else { return }
        await restorePendingChallengeIfNeeded(providerID: credentials.providerID)
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            status = try await credentials.client.fetchStatus(bearerToken: credentials.token)
        } catch ReferralInviteClientError.httpStatus(404, _) {
            status = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyPrivateInvite() {
        guard let status, status.remaining > 0,
              let inviteURL = status.inviteURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(inviteURL.absoluteString, forType: .string)
    }

    func shareOnX() async {
        // ADV-M2: claim the in-flight flag and bump the generation BEFORE the
        // first `await`. `@MainActor` methods are reentrant across suspension,
        // so setting `isSharing` after `await credentials()` would let two rapid
        // taps both pass the guard. Setting it synchronously here means the
        // second tap sees `isSharing == true` and returns immediately.
        guard !isSharing else { return }
        shareGeneration += 1
        let generation = shareGeneration
        isSharing = true
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            // Only clear the in-flight flag if this invocation is still current.
            if generation == shareGeneration { isSharing = false }
        }
        guard let credentials = await credentials() else { return }
        do {
            let challenge = try await credentials.client.createXChallenge(bearerToken: credentials.token)
            // Discard a superseded response: a newer shareOnX() (or startOver)
            // bumped the generation while this request was in flight.
            guard generation == shareGeneration else { return }
            guard challenge.challenge?.count == 64 else {
                throw ReferralInviteClientError.invalidResponse
            }
            pendingChallenge = challenge
            try await KeychainStore.saveReferralChallenge(
                providerID: credentials.providerID,
                data: JSONEncoder().encode(challenge)
            )
            NSWorkspace.shared.open(challenge.intentURL)
        } catch {
            guard generation == shareGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func verifyPost() async {
        guard let credentials = await credentials(), let challenge = pendingChallenge?.challenge else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            status = try await credentials.client.verifyXPost(
                postURL: postURL.trimmingCharacters(in: .whitespacesAndNewlines),
                challenge: challenge,
                bearerToken: credentials.token
            )
            pendingChallenge = nil
            postURL = ""
            try? await KeychainStore.deleteReferralChallenge(providerID: credentials.providerID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // PROD-L1: reopens the X compose window (intent URL), not the published
    // post — the published post URL is what the user pastes to verify.
    func reopenPostComposer() {
        if let intentURL = pendingChallenge?.intentURL {
            NSWorkspace.shared.open(intentURL)
        }
    }

    func startOver() async {
        // ADV-M2: supersede any in-flight Share-on-X request so its response is
        // discarded and the control re-enables.
        shareGeneration += 1
        isSharing = false
        pendingChallenge = nil
        postURL = ""
        if let providerID = ProviderConfig.readProviderID() {
            try? await KeychainStore.deleteReferralChallenge(providerID: providerID)
        }
    }

    private func restorePendingChallengeIfNeeded(providerID: String) async {
        guard restoredProviderID != providerID else { return }
        restoredProviderID = providerID
        guard let data = await KeychainStore.readReferralChallenge(providerID: providerID),
              let challenge = try? JSONDecoder().decode(ReferralShareChallenge.self, from: data),
              challenge.expiresAt > Date() else {
            try? await KeychainStore.deleteReferralChallenge(providerID: providerID)
            return
        }
        pendingChallenge = challenge
    }

    private func credentials() async -> (client: ReferralInviteClient, token: String, providerID: String)? {
        guard let providerID = ProviderConfig.readProviderID(),
              let token = await KeychainStore.readProviderToken(providerID: providerID) else {
            errorMessage = "Provider credentials are unavailable."
            return nil
        }
        let baseURL = ProviderConfig.readCoordinatorBaseURL()
            ?? URL(string: "https://coordinator.streamvc.live")!
        return (ReferralInviteClient(coordinatorBaseURL: baseURL), token, providerID)
    }
}
