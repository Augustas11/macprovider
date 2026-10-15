import CryptoKit
import Darwin
import Foundation

// SPEC-049-R035 item 4, provider runtime side: ask Malibu.app's local
// attestor to vouch for each posture, and send its App Attest assertion as
// `privacy_code_bound_evidence` right before the posture. The runtime never
// holds or emulates an App Attest key; any failure sends the posture alone,
// which stays device-bound (SPEC-049-R033).

protocol PrivacyCodeBoundAttesting: Sendable {
    /// A cheap check that an attestor may be listening. When false the
    /// runtime sends its posture at once, exactly as without code-bound.
    var mayBeAvailable: Bool { get }
    /// Nil when the attestor is absent, unreachable, slow, or malformed.
    func assert(_ request: PrivacyCodeBoundRequest) async -> PrivacyCodeBoundReply?
}

/// The Malibu.app attestor over its per-user Unix socket (§4.13).
struct PrivacyCodeBoundSocketAttestor: PrivacyCodeBoundAttesting {
    var socketURL: URL = PrivacyCodeBoundConstants.socketURL()
    /// SPEC-049-R035 item 4: the whole exchange is bounded by 3 seconds.
    var timeout: TimeInterval = 3

    var mayBeAvailable: Bool { Self.ownSocket(socketURL.path) }

    /// The path is a socket owned by this user.
    static func ownSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
    }

    func assert(_ request: PrivacyCodeBoundRequest) async -> PrivacyCodeBoundReply? {
        let url = socketURL
        let timeout = timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.exchange(request, socketURL: url, timeout: timeout))
            }
        }
    }

    static func exchange(_ request: PrivacyCodeBoundRequest, socketURL: URL, timeout: TimeInterval) -> PrivacyCodeBoundReply? {
        let path = socketURL.path
        // Only this user's socket. A missing socket (no Malibu.app) is the
        // common case and costs one lstat.
        guard ownSocket(path) else { return nil }
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let seconds = max(1, Int(timeout.rounded(.up)))
        var interval = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        do {
            try PrivacyCodeBoundFrame.write(request.wireObject, to: fd)
            return try PrivacyCodeBoundReply(object: try PrivacyCodeBoundFrame.read(from: fd))
        } catch {
            return nil
        }
    }
}

enum PrivacyCodeBoundEvidence {
    /// The encoded evidence message for request, or nil. The attestor's
    /// statement must echo every field the runtime asked about, so a confused
    /// or foreign attestor can never attach evidence about another posture.
    static func fetch(request: PrivacyCodeBoundRequest, attestor: any PrivacyCodeBoundAttesting) async -> Data? {
        guard let reply = await attestor.assert(request),
              case let .asserted(statement, assertion) = reply,
              statement.request == request,
              statement.runtimeSigningIdentifier == PrivacyCodeBoundConstants.runtimeSigningIdentifier,
              PrivacyCodeBoundConstants.csFlagsAcceptable(statement.runtimeCSFlags) else {
            return nil
        }
        let message = privacyCodeBoundEvidenceMessage(statement: statement, assertion: assertion)
        guard let encoded = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]),
              encoded.count <= PrivacyCodeBoundConstants.maxEvidenceBytes else {
            return nil
        }
        return encoded
    }
}

/// A posture response and the attestor request that vouches for exactly it.
struct PrivacyPostureReply {
    let response: [String: Any]
    let codeBoundRequest: PrivacyCodeBoundRequest
}

extension PrivacyCodeBoundRequest {
    /// The request for a posture this runtime built and signed.
    init(statement: PrivacyPostureStatement, framing: Data, sePublicKeyRaw: Data, identityPublicKey: String) {
        self.init(
            providerID: statement.providerID,
            assignedSession: statement.assignedSession,
            nonce: statement.nonce,
            postureDigest: PrivacyCodeBoundBase64URL.encode(Data(SHA256.hash(data: framing))),
            sePublicKey: sePublicKeyRaw.base64EncodedString(),
            identityPublicKey: identityPublicKey
        )
    }
}
