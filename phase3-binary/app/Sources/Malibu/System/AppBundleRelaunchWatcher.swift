import Foundation

/// SPEC-025 §3.3: the CLI-owned update swaps the installed Malibu.app in place
/// but never touches the running app process. Malibu notices that its own
/// installed bundle changed under it and relaunches onto the new bundle, so it
/// never keeps running old in-memory code against a newer CLI.
///
/// The decision is a pure function of the running identity, the on-disk
/// identity, the provider readiness, and the persisted attempt ledger. It waits
/// for the swap to settle, defers while an update, rollback, onboarding, quit
/// or modal is in flight, waits longer while the provider status is unknown,
/// and caps attempts so a bundle that cannot start never loops.
enum AppBundleRelaunchWatcher {
    /// Release versions are unique per tag (SPEC-025 v0.31), so the bundle's
    /// version and build identify it. A rollback that restores the launched
    /// version is therefore never a relaunch target.
    struct Identity: Equatable, Sendable {
        let version: String
        let build: String
    }

    enum Readiness: Equatable, Sendable {
        /// A transaction or a user flow is in flight: never relaunch now.
        case blocked
        /// Provider status is unavailable, so an update may still be in
        /// flight: relaunch only after the long settle window.
        case unknown
        case clear
    }

    struct Policy: Equatable, Sendable {
        /// The on-disk identity must stay unchanged this long with a clear
        /// provider status before relaunch.
        var settleSeconds: TimeInterval = 60
        /// With an unknown provider status the change must persist past the
        /// default 10-minute maintenance lease before relaunch.
        var unknownSettleSeconds: TimeInterval = 15 * 60
        /// Minimum spacing between any two relaunch attempts.
        var retryCooldownSeconds: TimeInterval = 10 * 60
        /// At most this many attempts in any rolling window.
        var maxAttemptsPerWindow = 3
        var attemptWindowSeconds: TimeInterval = 6 * 60 * 60
    }

    /// Persisted across relaunches so a target that never comes up, or a
    /// bundle swapped repeatedly, cannot drive a relaunch loop.
    struct AttemptLedger: Equatable, Sendable {
        var attempts: [Date] = []
    }

    struct State: Equatable, Sendable {
        var pending: Identity?
        var pendingSince: Date?
    }

    static func readiness(
        lifecycleState: String?,
        lifecycleRecordState: String?,
        lifecycleLeaseKind: String?,
        cliUpdateInProgress: Bool,
        providerSoftwareRepairInProgress: Bool,
        appFlowInProgress: Bool
    ) -> Readiness {
        if appFlowInProgress || cliUpdateInProgress || providerSoftwareRepairInProgress
            || lifecycleLeaseKind == "maintenance"
            || lifecycleState == "update_in_progress"
            || lifecycleState == "rollback_in_progress" {
            return .blocked
        }
        // Only a validated persisted lifecycle record is positive evidence
        // that no transaction is in flight; missing or invalid is unknown.
        return lifecycleState != nil && lifecycleRecordState == "valid" ? .clear : .unknown
    }

    static func shouldRelaunch(
        running: Identity,
        onDisk: Identity?,
        readiness: Readiness,
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
        let settle: TimeInterval
        switch readiness {
        case .blocked: return false
        case .unknown: settle = policy.unknownSettleSeconds
        case .clear: settle = policy.settleSeconds
        }
        guard let since = state.pendingSince, now.timeIntervalSince(since) >= settle else {
            return false
        }
        let recent = ledger.attempts.map { min($0, now) }
        if let last = recent.max(), now.timeIntervalSince(last) < policy.retryCooldownSeconds {
            return false
        }
        let inWindow = recent.filter { now.timeIntervalSince($0) < policy.attemptWindowSeconds }
        return inWindow.count < policy.maxAttemptsPerWindow
    }

    static func recordingAttempt(
        on ledger: AttemptLedger,
        now: Date,
        policy: Policy = Policy()
    ) -> AttemptLedger {
        let kept = ledger.attempts
            .map { min($0, now) }
            .filter { now.timeIntervalSince($0) < policy.attemptWindowSeconds }
        return AttemptLedger(attempts: Array((kept + [now]).suffix(policy.maxAttemptsPerWindow)))
    }

    /// Reads the installed bundle's version and build without following a
    /// symlinked bundle or Info.plist.
    static func readIdentity(bundleURL: URL, fileManager: FileManager = .default) -> Identity? {
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
              plist["CFBundleIdentifier"] as? String == "tech.malibu.app",
              let version = plist["CFBundleShortVersionString"] as? String,
              let build = plist["CFBundleVersion"] as? String else {
            return nil
        }
        return Identity(version: version, build: build)
    }

    /// The identity this process launched from (Bundle.main caches its
    /// Info.plist at launch, so a later swap does not change it).
    static func runningIdentity(bundle: Bundle = .main) -> Identity? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        return Identity(version: version, build: build)
    }
}

/// Drives `AppBundleRelaunchWatcher` on a timer for the running app.
@MainActor
final class AppBundleRelaunchMonitor {
    static let ledgerKey = "malibu.selfRelaunch.attempts"

    private let bundleURL: URL
    private let running: AppBundleRelaunchWatcher.Identity
    private let readiness: @MainActor () -> AppBundleRelaunchWatcher.Readiness
    private let isCLIOwnedInstall: @MainActor (URL) -> Bool
    private let relaunch: @MainActor (URL) async throws -> Void
    private let defaults: UserDefaults
    private let interval: TimeInterval
    private let policy: AppBundleRelaunchWatcher.Policy
    private var state = AppBundleRelaunchWatcher.State()
    private var timer: Timer?
    private(set) var relaunching = false

    /// Returns nil unless this process is the updater-owned installed
    /// Malibu.app, so development and test builds never relaunch.
    convenience init?(
        bundle: Bundle = .main,
        readiness: @escaping @MainActor () -> AppBundleRelaunchWatcher.Readiness
    ) {
        guard bundle.bundleIdentifier == "tech.malibu.app",
              bundle.bundleURL.lastPathComponent == "Malibu.app",
              CLIUpdateRunner.isUpdaterOwnedMalibuInstall(bundle.bundleURL),
              let running = AppBundleRelaunchWatcher.runningIdentity(bundle: bundle),
              // A debug or ad-hoc build copied into /Applications never
              // relaunches itself onto the installed release.
              CLIUpdateRunner.validateMalibuAppCodeSignature(at: bundle.bundleURL) else {
            return nil
        }
        self.init(
            bundleURL: bundle.bundleURL,
            running: running,
            readiness: readiness,
            isCLIOwnedInstall: { url in
                CLIUpdateRunner.installedAppMatchesInstalledCompatibilitySet(bundleURL: url)
            },
            relaunch: { url in try await CLIUpdateRunner.relaunchInstalledApp(at: url) }
        )
    }

    init(
        bundleURL: URL,
        running: AppBundleRelaunchWatcher.Identity,
        readiness: @escaping @MainActor () -> AppBundleRelaunchWatcher.Readiness,
        isCLIOwnedInstall: @escaping @MainActor (URL) -> Bool,
        relaunch: @escaping @MainActor (URL) async throws -> Void,
        defaults: UserDefaults = .standard,
        interval: TimeInterval = 15,
        policy: AppBundleRelaunchWatcher.Policy = .init()
    ) {
        self.bundleURL = bundleURL
        self.running = running
        self.readiness = readiness
        self.isCLIOwnedInstall = isCLIOwnedInstall
        self.relaunch = relaunch
        self.defaults = defaults
        self.interval = interval
        self.policy = policy
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.tick() }
        }
        timer.tolerance = interval / 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One evaluation. Returns the relaunch task when it starts one.
    @discardableResult
    func tick(now: Date = Date()) -> Task<Void, Never>? {
        guard !relaunching else { return nil }
        let onDisk = AppBundleRelaunchWatcher.readIdentity(bundleURL: bundleURL)
        var readiness = self.readiness()
        // Relaunch only onto the Malibu member of the installed CLI's signed
        // compatibility set: anything else is mid-transaction or out-of-band.
        if readiness != .blocked, let onDisk, onDisk != running, !isCLIOwnedInstall(bundleURL) {
            readiness = .blocked
        }
        let ledger = loadLedger()
        guard AppBundleRelaunchWatcher.shouldRelaunch(
            running: running,
            onDisk: onDisk,
            readiness: readiness,
            now: now,
            state: &state,
            ledger: ledger,
            policy: policy
        ), let target = onDisk else {
            return nil
        }
        saveLedger(AppBundleRelaunchWatcher.recordingAttempt(on: ledger, now: now, policy: policy))
        relaunching = true
        NSLog(
            "[malibu] installed Malibu.app changed (running %@ build %@, installed %@ build %@); relaunching onto the installed bundle",
            running.version, running.build, target.version, target.build
        )
        return Task<Void, Never> { @MainActor [weak self] in
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
        let stored = (defaults.array(forKey: Self.ledgerKey) as? [Double]) ?? []
        return AppBundleRelaunchWatcher.AttemptLedger(
            attempts: stored.suffix(policy.maxAttemptsPerWindow).map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func saveLedger(_ ledger: AppBundleRelaunchWatcher.AttemptLedger) {
        defaults.set(ledger.attempts.map(\.timeIntervalSince1970), forKey: Self.ledgerKey)
    }
}
