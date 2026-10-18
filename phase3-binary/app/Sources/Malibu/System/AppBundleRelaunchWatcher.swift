import Foundation

/// SPEC-025 §3.3: the CLI-owned update swaps the installed Malibu.app in place
/// but never touches the running app process. Malibu notices that its own
/// installed bundle changed under it and relaunches onto the new bundle, so it
/// never keeps running old in-memory code against a newer CLI.
///
/// The decision is a pure function of the running identity, the on-disk
/// identity, and the persisted attempt ledger. It waits for the swap to settle,
/// defers while an update, rollback, onboarding, quit or modal is in progress,
/// and caps attempts per target so a bundle that cannot launch never loops.
enum AppBundleRelaunchWatcher {
    struct Identity: Equatable, Sendable {
        let version: String?
        let build: String?
        let executableDevice: UInt64
        let executableInode: UInt64

        var fingerprint: String {
            "\(version ?? "-")|\(build ?? "-")|\(executableDevice):\(executableInode)"
        }
    }

    struct Policy: Equatable, Sendable {
        /// The on-disk identity must stay unchanged this long before relaunch.
        var settleSeconds: TimeInterval = 60
        /// Minimum spacing between two attempts at the same target.
        var retryCooldownSeconds: TimeInterval = 600
        /// Attempts at one target before the watcher gives up on it.
        var maxAttemptsPerTarget = 3
    }

    /// Persisted across relaunches so a target that never comes up cannot loop.
    struct AttemptLedger: Equatable, Sendable {
        var targetFingerprint: String?
        var attempts = 0
        var lastAttemptAt: Date?
    }

    struct State: Equatable, Sendable {
        var pending: Identity?
        var pendingSince: Date?
    }

    static func shouldRelaunch(
        running: Identity,
        onDisk: Identity?,
        blocked: Bool,
        now: Date,
        state: inout State,
        ledger: AttemptLedger,
        policy: Policy = Policy()
    ) -> Bool {
        // Unreadable mid-swap, or unchanged: nothing to settle.
        guard let onDisk, onDisk != running else {
            state = State()
            return false
        }
        if state.pending != onDisk {
            state = State(pending: onDisk, pendingSince: now)
            return false
        }
        guard !blocked,
              let since = state.pendingSince,
              now.timeIntervalSince(since) >= policy.settleSeconds else {
            return false
        }
        if ledger.targetFingerprint == onDisk.fingerprint {
            guard ledger.attempts < policy.maxAttemptsPerTarget else { return false }
            if let last = ledger.lastAttemptAt,
               now.timeIntervalSince(last) < policy.retryCooldownSeconds {
                return false
            }
        }
        return true
    }

    static func recordingAttempt(
        on ledger: AttemptLedger,
        target: Identity,
        now: Date
    ) -> AttemptLedger {
        let attempts = ledger.targetFingerprint == target.fingerprint ? ledger.attempts + 1 : 1
        return AttemptLedger(
            targetFingerprint: target.fingerprint,
            attempts: attempts,
            lastAttemptAt: now
        )
    }

    /// Reads the installed bundle's version, build and executable file
    /// identity without following a symlinked bundle or executable.
    static func readIdentity(
        bundleURL: URL,
        executableName: String,
        fileManager: FileManager = .default
    ) -> Identity? {
        let bundle = bundleURL.standardizedFileURL
        var bundleInfo = stat()
        guard lstat(bundle.path, &bundleInfo) == 0,
              (bundleInfo.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        var plistInfo = stat()
        guard lstat(infoURL.path, &plistInfo) == 0,
              (plistInfo.st_mode & S_IFMT) == S_IFREG,
              plistInfo.st_size <= 64 * 1_024,
              let data = fileManager.contents(atPath: infoURL.path),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "tech.malibu.app" else {
            return nil
        }
        guard !executableName.isEmpty, !executableName.contains("/") else { return nil }
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(executableName)")
        var executableInfo = stat()
        guard lstat(executable.path, &executableInfo) == 0,
              (executableInfo.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return Identity(
            version: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String,
            executableDevice: UInt64(bitPattern: Int64(executableInfo.st_dev)),
            executableInode: UInt64(executableInfo.st_ino)
        )
    }

    /// The identity this process launched from. The executable inode is read
    /// once at launch; a later in-place swap gives the path a new inode.
    static func runningIdentity(bundle: Bundle = .main) -> Identity? {
        guard let executableURL = bundle.executableURL else { return nil }
        var info = stat()
        guard lstat(executableURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return Identity(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            executableDevice: UInt64(bitPattern: Int64(info.st_dev)),
            executableInode: UInt64(info.st_ino)
        )
    }
}

/// Drives `AppBundleRelaunchWatcher` on a timer for the running app.
@MainActor
final class AppBundleRelaunchMonitor {
    private static let ledgerTargetKey = "malibu.selfRelaunch.targetFingerprint"
    private static let ledgerAttemptsKey = "malibu.selfRelaunch.attempts"
    private static let ledgerLastAttemptKey = "malibu.selfRelaunch.lastAttemptAt"

    private let bundleURL: URL
    private let executableName: String
    private let running: AppBundleRelaunchWatcher.Identity
    private let isBlocked: @MainActor () -> Bool
    private let relaunch: @MainActor (URL) async throws -> Void
    private let defaults: UserDefaults
    private let interval: TimeInterval
    private var state = AppBundleRelaunchWatcher.State()
    private var timer: Timer?
    private var relaunching = false

    /// Returns nil unless this process is the updater-owned installed
    /// Malibu.app, so development and test builds never relaunch.
    init?(
        bundle: Bundle = .main,
        isBlocked: @escaping @MainActor () -> Bool,
        relaunch: @escaping @MainActor (URL) async throws -> Void = { url in
            try await CLIUpdateRunner.relaunchInstalledApp(at: url)
        },
        defaults: UserDefaults = .standard,
        interval: TimeInterval = 15
    ) {
        guard bundle.bundleIdentifier == "tech.malibu.app",
              bundle.bundleURL.lastPathComponent == "Malibu.app",
              CLIUpdateRunner.isUpdaterOwnedMalibuInstall(bundle.bundleURL),
              let executableName = bundle.executableURL?.lastPathComponent,
              let running = AppBundleRelaunchWatcher.runningIdentity(bundle: bundle) else {
            return nil
        }
        self.bundleURL = bundle.bundleURL
        self.executableName = executableName
        self.running = running
        self.isBlocked = isBlocked
        self.relaunch = relaunch
        self.defaults = defaults
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(now: Date = Date()) {
        guard !relaunching else { return }
        let onDisk = AppBundleRelaunchWatcher.readIdentity(
            bundleURL: bundleURL,
            executableName: executableName
        )
        let ledger = loadLedger()
        guard AppBundleRelaunchWatcher.shouldRelaunch(
            running: running,
            onDisk: onDisk,
            blocked: isBlocked(),
            now: now,
            state: &state,
            ledger: ledger
        ), let target = onDisk else {
            return
        }
        saveLedger(AppBundleRelaunchWatcher.recordingAttempt(on: ledger, target: target, now: now))
        relaunching = true
        NSLog(
            "[malibu] installed Malibu.app changed (running %@ build %@, installed %@ build %@); relaunching onto the installed bundle",
            running.version ?? "unknown", running.build ?? "unknown",
            target.version ?? "unknown", target.build ?? "unknown"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.relaunch(self.bundleURL)
            } catch {
                NSLog("[malibu] relaunch onto the installed bundle failed: %@", error.localizedDescription)
                self.relaunching = false
            }
        }
    }

    private func loadLedger() -> AppBundleRelaunchWatcher.AttemptLedger {
        AppBundleRelaunchWatcher.AttemptLedger(
            targetFingerprint: defaults.string(forKey: Self.ledgerTargetKey),
            attempts: defaults.integer(forKey: Self.ledgerAttemptsKey),
            lastAttemptAt: defaults.object(forKey: Self.ledgerLastAttemptKey) as? Date
        )
    }

    private func saveLedger(_ ledger: AppBundleRelaunchWatcher.AttemptLedger) {
        defaults.set(ledger.targetFingerprint, forKey: Self.ledgerTargetKey)
        defaults.set(ledger.attempts, forKey: Self.ledgerAttemptsKey)
        defaults.set(ledger.lastAttemptAt, forKey: Self.ledgerLastAttemptKey)
    }
}
