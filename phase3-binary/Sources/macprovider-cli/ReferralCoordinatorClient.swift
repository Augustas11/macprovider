import AppKit
import Darwin
import Foundation

public struct ReferralPendingAdvocacy: Codable, Equatable, Sendable {
    public let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case expiresAt = "expires_at"
    }
}

public struct ReferralStatusSnapshot: Codable, Equatable, Sendable {
    public let campaign: String
    public let joinBaseURL: String
    public let socialState: String
    public let baseCapacity: Int
    public let configuredBonusCapacity: Int
    public let bonusCapacity: Int
    public let redemptions: Int
    public let remaining: Int
    public let firstServingSeen: Bool
    public let joinLinksEnabled: Bool
    public let socialBonusEnabled: Bool
    public let socialBonusGrantsRemaining: Int?
    public let inviteCode: String?
    public let inviteURL: String?
    public let observedAt: String
    public let pendingChallenge: ReferralPendingAdvocacy?

    enum CodingKeys: String, CodingKey {
        case campaign
        case joinBaseURL = "join_base_url"
        case socialState = "social_state"
        case baseCapacity = "base_capacity"
        case configuredBonusCapacity = "configured_bonus_capacity"
        case bonusCapacity = "bonus_capacity"
        case redemptions
        case remaining
        case firstServingSeen = "first_serving_seen"
        case joinLinksEnabled = "join_links_enabled"
        case socialBonusEnabled = "social_bonus_enabled"
        case socialBonusGrantsRemaining = "social_bonus_grants_remaining"
        case inviteCode = "invite_code"
        case inviteURL = "invite_url"
        case observedAt = "observed_at"
        case pendingChallenge = "pending_challenge"
    }

    func withPendingChallenge(_ pendingChallenge: ReferralPendingAdvocacy?) -> Self {
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
            pendingChallenge: pendingChallenge
        )
    }
}

public enum ReferralControlOperation: String, Codable, Equatable, Sendable {
    case status
    case challenge
    case verify
    case cancel
}

public enum ReferralControlErrorCode: String, Codable, Equatable, Sendable {
    case authenticationRequired = "authentication_required"
    case featureUnavailable = "feature_unavailable"
    case rateLimited = "rate_limited"
    case temporarilyUnavailable = "temporarily_unavailable"
    case invalidResponse = "invalid_response"
    case invalidPostURL = "invalid_post_url"
    case firstServingRequired = "first_serving_required"
    case challengeUnavailable = "challenge_unavailable"
    case challengeInvalid = "challenge_invalid"
    case postNotVerified = "post_not_verified"
    case referralLocked = "referral_locked"
}

enum ReferralCoordinatorClientError: Error, Equatable {
    case invalidCoordinatorURL
    case control(code: ReferralControlErrorCode, retryAfterSeconds: Int?, terminalVerify: Bool)
}

struct ReferralChallengePayload: Equatable, Sendable {
    let challenge: String
    let inviteURL: String
    let intentURL: String
    let expiresAt: Date
    let expiresAtWire: String
}

struct ReferralCoordinatorClient: Sendable {
    private static let maximumResponseBytes = 32 * 1024
    private static let maximumCount = 1_000_000
    private static let socialStates = Set([
        "locked_until_first_serving", "eligible", "pending", "matured", "failed", "revoked",
    ])

    let providerID: String
    private let bearerToken: String
    private let statusURL: URL
    private let challengeURL: URL
    private let verifyURL: URL
    private let session: URLSession?
    private let now: @Sendable () -> Date

    init(
        coordinatorURL: String?,
        providerID: String,
        bearerToken: String,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty, trimmedProviderID.count <= 256,
              !trimmedProviderID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !trimmedToken.isEmpty,
              let endpoints = Self.endpoints(from: coordinatorURL) else {
            throw ReferralCoordinatorClientError.invalidCoordinatorURL
        }
        self.providerID = trimmedProviderID
        self.bearerToken = trimmedToken
        statusURL = endpoints.status
        challengeURL = endpoints.challenge
        verifyURL = endpoints.verify
        self.session = session
        self.now = now
    }

    static func endpoints(from coordinatorURL: String?) -> (status: URL, challenge: URL, verify: URL)? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        if components.scheme == "wss" { components.scheme = "https" }
        guard components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        components.percentEncodedPath = "/v1/provider/referrals"
        guard let status = components.url else { return nil }
        components.percentEncodedPath = "/v1/provider/referrals/x/challenge"
        guard let challenge = components.url else { return nil }
        components.percentEncodedPath = "/v1/provider/referrals/x/verify"
        guard let verify = components.url else { return nil }
        return (status, challenge, verify)
    }

    func fetchStatus() async throws -> ReferralStatusSnapshot {
        let (object, _) = try await request(operation: .status, method: "GET", url: statusURL, body: nil)
        return try Self.decodeStatus(object, observedAt: now())
    }

    func createChallenge(joinBaseURL: String, inviteCode: String, inviteURL: String) async throws -> ReferralChallengePayload {
        guard let expectedJoinBaseURL = Self.validJoinBaseURL(joinBaseURL) else {
            throw Self.control(.invalidResponse)
        }
        guard Self.isInviteCode(inviteCode),
              Self.isValidInviteURL(
                  inviteURL,
                  code: inviteCode,
                  expectedJoinBaseURL: expectedJoinBaseURL
              ), let expectedInviteURL = URL(string: inviteURL) else {
            throw Self.control(.invalidResponse)
        }
        let (object, _) = try await request(operation: .challenge, method: "POST", url: challengeURL, body: Data("{}".utf8))
        guard let intent = object["intent_url"] as? String,
              let share = object["share_url"] as? String,
              let expiresWire = object["expires_at"] as? String,
              let expiresAt = Self.parseDate(expiresWire),
              expiresAt > now(), expiresAt.timeIntervalSince(now()) <= 86_400,
              Self.isValidXIntentURL(intent, containing: share),
              let challenge = Self.challenge(fromShareURL: share, expectedInviteURL: expectedInviteURL) else {
            throw Self.control(.invalidResponse)
        }
        return ReferralChallengePayload(
            challenge: challenge,
            inviteURL: inviteURL,
            intentURL: intent,
            expiresAt: expiresAt,
            expiresAtWire: Self.formatDate(expiresAt)
        )
    }

    func verify(postURL: String, challenge: String) async throws -> ReferralStatusSnapshot {
        guard Self.isValidXPostURL(postURL) else {
            throw Self.control(.invalidPostURL)
        }
        guard Self.isChallenge(challenge) else {
            throw Self.control(.challengeInvalid, terminalVerify: true)
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "post_url": postURL,
            "challenge": challenge,
        ])
        let (object, _) = try await request(operation: .verify, method: "POST", url: verifyURL, body: body)
        return try Self.decodeStatus(object, observedAt: now())
    }

    private func request(
        operation: ReferralControlOperation,
        method: String,
        url: URL,
        body: Data?
    ) async throws -> ([String: Any], HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            let bytes: URLSession.AsyncBytes
            if let session {
                (bytes, response) = try await session.bytes(for: request)
            } else {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 15
                configuration.timeoutIntervalForResource = 20
                let ephemeral = URLSession(
                    configuration: configuration,
                    delegate: NoRedirectURLSessionDelegate(),
                    delegateQueue: nil
                )
                defer { ephemeral.finishTasksAndInvalidate() }
                (bytes, response) = try await ephemeral.bytes(for: request)
            }
            var bounded = Data()
            bounded.reserveCapacity(min(Self.maximumResponseBytes, 4 * 1024))
            for try await byte in bytes {
                guard bounded.count < Self.maximumResponseBytes else {
                    throw Self.control(.invalidResponse)
                }
                bounded.append(byte)
            }
            data = bounded
        } catch let error as ReferralCoordinatorClientError {
            throw error
        } catch {
            throw Self.control(.temporarilyUnavailable)
        }
        guard let http = response as? HTTPURLResponse,
              http.url == url else {
            throw Self.control(.invalidResponse)
        }
        let retryAfter = Self.retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After"))
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401:
                throw Self.control(.authenticationRequired)
            case 404:
                throw Self.control(.featureUnavailable)
            case 429:
                throw Self.control(.rateLimited, retryAfter: retryAfter)
            case 500...599:
                throw Self.control(.temporarilyUnavailable, retryAfter: retryAfter)
            default:
                let serverCode = Self.serverErrorCode(from: data)
                throw Self.control(
                    Self.sanitizedErrorCode(serverCode, operation: operation),
                    retryAfter: retryAfter,
                    terminalVerify: operation == .verify && [409, 410, 422].contains(http.statusCode)
                )
            }
        }
        guard Self.isJSONContentType(http.value(forHTTPHeaderField: "Content-Type")) else {
            throw Self.control(.invalidResponse)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            throw Self.control(.invalidResponse)
        }
        return (object, http)
    }

    private static func decodeStatus(
        _ object: [String: Any],
        observedAt: Date
    ) throws -> ReferralStatusSnapshot {
        guard let campaign = boundedString("campaign", in: object, maximum: 128),
              let joinBaseURL = boundedString("join_base_url", in: object, maximum: 2048),
              let expectedJoinBaseURL = validJoinBaseURL(joinBaseURL),
              let socialState = boundedString("social_state", in: object, maximum: 64),
              socialStates.contains(socialState),
              let baseCapacity = count("base_capacity", in: object),
              let configuredBonusCapacity = count("configured_bonus_capacity", in: object),
              let bonusCapacity = count("bonus_capacity", in: object),
              let redemptions = count("redemptions", in: object),
              let remaining = count("remaining", in: object),
              let firstServingSeen = object["first_serving_seen"] as? Bool,
              let joinLinksEnabled = object["join_links_enabled"] as? Bool,
              let socialBonusEnabled = object["social_bonus_enabled"] as? Bool,
              remaining == max(0, baseCapacity + bonusCapacity - redemptions) else {
            throw control(.invalidResponse)
        }
        let inviteCode = optionalBoundedString("invite_code", in: object, maximum: 128)
        if object["invite_code"] != nil, inviteCode == nil { throw control(.invalidResponse) }
        let inviteURL = optionalBoundedString("invite_url", in: object, maximum: 2048)
        if object["invite_url"] != nil, inviteURL == nil { throw control(.invalidResponse) }
        if let inviteCode {
            guard isInviteCode(inviteCode) else {
                throw control(.invalidResponse)
            }
            if joinLinksEnabled {
                guard let inviteURL,
                      isValidInviteURL(inviteURL, code: inviteCode, expectedJoinBaseURL: expectedJoinBaseURL) else {
                    throw control(.invalidResponse)
                }
            } else if inviteURL != nil {
                throw control(.invalidResponse)
            }
        } else if inviteURL != nil {
            throw control(.invalidResponse)
        }
        let socialBonusGrantsRemaining: Int?
        if object["social_bonus_grants_remaining"] != nil {
            guard let value = count("social_bonus_grants_remaining", in: object) else {
                throw control(.invalidResponse)
            }
            socialBonusGrantsRemaining = value
        } else {
            socialBonusGrantsRemaining = nil
        }
        return ReferralStatusSnapshot(
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
            observedAt: formatDate(observedAt),
            pendingChallenge: nil
        )
    }

    private static func count(_ field: String, in object: [String: Any]) -> Int? {
        guard let number = object[field] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= 0, double <= Double(maximumCount) else { return nil }
        return Int(double)
    }

    private static func boundedString(_ field: String, in object: [String: Any], maximum: Int) -> String? {
        guard let value = object[field] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximum,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return trimmed
    }

    private static func optionalBoundedString(_ field: String, in object: [String: Any], maximum: Int) -> String? {
        guard object[field] != nil else { return nil }
        return boundedString(field, in: object, maximum: maximum)
    }

    private static func isInviteCode(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-._~".unicodeScalars.contains($0)
        }
    }

    private static func validJoinBaseURL(_ raw: String) -> URL? {
        guard raw.count <= 2048,
              let components = URLComponents(string: raw),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.split(separator: "/").last == "j",
              !raw.hasSuffix("/") else { return nil }
        return components.url
    }

    private static func isValidInviteURL(_ raw: String, code: String, expectedJoinBaseURL: URL) -> Bool {
        guard let inviteURL = URL(string: raw),
              let expected = URL(string: expectedJoinBaseURL.absoluteString + "#/" + code) else { return false }
        return inviteURL == expected
    }

    private static func challenge(fromShareURL raw: String, expectedInviteURL: URL) -> String? {
        guard raw.count <= 2048, let components = URLComponents(string: raw),
              components.scheme == "https",
              components.host?.lowercased() == expectedInviteURL.host?.lowercased(),
              components.port == expectedInviteURL.port,
              components.user == nil, components.password == nil,
              components.path == expectedInviteURL.path,
              components.query == nil,
              components.percentEncodedFragment == components.fragment,
              let expectedFragment = URLComponents(url: expectedInviteURL, resolvingAgainstBaseURL: false)?.fragment,
              let fragment = components.fragment,
              fragment.hasPrefix(expectedFragment + "?c=") else { return nil }
        let challenge = String(fragment.dropFirst(expectedFragment.count + 3))
        guard !challenge.contains("?"), !challenge.contains("&"),
              isChallenge(challenge) else { return nil }
        return challenge
    }

    static func isChallenge(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0))) || ("a"..."f").contains(Character(String($0)))
        }
    }

    private static func isValidXIntentURL(_ raw: String, containing shareURL: String) -> Bool {
        guard raw.count <= 4096, let components = URLComponents(string: raw),
              components.scheme == "https", ["twitter.com", "x.com"].contains(components.host?.lowercased() ?? ""),
              components.port == nil,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path == "/intent/tweet",
              let items = components.queryItems, items.count == 1,
              items[0].name == "text", items[0].value?.contains(shareURL) == true else { return false }
        return true
    }

    static func isValidStoredIntentURL(_ raw: String, challenge: String, inviteURL: String) -> Bool {
        guard isSafeStoredInviteURL(inviteURL) else { return false }
        let shareURL = inviteURL + "?c=" + challenge
        guard raw.count <= 8192,
              let components = URLComponents(string: raw),
              components.scheme == "https", ["twitter.com", "x.com"].contains(components.host?.lowercased() ?? ""),
              components.port == nil,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path == "/intent/tweet",
              let items = components.queryItems, items.count == 1,
              items[0].name == "text", items[0].value?.contains(shareURL) == true else { return false }
        return true
    }

    private static func isSafeStoredInviteURL(_ raw: String) -> Bool {
        guard raw.count <= 2048, let components = URLComponents(string: raw),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil,
              components.percentEncodedFragment == components.fragment,
              let fragment = components.fragment,
              fragment.hasPrefix("/") else { return false }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.last == "j", !fragment.dropFirst().contains("/") else { return false }
        return isInviteCode(String(fragment.dropFirst()))
    }

    static func isValidXPostURL(_ raw: String) -> Bool {
        guard raw.count <= 2048, let components = URLComponents(string: raw),
              components.scheme == "https", components.host?.lowercased() == "x.com", components.port == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[1] == "status", !parts[0].isEmpty else { return false }
        return (1...24).contains(parts[2].count) && parts[2].allSatisfy(\.isNumber)
    }

    private static func serverErrorCode(from data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let code = (raw["error"] as? [String: Any])?["code"] as? String
            ?? raw["error"] as? String
            ?? raw["code"] as? String
        guard let code, code.count <= 64 else { return nil }
        return code
    }

    private static func isJSONContentType(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return raw.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "application/json"
    }

    private static func sanitizedErrorCode(_ serverCode: String?, operation: ReferralControlOperation) -> ReferralControlErrorCode {
        switch serverCode {
        case "rate_limited": return .rateLimited
        case "first_serving_required": return .firstServingRequired
        case "challenge_unavailable": return .challengeUnavailable
        case "challenge_invalid": return .challengeInvalid
        case "invalid_post_url": return .invalidPostURL
        case "post_not_verified": return .postNotVerified
        case "referral_locked": return .referralLocked
        case "social_bonus_disabled": return .featureUnavailable
        default: return operation == .verify ? .temporarilyUnavailable : .invalidResponse
        }
    }

    private static func retryAfterSeconds(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...86_400).contains(value) else { return nil }
        return value
    }

    private static func control(
        _ code: ReferralControlErrorCode,
        retryAfter: Int? = nil,
        terminalVerify: Bool = false
    ) -> ReferralCoordinatorClientError {
        .control(code: code, retryAfterSeconds: retryAfter, terminalVerify: terminalVerify)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct ReferralChallengeRecord: Codable, Equatable {
    static let version = 2
    let version: Int
    let providerID: String
    let challenge: String
    let inviteURL: String
    let intentURL: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case version
        case providerID = "provider_id"
        case challenge
        case inviteURL = "invite_url"
        case intentURL = "intent_url"
        case expiresAt = "expires_at"
    }
}

struct ReferralChallengeStore: Sendable {
    let url: URL

    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider/referrals", isDirectory: true)
            .appendingPathComponent("pending-x-challenge.json")
    }

    func load(providerID: String, now: Date) throws -> ReferralChallengePayload? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try validateRegularOwnerOnlyFile()
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 16 * 1024,
                  let record = try? JSONDecoder().decode(ReferralChallengeRecord.self, from: data),
                  record.version == ReferralChallengeRecord.version,
                  record.providerID == providerID,
                  ReferralCoordinatorClient.isChallenge(record.challenge),
                  ReferralCoordinatorClient.isValidStoredIntentURL(
                      record.intentURL,
                      challenge: record.challenge,
                      inviteURL: record.inviteURL
                  ),
                  let expiresAt = Self.parseDate(record.expiresAt), expiresAt > now else {
                try clear()
                return nil
            }
            return ReferralChallengePayload(
                challenge: record.challenge,
                inviteURL: record.inviteURL,
                intentURL: record.intentURL,
                expiresAt: expiresAt,
                expiresAtWire: record.expiresAt
            )
        } catch let loadError {
            do {
                try clear()
            } catch let clearError {
                throw clearError
            }
            throw loadError
        }
    }

    func save(providerID: String, payload: ReferralChallengePayload) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == geteuid() else { throw CocoaError(.fileWriteNoPermission) }
        guard chmod(parent.path, S_IRWXU) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        let record = ReferralChallengeRecord(
            version: ReferralChallengeRecord.version,
            providerID: providerID,
            challenge: payload.challenge,
            inviteURL: payload.inviteURL,
            intentURL: payload.intentURL,
            expiresAt: payload.expiresAtWire
        )
        let data = try JSONEncoder().encode(record)
        let temporary = parent.appendingPathComponent(".pending-x-challenge.\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                written += count
            }
        }
        guard fsync(fd) == 0, fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func clear() throws {
        if unlink(url.path) != 0, errno != ENOENT { throw CocoaError(.fileWriteUnknown) }
    }

    private func validateRegularOwnerOnlyFile() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o600 else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

actor ReferralCoordinatorService {
    private let client: ReferralCoordinatorClient
    private let store: ReferralChallengeStore
    private let now: @Sendable () -> Date
    private let openIntent: @Sendable (URL) async -> Bool

    init(
        client: ReferralCoordinatorClient,
        store: ReferralChallengeStore,
        now: @escaping @Sendable () -> Date = { Date() },
        openIntent: @escaping @Sendable (URL) async -> Bool = { url in
            await MainActor.run { NSWorkspace.shared.open(url) }
        }
    ) {
        self.client = client
        self.store = store
        self.now = now
        self.openIntent = openIntent
    }

    func status() async throws -> ReferralStatusSnapshot {
        var status = try await client.fetchStatus()
        if !status.socialBonusEnabled {
            try store.clear()
            return status
        }
        // Keep the local challenge only while the coordinator can still accept
        // or reopen an X verification for this provider.
        guard Self.canAttemptSocialChallenge(status) else {
            try store.clear()
            return status
        }
        if let pending = try store.load(providerID: client.providerID, now: now()) {
            guard status.inviteURL == pending.inviteURL else {
                try store.clear()
                return status
            }
            status = status.withPendingChallenge(
                ReferralPendingAdvocacy(expiresAt: pending.expiresAtWire)
            )
        }
        return status
    }

    func challenge() async throws -> ReferralPendingAdvocacy {
        let current = try await client.fetchStatus()
        guard current.socialBonusEnabled else {
            throw ReferralCoordinatorClientError.control(
                code: .featureUnavailable,
                retryAfterSeconds: nil,
                terminalVerify: false
            )
        }
        guard Self.canAttemptSocialChallenge(current),
              let inviteCode = current.inviteCode,
              let inviteURL = current.inviteURL else {
            throw ReferralCoordinatorClientError.control(
                code: .challengeUnavailable,
                retryAfterSeconds: nil,
                terminalVerify: false
            )
        }
        let payload = try await client.createChallenge(
            joinBaseURL: current.joinBaseURL,
            inviteCode: inviteCode,
            inviteURL: inviteURL
        )
        try store.save(providerID: client.providerID, payload: payload)
        guard let intentURL = URL(string: payload.intentURL), await openIntent(intentURL) else {
            throw ReferralCoordinatorClientError.control(
                code: .temporarilyUnavailable,
                retryAfterSeconds: nil,
                terminalVerify: false
            )
        }
        return ReferralPendingAdvocacy(expiresAt: payload.expiresAtWire)
    }

    func reopenChallenge() async throws -> ReferralPendingAdvocacy {
        let current = try await client.fetchStatus()
        guard current.socialBonusEnabled else {
            try store.clear()
            throw ReferralCoordinatorClientError.control(
                code: .featureUnavailable,
                retryAfterSeconds: nil,
                terminalVerify: false
            )
        }
        guard Self.canAttemptSocialChallenge(current),
              let payload = try store.load(providerID: client.providerID, now: now()),
              current.inviteURL == payload.inviteURL,
              let intentURL = URL(string: payload.intentURL),
              await openIntent(intentURL) else {
            try store.clear()
            throw ReferralCoordinatorClientError.control(
                code: .challengeUnavailable,
                retryAfterSeconds: nil,
                terminalVerify: false
            )
        }
        return ReferralPendingAdvocacy(expiresAt: payload.expiresAtWire)
    }

    private static func canAttemptSocialChallenge(_ status: ReferralStatusSnapshot) -> Bool {
        guard ["eligible", "failed", "matured"].contains(status.socialState) else { return false }
        if status.socialState == "matured" {
            return (status.socialBonusGrantsRemaining ?? 0) > 0
        }
        return true
    }

    func verify(postURL: String) async throws -> ReferralStatusSnapshot {
        guard let pending = try store.load(providerID: client.providerID, now: now()) else {
            throw ReferralCoordinatorClientError.control(
                code: .challengeUnavailable,
                retryAfterSeconds: nil,
                terminalVerify: false
            )
        }
        do {
            let status = try await client.verify(postURL: postURL, challenge: pending.challenge)
            try store.clear()
            return status
        } catch let error as ReferralCoordinatorClientError {
            if case .control(_, _, let terminal) = error, terminal { try store.clear() }
            throw error
        }
    }

    func cancel() async throws -> ReferralStatusSnapshot? {
        try store.clear()
        return try? await client.fetchStatus()
    }
}
