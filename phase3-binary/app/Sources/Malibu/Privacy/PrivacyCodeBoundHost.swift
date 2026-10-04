import DeviceCheck
import Darwin
import Foundation
import Security

// SPEC-049 v0.2 host wiring: the real App Attest service, the keyId file, the
// supervisor's own bundle identity, the authenticated Unix-domain socket, and
// the supervised `macprovider-cli` child. Everything here is default off
// (`privacyCodeBound`, SPEC-049-R034).

enum PrivacyCodeBoundSetting {
    static let defaultsKey = "privacyCodeBound"

    /// SPEC-049-R034: false unless the operator turned it on.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }
}

/// `DCAppAttestService` on macOS 27 or later.
struct DeviceCheckAppAttestProvider: AppAttestProviding {
    static let minimumMajorVersion = 27

    var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: Self.minimumMajorVersion, minorVersion: 0, patchVersion: 0)
        ) && DCAppAttestService.shared.isSupported
    }

    func generateKey() async throws -> String {
        guard isSupported else { throw AppAttestProviderError.unsupported }
        do {
            return try await DCAppAttestService.shared.generateKey()
        } catch {
            throw Self.map(error)
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard isSupported else { throw AppAttestProviderError.unsupported }
        do {
            return try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        } catch {
            throw Self.map(error)
        }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard isSupported else { throw AppAttestProviderError.unsupported }
        do {
            return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: Error) -> AppAttestProviderError {
        let ns = error as NSError
        guard ns.domain == DCError.errorDomain else { return .failed }
        switch DCError.Code(rawValue: ns.code) {
        case .invalidKey: return .invalidKey
        case .featureUnsupported: return .unsupported
        default: return .failed
        }
    }
}

/// The keyId in a 0600 file under the app's 0700 support directory.
struct PrivacyAppAttestKeyIDFile: PrivacyAppAttestKeyIDStoring {
    let url: URL

    static func `default`(paths: ProviderPaths = .current) -> PrivacyAppAttestKeyIDFile {
        PrivacyAppAttestKeyIDFile(url: paths.appSupport
            .appendingPathComponent("privacy", isDirectory: true)
            .appendingPathComponent("app-attest-key-id"))
    }

    func load() -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              (1...128).contains(info.st_size) else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        guard read(fd, &buffer, buffer.count) == buffer.count,
              let text = String(bytes: buffer, encoding: .utf8),
              PrivacySupervisorBase64URL.fromAppAttestKeyID(text) != nil else {
            return nil
        }
        return text
    }

    func save(_ keyID: String) throws {
        guard PrivacySupervisorBase64URL.fromAppAttestKeyID(keyID) != nil else { throw AppAttestProviderError.failed }
        try PrivacyCodeBoundHost.prepareDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".app-attest-key-id.\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AppAttestProviderError.failed }
        let bytes = Array(keyID.utf8)
        let written = write(fd, bytes, bytes.count)
        let synced = fsync(fd) == 0
        close(fd)
        guard written == bytes.count, synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw AppAttestProviderError.failed
        }
    }

    func delete() {
        unlink(url.path)
    }
}

enum PrivacyCodeBoundHostError: Error, Equatable {
    case unsupported
    case latched
    case identityUnavailable
    case socketUnavailable
    case spawnFailed
}

/// Owns the supervisor socket and the supervised child for one launch.
final class PrivacyCodeBoundHost: @unchecked Sendable {
    static let socketName = "ps.sock"

    let supervisor: PrivacyCodeBoundSupervisor
    private let socketURL: URL
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "tech.malibu.privacy-supervisor")
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var listenerClosed = false

    /// The supervised child's PID while it runs.
    var childPID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true ? process?.processIdentifier : nil
    }

    /// SPEC-049-R025: macOS 27 or later with App Attest supported.
    static func platformSupported(_ provider: any AppAttestProviding = DeviceCheckAppAttestProvider()) -> Bool {
        provider.isSupported
    }

    /// Validates this bundle, binds the socket, and spawns the child. Throws
    /// before spawning anything when any precondition fails, so the caller
    /// can fall back to the Beta-only launchd provider.
    static func start(
        configPath: URL,
        logFileURL: URL,
        paths: ProviderPaths = .current,
        bundleURL: URL = Bundle.main.bundleURL,
        onChildExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> PrivacyCodeBoundHost {
        guard PrivacyCodeBoundLatch.latchedReason == nil else { throw PrivacyCodeBoundHostError.latched }
        let provider = DeviceCheckAppAttestProvider()
        guard provider.isSupported else { throw PrivacyCodeBoundHostError.unsupported }
        let childURL = bundleURL.appendingPathComponent("Contents/MacOS/macprovider-cli")
        guard let identity = readSupervisorIdentity(bundleURL: bundleURL, childURL: childURL) else {
            throw PrivacyCodeBoundHostError.identityUnavailable
        }
        let directory = paths.appSupport.appendingPathComponent("privacy", isDirectory: true)
        try prepareDirectory(directory)
        let socketURL = directory.appendingPathComponent(socketName)
        let fd = try bindListener(at: socketURL)
        let host = PrivacyCodeBoundHost(
            identity: identity,
            appAttest: provider,
            keyStore: PrivacyAppAttestKeyIDFile.default(paths: paths),
            socketURL: socketURL,
            listenFD: fd
        )
        do {
            try await host.spawn(executable: childURL, configPath: configPath, logFileURL: logFileURL, onChildExit: onChildExit)
        } catch {
            host.stopListening()
            throw error
        }
        host.acceptLoop()
        return host
    }

    private init(
        identity: PrivacySupervisorIdentity,
        appAttest: any AppAttestProviding,
        keyStore: any PrivacyAppAttestKeyIDStoring,
        socketURL: URL,
        listenFD: Int32
    ) {
        self.socketURL = socketURL
        self.listenFD = listenFD
        let terminate = TerminateBox()
        self.supervisor = PrivacyCodeBoundSupervisor(
            identity: identity,
            appAttest: appAttest,
            keyStore: keyStore,
            terminateChild: { terminate.fire() }
        )
        terminate.action = { [weak self] in self?.terminateChild() }
    }

    func stop() async {
        let running: Process? = lock.withLock {
            stopped = true
            return process
        }
        stopListening()
        guard let running, running.isRunning else { return }
        running.terminate()
        let deadline = Date().addingTimeInterval(5)
        while running.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if running.isRunning { kill(running.processIdentifier, SIGKILL) }
    }

    // MARK: Child

    private func spawn(
        executable: URL,
        configPath: URL,
        logFileURL: URL,
        onChildExit: @escaping @Sendable (Int32) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logFileURL)
        try log.seekToEnd()
        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "serve",
            "--config", configPath.path,
            "--privacy-code-bound",
            "--privacy-supervisor-socket", socketURL.path,
        ]
        child.environment = try ProcessEnvironmentSanitizer.sanitized()
        child.standardOutput = log
        child.standardError = log
        let supervisor = self.supervisor
        child.terminationHandler = { [weak self] terminated in
            try? log.close()
            Task { await supervisor.childExited() }
            guard let self else { return }
            self.lock.lock()
            let intentional = self.stopped
            self.lock.unlock()
            if !intentional { onChildExit(terminated.terminationStatus) }
        }
        do {
            try child.run()
        } catch {
            throw PrivacyCodeBoundHostError.spawnFailed
        }
        // SPEC-049-R026 step 2: remember the exact process (PID and PID
        // version) so a later peer can be matched to it.
        guard let token = PrivacySupervisorPeer.auditToken(pid: child.processIdentifier) else {
            child.terminate()
            throw PrivacyCodeBoundHostError.spawnFailed
        }
        lock.withLock { process = child }
        await supervisor.childSpawned(pid: child.processIdentifier, pidVersion: PrivacySupervisorPeer.pidVersion(token))
    }

    private func terminateChild() {
        lock.lock()
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        let pid = running.processIdentifier
        running.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if running.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: Socket

    private func acceptLoop() {
        queue.async { [weak self] in
            while let self {
                let fd = accept(self.listenFD, nil, nil)
                if fd < 0 {
                    let done = self.lock.withLock { self.stopped || self.listenerClosed }
                    if !done && (errno == EINTR || errno == ECONNABORTED) { continue }
                    return
                }
                self.serve(connection: fd)
                close(fd)
                self.lock.lock()
                let done = self.stopped
                self.lock.unlock()
                if done { return }
            }
        }
    }

    /// One connection at a time. A peer that is not the spawned child is
    /// dropped without a reply; a malformed frame closes the connection.
    private func serve(connection fd: Int32) {
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let token = PrivacySupervisorPeer.auditToken(socket: fd) else { return }
        let peer = PrivacyChildPeer(
            pid: PrivacySupervisorPeer.pid(token),
            pidVersion: PrivacySupervisorPeer.pidVersion(token),
            token: token
        )
        let supervisor = self.supervisor
        guard Self.wait({ await supervisor.isSpawnedChild(peer) }) else { return }
        while true {
            let request: PrivacySupervisorRequest
            do {
                request = try PrivacySupervisorRequest(object: try PrivacySupervisorFrame.read(from: fd))
            } catch {
                return
            }
            // The peer is re-read from the kernel on every request; the
            // connection-time token is not trusted for later requests.
            guard let current = PrivacySupervisorPeer.auditToken(socket: fd) else { return }
            let currentPeer = PrivacyChildPeer(
                pid: PrivacySupervisorPeer.pid(current),
                pidVersion: PrivacySupervisorPeer.pidVersion(current),
                token: current
            )
            let reply = Self.wait { await supervisor.handle(request, peer: currentPeer) }
            do {
                try PrivacySupervisorFrame.write(reply.wireObject, to: fd)
            } catch {
                return
            }
            if case .error(.childCheckFailed) = reply { return }
        }
    }

    private func stopListening() {
        let first: Bool = lock.withLock {
            defer { listenerClosed = true }
            return !listenerClosed
        }
        guard first else { return }
        // shutdown wakes the accept loop; close alone does not on Darwin.
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(socketURL.path)
    }

    /// Bridges the actor to this dedicated, non-cooperative queue.
    private static func wait<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else {
            throw PrivacyCodeBoundHostError.socketUnavailable
        }
    }

    /// A 0600 listening socket in the 0700 directory. A stale socket from an
    /// earlier launch is removed only when it is our own socket file.
    static func bindListener(at url: URL) throws -> Int32 {
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, existing.st_uid == getuid() else {
                throw PrivacyCodeBoundHostError.socketUnavailable
            }
            unlink(url.path)
        }
        var address = sockaddr_un()
        let pathBytes = Array(url.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw PrivacyCodeBoundHostError.socketUnavailable
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PrivacyCodeBoundHostError.socketUnavailable }
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
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 1) == 0 else {
            close(fd)
            unlink(url.path)
            throw PrivacyCodeBoundHostError.socketUnavailable
        }
        return fd
    }

    // MARK: Identity

    /// Reads the supervisor's team and bundle version from its own validated
    /// signature, and the approved child cdhash from the `macprovider-cli`
    /// sealed in this bundle (SPEC-049-R026 step 3).
    static func readSupervisorIdentity(bundleURL: URL, childURL: URL) -> PrivacySupervisorIdentity? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let selfCode,
              let team = signingTeam(of: unsafeBitCast(selfCode, to: SecStaticCode.self)),
              let appRequirement = PrivacySupervisorPeer.requirement(
                  identifier: PrivacySupervisorConstants.supervisorBundleID,
                  teamID: team
              ),
              PrivacySupervisorPeer.satisfies(selfCode, requirement: appRequirement) else {
            return nil
        }
        // The whole bundle, including the sealed child executable, must verify.
        var bundleCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &bundleCode) == errSecSuccess,
              let bundleCode,
              SecStaticCodeCheckValidity(bundleCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return nil
        }
        var childCode: SecStaticCode?
        var childRequirement: SecRequirement?
        guard let childRequirementText = PrivacySupervisorPeer.requirement(
                  identifier: PrivacySupervisorConstants.childSigningIdentifier,
                  teamID: team
              ),
              SecRequirementCreateWithString(childRequirementText as CFString, SecCSFlags(), &childRequirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(childURL as CFURL, SecCSFlags(), &childCode) == errSecSuccess,
              let childCode,
              SecStaticCodeCheckValidity(childCode, SecCSFlags(rawValue: kSecCSStrictValidate), childRequirement) == errSecSuccess,
              let cdhash = cdhash(of: childCode),
              let version = Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              (1...PrivacySupervisorConstants.maxSupervisorBundleVersionBytes).contains(version.utf8.count),
              version.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            return nil
        }
        return PrivacySupervisorIdentity(teamID: team, bundleVersion: version, approvedChildCDHash: cdhash)
    }

    private static func signingTeam(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as NSDictionary?,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            return nil
        }
        return team
    }

    private static func cdhash(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as NSDictionary?,
              let unique = info[kSecCodeInfoUnique as String] as? Data,
              unique.count == 20 else {
            return nil
        }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}

private final class TerminateBox: @unchecked Sendable {
    var action: (() -> Void)?
    func fire() { action?() }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
