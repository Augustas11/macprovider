import Foundation

enum ReferralRefreshPolicy {
    static let minimumInterval: TimeInterval = 60
    static let statusLifetime: TimeInterval = 90

    static func shouldRequest(now: Date, lastRequestedAt: Date?) -> Bool {
        lastRequestedAt.map { now.timeIntervalSince($0) >= minimumInterval } != false
    }
}

enum ReferralAvailability: Equatable {
    case unsupported
    case disabled
    case unavailable
    case available
}

struct ReferralPendingChallengeProjection: Equatable, Sendable {
    let expiresAt: Date
}

struct ReferralStatusProjection: Equatable, Sendable {
    static let locked = "locked_until_first_serving"
    static let eligible = "eligible"
    static let pending = "pending"
    static let matured = "matured"
    static let failed = "failed"
    static let revoked = "revoked"
    static let supportedStates: Set<String> = [locked, eligible, pending, matured, failed, revoked]

    let campaign: String
    let joinBaseURL: URL
    let socialState: String
    let baseCapacity: Int
    let configuredBonusCapacity: Int
    let bonusCapacity: Int
    let redemptions: Int
    let remaining: Int
    let firstServingSeen: Bool
    let socialBonusEnabled: Bool
    let inviteCode: String?
    let inviteURL: URL?
    let observedAt: Date
    let pendingChallenge: ReferralPendingChallengeProjection?

    init?(
        campaign: String,
        joinBaseURL: URL,
        socialState: String,
        baseCapacity: Int,
        configuredBonusCapacity: Int,
        bonusCapacity: Int,
        redemptions: Int,
        remaining: Int,
        firstServingSeen: Bool,
        socialBonusEnabled: Bool,
        inviteCode: String?,
        inviteURL: URL?,
        observedAt: Date,
        pendingChallenge: ReferralPendingChallengeProjection?
    ) {
        let counts = [baseCapacity, configuredBonusCapacity, bonusCapacity, redemptions, remaining]
        guard Self.supportedStates.contains(socialState),
              !campaign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isCanonicalJoinBase(joinBaseURL),
              counts.allSatisfy({ (0...1_000_000).contains($0) }),
              remaining == max(0, baseCapacity + bonusCapacity - redemptions),
              observedAt <= Date().addingTimeInterval(60) else {
            return nil
        }
        switch (inviteCode, inviteURL) {
        case (nil, nil):
            break
        case let (code?, url?):
            guard Self.isCanonicalInvite(url, code: code, joinBaseURL: joinBaseURL) else { return nil }
        default:
            return nil
        }
        if let pendingChallenge, pendingChallenge.expiresAt <= observedAt {
            return nil
        }
        self.campaign = campaign
        self.joinBaseURL = joinBaseURL
        self.socialState = socialState
        self.baseCapacity = baseCapacity
        self.configuredBonusCapacity = configuredBonusCapacity
        self.bonusCapacity = bonusCapacity
        self.redemptions = redemptions
        self.remaining = remaining
        self.firstServingSeen = firstServingSeen
        self.socialBonusEnabled = socialBonusEnabled
        self.inviteCode = inviteCode
        self.inviteURL = inviteURL
        self.observedAt = observedAt
        self.pendingChallenge = pendingChallenge
    }

    var availableInviteURL: URL? {
        guard firstServingSeen,
              socialState != Self.locked,
              socialState != Self.revoked,
              remaining > 0,
              let inviteCode,
              !inviteCode.isEmpty,
              let inviteURL,
              Self.isCanonicalInvite(inviteURL, code: inviteCode, joinBaseURL: joinBaseURL) else {
            return nil
        }
        return inviteURL
    }

    var canStartSocialChallenge: Bool {
        socialBonusEnabled
            && configuredBonusCapacity > 0
            && [Self.eligible, Self.failed].contains(socialState)
            && pendingChallenge == nil
            && availableInviteURL != nil
    }

    func withPendingChallenge(_ challenge: ReferralPendingChallengeProjection?) -> Self? {
        Self(
            campaign: campaign,
            joinBaseURL: joinBaseURL,
            socialState: socialState,
            baseCapacity: baseCapacity,
            configuredBonusCapacity: configuredBonusCapacity,
            bonusCapacity: bonusCapacity,
            redemptions: redemptions,
            remaining: remaining,
            firstServingSeen: firstServingSeen,
            socialBonusEnabled: socialBonusEnabled,
            inviteCode: inviteCode,
            inviteURL: inviteURL,
            observedAt: observedAt,
            pendingChallenge: challenge
        )
    }

    func withSocialBonusEnabled(_ enabled: Bool) -> Self? {
        Self(
            campaign: campaign,
            joinBaseURL: joinBaseURL,
            socialState: socialState,
            baseCapacity: baseCapacity,
            configuredBonusCapacity: configuredBonusCapacity,
            bonusCapacity: bonusCapacity,
            redemptions: redemptions,
            remaining: remaining,
            firstServingSeen: firstServingSeen,
            socialBonusEnabled: enabled,
            inviteCode: inviteCode,
            inviteURL: inviteURL,
            observedAt: observedAt,
            pendingChallenge: enabled ? pendingChallenge : nil
        )
    }

    func isCurrent(
        at now: Date = Date(),
        maximumAge: TimeInterval = ReferralRefreshPolicy.statusLifetime
    ) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return age >= -60 && age <= maximumAge
    }

    private static func isCanonicalJoinBase(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.split(separator: "/").last == "j",
              !url.absoluteString.hasSuffix("/") else { return false }
        return true
    }

    private static func isCanonicalInvite(_ url: URL, code: String, joinBaseURL: URL) -> Bool {
        guard !code.isEmpty,
              let expected = URL(string: joinBaseURL.absoluteString + "/" + code) else { return false }
        return url == expected
    }
}

enum ReferralPanelPresenter {
    static func headline(availability: ReferralAvailability, status: ReferralStatusProjection?) -> String {
        switch availability {
        case .unsupported: return "Invites unavailable with this provider CLI"
        case .disabled: return "Invites are not available yet"
        case .unavailable: return "Referral status unavailable"
        case .available:
            guard let status else { return "Referral status unavailable" }
            switch status.socialState {
            case ReferralStatusProjection.locked: return "Serve once to unlock invites"
            case ReferralStatusProjection.eligible: return status.remaining == 0 ? "Invite capacity used" : "Invites ready"
            case ReferralStatusProjection.pending: return "X post awaiting coordinator review"
            case ReferralStatusProjection.matured: return "X bonus awarded"
            case ReferralStatusProjection.failed: return "X post was not verified"
            case ReferralStatusProjection.revoked: return "Invites revoked"
            default: return "Referral status unavailable"
            }
        }
    }

    static func detail(availability: ReferralAvailability, status: ReferralStatusProjection?) -> String {
        switch availability {
        case .unsupported:
            return "Update the CLI compatibility set to view coordinator-authoritative referral status."
        case .disabled:
            return "The coordinator has not enabled referral actions. Provider serving is unaffected."
        case .unavailable:
            return "Malibu cannot confirm invite capacity right now. Provider serving is unaffected."
        case .available:
            guard let status else { return "Malibu cannot confirm invite capacity right now." }
            switch status.socialState {
            case ReferralStatusProjection.locked:
                return "The coordinator has not yet confirmed a verified buyer-serving receipt."
            case ReferralStatusProjection.pending:
                return "No bonus is earned until the coordinator verifies the public post."
            case ReferralStatusProjection.matured:
                return "The coordinator reports \(invitePhrase(status.bonusCapacity)) earned from the X reward."
            case ReferralStatusProjection.failed:
                return "No bonus was awarded. You can create a new verification post when available."
            case ReferralStatusProjection.revoked:
                return "Referral actions are disabled. Your provider can continue serving."
            default:
                return "\(invitePhrase(status.remaining)) remaining · \(status.redemptions) redeemed."
            }
        }
    }

    static func capacity(_ status: ReferralStatusProjection) -> String {
        "\(status.remaining) remaining · \(status.redemptions) redeemed · \(status.baseCapacity + status.bonusCapacity) total"
    }

    static func invitePhrase(_ count: Int) -> String {
        "\(count) invite use\(count == 1 ? "" : "s")"
    }
}
