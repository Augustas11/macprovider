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
        let plist = paths.plist
        if FileManager.default.fileExists(atPath: plist.path) {
            try runProcess("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", "live.streamvc.macprovider"], allowFailure: true)
            removeIfPresent(plist, warnings: &warnings)
        }

        removeIfPresent(paths.binary, warnings: &warnings)
        removeIfPresent(paths.supportDirectory, warnings: &warnings)
        removeIfPresent(paths.logsDirectory, warnings: &warnings)

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
        let cacheDirectory: URL
    }

    static func artifactPaths(home: URL) -> ArtifactPaths {
        ArtifactPaths(
            binary: home.appendingPathComponent(".local/bin/macprovider-cli"),
            supportDirectory: home.appendingPathComponent("macprovider"),
            logsDirectory: home.appendingPathComponent("Library/Logs/macprovider"),
            plist: home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist"),
            cacheDirectory: home.appendingPathComponent(".cache/macprovider")
        )
    }

    private func removeIfPresent(_ url: URL, warnings: inout [String]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            warnings.append("failed to remove \(url.path): \(error)")
        }
    }

    private func runProcess(_ executable: String, arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            throw NSError(
                domain: "macprovider.uninstall",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) exited with status \(process.terminationStatus)"]
            )
        }
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
