import ArgumentParser
import Darwin
import Foundation

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop macprovider-cli and remove installed artifacts."
    )

    @Flag(help: "Accepted for compatibility; support files and logs are always removed.")
    var removeConfigAndLogs = false

    @Flag(help: "Accepted for compatibility; uninstall is non-interactive.")
    var yes = false

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var warnings: [String] = []
        let paths = Self.artifactPaths(home: home)
        let manifest: InstallManifest
        if let loaded = Self.loadManifest(home: home) {
            manifest = loaded
        } else {
            warnings.append("install manifest missing; using legacy uninstall locations")
            manifest = Self.legacyManifest(home: home)
        }

        try Self.stopLaunchdServices(labels: manifest.launchdLabels, uid: getuid()) { arguments in
            try runProcess("/bin/launchctl", arguments: arguments)
        }
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
        if let binaryPath = manifest.binaryPath {
            removeIfPresent(URL(fileURLWithPath: binaryPath), allowed: allowed.binaries, label: "binary", warnings: &warnings)
        }
        for dataDir in manifest.dataDirs {
            removeIfPresent(URL(fileURLWithPath: dataDir), allowed: allowed.dataDirs, label: "data directory", warnings: &warnings)
        }
        removeIfPresent(paths.manifest, allowed: [paths.manifest.path], label: "manifest", warnings: &warnings)
        try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)

        try removePathMarker(from: home.appendingPathComponent(".zshrc"))
        if FileManager.default.fileExists(atPath: paths.cacheDirectory.path) {
            warnings.append("left cache directory in place: \(paths.cacheDirectory.path)")
        }
        for warning in warnings {
            print("warning: \(warning)")
        }
        print("macprovider-cli has been uninstalled.")
    }

    struct ArtifactPaths: Equatable {
        let binary: URL
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

        var description: String {
            switch self {
            case .serviceStillLoaded(let label):
                return "refusing to remove provider artifacts while launchd service remains loaded: \(label)"
            case .serviceAbsenceVerificationFailed(let label, let status):
                return "refusing to remove provider artifacts because launchd service absence could not be verified: \(label) (launchctl print exited \(status))"
            case .unexpectedServiceLabel(let label):
                return "refusing to use an unrecognized launchd service label from the install manifest: \(label)"
            }
        }
    }

    // Stop the watchdog before the provider so no managed process remains that
    // can bootstrap or kickstart the provider during uninstall. The fixed list
    // also prevents a user-writable manifest from targeting unrelated jobs.
    static let managedLaunchdStopOrder = [
        "live.streamvc.macprovider-watchdog",
        "live.streamvc.macprovider",
    ]

    static func stopLaunchdServices(
        labels: [String],
        uid: uid_t,
        run: ([String]) throws -> Int32
    ) throws {
        let managedLabels = Set(managedLaunchdStopOrder)
        for label in Set(labels) where !managedLabels.contains(label) {
            throw UninstallError.unexpectedServiceLabel(label)
        }

        for label in managedLaunchdStopOrder {
            let target = "gui/\(uid)/\(label)"
            _ = try run(["bootout", target])
            // `bootout` returns nonzero both for an absent job and for real
            // failures. A follow-up `print` is the stop proof: only a missing
            // job is safe before deleting the executable and plist.
            try verifyServiceAbsent(label: label, uid: uid, run: run)
        }

        // Recheck the complete managed set only after every restart-capable job
        // has stopped. This closes the provider-first/watchdog-restart race.
        for label in managedLaunchdStopOrder {
            try verifyServiceAbsent(label: label, uid: uid, run: run)
        }
    }

    private static func verifyServiceAbsent(
        label: String,
        uid: uid_t,
        run: ([String]) throws -> Int32
    ) throws {
        let target = "gui/\(uid)/\(label)"
        let printStatus = try run(["print", target])
        guard printStatus != 0 else {
            throw UninstallError.serviceStillLoaded(label)
        }
        guard printStatus == 113 else {
            throw UninstallError.serviceAbsenceVerificationFailed(label, printStatus)
        }
    }

    static func artifactPaths(home: URL) -> ArtifactPaths {
        ArtifactPaths(
            binary: home.appendingPathComponent(".local/bin/macprovider-cli"),
            supportDirectory: home.appendingPathComponent("macprovider"),
            logsDirectory: home.appendingPathComponent("Library/Logs/macprovider"),
            plist: home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist"),
            watchdogPlist: home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"),
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

        enum CodingKeys: String, CodingKey {
            case installPrefix = "install_prefix"
            case launchdLabels = "launchd_labels"
            case dataDirs = "data_dirs"
            case version
            case binaryPath = "binary_path"
            case symlinkPath = "symlink_path"
            case launchdPlists = "launchd_plists"
        }
    }

    static func loadManifest(home: URL, fileManager: FileManager = .default) -> InstallManifest? {
        let url = artifactPaths(home: home).manifest
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(InstallManifest.self, from: data)
    }

    static func legacyManifest(home: URL) -> InstallManifest {
        let paths = artifactPaths(home: home)
        return InstallManifest(
            installPrefix: paths.supportDirectory.path,
            launchdLabels: ["live.streamvc.macprovider", "live.streamvc.macprovider-watchdog"],
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
            ]
        )
    }

    struct AllowedRemovalPaths {
        let plists: [String]
        let symlinks: [String]
        let binaries: [String]
        let dataDirs: [String]
    }

    static func allowedRemovalPaths(home: URL, manifest: InstallManifest) throws -> AllowedRemovalPaths {
        let paths = artifactPaths(home: home)
        let installPrefix = URL(fileURLWithPath: manifest.installPrefix)
        return AllowedRemovalPaths(
            plists: [
                paths.plist.path,
                paths.watchdogPlist.path,
            ],
            symlinks: [
                paths.binary.path,
            ],
            binaries: [
                installPrefix.appendingPathComponent("macprovider-cli").path,
            ],
            dataDirs: [
                installPrefix.path,
                paths.logsDirectory.path,
                paths.watchdogDirectory.path,
            ]
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
