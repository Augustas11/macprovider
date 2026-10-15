import CryptoKit
import Darwin
import DeviceCheck
import Foundation
import Security

// SPEC-049-R035: Malibu.app's local attestor. It asserts, with the App Attest
// key SPEC-033 recorded for the provider, a privacy-code-bound-v1 statement
// for a posture the requesting process built, only after the kernel has
// identified that process as the team-signed, hardened, non-debugged
// provider runtime. It never sees request or response plaintext or any
// private key; everything it reads and writes is public.

/// What the kernel says about the process on the other end of the socket.
struct PrivacyCodeBoundPeer: Equatable, Sendable {
    let teamID: String
    let signingIdentifier: String
    let cdhash: String
    let csFlags: UInt64
}

protocol PrivacyCodeBoundPeerInspecting: Sendable {
    /// The peer of a connected socket when it is valid code signed by
    /// teamID as the provider runtime, otherwise nil.
    func inspect(socket fd: Int32, teamID: String) -> PrivacyCodeBoundPeer?
}

/// Reads the peer from its kernel audit token (SPEC-049-R035 item 3).
struct KernelPrivacyCodeBoundPeerInspector: PrivacyCodeBoundPeerInspecting {
    /// `<sys/un.h>` SOL_LOCAL and LOCAL_PEERTOKEN.
    private static let solLocal: Int32 = 0
    private static let localPeerToken: Int32 = 0x006
    /// `<sys/codesign.h>` CS_OPS_STATUS.
    private static let csOpsStatus: UInt32 = 0
    /// `<Security/SecCode.h>` kSecCSSigningInformation and kSecCSDynamicInformation.
    private static let signingInformation: UInt32 = 1 << 1
    private static let dynamicInformation: UInt32 = 1 << 3

    func inspect(socket fd: Int32, teamID: String) -> PrivacyCodeBoundPeer? {
        guard let token = Self.auditToken(socket: fd),
              let requirementText = Self.requirement(teamID: teamID),
              let code = Self.code(for: token),
              Self.satisfies(code, requirement: requirementText),
              let identity = Self.dynamicIdentity(code),
              let flags = Self.codeSigningFlags(token) else {
            return nil
        }
        return PrivacyCodeBoundPeer(teamID: identity.teamID, signingIdentifier: identity.identifier, cdhash: identity.cdhash, csFlags: UInt64(flags))
    }

    static func auditToken(socket fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, solLocal, localPeerToken, UnsafeMutableRawPointer(pointer), &length)
        }
        guard rc == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }

    static func code(for token: audit_token_t) -> SecCode? {
        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess else { return nil }
        return code
    }

    /// Dynamic validity against the requirement: the running code is valid
    /// now, not only its file.
    static func satisfies(_ code: SecCode, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    static func dynamicIdentity(_ code: SecCode) -> (identifier: String, teamID: String, cdhash: String)? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: signingInformation | dynamicInformation)
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), flags, &information) == errSecSuccess,
              let info = information as NSDictionary?,
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let unique = info[kSecCodeInfoUnique as String] as? Data,
              unique.count == 20 else {
            return nil
        }
        return (identifier, team, unique.map { String(format: "%02x", $0) }.joined())
    }

    /// `csops_audittoken(pid, CS_OPS_STATUS, ...)`, the kernel's current
    /// code-signing flags for exactly this process. Nil when unreadable.
    static func codeSigningFlags(_ token: audit_token_t) -> UInt32? {
        typealias CSOpsAuditToken = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<audit_token_t>?) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops_audittoken") else { return nil }
        let function = unsafeBitCast(symbol, to: CSOpsAuditToken.self)
        var flags: UInt32 = 0
        var mutableToken = token
        let pid = pid_t(bitPattern: token.val.5)
        let rc = withUnsafeMutablePointer(to: &flags) { flagsPointer in
            withUnsafeMutablePointer(to: &mutableToken) { tokenPointer in
                function(pid, csOpsStatus, UnsafeMutableRawPointer(flagsPointer), MemoryLayout<UInt32>.size, tokenPointer)
            }
        }
        return rc == 0 ? flags : nil
    }

    /// The runtime requirement, with the team restricted to its charset so a
    /// value can never change the requirement's grammar.
    static func requirement(teamID: String) -> String? {
        guard cbTeamID(teamID) else { return nil }
        return "anchor apple generic and identifier \"\(PrivacyCodeBoundConstants.runtimeSigningIdentifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// This app's own team, from its validated signature. Nil for an ad-hoc
    /// or unsigned build, which therefore never starts an attestor.
    static func ownTeamID() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let selfCode,
              SecCodeCheckValidity(selfCode, SecCSFlags(), nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(selfCode, to: SecStaticCode.self), SecCSFlags(rawValue: signingInformation), &information) == errSecSuccess,
              let info = information as NSDictionary?,
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              identifier == "tech.malibu.app",
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              cbTeamID(team) else {
            return nil
        }
        return team
    }
}

/// The attestor's decision for one request, free of sockets so it can be
/// tested (SPEC-049-R035 items 1 and 3).
final class PrivacyCodeBoundAttestorCore: @unchecked Sendable {
    /// At most one assertion per this interval.
    static let minimumInterval: TimeInterval = 1

    let teamID: String
    let keyService: any AppAttestKeyService
    let store: AppAttestEnrollmentStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastAssertion: Date?

    init(teamID: String, keyService: any AppAttestKeyService, store: AppAttestEnrollmentStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.teamID = teamID
        self.keyService = keyService
        self.store = store
        self.now = now
    }

    func handle(_ object: [String: Any], peer: PrivacyCodeBoundPeer?) async -> PrivacyCodeBoundReply {
        guard keyService.isSupported else { return .unavailable(reason: "unsupported") }
        guard let request = try? PrivacyCodeBoundRequest(object: object) else {
            return .unavailable(reason: "invalid_request")
        }
        guard let peer,
              peer.teamID == teamID,
              peer.signingIdentifier == PrivacyCodeBoundConstants.runtimeSigningIdentifier,
              cbCDHash(peer.cdhash),
              PrivacyCodeBoundConstants.csFlagsAcceptable(peer.csFlags) else {
            return .unavailable(reason: "peer_rejected")
        }
        guard let keyID = store.keyID(request.providerID),
              let wireKeyID = PrivacyCodeBoundBase64URL.fromAppAttestKeyID(keyID) else {
            return .unavailable(reason: "no_key")
        }
        if store.isKeyInvalid(keyID, for: request.providerID) {
            return .unavailable(reason: "key_invalid")
        }
        let checkedAt = now()
        let admitted: Bool = lock.withLock {
            if let last = lastAssertion, checkedAt.timeIntervalSince(last) < Self.minimumInterval { return false }
            lastAssertion = checkedAt
            return true
        }
        guard admitted else { return .unavailable(reason: "rate_limited") }
        let statement = PrivacyCodeBoundStatement(
            request: request,
            appAttestKeyID: wireKeyID,
            runtimeTeamID: peer.teamID,
            runtimeSigningIdentifier: peer.signingIdentifier,
            runtimeCDHash: peer.cdhash,
            runtimeCSFlags: peer.csFlags,
            checkedAtUnix: Int64(checkedAt.timeIntervalSince1970)
        )
        guard let framing = try? statement.framing() else { return .unavailable(reason: "invalid_request") }
        let clientDataHash = Data(SHA256.hash(data: framing))
        let assertion: Data
        do {
            assertion = try await keyService.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch {
            let ns = error as NSError
            if ns.domain == DCError.errorDomain, ns.code == DCError.Code.invalidKey.rawValue {
                store.markKeyInvalid(keyID, for: request.providerID)
                NSLog("[malibu] privacy_code_bound_attestor key_invalid")
                return .unavailable(reason: "key_invalid")
            }
            return .unavailable(reason: "assertion_failed")
        }
        guard (1...PrivacyCodeBoundConstants.maxAssertionBytes).contains(assertion.count) else {
            return .unavailable(reason: "assertion_failed")
        }
        return .asserted(statement: statement, assertion: PrivacyCodeBoundBase64URL.encode(assertion))
    }
}

/// The attestor's Unix socket (SPEC-049 §4.13): one request per connection,
/// one connection at a time, on its own queue.
final class PrivacyCodeBoundAttestorServer: @unchecked Sendable {
    private let core: PrivacyCodeBoundAttestorCore
    private let inspector: any PrivacyCodeBoundPeerInspecting
    private let socketURL: URL
    private let queue = DispatchQueue(label: "tech.malibu.privacy-code-bound-attestor")
    private let lock = NSLock()
    private var listenFD: Int32 = -1

    init(core: PrivacyCodeBoundAttestorCore, inspector: any PrivacyCodeBoundPeerInspecting = KernelPrivacyCodeBoundPeerInspector(), socketURL: URL = PrivacyCodeBoundConstants.socketURL()) {
        self.core = core
        self.inspector = inspector
        self.socketURL = socketURL
    }

    /// The live attestor, or nil where App Attest or a team signature is
    /// missing (macOS before 27, local and ad-hoc builds).
    static func live(store: AppAttestEnrollmentStore = AppAttestEnrollmentStore(defaults: .standard)) -> PrivacyCodeBoundAttestorServer? {
        let keyService = DeviceCheckAppAttestKeyService()
        guard keyService.isSupported, let teamID = KernelPrivacyCodeBoundPeerInspector.ownTeamID() else { return nil }
        return PrivacyCodeBoundAttestorServer(core: PrivacyCodeBoundAttestorCore(teamID: teamID, keyService: keyService, store: store))
    }

    var isListening: Bool { lock.withLock { listenFD >= 0 } }

    func start() throws {
        try lock.withLock {
            guard listenFD < 0 else { return }
            try Self.prepareDirectory(socketURL.deletingLastPathComponent())
            listenFD = try Self.bindListener(at: socketURL)
        }
        let fd = lock.withLock { listenFD }
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        let fd: Int32 = lock.withLock {
            defer { listenFD = -1 }
            return listenFD
        }
        guard fd >= 0 else { return }
        // shutdown wakes the accept loop; close alone does not on Darwin.
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(socketURL.path)
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED, isListening { continue }
                return
            }
            serve(fd)
            close(fd)
        }
    }

    private func serve(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let object = try? PrivacyCodeBoundFrame.read(from: fd) else { return }
        // The peer is read from the kernel after the request arrived, never
        // from the message.
        let peer = inspector.inspect(socket: fd, teamID: core.teamID)
        let reply = Self.wait { [core] in await core.handle(object, peer: peer) }
        try? PrivacyCodeBoundFrame.write(reply.wireObject, to: fd)
    }

    /// Bridges the async core to this dedicated, non-cooperative queue.
    private static func wait(_ operation: @escaping @Sendable () async -> PrivacyCodeBoundReply) -> PrivacyCodeBoundReply {
        let box = ReplyBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        return box.value ?? .unavailable(reason: "assertion_failed")
    }

    /// A 0700 directory owned by this user.
    static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else {
            throw PrivacyCodeBoundWireError.invalid
        }
    }

    /// A 0600 listening socket. A stale socket from an earlier launch is
    /// removed only when it is this user's socket.
    static func bindListener(at url: URL) throws -> Int32 {
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, existing.st_uid == getuid() else {
                throw PrivacyCodeBoundWireError.invalid
            }
            unlink(url.path)
        }
        var address = sockaddr_un()
        let pathBytes = Array(url.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw PrivacyCodeBoundWireError.invalid }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PrivacyCodeBoundWireError.invalid }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
        }
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd)
            unlink(url.path)
            throw PrivacyCodeBoundWireError.invalid
        }
        return fd
    }
}

private final class ReplyBox: @unchecked Sendable {
    var value: PrivacyCodeBoundReply?
}
