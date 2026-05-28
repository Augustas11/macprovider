import ArgumentParser
import Darwin
import Foundation

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Stop macprovider-cli and remove installed artifacts."
    )

    @Flag(help: "Remove config and logs without prompting.")
    var removeConfigAndLogs = false

    @Flag(help: "Do not prompt before keeping or removing config and logs.")
    var yes = false

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var warnings: [String] = []
        let plist = home.appendingPathComponent("Library/LaunchAgents/live.streamvc.macprovider.plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            try runProcess("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())", "live.streamvc.macprovider"], allowFailure: true)
            removeIfPresent(plist, warnings: &warnings)
        }

        let binary = home.appendingPathComponent(".local/bin/macprovider-cli")
        removeIfPresent(binary, warnings: &warnings)

        let shouldRemoveState: Bool
        if removeConfigAndLogs {
            shouldRemoveState = true
        } else if yes {
            shouldRemoveState = false
        } else {
            print("Remove configuration and logs? [y/N] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            shouldRemoveState = answer == "y" || answer == "yes"
        }

        if shouldRemoveState {
            removeIfPresent(home.appendingPathComponent(".config/macprovider"), warnings: &warnings)
            removeIfPresent(home.appendingPathComponent(".local/share/macprovider"), warnings: &warnings)
            removeIfPresent(home.appendingPathComponent("Library/Logs/macprovider"), warnings: &warnings)
        }

        try removePathMarker(from: home.appendingPathComponent(".zshrc"))
        for warning in warnings {
            print("warning: \(warning)")
        }
        print("macprovider-cli has been uninstalled.")
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
