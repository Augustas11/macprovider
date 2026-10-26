import AppKit
import Darwin
import Security

/// Process identities are captured at launch. Reading a peer's bundle after
/// the updater replaces it would give every old process the new version.
@MainActor
final class AppInstanceHandoff {
    struct Identity: Codable, Hashable {
        let pid: Int32
        let launchedAt: Date
        let version: String?
    }

    static func winner(in peers: [Identity]) -> Identity? {
        peers.max { lhs, rhs in
            switch (lhs.version, rhs.version) {
            case let (left?, right?):
                let order = ProviderCLIVersion.compare(left, right)
                if order != .same { return order == .ascending }
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil): break
            }
            if lhs.launchedAt != rhs.launchedAt { return lhs.launchedAt < rhs.launchedAt }
            return lhs.pid < rhs.pid
        }
    }

    /// A missing record is legacy only when the process predates us. A
    /// successor may be slow before publishing its identity; elapsed time
    /// alone is never permission for its predecessor to terminate it.
    static func discoveredIdentity(
        pid: Int32, launchedAt: Date, record: Identity?, recordReady: Bool = true, own: Identity, now: Date
    ) -> Identity? {
        if let record, record.pid == pid, record.launchedAt == launchedAt,
           let version = record.version, ProviderCLIVersion.strictNormalize(version) != nil {
            return recordReady ? record : nil
        }
        guard launchedAt < own.launchedAt, now.timeIntervalSince(launchedAt) >= 2 else { return nil }
        return Identity(pid: pid, launchedAt: launchedAt, version: nil)
    }

    /// The relaunching predecessor quits only after a signed successor has
    /// published its launch identity and acknowledged a successful claim.
    static func isReadySuccessor(_ app: NSRunningApplication, runningVersion: String?) -> Bool {
        guard let date = app.launchDate,
              let minimum = runningVersion.flatMap(ProviderCLIVersion.strictNormalize),
              let record = Registry().record(pid: app.processIdentifier, launchedAt: date),
              record.ready, let version = record.identity.version,
              ProviderCLIVersion.compare(version, minimum) != .ascending,
              Registry.application(matching: record.identity) != nil else { return false }
        return true
    }

    private struct Pending {
        let requestedAt: TimeInterval
        var forcedAt: TimeInterval?
        var failureLogged = false
    }

    private let own: Identity
    private let peers: () -> [Identity]
    private let terminate: (Identity, Bool) -> Bool
    private let quitSelf: () -> Void
    private let clock: () -> TimeInterval
    private let log: (String) -> Void
    private let publishReady: () throws -> Void
    private var pending: [Identity: Pending] = [:]
    private var canClaim = true
    private var yielding = false
    private var timer: Timer?

    /// Test and development hosts never enumerate or signal installed apps.
    convenience init?(bundle: Bundle = .main) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              bundle.bundleIdentifier == "tech.malibu.app",
              CLIUpdateRunner.isUpdaterOwnedMalibuInstall(bundle.bundleURL),
              CLIUpdateRunner.validateMalibuAppCodeSignature(at: bundle.bundleURL),
              let raw = CLIUpdateRunner.runningAppVersion,
              let version = ProviderCLIVersion.strictNormalize(raw),
              let launchedAt = NSRunningApplication.current.launchDate else { return nil }
        let own = Identity(
            pid: ProcessInfo.processInfo.processIdentifier,
            launchedAt: launchedAt,
            version: version
        )
        let registry = Registry()
        do {
            try registry.publish(own)
        } catch {
            // Without publishing our launch identity a rollback could be
            // mistaken for a newer process. Do not signal any peers.
            NSLog("Malibu handoff: cannot publish launch identity: %@", error.localizedDescription)
            self.init(
                own: own, peers: { [] }, terminate: { _, _ in false },
                quitSelf: { NSApp.terminate(nil) },
                clock: { ProcessInfo.processInfo.systemUptime },
                log: { NSLog("Malibu handoff: %@", $0) }
            )
            canClaim = false
            return
        }
        self.init(
            own: own,
            peers: { registry.peers(own: own) },
            terminate: { identity, force in
                // Re-resolve and compare the launch time before every signal:
                // a recycled PID must never become a termination target.
                guard let app = Registry.application(matching: identity) else { return true }
                return force ? app.forceTerminate() : app.terminate()
            },
            quitSelf: { NSApp.terminate(nil) },
            clock: { ProcessInfo.processInfo.systemUptime },
            log: { NSLog("Malibu handoff: %@", $0) },
            publishReady: { try registry.publish(own, ready: true) }
        )
    }

    init(
        own: Identity,
        peers: @escaping () -> [Identity],
        terminate: @escaping (Identity, Bool) -> Bool,
        quitSelf: @escaping () -> Void,
        clock: @escaping () -> TimeInterval,
        log: @escaping (String) -> Void,
        publishReady: @escaping () throws -> Void = {}
    ) {
        self.own = own
        self.peers = peers
        self.terminate = terminate
        self.quitSelf = quitSelf
        self.clock = clock
        self.log = log
        self.publishReady = publishReady
    }

    /// Call before starting provider observers or exposing a menu-bar item.
    /// The retained monitor verifies that superseded PIDs actually disappear.
    func claim() async -> Bool {
        guard canClaim else { quitSelf(); return false }
        do { try await Task.sleep(nanoseconds: 500_000_000) }
        catch { return false }
        guard Self.winner(in: peers() + [own]) == own else {
            _ = tick()
            return false
        }
        do { try publishReady() }
        catch {
            log("cannot acknowledge successor readiness: \(error.localizedDescription)")
            quitSelf()
            return false
        }
        guard tick() else { return false }
        guard timer == nil else { return true }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    /// Every escalation re-elects the winner, including when another update
    /// arrives during a previous handoff's grace period.
    @discardableResult
    func tick() -> Bool {
        guard !yielding else { return false }
        let running = peers()
        guard Self.winner(in: running + [own]) == own else {
            yielding = true
            pending.removeAll()
            timer?.invalidate()
            log("yielding PID \(own.pid) to the elected running app")
            quitSelf()
            return false
        }
        let live = Set(running.filter { $0.pid != own.pid })
        for identity in Array(pending.keys) where !live.contains(identity) {
            log("superseded PID \(identity.pid) exited")
            pending.removeValue(forKey: identity)
        }
        let now = clock()
        for identity in live {
            guard var state = pending[identity] else {
                log("asking superseded PID \(identity.pid) to quit")
                _ = terminate(identity, false)
                pending[identity] = Pending(requestedAt: now)
                continue
            }
            if state.forcedAt == nil, now - state.requestedAt >= 40 {
                log("PID \(identity.pid) exceeded the quit deadline; forcing termination")
                let accepted = terminate(identity, true)
                state.forcedAt = now
                if !accepted { log("forceTerminate refused for PID \(identity.pid)") }
            } else if let forcedAt = state.forcedAt, now - forcedAt >= 5, !state.failureLogged {
                log("PID \(identity.pid) still running five seconds after forceTerminate")
                state.failureLogged = true
            }
            pending[identity] = state
        }
        return true
    }

    /// Registry files are private, small and bound to a process launch date.
    /// Stale files can never manufacture a live process or target a reused PID.
    @MainActor
    final class Registry {
        struct Record: Codable {
            let identity: Identity
            let ready: Bool
        }

        private let directory: URL
        private let validatesSignature: (Int32) -> Bool

        init(
            directory: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Malibu/app-instances", isDirectory: true),
            validatesSignature: @escaping (Int32) -> Bool = Registry.isSignedMalibu
        ) {
            self.directory = directory
            self.validatesSignature = validatesSignature
        }

        private func recordURL(_ pid: Int32) -> URL {
            directory.appendingPathComponent("\(pid).json")
        }

        func publish(_ identity: Identity, ready: Bool = false) throws {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let url = recordURL(identity.pid)
            try JSONEncoder().encode(Record(identity: identity, ready: ready)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        func record(pid: Int32, launchedAt: Date) -> Record? {
            let url = recordURL(pid)
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= 1_024,
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.identity.pid == pid, record.identity.launchedAt == launchedAt,
                  let version = record.identity.version,
                  ProviderCLIVersion.strictNormalize(version) != nil else { return nil }
            return record
        }

        private static func isSameUser(_ pid: Int32) -> Bool {
            var process = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            return sysctl(&query, u_int(query.count), &process, &size, nil, 0) == 0
                && size == MemoryLayout<kinfo_proc>.stride
                && process.kp_eproc.e_ucred.cr_uid == getuid()
        }

        /// Validate the running guest, not its replaced on-disk bundle.
        static func isSignedMalibu(_ pid: Int32) -> Bool {
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(
                nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code
            ) == errSecSuccess, let code else { return false }
            var requirement: SecRequirement?
            let text = "identifier \"tech.malibu.app\" and anchor apple generic and certificate leaf[subject.OU] = \"YF7XNRJUG4\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }

        static func application(matching identity: Identity) -> NSRunningApplication? {
            Registry().application(matching: identity)
        }

        // A running app's location is not its identity: activation renames
        // the predecessor bundle, and LaunchServices may retain its old URL.
        // Verify the running code and launch date again before every signal.
        func application(matching identity: Identity) -> NSRunningApplication? {
            guard let app = NSRunningApplication(processIdentifier: identity.pid),
                  !app.isTerminated, app.bundleIdentifier == "tech.malibu.app",
                  app.launchDate == identity.launchedAt,
                  Self.isSameUser(identity.pid), validatesSignature(identity.pid) else { return nil }
            return app
        }

        func peers(own: Identity) -> [Identity] {
            NSRunningApplication.runningApplications(withBundleIdentifier: "tech.malibu.app")
                .compactMap { app in
                    guard !app.isTerminated, let date = app.launchDate else { return nil }
                    let pid = app.processIdentifier
                    if pid == own.pid { return own }
                    let observed = Identity(pid: pid, launchedAt: date, version: nil)
                    guard application(matching: observed) != nil else { return nil }
                    let published = record(pid: pid, launchedAt: date)
                    return AppInstanceHandoff.discoveredIdentity(
                        pid: pid, launchedAt: date,
                        record: published?.identity, recordReady: published?.ready ?? false,
                        own: own, now: Date()
                    )
                }
        }
    }
}
