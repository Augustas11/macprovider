import AppKit
import Foundation

struct ProviderReferralStatus: Decodable, Equatable {
    let advocacyStatus: String
    let inviteCode: String
    let remaining: Int
    let socialVerified: Bool
    let firstServingSeen: Bool
    let socialBonusEnabled: Bool
    let inviteURL: URL?

    enum CodingKeys: String, CodingKey {
        case advocacyStatus = "advocacy_status"
        case inviteCode = "invite_code"
        case remaining
        case socialVerified = "social_verified"
        case firstServingSeen = "first_serving_seen"
        case socialBonusEnabled = "social_bonus_enabled"
        case inviteURL = "invite_url"
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
    private var restoredProviderID: String?

    var isVisible: Bool {
        !dismissed && (isLoading || status != nil || errorMessage != nil)
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
        guard let credentials = await credentials() else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let challenge = try await credentials.client.createXChallenge(bearerToken: credentials.token)
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

    func reopenXPost() {
        if let intentURL = pendingChallenge?.intentURL {
            NSWorkspace.shared.open(intentURL)
        }
    }

    func startOver() async {
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
