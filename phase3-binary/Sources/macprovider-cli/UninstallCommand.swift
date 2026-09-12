import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop macprovider-cli and remove installed artifacts."
    )

    @Flag(help: "Accepted for compatibility; support files, logs, and pending-update residue are always removed. The provider identity (config provider_id + CLI credential, in Keychain or protected-file custody) is preserved for safe reinstall per SPEC-001; a future full-identity-reset is required to destroy it.")
    var removeConfigAndLogs = false

    @Flag(help: "Accepted for compatibility; uninstall is non-interactive.")
    var yes = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var warnings: [String] = []
        let paths = Self.artifactPaths(home: home)
        let lifecycleStore = ProviderLifecycleStateStore(
            url: ProviderLifecycleStateStore.defaultURL(homeDirectory: home)
        )
        let priorLifecycle: ProviderLifecycleStateRecord?
        if case .valid(let record) = lifecycleStore.inspect() {
            priorLifecycle = record
        } else {
            priorLifecycle = nil
        }
        let manifest: InstallManifest
        switch try Self.loadManifest(home: home) {
        case .loaded(let loaded):
            manifest = loaded
        case .missing:
            warnings.append("install manifest missing; using legacy uninstall locations")
            manifest = Self.legacyManifest(home: home)
        }
        let systemDomain = Self.installsInSystemDomain(manifest)
        if !systemDomain {
            try Self.validateNoHeadlessSystemArtifactsPresent { arguments in
                try runProcess("/bin/launchctl", arguments: arguments)
            }
        }

        // SPEC-001 FR-12 / SPEC-020 R-4.14: an uninstall is a validated local
        // stop intent. Resolve the running provider PID now, and record the
        // intent (PID+boot+process-start-bound, short-lived, consumed-once) at
        // the exact moment its launchd job is booted out — so the serve process
        // exits 0 for that SIGTERM rather than treating it as unsolicited. The
        // marker is written inside `stopLaunchdServices` right before the
        // provider bootout (after restart-capable watchdog jobs are gone), so it
        // opens no fail-open window. Best-effort: if the PID is unresolvable or
        // the write fails the serve simply exits nonzero, and `bootout` removes
        // the job either way (no relaunch).
        let providerStopPID: Int32?
        if case .launchdManaged(let pid?) = ((try? ProviderConflictDetector().detect()) ?? .none) {
            providerStopPID = pid
        } else {
            providerStopPID = nil
            warnings.append("could not resolve running provider PID; stop-intent marker not recorded (serve will exit nonzero, launchd job still booted out)")
        }
        try Self.stopUninstallServices(
            labels: manifest.launchdLabels,
            uid: getuid(),
            systemDomain: systemDomain,
            run: { arguments in try runProcess("/bin/launchctl", arguments: arguments) },
            beforeBootout: { label in
                guard label == ProviderConflictDetector.launchdLabel, let pid = providerStopPID else { return }
                if !StopIntentMarker.record(targetPID: pid, reason: "uninstall", home: home) {
                    warnings.append("failed to record stop-intent marker for provider uninstall (serve may exit nonzero)")
                }
            }
        )
        // The signed CLI remains the sole lifecycle author. Publish the
        // uninstall tombstone only after both launchd jobs are proven absent,
        // and before removing the executable that can author it.
        _ = try lifecycleStore.transition(
            to: .uninstalled,
            reasonCode: "uninstall_services_stopped",
            writer: .installer,
            providerID: priorLifecycle?.providerID,
            modelID: priorLifecycle?.modelID,
            compatibilitySetID: priorLifecycle?.compatibilitySetID,
            operationID: "uninstall:\(UUID().uuidString.lowercased())",
            operatorPaused: false
        )
        // SPEC-037 FR-KVP8 — before removing product files, purge the encrypted KV
        // survival disk tier (purge --all --forget): remove the namespace directory
        // and all per-epoch master + per-entry DEK Keychain items so no orphaned
        // ciphertext or key material outlives the product. Runs now that both
        // launchd jobs are proven stopped (no serve process holds the namespace
        // lock). Best-effort: it works while the tier is disabled and NEVER
        // hard-fails uninstall — a KV-cleanup hiccup is recorded as a warning.
        await Self.purgeKVDiskCacheBestEffort(warnings: &warnings)

        // Preserve the provider identity credential for safe reinstall. A
        // routine uninstall is reversible and does not constitute an explicit
        // cryptographic identity reset; destroying the bearer while provider_id
        // survives would strand an already-used coordinator principal.
        let allowed = try Self.allowedRemovalPaths(home: home, manifest: manifest)
        for plist in manifest.launchdPlists {
            removeIfPresent(URL(fileURLWithPath: plist), allowed: allowed.plists, label: "plist", warnings: &warnings)
        }
        if let symlinkPath = manifest.symlinkPath {
            removeIfPresent(URL(fileURLWithPath: symlinkPath), allowed: allowed.symlinks, label: "binary symlink", warnings: &warnings)
        } else {
            removeIfPresent(paths.binary, allowed: allowed.symlinks, label: "binary symlink", warnings: &warnings)
        }
        // Malibu-branded alias (#1261) is materialized by entrypoint convergence,
        // not recorded in older manifests, so remove it by its fixed path -- but
        // only when it is a symlink we own (points exactly at the canonical
        // `~/.local/bin/macprovider-cli` entrypoint), never an unrelated user
        // file/dir/symlink at the `malibu-cli` path. lstat/unlink (not
        // fileExists) so a dangling owned alias symlink is still cleaned up.
        if Self.aliasIsOwnedSymlink(paths.aliasBinary, canonicalEntrypoint: paths.binary) {
            removeOwnedSymlink(paths.aliasBinary, allowed: allowed.symlinks, label: "malibu-cli alias symlink", warnings: &warnings)
        }
        if let binaryPath = manifest.binaryPath {
            removeIfPresent(URL(fileURLWithPath: binaryPath), allowed: allowed.binaries, label: "binary", warnings: &warnings)
        }
        for dataDir in manifest.dataDirs {
            removeIfPresent(URL(fileURLWithPath: dataDir), allowed: allowed.dataDirs, label: "data directory", warnings: &warnings)
        }
        // Clear the autoupdate transaction residue (`pending.json`, `update.lock`)
        // under the provider state root. Both launchd jobs are proven absent by
        // this point, so no updater owns these markers; leaving `pending.json`
        // makes the next `install.sh` falsely report "a provider update is
        // awaiting coordinator admission or recovery" and refuse to install
        // (issue #1420). Preserves the rest of the state root and the identity.
        if let residue = allowed.autoupdateResidue {
            removeIfPresent(
                URL(fileURLWithPath: residue),
                allowed: [residue],
                label: "autoupdate transaction residue",
                warnings: &warnings
            )
        }
        removeIfPresent(paths.manifest, allowed: [paths.manifest.path], label: "manifest", warnings: &warnings)
        Self.cleanupApplicationSupportPreservingLifecycleState(
            paths.applicationSupportDirectory,
            warnings: &warnings
        )

        try removePathMarker(from: home.appendingPathComponent(".zshrc"))
        if FileManager.default.fileExists(atPath: paths.cacheDirectory.path) {
            warnings.append(
                "left cache directory in place: \(paths.cacheDirectory.path)"
                + " — this does not block reinstall; remove it with"
                + " `rm -rf \(paths.cacheDirectory.path)` for a full wipe.")
        }
        for warning in warnings {
            print("warning: \(warning)")
        }
        print("malibu-cli has been uninstalled.")
    }

    /// FR-KVP8 — resolve the installed KV disk tier and purge --all --forget it,
    /// best-effort. When the tier cannot be resolved (config unreadable or empty
    /// provider_id), we cannot locate the namespace to shred, so surface an explicit
    /// warning rather than skipping silently — any encrypted KV survival data + Keychain
    /// DEKs from a prior enabled run may remain. Never throws — uninstall must not
    /// hard-fail on a KV-cleanup hiccup (it is reversible and preserves identity).
    static func purgeKVDiskCacheBestEffort(warnings: inout [String]) async {
        guard let tier = makeKVDiskTierForUninstall() else {
            warnings.append(
                "kv-cache cleanup skipped: could not resolve config/provider_id; encrypted KV "
                + "survival data and Keychain DEKs may remain under the configured cache directory "
                + "— run `malibu-cli kv-cache purge --all --forget` after restoring config, or "
                + "remove the cache dir manually.")
            return
        }
        await purgeKVDiskCache(tier, warnings: &warnings)
    }

    /// Build the KV disk tier for the installed namespace (provider ID) from config,
    /// or nil when unresolvable. `purgeAllAndForget` works even while the tier is
    /// disabled (it only needs the namespace lock + provider ID).
    static func makeKVDiskTierForUninstall() -> KVDiskTier? {
        guard let resolved = try? ConfigLoader.load(cli: CLIOverrides()) else { return nil }
        guard let providerID = resolved.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else { return nil }
        let ttl = Int(ConversationCache.Config.fromEnvironment().ttlSeconds)
        return KVDiskTier(config: resolved.kvDiskCache, namespaceID: providerID, eligibilityTTLSeconds: ttl)
    }

    /// Purge --all --forget the given tier (testable seam), then release the lock.
    /// Best-effort: a failure is surfaced as a warning, never a thrown error.
    static func purgeKVDiskCache(_ tier: KVDiskTier, warnings: inout [String]) async {
        let result = await tier.purgeAllAndForget()
        await tier.shutdown()
        if case let .failed(detail) = result {
            warnings.append("kv-cache cleanup incomplete: \(detail.rawValue)")
        }
    }

    struct ArtifactPaths: Equatable {
        let binary: URL
        /// Malibu-branded PATH alias (`~/.local/bin/malibu-cli`, #1261). Removed
        /// alongside the canonical entrypoint so uninstall leaves no dangling
        /// symlink behind.
        let aliasBinary: URL
        let supportDirectory: URL
        let logsDirectory: URL
        let plist: URL
        let watchdogPlist: URL
        let watchdogDirectory: URL
        let applicationSupportDirectory: URL
        let manifest: URL
        let cacheDirectory: URL
    }

    enum UninstallError: Error, Equatable, CustomStringConvertible {
        case serviceStillLoaded(String)
        case serviceAbsenceVerificationFailed(String, Int32)
        case unexpectedServiceLabel(String)
        case unsupportedHeadlessInstallProfile
        case headlessProfileIndeterminateWithoutManifest(String, Int32)
        case headlessUninstallPrivilegeRequired
        case invalidInstallManifest(String)

        var description: String {
            switch self {
            case .serviceStillLoaded(let label):
                return "refusing to remove provider artifacts while launchd service remains loaded: \(label). "
                    + "Remedy: stop it and re-run uninstall — `launchctl bootout gui/$(id -u)/\(label)` "
                    + "(or reboot), then `malibu-cli uninstall`."
            case .serviceAbsenceVerificationFailed(let label, let status):
                return "refusing to remove provider artifacts because launchd service absence could not be verified: "
                    + "\(label) (launchctl print exited \(status)). "
                    + "Remedy: inspect with `launchctl print gui/$(id -u)/\(label)`, boot it out with "
                    + "`launchctl bootout gui/$(id -u)/\(label)` (or reboot), then re-run `malibu-cli uninstall`."
            case .unexpectedServiceLabel(let label):
                return "refusing to use an unrecognized launchd service label from the install manifest: \(label)"
            case .unsupportedHeadlessInstallProfile:
                return "headless_fleet uninstall is not supported until system-domain service stop and absence proof are implemented"
            case .headlessProfileIndeterminateWithoutManifest(let label, let status):
                return "refusing legacy uninstall because system-domain service absence could not be verified without an install manifest: \(label) (launchctl print exited \(status))"
            case .headlessUninstallPrivilegeRequired:
                return "headless_fleet uninstall must stop system LaunchDaemons; run it with passwordless sudo launchctl access as the headless fleet user"
            case .invalidInstallManifest(let reason):
                return "refusing uninstall because install manifest is invalid: \(reason)"
            }
        }
    }

    // Stop the watchdog before the provider so no managed process remains that
    // can bootstrap or kickstart the provider during uninstall. The fixed list
    // also prevents a user-writable manifest from targeting unrelated jobs.
    static let managedLaunchdStopOrder = [
        "live.malibu.provider-watchdog",
        "live.malibu.provider",
        "live.streamvc.macprovider-watchdog",
        "live.streamvc.macprovider",
    ]

    // `bootout` is asynchronous: it can return while the job is still in its
    // exiting state, during which `launchctl print` still reports status 0
    // ("loaded"). SPEC-001 still requires proving absence before removing
    // artifacts, so we re-check for a bounded grace window and treat a
    // persistent status 0 as still-loaded (fail closed) only after it elapses.
    // Any other non-absent result is indeterminate and fails closed at once.
    static let serviceAbsenceMaxAttempts = 20
    static let serviceAbsencePollIntervalMicroseconds: useconds_t = 100_000

    static func stopLaunchdServices(
        labels: [String],
        uid: uid_t,
        run: ([String]) throws -> Int32,
        beforeBootout: (String) -> Void = { _ in },
        sleep: (useconds_t) -> Void = { _ = usleep($0) }
    ) throws {
        let managedLabels = Set(managedLaunchdStopOrder)
        for label in Set(labels) where !managedLabels.contains(label) {
            throw UninstallError.unexpectedServiceLabel(label)
        }

        for label in managedLaunchdStopOrder {
            let target = "gui/\(uid)/\(label)"
            // Hook fires immediately before this label's bootout. The stop order
            // stops restart-capable watchdog jobs first, so by the time the
            // provider label is booted out no watchdog remains to fight it — and
            // a validated stop-intent marker recorded here (SPEC-001 FR-12) has no
            // fail-open window: if an earlier bootout failed we throw before ever
            // reaching the provider label.
            beforeBootout(label)
            _ = try run(["bootout", target])
            // `bootout` returns nonzero both for an absent job and for real
            // failures. A follow-up `print` is the stop proof: only a missing
            // job is safe before deleting the executable and plist.
            try verifyServiceAbsent(label: label, uid: uid, run: run, sleep: sleep)
        }

        // Recheck the complete managed set only after every restart-capable job
        // has stopped. This closes the provider-first/watchdog-restart race.
        for label in managedLaunchdStopOrder {
            try verifyServiceAbsent(label: label, uid: uid, run: run, sleep: sleep)
        }
    }

    /// Uninstall-specific launchd stop. GUI-domain installs retain the existing
    /// behavior. A `headless_fleet` install owns system LaunchDaemons, so it
    /// must stop those through `sudo launchctl` and prove absence in the system
    /// domain; a GUI-domain `bootout` cannot stop (and must never be used as a
    /// remedy for) a system-domain job.
    static func stopUninstallServices(
        labels: [String],
        uid: uid_t,
        systemDomain: Bool,
        run: ([String]) throws -> Int32,
        beforeBootout: (String) -> Void = { _ in },
        sleep: (useconds_t) -> Void = { _ = usleep($0) }
    ) throws {
        guard systemDomain else {
            try stopLaunchdServices(
                labels: labels,
                uid: uid,
                run: run,
                beforeBootout: beforeBootout,
                sleep: sleep
            )
            return
        }

        let managedLabels = Set(managedLaunchdStopOrder)
        for label in Set(labels) where !managedLabels.contains(label) {
            throw UninstallError.unexpectedServiceLabel(label)
        }

        for label in managedLaunchdStopOrder {
            beforeBootout(label)
            let bootStatus = try run(["-n", "/bin/launchctl", "bootout", "system/\(label)"])
            if bootStatus != 0 {
                throw UninstallError.headlessUninstallPrivilegeRequired
            }
            try verifySystemServiceAbsent(label: label, run: run, sleep: sleep)
        }
        for label in managedLaunchdStopOrder {
            try verifySystemServiceAbsent(label: label, run: run, sleep: sleep)
        }
    }

    private static func verifySystemServiceAbsent(
        label: String,
        run: ([String]) throws -> Int32,
        sleep: (useconds_t) -> Void
    ) throws {
        let target = "system/\(label)"
        var attempt = 0
        while true {
            let printStatus = try run(["-n", "/bin/launchctl", "print", target])
            if isLaunchdAbsentStatus(printStatus) {
                return
            }
            guard printStatus == 0 else {
                throw UninstallError.serviceAbsenceVerificationFailed(label, printStatus)
            }
            attempt += 1
            if attempt >= serviceAbsenceMaxAttempts {
                throw UninstallError.serviceStillLoaded(label)
            }
            sleep(serviceAbsencePollIntervalMicroseconds)
        }
    }

    static let managedSystemLaunchDaemonPlists = [
        "/Library/LaunchDaemons/live.malibu.provider.plist",
        "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist",
        "/Library/LaunchDaemons/live.streamvc.macprovider.plist",
        "/Library/LaunchDaemons/live.streamvc.macprovider-watchdog.plist",
    ]

    static func validateNoHeadlessSystemArtifactsPresent(
        systemPlists: [String] = managedSystemLaunchDaemonPlists,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        run: ([String]) throws -> Int32
    ) throws {
        for plist in systemPlists where fileExists(plist) {
            throw UninstallError.unsupportedHeadlessInstallProfile
        }
        for label in managedLaunchdStopOrder {
            let target = "system/\(label)"
            let status = try run(["print", target])
            guard status != 0 else {
                throw UninstallError.unsupportedHeadlessInstallProfile
            }
            guard isLaunchdAbsentStatus(status) else {
                throw UninstallError.headlessProfileIndeterminateWithoutManifest(label, status)
            }
        }
    }

    private static func verifyServiceAbsent(
        label: String,
        uid: uid_t,
        run: ([String]) throws -> Int32,
        sleep: (useconds_t) -> Void = { _ = usleep($0) }
    ) throws {
        let target = "gui/\(uid)/\(label)"
        var attempt = 0
        while true {
            let printStatus = try run(["print", target])
            if isLaunchdAbsentStatus(printStatus) {
                return
            }
            // Status 0 == still loaded. Immediately after `bootout` this may just
            // be the asynchronous teardown finishing, so poll for a bounded grace
            // window before failing closed. Every other non-absent result is
            // indeterminate per SPEC-001 and fails closed without retry.
            guard printStatus == 0 else {
                throw UninstallError.serviceAbsenceVerificationFailed(label, printStatus)
            }
            attempt += 1
            if attempt >= serviceAbsenceMaxAttempts {
                throw UninstallError.serviceStillLoaded(label)
            }
            sleep(serviceAbsencePollIntervalMicroseconds)
        }
    }

    static func isLaunchdAbsentStatus(_ status: Int32) -> Bool {
        status == 1 || status == 3 || status == 113
    }

    /// True only when `url` is a symlink this tool owns: it points exactly at
    /// the canonical `macprovider-cli` entrypoint (`~/.local/bin/macprovider-cli`,
    /// = `canonicalEntrypoint`). A user's own file, or a symlink to any other
    /// target, is not owned. Uses lstat/readlink (not fileExists) so a dangling
    /// owned alias still counts. Guards uninstall against deleting an unrelated
    /// user file at the alias path (#1261).
    static func aliasIsOwnedSymlink(_ url: URL, canonicalEntrypoint: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else {
            return false
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(url.path, &buffer, buffer.count - 1)
        guard length > 0 else { return false }
        buffer[length] = 0
        let target = String(cString: buffer)
        let resolved = target.hasPrefix("/")
            ? URL(fileURLWithPath: target).standardizedFileURL.path
            : url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
        return resolved == canonicalEntrypoint.standardizedFileURL.path
    }

    static func artifactPaths(home: URL) -> ArtifactPaths {
        ArtifactPaths(
            binary: home.appendingPathComponent(".local/bin/macprovider-cli"),
            aliasBinary: home.appendingPathComponent(".local/bin/malibu-cli"),
            supportDirectory: home.appendingPathComponent("macprovider"),
            logsDirectory: home.appendingPathComponent("Library/Logs/macprovider"),
            plist: home.appendingPathComponent("Library/LaunchAgents/live.malibu.provider.plist"),
            watchdogPlist: home.appendingPathComponent("Library/LaunchAgents/live.malibu.provider-watchdog.plist"),
            watchdogDirectory: home.appendingPathComponent(".local/share/macprovider-watchdog"),
            applicationSupportDirectory: home.appendingPathComponent("Library/Application Support/macprovider", isDirectory: true),
            manifest: home.appendingPathComponent("Library/Application Support/macprovider/install_manifest.json"),
            cacheDirectory: home.appendingPathComponent(".cache/macprovider")
        )
    }

    struct InstallManifest: Codable, Equatable {
        let installPrefix: String
        let launchdLabels: [String]
        let dataDirs: [String]
        let version: String?
        let binaryPath: String?
        let symlinkPath: String?
        let launchdPlists: [String]
        let installProfile: String?
        let launchdDomain: String?
        /// Root of the provider's `~/.local/share/macprovider` state tree. Its
        /// `autoupdate/` subdirectory holds in-flight update transaction residue
        /// (`pending.json`, `update.lock`) that must be cleared on uninstall so a
        /// subsequent install is not falsely told an update is awaiting
        /// admission. Optional for backward compatibility with older manifests.
        let providerStateRoot: String?

        enum CodingKeys: String, CodingKey {
            case installPrefix = "install_prefix"
            case launchdLabels = "launchd_labels"
            case dataDirs = "data_dirs"
            case version
            case binaryPath = "binary_path"
            case symlinkPath = "symlink_path"
            case launchdPlists = "launchd_plists"
            case installProfile = "install_profile"
            case launchdDomain = "launchd_domain"
            case providerStateRoot = "provider_state_root"
        }

        // Explicit memberwise initializer with a default for `providerStateRoot`
        // so existing constructors (and older tests) remain source-compatible.
        // Codable's synthesized `init(from:)` is unaffected and decodes a missing
        // `provider_state_root` key as nil.
        init(
            installPrefix: String,
            launchdLabels: [String],
            dataDirs: [String],
            version: String?,
            binaryPath: String?,
            symlinkPath: String?,
            launchdPlists: [String],
            installProfile: String?,
            launchdDomain: String?,
            providerStateRoot: String? = nil
        ) {
            self.installPrefix = installPrefix
            self.launchdLabels = launchdLabels
            self.dataDirs = dataDirs
            self.version = version
            self.binaryPath = binaryPath
            self.symlinkPath = symlinkPath
            self.launchdPlists = launchdPlists
            self.installProfile = installProfile
            self.launchdDomain = launchdDomain
            self.providerStateRoot = providerStateRoot
        }
    }

    static func validateUninstallProfile(_ manifest: InstallManifest) throws {
        guard manifest.installProfile != "headless_fleet",
              manifest.launchdDomain != "system" else {
            throw UninstallError.unsupportedHeadlessInstallProfile
        }
    }

    /// True for a `headless_fleet` install whose provider/watchdog jobs live in
    /// launchd's system domain. Missing legacy fields are treated as a GUI
    /// install; `validateNoHeadlessSystemArtifactsPresent` still fail-closes a
    /// consumer uninstall when system-domain artifacts are present.
    static func installsInSystemDomain(_ manifest: InstallManifest) -> Bool {
        manifest.installProfile == "headless_fleet" || manifest.launchdDomain == "system"
    }

    enum ManifestLoadResult: Equatable {
        case missing
        case loaded(InstallManifest)
    }

    static func loadManifest(home: URL, fileManager: FileManager = .default) throws -> ManifestLoadResult {
        let url = artifactPaths(home: home).manifest
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try JSONDecoder().decode(InstallManifest.self, from: data))
        } catch {
            throw UninstallError.invalidInstallManifest(String(describing: error))
        }
    }

    static func legacyManifest(home: URL) -> InstallManifest {
        let paths = artifactPaths(home: home)
        return InstallManifest(
            installPrefix: paths.supportDirectory.path,
            launchdLabels: ["live.malibu.provider", "live.malibu.provider-watchdog"],
            dataDirs: [
                paths.supportDirectory.path,
                paths.logsDirectory.path,
                paths.watchdogDirectory.path,
            ],
            version: nil,
            binaryPath: nil,
            symlinkPath: paths.binary.path,
            launchdPlists: [
                paths.plist.path,
                paths.watchdogPlist.path,
                home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist").path,
                home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist").path,
            ],
            installProfile: nil,
            launchdDomain: nil,
            providerStateRoot: home.appendingPathComponent(".local/share/macprovider").path
        )
    }

    /// Remove installer/update/runtime residue while retaining the canonical
    /// lifecycle tombstone. A subsequent reinstall extends the same transition
    /// chain instead of making Malibu guess whether a missing status endpoint is
    /// an uninstall, crash, or permissions failure.
    static func cleanupApplicationSupportPreservingLifecycleState(
        _ root: URL,
        fileManager: FileManager = .default,
        warnings: inout [String]
    ) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        do {
            for entry in try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            ) {
                if entry.lastPathComponent == "lifecycle" {
                    try cleanupLifecycleDirectory(entry, fileManager: fileManager)
                } else {
                    try fileManager.removeItem(at: entry)
                }
            }
        } catch {
            warnings.append("failed to remove application support residue: \(error)")
        }
    }

    private static func cleanupLifecycleDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        let retained = Set(["state-v1.json", ".state-v1.json.lock"])
        for entry in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) where !retained.contains(entry.lastPathComponent) {
            try fileManager.removeItem(at: entry)
        }
    }

    struct AllowedRemovalPaths {
        let plists: [String]
        let symlinks: [String]
        let binaries: [String]
        let dataDirs: [String]
        /// The single `<provider_state_root>/autoupdate` directory holding update
        /// transaction residue, or nil when no safe state root can be resolved.
        let autoupdateResidue: String?
    }

    /// Canonical provider state root when the manifest does not record one
    /// (older manifests predate `provider_state_root`); matches install.sh's
    /// `$HOME/.local/share/macprovider`.
    static func defaultProviderStateRoot(home: URL) -> URL {
        home.appendingPathComponent(".local/share/macprovider", isDirectory: true)
    }

    static func allowedRemovalPaths(home: URL, manifest: InstallManifest) throws -> AllowedRemovalPaths {
        let paths = artifactPaths(home: home)
        let systemPlists = installsInSystemDomain(manifest)
            ? managedSystemLaunchDaemonPlists
            : []
        let installPrefix = URL(fileURLWithPath: manifest.installPrefix)
        // Only honor a manifest-supplied provider_state_root when it is exactly
        // the canonical location. A corrupt or tampered manifest must not be able
        // to redirect the recursive autoupdate-residue removal at an arbitrary
        // path (audit finding). install.sh only ever writes the canonical
        // `~/.local/share/macprovider`, so this loses nothing in practice and
        // fails safe to the canonical path for any other value.
        let canonicalStateRoot = defaultProviderStateRoot(home: home)
        let stateRoot: URL
        if let declared = manifest.providerStateRoot.map({ URL(fileURLWithPath: $0) }),
           declared.standardizedFileURL.path == canonicalStateRoot.standardizedFileURL.path {
            stateRoot = declared
        } else {
            stateRoot = canonicalStateRoot
        }
        return AllowedRemovalPaths(
            plists: [
                paths.plist.path,
                paths.watchdogPlist.path,
                home.appendingPathComponent("Library/LaunchAgents/live.malibu.provider.plist").path,
                home.appendingPathComponent("Library/LaunchAgents/live.malibu.provider-watchdog.plist").path,
                home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist").path,
                home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist").path,
            ] + systemPlists,
            symlinks: [
                paths.binary.path,
                paths.aliasBinary.path,
            ],
            binaries: [
                installPrefix.appendingPathComponent("macprovider-cli").path,
            ],
            dataDirs: [
                installPrefix.path,
                paths.logsDirectory.path,
                paths.watchdogDirectory.path,
            ],
            autoupdateResidue: stateRoot.appendingPathComponent("autoupdate", isDirectory: true).path
        )
    }

    private func removeIfPresent(_ url: URL, allowed: [String], label: String, warnings: inout [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            guard try Self.path(url.path, isAllowedBy: allowed) else {
                warnings.append("refusing unsafe \(label) path: \(url.path)")
                return
            }
        } catch {
            warnings.append("refusing unsafe \(label) path: \(url.path): \(error)")
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            warnings.append("failed to remove \(url.path): \(error)")
        }
    }

    /// Removes a symlink at `url` that lstat confirms is present, without
    /// following it -- so a dangling owned alias symlink is still cleaned up
    /// (unlike `removeIfPresent`, which uses `fileExists` and skips dangling
    /// links). The caller must have already established ownership. #1261
    private func removeOwnedSymlink(_ url: URL, allowed: [String], label: String, warnings: inout [String]) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return
        }
        do {
            guard try Self.path(url.path, isAllowedBy: allowed) else {
                warnings.append("refusing unsafe \(label) path: \(url.path)")
                return
            }
        } catch {
            warnings.append("refusing unsafe \(label) path: \(url.path): \(error)")
            return
        }
        if unlink(url.path) != 0 {
            warnings.append("failed to remove \(label) at \(url.path)")
        }
    }

    static func path(_ path: String, isAllowedBy allowedPaths: [String]) throws -> Bool {
        let canonical = try canonicalPath(path)
        for allowed in allowedPaths {
            if canonical == (try canonicalPath(allowed)) {
                return true
            }
        }
        return false
    }

    static func canonicalPath(_ path: String) throws -> String {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(PATH_MAX))
        defer { buffer.deallocate() }
        if realpath(path, buffer) != nil {
            return String(cString: buffer)
        }
        if errno == ENOENT {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func removePathMarker(from file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return
        }
        let original = try String(contentsOf: file, encoding: .utf8)
        let filtered = original
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != #"export PATH="$HOME/.local/bin:$PATH" # Added by macprovider-cli"# }
            .joined(separator: "\n")
        if filtered != original {
            try filtered.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
