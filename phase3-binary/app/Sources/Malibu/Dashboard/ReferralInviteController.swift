import AppKit
import Foundation

struct ProviderReferralStatus: Decodable, Equatable {
    static let locked = "locked_until_first_serving"
    static let eligible = "eligible"
    static let pending = "pending"
    static let matured = "matured"
    static let failed = "failed"
    static let revoked = "revoked"

    let campaign: String
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
    let reviewDueAt: Date?

    enum CodingKeys: String, CodingKey {
        case campaign
        case socialState = "social_state"
        case baseCapacity = "base_capacity"
        case configuredBonusCapacity = "configured_bonus_capacity"
        case bonusCapacity = "bonus_capacity"
        case redemptions
        case remaining
        case firstServingSeen = "first_serving_seen"
        case socialBonusEnabled = "social_bonus_enabled"
        case inviteCode = "invite_code"
        case inviteURL = "invite_url"
        case reviewDueAt = "review_due_at"
    }

    /// The coordinator is authoritative for first-serving eligibility. Even if
    /// a malformed mixed-version response includes a URL early, do not expose it.
    var availableInviteURL: URL? {
        guard firstServingSeen,
              [Self.eligible, Self.pending, Self.matured, Self.failed].contains(socialState),
              let inviteCode,
              !inviteCode.isEmpty,
              let inviteURL,
              let components = URLComponents(url: inviteURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.split(separator: "/").last.map(String.init) == inviteCode else {
            return nil
        }
        return inviteURL
    }

    var canStartSocialChallenge: Bool {
        socialBonusEnabled
            && socialState == Self.eligible
            && configuredBonusCapacity > 0
            && availableInviteURL != nil
    }

    var configuredBonusPhrase: String {
        Self.inviteUsePhrase(configuredBonusCapacity)
    }

    var earnedBonusPhrase: String {
        Self.inviteUsePhrase(bonusCapacity)
    }

    static func inviteUsePhrase(_ count: Int) -> String {
        "\(count) invite use\(count == 1 ? "" : "s")"
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

    var isSafeToOpen: Bool {
        guard let intent = URLComponents(url: intentURL, resolvingAgainstBaseURL: false),
              intent.scheme?.lowercased() == "https",
              ["twitter.com", "x.com"].contains(intent.host?.lowercased() ?? ""),
              intent.user == nil,
              intent.password == nil,
              let share = URLComponents(url: shareURL, resolvingAgainstBaseURL: false),
              share.scheme?.lowercased() == "https",
              share.host?.isEmpty == false,
              share.user == nil,
              share.password == nil,
              let challenge,
              Self.isASCIIChallenge(challenge) else {
            return false
        }
        return true
    }

    static func isASCIIChallenge(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
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
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
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
        do {
            return try decoder.decode(response, from: data)
        } catch {
            throw ReferralInviteClientError.invalidResponse
        }
    }
}

struct ReferralInviteCredentials {
    let providerID: String
    let bearerToken: String
    let coordinatorBaseURL: URL
}

struct ReferralInviteDependencies {
    let credentials: () async -> ReferralInviteCredentials?
    let fetchStatus: (URL, String) async throws -> ProviderReferralStatus
    let createChallenge: (URL, String) async throws -> ReferralShareChallenge
    let verifyPost: (URL, String, String, String) async throws -> ProviderReferralStatus
    let loadChallenge: (String) async -> Data?
    let saveChallenge: (String, Data) async throws -> Void
    let deleteChallenge: (String) async throws -> Void
    let openURL: (URL) -> Void
    let copyText: (String) -> Void
    let now: () -> Date

    static var live: ReferralInviteDependencies {
        ReferralInviteDependencies(
            credentials: {
                guard let providerID = ProviderConfig.readProviderID(),
                      let token = await KeychainStore.readProviderToken(providerID: providerID) else {
                    return nil
                }
                let baseURL = ProviderConfig.readCoordinatorBaseURL()
                    ?? URL(string: "https://coordinator.streamvc.live")!
                return ReferralInviteCredentials(
                    providerID: providerID,
                    bearerToken: token,
                    coordinatorBaseURL: baseURL
                )
            },
            fetchStatus: { baseURL, token in
                try await ReferralInviteClient(coordinatorBaseURL: baseURL).fetchStatus(bearerToken: token)
            },
            createChallenge: { baseURL, token in
                try await ReferralInviteClient(coordinatorBaseURL: baseURL).createXChallenge(bearerToken: token)
            },
            verifyPost: { baseURL, postURL, challenge, token in
                try await ReferralInviteClient(coordinatorBaseURL: baseURL).verifyXPost(
                    postURL: postURL,
                    challenge: challenge,
                    bearerToken: token
                )
            },
            loadChallenge: { await KeychainStore.readReferralChallenge(providerID: $0) },
            saveChallenge: { try await KeychainStore.saveReferralChallenge(providerID: $0, data: $1) },
            deleteChallenge: { try await KeychainStore.deleteReferralChallenge(providerID: $0) },
            openURL: { NSWorkspace.shared.open($0) },
            copyText: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString($0, forType: .string)
            },
            now: Date.init
        )
    }
}

@MainActor
final class ReferralInviteController: ObservableObject {
    @Published private(set) var status: ProviderReferralStatus?
    @Published private(set) var isLoading = false
    @Published private(set) var isSharing = false
    @Published private(set) var pendingChallenge: ReferralShareChallenge?
    @Published private(set) var errorMessage: String?
    @Published var postURL = ""

    private let dependencies: ReferralInviteDependencies
    private var refreshGeneration = 0
    private var shareGeneration = 0
    private var restoredProviderID: String?

    init(dependencies: ReferralInviteDependencies = .live) {
        self.dependencies = dependencies
    }

    var isVisible: Bool {
        isLoading || status != nil || errorMessage != nil
    }

    var autoRefreshes: Bool {
        status?.socialState == ProviderReferralStatus.locked
            || status?.socialState == ProviderReferralStatus.pending
    }

    var canCopyInvite: Bool {
        status?.remaining ?? 0 > 0 && status?.availableInviteURL != nil
    }

    var canShareOnX: Bool {
        pendingChallenge == nil && status?.canStartSocialChallenge == true && !isSharing
    }

    var canVerify: Bool {
        guard let challenge = pendingChallenge?.challenge,
              isValidChallenge(challenge),
              let expiresAt = pendingChallenge?.expiresAt,
              expiresAt > dependencies.now() else {
            return false
        }
        return !postURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var pendingExpiryText: String? {
        guard let expiry = pendingChallenge?.expiresAt else { return nil }
        if expiry <= dependencies.now() {
            return "This verification link has expired. Start over to create a new one."
        }
        return "Verification link expires \(expiry.formatted(date: .omitted, time: .shortened))."
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == refreshGeneration { isLoading = false }
        }
        guard let credentials = await dependencies.credentials() else {
            guard generation == refreshGeneration else { return }
            status = nil
            errorMessage = "Provider credentials are unavailable."
            return
        }
        do {
            let next = try await dependencies.fetchStatus(
                credentials.coordinatorBaseURL,
                credentials.bearerToken
            )
            guard generation == refreshGeneration else { return }
            status = next
            await reconcileChallenge(for: next, providerID: credentials.providerID)
        } catch ReferralInviteClientError.httpStatus(404, _) {
            guard generation == refreshGeneration else { return }
            status = nil
            errorMessage = nil
            await clearChallenge(providerID: credentials.providerID)
        } catch {
            guard generation == refreshGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func copyPrivateInvite() {
        guard canCopyInvite, let url = status?.availableInviteURL else { return }
        dependencies.copyText(url.absoluteString)
    }

    func shareOnX() async {
        guard canShareOnX else { return }
        shareGeneration += 1
        let generation = shareGeneration
        isSharing = true
        errorMessage = nil
        defer {
            if generation == shareGeneration { isSharing = false }
        }
        guard let credentials = await dependencies.credentials() else {
            errorMessage = "Provider credentials are unavailable."
            return
        }
        do {
            let challenge = try await dependencies.createChallenge(
                credentials.coordinatorBaseURL,
                credentials.bearerToken
            )
            guard generation == shareGeneration,
                  let cleartext = challenge.challenge,
                  isValidChallenge(cleartext),
                  challenge.isSafeToOpen,
                  challenge.expiresAt > dependencies.now() else {
                if generation == shareGeneration {
                    errorMessage = ReferralInviteClientError.invalidResponse.localizedDescription
                }
                return
            }
            let data = try JSONEncoder().encode(challenge)
            try await dependencies.saveChallenge(credentials.providerID, data)
            guard generation == shareGeneration else { return }
            pendingChallenge = challenge
            restoredProviderID = credentials.providerID
            dependencies.openURL(challenge.intentURL)
        } catch {
            guard generation == shareGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func verifyPost() async {
        guard canVerify,
              let cleartext = pendingChallenge?.challenge,
              let credentials = await dependencies.credentials() else {
            if pendingChallenge != nil {
                errorMessage = "Provider credentials are unavailable."
            }
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let next = try await dependencies.verifyPost(
                credentials.coordinatorBaseURL,
                postURL.trimmingCharacters(in: .whitespacesAndNewlines),
                cleartext,
                credentials.bearerToken
            )
            status = next
            pendingChallenge = nil
            postURL = ""
            try? await dependencies.deleteChallenge(credentials.providerID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reopenPostComposer() {
        guard let challenge = pendingChallenge,
              challenge.isSafeToOpen,
              challenge.expiresAt > dependencies.now() else { return }
        dependencies.openURL(challenge.intentURL)
    }

    func startOver() async {
        shareGeneration += 1
        isSharing = false
        pendingChallenge = nil
        postURL = ""
        if let credentials = await dependencies.credentials() {
            try? await dependencies.deleteChallenge(credentials.providerID)
        }
    }

    private func reconcileChallenge(for status: ProviderReferralStatus, providerID: String) async {
        guard status.canStartSocialChallenge else {
            await clearChallenge(providerID: providerID)
            return
        }
        guard restoredProviderID != providerID else { return }
        restoredProviderID = providerID
        guard let data = await dependencies.loadChallenge(providerID),
              let challenge = try? JSONDecoder().decode(ReferralShareChallenge.self, from: data),
              let cleartext = challenge.challenge,
              isValidChallenge(cleartext) else {
            try? await dependencies.deleteChallenge(providerID)
            return
        }
        pendingChallenge = challenge
    }

    private func clearChallenge(providerID: String) async {
        pendingChallenge = nil
        postURL = ""
        restoredProviderID = providerID
        try? await dependencies.deleteChallenge(providerID)
    }

    private func isValidChallenge(_ value: String) -> Bool {
        ReferralShareChallenge.isASCIIChallenge(value)
    }
}
