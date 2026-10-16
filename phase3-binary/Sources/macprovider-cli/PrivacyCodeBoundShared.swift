import Darwin
import Foundation

// SPEC-049 §4.13 code-bound evidence and the local attestor channel
// (SPEC-049-R033, SPEC-049-R035). This one file is compiled into both
// macprovider-cli and Malibu.app (phase3-binary/app/project.yml), so both
// sides frame the statement and the channel messages from the same source. It
// must stay free of types that exist in only one of the two targets.

enum PrivacyCodeBoundConstants {
    static let version = "privacy-code-bound-v1"
    static let domain = "macprovider/spec049/code-bound/v1"
    static let privacyClass = "operator_constrained_beta_v1"
    static let runtimeSigningIdentifier = "live.malibu.provider.cli"
    static let evidenceType = "privacy_code_bound_evidence"
    static let requestType = "code_bound_assert_request"
    static let resultType = "code_bound_assert_result"
    static let statusAsserted = "asserted"
    static let statusUnavailable = "unavailable"
    static let channelVersion = 1
    /// CS_VALID | CS_HARD | CS_KILL | CS_RUNTIME.
    static let requiredCSFlags: UInt64 = 0x0001_0301
    /// CS_ADHOC | CS_GET_TASK_ALLOW | CS_INVALID_ALLOWED | CS_DEBUGGED.
    static let forbiddenCSFlags: UInt64 = 0x1000_0026
    static let maxChannelFrameBytes = 16384
    static let maxAssertionBytes = 2048
    static let maxEvidenceBytes = 8192
    static let maxIdentifierBytes = 128
    /// The attestor socket, relative to the user's home directory.
    static let socketRelativePath = "Library/Application Support/Malibu/privacy/attestor.sock"
    static let unavailableReasons: Set<String> = [
        "unsupported", "no_key", "key_invalid", "peer_rejected", "rate_limited", "invalid_request", "assertion_failed",
    ]

    static func socketURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(socketRelativePath)
    }

    static func csFlagsAcceptable(_ flags: UInt64) -> Bool {
        flags <= 0xffff_ffff && flags & requiredCSFlags == requiredCSFlags && flags & forbiddenCSFlags == 0
    }
}

enum PrivacyCodeBoundWireError: Error, Equatable, CustomStringConvertible {
    case invalid

    var description: String { "privacy_code_bound_invalid_message" }
}

// MARK: - Request

/// What the runtime asks the attestor to vouch for: §4.13 fields 1..8 minus
/// the constants. The attestor fills fields 9..14 itself.
struct PrivacyCodeBoundRequest: Equatable, Sendable {
    var providerID: String
    var assignedSession: String
    /// base64url of the 32-byte posture challenge nonce.
    var nonce: String
    /// base64url SHA-256 of the posture framing.
    var postureDigest: String
    /// Standard base64 of the raw 64-byte X || Y Secure Enclave public key.
    var sePublicKey: String
    /// base64url of the raw 32-byte Ed25519 identity public key.
    var identityPublicKey: String

    static let fieldNames: Set<String> = [
        "type", "version", "provider_id", "assigned_session", "nonce", "posture_digest", "se_public_key", "identity_public_key",
    ]

    var wireObject: [String: Any] {
        [
            "type": PrivacyCodeBoundConstants.requestType,
            "version": PrivacyCodeBoundConstants.channelVersion,
            "provider_id": providerID,
            "assigned_session": assignedSession,
            "nonce": nonce,
            "posture_digest": postureDigest,
            "se_public_key": sePublicKey,
            "identity_public_key": identityPublicKey,
        ]
    }

    init(providerID: String, assignedSession: String, nonce: String, postureDigest: String, sePublicKey: String, identityPublicKey: String) {
        self.providerID = providerID
        self.assignedSession = assignedSession
        self.nonce = nonce
        self.postureDigest = postureDigest
        self.sePublicKey = sePublicKey
        self.identityPublicKey = identityPublicKey
    }

    /// Closed decode.
    init(object: [String: Any]) throws {
        let reader = try PrivacyCodeBoundReader(object, keys: Self.fieldNames)
        guard try reader.string("type") == PrivacyCodeBoundConstants.requestType else { throw PrivacyCodeBoundWireError.invalid }
        try reader.requireVersion()
        self.init(
            providerID: try reader.string("provider_id"),
            assignedSession: try reader.string("assigned_session"),
            nonce: try reader.string("nonce"),
            postureDigest: try reader.string("posture_digest"),
            sePublicKey: try reader.string("se_public_key"),
            identityPublicKey: try reader.string("identity_public_key")
        )
        try validate()
    }

    func validate() throws {
        guard cbVisibleASCII(providerID, maxBytes: PrivacyCodeBoundConstants.maxIdentifierBytes),
              cbVisibleASCII(assignedSession, maxBytes: PrivacyCodeBoundConstants.maxIdentifierBytes),
              cbFixed(nonce, count: 32) != nil,
              cbFixed(postureDigest, count: 32) != nil,
              let se = Data(base64Encoded: sePublicKey), se.count == 64, se.base64EncodedString() == sePublicKey,
              cbFixed(identityPublicKey, count: 32) != nil else {
            throw PrivacyCodeBoundWireError.invalid
        }
    }
}

// MARK: - Statement

/// The closed `privacy-code-bound-v1` statement (§4.13).
struct PrivacyCodeBoundStatement: Equatable, Sendable {
    var version: String = PrivacyCodeBoundConstants.version
    var privacyClass: String = PrivacyCodeBoundConstants.privacyClass
    var providerID: String
    var assignedSession: String
    var nonce: String
    var postureDigest: String
    var sePublicKey: String
    var identityPublicKey: String
    var appAttestKeyID: String
    var runtimeTeamID: String
    var runtimeSigningIdentifier: String
    var runtimeCDHash: String
    var runtimeCSFlags: UInt64
    var checkedAtUnix: Int64

    static let fieldNames: Set<String> = [
        "version", "privacy_class", "provider_id", "assigned_session", "nonce", "posture_digest", "se_public_key",
        "identity_public_key", "app_attest_key_id", "runtime_team_id", "runtime_signing_identifier", "runtime_cdhash",
        "runtime_cs_flags", "checked_at_unix",
    ]

    init(
        request: PrivacyCodeBoundRequest,
        appAttestKeyID: String,
        runtimeTeamID: String,
        runtimeSigningIdentifier: String,
        runtimeCDHash: String,
        runtimeCSFlags: UInt64,
        checkedAtUnix: Int64
    ) {
        self.providerID = request.providerID
        self.assignedSession = request.assignedSession
        self.nonce = request.nonce
        self.postureDigest = request.postureDigest
        self.sePublicKey = request.sePublicKey
        self.identityPublicKey = request.identityPublicKey
        self.appAttestKeyID = appAttestKeyID
        self.runtimeTeamID = runtimeTeamID
        self.runtimeSigningIdentifier = runtimeSigningIdentifier
        self.runtimeCDHash = runtimeCDHash
        self.runtimeCSFlags = runtimeCSFlags
        self.checkedAtUnix = checkedAtUnix
    }

    /// Closed decode of exactly the §4.13 fields.
    init(object: [String: Any]) throws {
        let r = try PrivacyCodeBoundReader(object, keys: Self.fieldNames)
        self.version = try r.string("version")
        self.privacyClass = try r.string("privacy_class")
        self.providerID = try r.string("provider_id")
        self.assignedSession = try r.string("assigned_session")
        self.nonce = try r.string("nonce")
        self.postureDigest = try r.string("posture_digest")
        self.sePublicKey = try r.string("se_public_key")
        self.identityPublicKey = try r.string("identity_public_key")
        self.appAttestKeyID = try r.string("app_attest_key_id")
        self.runtimeTeamID = try r.string("runtime_team_id")
        self.runtimeSigningIdentifier = try r.string("runtime_signing_identifier")
        self.runtimeCDHash = try r.string("runtime_cdhash")
        self.runtimeCSFlags = try r.unsigned("runtime_cs_flags")
        self.checkedAtUnix = try r.signed("checked_at_unix")
        try validate()
    }

    var request: PrivacyCodeBoundRequest {
        PrivacyCodeBoundRequest(
            providerID: providerID, assignedSession: assignedSession, nonce: nonce,
            postureDigest: postureDigest, sePublicKey: sePublicKey, identityPublicKey: identityPublicKey
        )
    }

    var wireObject: [String: Any] {
        [
            "version": version,
            "privacy_class": privacyClass,
            "provider_id": providerID,
            "assigned_session": assignedSession,
            "nonce": nonce,
            "posture_digest": postureDigest,
            "se_public_key": sePublicKey,
            "identity_public_key": identityPublicKey,
            "app_attest_key_id": appAttestKeyID,
            "runtime_team_id": runtimeTeamID,
            "runtime_signing_identifier": runtimeSigningIdentifier,
            "runtime_cdhash": runtimeCDHash,
            "runtime_cs_flags": NSNumber(value: runtimeCSFlags),
            "checked_at_unix": NSNumber(value: checkedAtUnix),
        ]
    }

    func validate() throws {
        guard version == PrivacyCodeBoundConstants.version,
              privacyClass == PrivacyCodeBoundConstants.privacyClass,
              cbFixed(appAttestKeyID, count: 32) != nil,
              cbTeamID(runtimeTeamID),
              cbVisibleASCII(runtimeSigningIdentifier, maxBytes: PrivacyCodeBoundConstants.maxIdentifierBytes),
              cbCDHash(runtimeCDHash),
              runtimeCSFlags <= 0xffff_ffff else {
            throw PrivacyCodeBoundWireError.invalid
        }
        try request.validate()
    }

    /// The §4.13 signing framing: the domain, then every field in order;
    /// strings u32-framed, the nonce, posture digest and key id as their raw
    /// 32 bytes, the flags as u64 and the time as i64.
    func framing() throws -> Data {
        try validate()
        guard let nonceBytes = cbFixed(nonce, count: 32),
              let digestBytes = cbFixed(postureDigest, count: 32),
              let keyIDBytes = cbFixed(appAttestKeyID, count: 32) else {
            throw PrivacyCodeBoundWireError.invalid
        }
        var framed = Data()
        for value in [PrivacyCodeBoundConstants.domain, version, privacyClass, providerID, assignedSession] {
            framed.cbAppendFramed(Data(value.utf8))
        }
        framed.cbAppendFramed(nonceBytes)
        framed.cbAppendFramed(digestBytes)
        framed.cbAppendFramed(Data(sePublicKey.utf8))
        framed.cbAppendFramed(Data(identityPublicKey.utf8))
        framed.cbAppendFramed(keyIDBytes)
        for value in [runtimeTeamID, runtimeSigningIdentifier, runtimeCDHash] {
            framed.cbAppendFramed(Data(value.utf8))
        }
        framed.cbAppendUnsigned64(runtimeCSFlags)
        framed.cbAppendUnsigned64(UInt64(bitPattern: checkedAtUnix))
        return framed
    }
}

// MARK: - Reply

enum PrivacyCodeBoundReply: Equatable, Sendable {
    /// `assertion` is canonical base64url of the App Attest assertion object.
    case asserted(statement: PrivacyCodeBoundStatement, assertion: String)
    case unavailable(reason: String)

    var wireObject: [String: Any] {
        switch self {
        case let .asserted(statement, assertion):
            return [
                "type": PrivacyCodeBoundConstants.resultType,
                "version": PrivacyCodeBoundConstants.channelVersion,
                "status": PrivacyCodeBoundConstants.statusAsserted,
                "statement": statement.wireObject,
                "assertion": assertion,
            ]
        case let .unavailable(reason):
            return [
                "type": PrivacyCodeBoundConstants.resultType,
                "version": PrivacyCodeBoundConstants.channelVersion,
                "status": PrivacyCodeBoundConstants.statusUnavailable,
                "reason": reason,
            ]
        }
    }

    /// Closed decode of either reply shape.
    init(object: [String: Any]) throws {
        switch object["status"] as? String {
        case PrivacyCodeBoundConstants.statusAsserted:
            let r = try PrivacyCodeBoundReader(object, keys: ["type", "version", "status", "statement", "assertion"])
            guard try r.string("type") == PrivacyCodeBoundConstants.resultType else { throw PrivacyCodeBoundWireError.invalid }
            try r.requireVersion()
            let statement = try PrivacyCodeBoundStatement(object: try r.object("statement"))
            let assertion = try r.string("assertion")
            guard let decoded = PrivacyCodeBoundBase64URL.decode(assertion),
                  (1...PrivacyCodeBoundConstants.maxAssertionBytes).contains(decoded.count) else {
                throw PrivacyCodeBoundWireError.invalid
            }
            self = .asserted(statement: statement, assertion: assertion)
        case PrivacyCodeBoundConstants.statusUnavailable:
            let r = try PrivacyCodeBoundReader(object, keys: ["type", "version", "status", "reason"])
            guard try r.string("type") == PrivacyCodeBoundConstants.resultType else { throw PrivacyCodeBoundWireError.invalid }
            try r.requireVersion()
            let reason = try r.string("reason")
            guard PrivacyCodeBoundConstants.unavailableReasons.contains(reason) else { throw PrivacyCodeBoundWireError.invalid }
            self = .unavailable(reason: reason)
        default:
            throw PrivacyCodeBoundWireError.invalid
        }
    }
}

/// The §4.13 `privacy_code_bound_evidence` message for an asserted statement.
func privacyCodeBoundEvidenceMessage(statement: PrivacyCodeBoundStatement, assertion: String) -> [String: Any] {
    [
        "type": PrivacyCodeBoundConstants.evidenceType,
        "version": 1,
        "statement": statement.wireObject,
        "assertion": assertion,
    ]
}

// MARK: - Channel framing

/// u32 big-endian body length (1..16384) followed by canonical JSON.
enum PrivacyCodeBoundFrame {
    static let headerBytes = 4

    static func canonicalJSON(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw PrivacyCodeBoundWireError.invalid }
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw PrivacyCodeBoundWireError.invalid
        }
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        let body = try canonicalJSON(object)
        guard (1...PrivacyCodeBoundConstants.maxChannelFrameBytes).contains(body.count) else {
            throw PrivacyCodeBoundWireError.invalid
        }
        var frame = Data()
        frame.cbAppendUnsigned32(UInt32(body.count))
        frame.append(body)
        return frame
    }

    static func bodyLength(header: Data) throws -> Int {
        guard header.count == headerBytes else { throw PrivacyCodeBoundWireError.invalid }
        let bytes = Array(header)
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard (1...PrivacyCodeBoundConstants.maxChannelFrameBytes).contains(length) else {
            throw PrivacyCodeBoundWireError.invalid
        }
        return length
    }

    /// Only canonical JSON is accepted, so one message has one encoding.
    static func decodeBody(_ body: Data) throws -> [String: Any] {
        guard (1...PrivacyCodeBoundConstants.maxChannelFrameBytes).contains(body.count),
              let object = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
              try canonicalJSON(object) == body else {
            throw PrivacyCodeBoundWireError.invalid
        }
        return object
    }

    /// Whole-frame I/O on a stream socket within one monotonic deadline
    /// (SPEC-049-R035 item 4): every read and write first polls for the time
    /// left, so a peer that drips bytes cannot stretch the exchange.
    static func write(_ object: [String: Any], to fd: Int32, deadline: DispatchTime) throws {
        let frame = try encode(object)
        var offset = 0
        try frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw PrivacyCodeBoundWireError.invalid }
            while offset < frame.count {
                try waitUntil(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, base.advanced(by: offset), frame.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw PrivacyCodeBoundWireError.invalid }
                offset += count
            }
        }
    }

    static func read(from fd: Int32, deadline: DispatchTime) throws -> [String: Any] {
        let header = try readExactly(fd, count: headerBytes, deadline: deadline)
        return try decodeBody(try readExactly(fd, count: try bodyLength(header: header), deadline: deadline))
    }

    private static func readExactly(_ fd: Int32, count: Int, deadline: DispatchTime) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw PrivacyCodeBoundWireError.invalid }
            while offset < count {
                try waitUntil(fd, events: Int16(POLLIN), deadline: deadline)
                let read = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if read < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard read > 0 else { throw PrivacyCodeBoundWireError.invalid }
                offset += read
            }
        }
        return data
    }

    /// Polls fd for events until the deadline; throws when it passes.
    private static func waitUntil(_ fd: Int32, events: Int16, deadline: DispatchTime) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw PrivacyCodeBoundWireError.invalid }
            let remaining = Int32(min(Int64(Int32.max), max(1, Int64((deadline.uptimeNanoseconds - now) / 1_000_000))))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, remaining)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw PrivacyCodeBoundWireError.invalid }
            return
        }
    }
}

// MARK: - Encoding helpers

enum PrivacyCodeBoundBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Canonical unpadded base64url only.
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty,
              text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x5f }),
              text.utf8.count % 4 != 1 else {
            return nil
        }
        let remainder = text.utf8.count % 4
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)
        guard let data = Data(base64Encoded: standard), encode(data) == text else { return nil }
        return data
    }

    /// App Attest key ids are standard base64 of 32 bytes; the wire uses base64url.
    static func fromAppAttestKeyID(_ keyID: String) -> String? {
        guard let data = Data(base64Encoded: keyID), data.count == 32, data.base64EncodedString() == keyID else {
            return nil
        }
        return encode(data)
    }
}

private struct PrivacyCodeBoundReader {
    let object: [String: Any]

    init(_ object: [String: Any], keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw PrivacyCodeBoundWireError.invalid }
        self.object = object
    }

    func requireVersion() throws {
        guard try signed("version") == Int64(PrivacyCodeBoundConstants.channelVersion) else {
            throw PrivacyCodeBoundWireError.invalid
        }
    }

    func string(_ key: String) throws -> String {
        guard let value = object[key] as? String else { throw PrivacyCodeBoundWireError.invalid }
        return value
    }

    func object(_ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw PrivacyCodeBoundWireError.invalid }
        return value
    }

    func signed(_ key: String) throws -> Int64 {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw PrivacyCodeBoundWireError.invalid
        }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e"), let value = Int64(text) else {
            throw PrivacyCodeBoundWireError.invalid
        }
        return value
    }

    func unsigned(_ key: String) throws -> UInt64 {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw PrivacyCodeBoundWireError.invalid
        }
        let text = number.stringValue
        guard !text.contains("."), !text.lowercased().contains("e"), let value = UInt64(text) else {
            throw PrivacyCodeBoundWireError.invalid
        }
        return value
    }
}

func cbFixed(_ text: String, count: Int) -> Data? {
    guard let data = PrivacyCodeBoundBase64URL.decode(text), data.count == count else { return nil }
    return data
}

func cbVisibleASCII(_ value: String, maxBytes: Int) -> Bool {
    let bytes = Array(value.utf8)
    return !bytes.isEmpty && bytes.count <= maxBytes && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
}

func cbCDHash(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 40 && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
}

func cbTeamID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 10 && bytes.allSatisfy { ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39) }
}

extension Data {
    mutating func cbAppendUnsigned32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    mutating func cbAppendUnsigned64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(value >> UInt64(shift) & 0xff))
        }
    }

    mutating func cbAppendFramed(_ value: Data) {
        cbAppendUnsigned32(UInt32(value.count))
        append(value)
    }
}
