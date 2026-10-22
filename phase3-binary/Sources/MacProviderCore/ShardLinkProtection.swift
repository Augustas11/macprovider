import CryptoKit
import Foundation

// Issue #2084 SPEC-051-R011 frame authentication. On an `hmac-sha256` link the two
// members run an authenticated key agreement right after the TCP connect: each
// sends a fresh X25519 key, then signs the transcript (group epoch, its role, both
// ephemeral keys, its member id) with its SPEC-015 receipt key. Both derive one
// HMAC-SHA256 key per direction with HKDF over the X25519 secret, salted with the
// transcript. Every later frame carries a 32-byte tag over all its bytes (header,
// payload and CRC32C). Keys live only in the two link objects: they are never
// serialized, logged, sent to the coordinator, or reused on another link or epoch.

/// SPEC-051-R011 frame protection a link runs.
public enum ShardLinkFrameProtection: String, Equatable, Sendable {
    case crc32c
    case hmacSHA256 = "hmac-sha256"
}

/// The authenticated member at the other end of a protected link.
public struct ShardLinkPeer: Equatable, Sendable {
    public let memberDeviceID: String
    /// Raw Ed25519 receipt key (base64) that signed the key agreement.
    public let publicKey: String

    public init(memberDeviceID: String, publicKey: String) {
        self.memberDeviceID = memberDeviceID
        self.publicKey = publicKey
    }
}

/// The 32-byte HMAC-SHA256 tag after the CRC32C of a protected frame.
public struct ShardFrameAuthenticator: Sendable {
    public static let tagSize = 32
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// The encoded frame followed by its tag.
    public func seal(_ encoded: Data) -> Data {
        var sealed = encoded
        sealed.append(contentsOf: HMAC<SHA256>.authenticationCode(for: encoded, using: key))
        return sealed
    }

    /// The encoded frame of a sealed one whose tag verifies (constant time).
    public func open(_ sealed: Data) throws -> Data {
        guard sealed.count > Self.tagSize else {
            throw ShardFrameError.truncated(needed: Self.tagSize + 1, available: sealed.count)
        }
        let body = sealed.prefix(sealed.count - Self.tagSize)
        let tag = sealed.suffix(Self.tagSize)
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: body, using: key) else {
            throw ShardFrameError.authenticationFailed
        }
        return Data(body)
    }
}

/// Receiver side of a protected link direction: tag, then strict decode, then the
/// epoch and sequence check. A replayed frame keeps a valid tag but repeats a
/// sequence number, so it fails like any other replay (SPEC-051-R012).
public struct ShardProtectedReceiver: Sendable {
    public let authenticator: ShardFrameAuthenticator
    public private(set) var state: ShardLinkReceiveState
    public let limits: ShardFrameLimits

    public init(authenticator: ShardFrameAuthenticator, state: ShardLinkReceiveState, limits: ShardFrameLimits = ShardFrameLimits()) {
        self.authenticator = authenticator
        self.state = state
        self.limits = limits
    }

    public mutating func accept(_ sealed: Data) throws -> ShardStageFrame {
        let frame = try ShardStageFrameCodec.decode(try authenticator.open(sealed), limits: limits)
        try state.accept(frame.header)
        return frame
    }
}

/// The key agreement messages and derivation. Pure, so the protocol is tested
/// without sockets; `ShardStageLink.authenticate` runs it on a link.
public enum ShardLinkHandshake {
    public static let authDomain = "macprovider.shard-link-auth.v1\n"
    static let kdfLabel = "macprovider.shard-link.v1"

    public enum Role: UInt8, Sendable {
        /// The side that dialed the TCP connection.
        case initiator = 0
        case responder = 1
    }

    /// First message: this side's ephemeral X25519 key.
    public struct Share: Codable, Equatable, Sendable {
        public let op: String
        public let ephemeral: String

        public init(ephemeral: Curve25519.KeyAgreement.PublicKey) {
            self.op = "share"
            self.ephemeral = ephemeral.rawRepresentation.base64EncodedString()
        }
    }

    /// Second message: this side's identity and its signature over the transcript.
    public struct Auth: Codable, Equatable, Sendable {
        public let op: String
        public let memberDeviceID: String
        public let publicKey: String
        public let signature: String

        enum CodingKeys: String, CodingKey {
            case op
            case memberDeviceID = "member_device_id"
            case publicKey = "public_key"
            case signature
        }

        public init(memberDeviceID: String, publicKey: String, signature: String) {
            self.op = "auth"
            self.memberDeviceID = memberDeviceID
            self.publicKey = publicKey
            self.signature = signature
        }
    }

    public struct Keys: Sendable {
        public let send: SymmetricKey
        public let receive: SymmetricKey
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case malformed(String)
        case signatureInvalid(memberDeviceID: String)
        case reflected

        public var description: String {
            switch self {
            case .malformed(let detail): return "malformed link key agreement: \(detail)"
            case .signatureInvalid(let member): return "link key agreement signature of \(member) does not verify"
            case .reflected: return "the peer echoed this side's own ephemeral key"
            }
        }
    }

    /// Bytes a side signs: domain, epoch, its role, the initiator's and the
    /// responder's ephemeral keys, its member id. Covering both ephemeral keys binds
    /// the signature to this one exchange; covering the role stops reflection.
    public static func signedBytes(
        epoch: UInt64, role: Role, initiatorEphemeral: Data, responderEphemeral: Data, memberDeviceID: String
    ) -> Data {
        var bytes = Data(authDomain.utf8)
        withUnsafeBytes(of: epoch.littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(role.rawValue)
        bytes.append(initiatorEphemeral)
        bytes.append(responderEphemeral)
        bytes.append(contentsOf: memberDeviceID.utf8)
        return bytes
    }

    public static func auth(
        signer: ShardMemberSigner, epoch: UInt64, role: Role, initiatorEphemeral: Data, responderEphemeral: Data
    ) throws -> Auth {
        let message = signedBytes(
            epoch: epoch, role: role, initiatorEphemeral: initiatorEphemeral, responderEphemeral: responderEphemeral,
            memberDeviceID: signer.memberDeviceID)
        return Auth(
            memberDeviceID: signer.memberDeviceID, publicKey: signer.publicKeyBase64,
            signature: try signer.key.signature(for: message).base64EncodedString())
    }

    /// Check the peer's share and auth and derive this side's directional keys.
    public static func complete(
        ephemeral: Curve25519.KeyAgreement.PrivateKey,
        role: Role,
        epoch: UInt64,
        ownPublicKey: String,
        peerShare: Share,
        peerAuth: Auth
    ) throws -> (keys: Keys, peer: ShardLinkPeer) {
        guard peerShare.op == "share", peerAuth.op == "auth" else { throw Failure.malformed("unexpected message order") }
        guard let peerEphemeralRaw = Data(base64Encoded: peerShare.ephemeral),
              let peerEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeralRaw)
        else { throw Failure.malformed("ephemeral key") }
        let ownEphemeral = ephemeral.publicKey.rawRepresentation
        guard peerEphemeralRaw != ownEphemeral else { throw Failure.reflected }
        guard let peerKeyRaw = Data(base64Encoded: peerAuth.publicKey),
              let peerKey = try? Curve25519.Signing.PublicKey(rawRepresentation: peerKeyRaw),
              let signature = Data(base64Encoded: peerAuth.signature), signature.count == 64,
              ShardMemberSigner.isCanonicalString(peerAuth.memberDeviceID)
        else { throw Failure.malformed("identity") }
        let peerRole: Role = role == .initiator ? .responder : .initiator
        let initiatorEphemeral = role == .initiator ? ownEphemeral : peerEphemeralRaw
        let responderEphemeral = role == .initiator ? peerEphemeralRaw : ownEphemeral
        let peerMessage = signedBytes(
            epoch: epoch, role: peerRole, initiatorEphemeral: initiatorEphemeral, responderEphemeral: responderEphemeral,
            memberDeviceID: peerAuth.memberDeviceID)
        guard peerKey.isValidSignature(signature, for: peerMessage) else {
            throw Failure.signatureInvalid(memberDeviceID: peerAuth.memberDeviceID)
        }
        let secret: SharedSecret
        do {
            secret = try ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)
        } catch {
            throw Failure.malformed("key agreement: \(error)")
        }
        let initiatorKey = role == .initiator ? ownPublicKey : peerAuth.publicKey
        let responderKey = role == .initiator ? peerAuth.publicKey : ownPublicKey
        var salt = Data(kdfLabel.utf8)
        withUnsafeBytes(of: epoch.littleEndian) { salt.append(contentsOf: $0) }
        salt.append(initiatorEphemeral)
        salt.append(responderEphemeral)
        salt.append(contentsOf: initiatorKey.utf8)
        salt.append(contentsOf: responderKey.utf8)
        let transcript = Data(SHA256.hash(data: salt))
        func derive(_ direction: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: transcript, sharedInfo: Data("\(kdfLabel) \(direction)".utf8), outputByteCount: 32)
        }
        let initiatorToResponder = derive("initiator->responder")
        let responderToInitiator = derive("responder->initiator")
        let keys = role == .initiator
            ? Keys(send: initiatorToResponder, receive: responderToInitiator)
            : Keys(send: responderToInitiator, receive: initiatorToResponder)
        return (keys, ShardLinkPeer(memberDeviceID: peerAuth.memberDeviceID, publicKey: peerAuth.publicKey))
    }
}
