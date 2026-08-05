import Foundation

enum ReferralRefreshPolicy {
    static let minimumInterval: TimeInterval = 60
    static let statusLifetime: TimeInterval = 90
    // Challenge creation performs two sequential coordinator requests, each
    // with a 20-second resource budget, before persisting and opening the X
    // intent. Keep the UI watchdog beyond that complete valid path.
    static let actionResponseTimeout: TimeInterval = 45

    static func shouldRequest(now: Date, lastRequestedAt: Date?) -> Bool {
        lastRequestedAt.map { now.timeIntervalSince($0) >= minimumInterval } != false
    }
}

@MainActor
final class ReferralActionWatchdog {
    private let timeout: TimeInterval
    private var task: Task<Void, Never>?

    init(timeout: TimeInterval = ReferralRefreshPolicy.actionResponseTimeout) {
        self.timeout = timeout
    }

    func arm(onTimeout: @escaping @MainActor @Sendable () -> Void) {
        task?.cancel()
        task = Task {
            let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            onTimeout()
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
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
    let joinLinksEnabled: Bool
    let socialBonusEnabled: Bool
    let socialBonusGrantsRemaining: Int?
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
        joinLinksEnabled: Bool,
        socialBonusEnabled: Bool,
        socialBonusGrantsRemaining: Int?,
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
        if let socialBonusGrantsRemaining, !(0...1_000_000).contains(socialBonusGrantsRemaining) {
            return nil
        }
        if let inviteCode, !Self.isSafeInviteCode(inviteCode) { return nil }
        if joinLinksEnabled {
            switch (inviteCode, inviteURL) {
            case (nil, nil):
                break
            case let (code?, url?):
                guard Self.isCanonicalInvite(url, code: code, joinBaseURL: joinBaseURL) else { return nil }
            default:
                return nil
            }
        } else {
            guard inviteURL == nil else { return nil }
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
        self.joinLinksEnabled = joinLinksEnabled
        self.socialBonusEnabled = socialBonusEnabled
        self.socialBonusGrantsRemaining = socialBonusGrantsRemaining
        self.inviteCode = inviteCode
        self.inviteURL = inviteURL
        self.observedAt = observedAt
        self.pendingChallenge = pendingChallenge
    }

    var availableInviteURL: URL? {
        guard firstServingSeen,
              joinLinksEnabled,
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

    var socialChallengeInviteURL: URL? {
        guard firstServingSeen,
              joinLinksEnabled,
              socialState != Self.locked,
              socialState != Self.revoked,
              let inviteCode,
              !inviteCode.isEmpty,
              let inviteURL,
              Self.isCanonicalInvite(inviteURL, code: inviteCode, joinBaseURL: joinBaseURL) else {
            return nil
        }
        return inviteURL
    }

    var canStartSocialChallenge: Bool {
        let grantsAvailable = socialBonusGrantsRemaining.map { $0 > 0 } ?? (socialState != Self.matured)
        return socialBonusEnabled
            && grantsAvailable
            && configuredBonusCapacity > 0
            && [Self.eligible, Self.failed, Self.matured].contains(socialState)
            && pendingChallenge == nil
            && socialChallengeInviteURL != nil
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
            joinLinksEnabled: joinLinksEnabled,
            socialBonusEnabled: socialBonusEnabled,
            socialBonusGrantsRemaining: socialBonusGrantsRemaining,
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
            joinLinksEnabled: joinLinksEnabled,
            socialBonusEnabled: enabled,
            socialBonusGrantsRemaining: enabled ? socialBonusGrantsRemaining : nil,
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
        guard isSafeInviteCode(code),
              let expected = URL(string: joinBaseURL.absoluteString + "#/" + code) else { return false }
        return url == expected
    }

    private static func isSafeInviteCode(_ code: String) -> Bool {
        !code.isEmpty && code.count <= 128 && code.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-._~".unicodeScalars.contains($0)
        }
    }
}

enum ReferralPanelPresenter {
    /// Persistent chrome clarifying SPEC-034's two-step earn path: base from
    /// first verified buyer-serving settlement, then repeatable X bonuses.
    static let pathChrome =
        "Base unlocks after first paid serve · Each X post can add bonus invites"

    static func headline(availability: ReferralAvailability, status: ReferralStatusProjection?) -> String {
        switch availability {
        case .unsupported: return "Invites unavailable with this provider software"
        case .disabled: return "Invites are not available yet"
        case .unavailable: return "Referral status unavailable"
        case .available:
            guard let status else { return "Referral status unavailable" }
            if !status.joinLinksEnabled { return "Invite links temporarily unavailable" }
            switch status.socialState {
            case ReferralStatusProjection.locked: return "Serve once to unlock your base invite"
            case ReferralStatusProjection.eligible:
                return status.remaining == 0 ? "Invite capacity used" : "Base invite ready"
            case ReferralStatusProjection.pending: return "X bonus pending verification"
            case ReferralStatusProjection.matured: return "Base invite unlocked · X bonus awarded"
            case ReferralStatusProjection.failed:
                if status.remaining == 0 { return "Invite capacity used · X bonus not awarded" }
                if status.availableInviteURL != nil { return "Base invite ready · X bonus not awarded" }
                return "Base invite unlocked · X bonus not awarded"
            case ReferralStatusProjection.revoked: return "Invites revoked"
            default: return "Referral status unavailable"
            }
        }
    }

    static func detail(availability: ReferralAvailability, status: ReferralStatusProjection?) -> String {
        switch availability {
        case .unsupported:
            return "Update provider software to view current invite status."
        case .disabled:
            return "Invites are not enabled yet. Provider serving is unaffected."
        case .unavailable:
            return "Malibu cannot confirm invite capacity right now. Provider serving is unaffected."
        case .available:
            guard let status else { return "Malibu cannot confirm invite capacity right now." }
            if !status.joinLinksEnabled {
                return "Your invite balance is preserved while public join links are disabled."
            }
            switch status.socialState {
            case ReferralStatusProjection.locked:
                return "Complete one verified customer job to unlock the base invite. X is an optional bonus after that."
            case ReferralStatusProjection.pending:
                return "Your base invite is already unlocked. No X bonus is earned until the public post is verified."
            case ReferralStatusProjection.matured:
                return maturedDetail(status)
            case ReferralStatusProjection.failed:
                if status.availableInviteURL != nil {
                    return "Your base invite remains available. You can start a new X verification when available."
                }
                return "No X bonus was awarded. You can create a new verification post when available."
            case ReferralStatusProjection.revoked:
                return "Referral actions are disabled. Your provider can continue serving."
            case ReferralStatusProjection.eligible:
                if status.remaining == 0 {
                    return "\(invitePhrase(status.remaining)) remaining · \(status.redemptions) redeemed."
                }
                if status.availableInviteURL != nil {
                    if status.canStartSocialChallenge {
                        return "Copy your private invite anytime. Optional: share on X for \(invitePhrase(status.configuredBonusCapacity))."
                    }
                    return "Copy your private invite anytime."
                }
                return "\(invitePhrase(status.remaining)) remaining · \(status.redemptions) redeemed."
            default:
                return "\(invitePhrase(status.remaining)) remaining · \(status.redemptions) redeemed."
            }
        }
    }

    static func capacity(_ status: ReferralStatusProjection) -> String {
        let total = status.baseCapacity + status.bonusCapacity
        if status.bonusCapacity > 0 {
            return "\(status.remaining) remaining · \(status.redemptions) redeemed · \(status.baseCapacity) base + \(status.bonusCapacity) X bonus (\(total) total)"
        }
        if status.canStartSocialChallenge {
            return "\(status.remaining) remaining · \(status.redemptions) redeemed · \(status.baseCapacity) base · X bonus available"
        }
        return "\(status.remaining) remaining · \(status.redemptions) redeemed · \(total) total"
    }

    static func invitePhrase(_ count: Int) -> String {
        "\(count) invite use\(count == 1 ? "" : "s")"
    }

    private static func maturedDetail(_ status: ReferralStatusProjection) -> String {
        let base = "\(status.baseCapacity) base from serving"
        let bonus = "\(status.bonusCapacity) from X bonus"
        if status.remaining > 0, status.availableInviteURL != nil {
            if status.canStartSocialChallenge {
                return "\(base) · \(bonus). Copy invites anytime, or share another X post for \(invitePhrase(status.configuredBonusCapacity))."
            }
            return "\(base) · \(bonus). Remaining invites stay copyable; X is not required to invite."
        }
        if status.remaining > 0 {
            return "\(base) · \(bonus). Remaining capacity is preserved; invite link unavailable right now."
        }
        return "\(base) · \(bonus). Invite capacity is fully used."
    }
}
