import Darwin
import Foundation

// SPEC-049 v0.2 provider side of the code-bound label (SPEC-049-R025,
// SPEC-049-R027, SPEC-049-R030, SPEC-049-R032, SPEC-049-R033). The provider
// never holds an App Attest key. It asks its Malibu.app supervisor, over an
// authenticated local channel, for a keyId, an enrollment attestation, and
// per-posture assertions, and it stays on the Beta label whenever the
// supervisor is absent, unsupported, or failing.

/// The supervisor channel. Production is `PrivacySupervisorSocketClient`;
/// tests inject a double.
protocol PrivacySupervisorChannel: Sendable {
    func exchange(_ request: PrivacySupervisorRequest, timeout: TimeInterval) async throws -> PrivacySupervisorReply
}

enum PrivacySupervisorChannelError: Error, Equatable {
    case unavailable
    case peerRejected
}

/// Connects to the Unix-domain socket Malibu.app created for this child and
/// verifies, by the kernel audit token, that the listening peer is this
/// process's parent and is a valid `tech.malibu.app` signed by the same team
/// as this binary. Only then does it send anything.
final class PrivacySupervisorSocketClient: PrivacySupervisorChannel, @unchecked Sendable {
    private let path: String
    private let teamID: String
    private let queue = DispatchQueue(label: "macprovider.privacy-supervisor-channel")
    /// Guarded by `queue`.
    private var descriptor: Int32 = -1

    init(path: String, teamID: String) {
        self.path = path
        self.teamID = teamID
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    func exchange(_ request: PrivacySupervisorRequest, timeout: TimeInterval) async throws -> PrivacySupervisorReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.exchangeOnQueue(request, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func exchangeOnQueue(_ request: PrivacySupervisorRequest, timeout: TimeInterval) throws -> PrivacySupervisorReply {
        if descriptor < 0 {
            descriptor = try connectAndVerify()
        }
        do {
            try setTimeout(descriptor, seconds: timeout)
            try PrivacySupervisorFrame.write(request.wireObject, to: descriptor)
            return try PrivacySupervisorReply(object: try PrivacySupervisorFrame.read(from: descriptor))
        } catch {
            close(descriptor)
            descriptor = -1
            throw PrivacySupervisorChannelError.unavailable
        }
    }

    private func connectAndVerify() throws -> Int32 {
        guard let requirement = PrivacySupervisorPeer.requirement(
            identifier: PrivacySupervisorConstants.supervisorBundleID,
            teamID: teamID
        ) else {
            throw PrivacySupervisorChannelError.peerRejected
        }
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard path.hasPrefix("/"), pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw PrivacySupervisorChannelError.unavailable
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PrivacySupervisorChannelError.unavailable }
        var keep = false
        defer { if !keep { close(fd) } }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw PrivacySupervisorChannelError.unavailable }
        // SPEC-049-R025: only the supervising Malibu.app may attest for this
        // child. The listening peer must be our parent and pass the team pin.
        guard let token = PrivacySupervisorPeer.auditToken(socket: fd),
              PrivacySupervisorPeer.pid(token) == getppid(),
              let code = PrivacySupervisorPeer.code(for: token),
              PrivacySupervisorPeer.satisfies(code, requirement: requirement) else {
            throw PrivacySupervisorChannelError.peerRejected
        }
        keep = true
        return fd
    }

    private func setTimeout(_ fd: Int32, seconds: TimeInterval) throws {
        let whole = max(1, Int(seconds.rounded(.up)))
        var value = timeval(tv_sec: whole, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size) == 0 else {
            throw PrivacySupervisorChannelError.unavailable
        }
    }
}

/// How the provider advertises `privacy_key_records` right now.
enum PrivacyRecordAdvertisement: Equatable, Sendable {
    case beta
    case codeBound
    /// Omit the field. Used while an enrollment request is outstanding from
    /// the Beta state, when the session may turn enrolled at any moment and
    /// either label could be a violation (SPEC-049-R032).
    case suppressed

    var assurance: String? {
        switch self {
        case .beta: return PrivacyClassConstants.assurance
        case .codeBound: return PrivacyClassConstants.assuranceCodeBound
        case .suppressed: return nil
        }
    }
}

/// Which posture response the provider may send right now.
enum PrivacyPostureMode: Equatable, Sendable {
    case v1
    case v2(appAttestKeyID: String)
    /// Answer nothing. A missed challenge only makes the session ineligible,
    /// which is always safer than a `version: 1` response in the enrolled
    /// state (quarantine reason `assurance_regression`).
    case skip
}

/// The effect of a coordinator enrollment result on the provider.
enum PrivacyEnrollmentEffect: Equatable, Sendable {
    case none
    /// Re-advertise privacy key records under the new label at once.
    case readvertise
}

/// The provider's code-bound state machine. Session state is per assigned
/// session; the retry window and the `rejected` latch live for the process.
final class PrivacyCodeBoundController: @unchecked Sendable {
    /// SPEC-049-R027: retry no sooner than 300 seconds after `unavailable`.
    static let retryInterval: TimeInterval = 300

    private let lock = NSLock()
    private var session: String?
    /// The keyId the coordinator acknowledged `enrolled` in this session.
    private var enrolledKeyID: String?
    /// False after the supervisor reported the enrolled key unusable.
    private var enrolledKeyUsable = true
    /// The keyId of the outstanding enroll request in this session.
    private var pendingKeyID: String?
    private var challengeTaken = false
    private var startInFlight = false
    private var discardKeyID: String?
    private var retryAfter: Date?
    private var rejected = false

    /// Rebinds to the live assigned session. Any change, including a lost
    /// session, resets the in-memory enrolled state (SPEC-049-R033): a new
    /// session starts on the Beta label and re-presents its keyId.
    func bind(session newSession: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard newSession != session else { return }
        session = newSession
        enrolledKeyID = nil
        enrolledKeyUsable = true
        pendingKeyID = nil
        challengeTaken = false
        startInFlight = false
    }

    var advertisement: PrivacyRecordAdvertisement {
        lock.lock()
        defer { lock.unlock() }
        if enrolledKeyID != nil { return .codeBound }
        if pendingKeyID != nil || startInFlight { return .suppressed }
        return .beta
    }

    var postureMode: PrivacyPostureMode {
        lock.lock()
        defer { lock.unlock() }
        if let enrolledKeyID {
            return enrolledKeyUsable && pendingKeyID == nil && !startInFlight ? .v2(appAttestKeyID: enrolledKeyID) : .skip
        }
        return pendingKeyID != nil || startInFlight ? .skip : .v1
    }

    var isRejected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }

    /// Starts an enrollment when one is due: a live session whose privacy
    /// records were accepted (the caller only asks after a posture challenge),
    /// no outstanding request, not rejected in this process, outside the retry
    /// window, and either not enrolled or enrolled with an unusable key.
    /// Returns the keyId to discard (if any) wrapped in `.some`; nil means not due.
    func beginEnrollmentIfDue(now: Date) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        guard session != nil, !rejected, !startInFlight, pendingKeyID == nil else { return nil }
        if let retryAfter, now < retryAfter { return nil }
        if enrolledKeyID != nil && enrolledKeyUsable { return nil }
        startInFlight = true
        return .some(discardKeyID ?? (enrolledKeyUsable ? nil : enrolledKeyID))
    }

    /// The supervisor returned a keyId; the request is about to be sent.
    func enrollmentRequested(appAttestKeyID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard startInFlight else { return }
        startInFlight = false
        pendingKeyID = appAttestKeyID
        challengeTaken = false
        discardKeyID = nil
    }

    /// The supervisor could not supply a keyId or an attestation. The
    /// provider stays (or returns to) Beta and retries later.
    func enrollmentFailedLocally(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        startInFlight = false
        pendingKeyID = nil
        challengeTaken = false
        retryAfter = now.addingTimeInterval(Self.retryInterval)
    }

    /// True once per outstanding request for its own keyId.
    func takeChallenge(appAttestKeyID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pendingKeyID == appAttestKeyID, !challengeTaken else { return false }
        challengeTaken = true
        return true
    }

    /// Applies a `privacy_app_attest_enroll_result` (SPEC-049-R027,
    /// SPEC-049-R033). Results for other keyIds are ignored.
    func apply(result status: String, appAttestKeyID: String, now: Date) -> PrivacyEnrollmentEffect {
        lock.lock()
        defer { lock.unlock() }
        let matchesPending = pendingKeyID == appAttestKeyID
        let matchesEnrolled = enrolledKeyID == appAttestKeyID
        guard matchesPending || matchesEnrolled else { return .none }
        switch status {
        case "enrolled":
            guard matchesPending else { return .none }
            pendingKeyID = nil
            challengeTaken = false
            enrolledKeyID = appAttestKeyID
            enrolledKeyUsable = true
            retryAfter = nil
            return .readvertise
        case "reenroll_required":
            // The coordinator retired this keyId and ended the enrolled state.
            // Discard it, return to Beta, and enroll a new key at once.
            if matchesPending {
                pendingKeyID = nil
                challengeTaken = false
            }
            if matchesEnrolled {
                enrolledKeyID = nil
                enrolledKeyUsable = true
            }
            discardKeyID = appAttestKeyID
            retryAfter = nil
            return .readvertise
        case "unavailable":
            guard matchesPending else { return .none }
            pendingKeyID = nil
            challengeTaken = false
            retryAfter = now.addingTimeInterval(Self.retryInterval)
            return .none
        case "rejected":
            // SPEC-049-R027: never enroll again in this process lifetime.
            guard matchesPending else { return .none }
            pendingKeyID = nil
            challengeTaken = false
            rejected = true
            return .none
        default:
            return .none
        }
    }

    /// The supervisor could not assert for the enrolled key.
    func noteAssertionFailure(_ reason: PrivacySupervisorErrorReason?, keyID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard enrolledKeyID == keyID else { return }
        if reason == .keyInvalid {
            // SPEC-049-R033: the supervisor discarded the key; enroll a new
            // one. The session stays enrolled at the coordinator and skips
            // postures until the new key is acknowledged.
            enrolledKeyUsable = false
            discardKeyID = keyID
        }
    }
}

/// Closed decoders for the two coordinator-to-provider messages of §4.11.
enum PrivacyAppAttestCoordinatorMessage {
    struct Challenge: Equatable, Sendable {
        let appAttestKeyID: String
        let challenge: String
        let issuedAtUnix: Int64
    }

    struct Result: Equatable, Sendable {
        let appAttestKeyID: String
        let status: String
    }

    static let statuses: Set<String> = ["enrolled", "reenroll_required", "unavailable", "rejected"]

    static func challenge(_ object: [String: Any]) throws -> Challenge {
        guard Set(object.keys) == ["type", "version", "app_attest_key_id", "challenge", "issued_at_unix"],
              object["type"] as? String == "privacy_app_attest_enroll_challenge",
              strictInteger(object["version"]) == 1,
              let keyID = object["app_attest_key_id"] as? String,
              let challenge = object["challenge"] as? String,
              let issuedAt = strictInteger(object["issued_at_unix"]),
              (try? RelayBlindBase64URL.decode(keyID, exactCount: 32)) != nil,
              (try? RelayBlindBase64URL.decode(challenge, exactCount: 32)) != nil else {
            throw PrivacyClassError.invalidMaterial
        }
        return Challenge(appAttestKeyID: keyID, challenge: challenge, issuedAtUnix: issuedAt)
    }

    static func result(_ object: [String: Any]) throws -> Result {
        guard Set(object.keys) == ["type", "version", "app_attest_key_id", "status"],
              object["type"] as? String == "privacy_app_attest_enroll_result",
              strictInteger(object["version"]) == 1,
              let keyID = object["app_attest_key_id"] as? String,
              let status = object["status"] as? String,
              statuses.contains(status),
              (try? RelayBlindBase64URL.decode(keyID, exactCount: 32)) != nil else {
            throw PrivacyClassError.invalidMaterial
        }
        return Result(appAttestKeyID: keyID, status: status)
    }

    static func enrollRequest(appAttestKeyID: String) -> [String: Any] {
        ["type": "privacy_app_attest_enroll_request", "version": 1, "app_attest_key_id": appAttestKeyID]
    }

    private static func strictInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e") else { return nil }
        return Int64(text)
    }
}

/// Removes `privacy_key_records` from an outbound message when the records'
/// label no longer matches the current advertisement. Payloads are built
/// before an `await`, so the label can change between build and send; the
/// field is optional and its absence is a no-op at the coordinator.
enum PrivacyRecordSendFilter {
    static func apply(_ message: inout [String: Any], advertisement: PrivacyRecordAdvertisement) {
        guard let records = message["privacy_key_records"] as? [[String: Any]], !records.isEmpty else { return }
        guard let assurance = advertisement.assurance else {
            message.removeValue(forKey: "privacy_key_records")
            return
        }
        let consistent = records.allSatisfy { record in
            (record["privacy_key_attestation"] as? [String: Any])?["assurance"] as? String == assurance
        }
        if !consistent {
            message.removeValue(forKey: "privacy_key_records")
        }
    }
}
