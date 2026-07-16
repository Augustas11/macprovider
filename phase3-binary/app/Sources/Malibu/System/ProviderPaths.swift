import Foundation

// Filesystem layout used by the App track. Config path (~/.config/macprovider/config.yaml)
// is shared with the CLI track intentionally so both tracks agree on where the daemon
// reads secrets. Everything else lives under the app's own namespace so uninstall stays
// clean (see SPEC-025 §7).

struct ProviderPaths {
    let configFile: URL          // ~/.config/macprovider/config.yaml (shared with CLI track)
    let controlSocket: URL       // $TMPDIR/macprovider-cli/ctl.sock (CLI-owned, 0600)
    let cliLogFile: URL          // ~/Library/Logs/malibu/malibu-cli.log
    let launchdStdoutLog: URL    // ~/Library/Logs/macprovider/macprovider.out.log
    let launchdStderrLog: URL    // ~/Library/Logs/macprovider/macprovider.err.log
    let appSupport: URL          // ~/Library/Application Support/Malibu
    let appMarkerFile: URL       // ~/Library/Application Support/Malibu/.installed-by-app
    let onboardingStateFile: URL // ~/Library/Application Support/Malibu/onboarding.json
    let downloadsDirectory: URL  // ~/Library/Application Support/Malibu/Downloads

    static let current: ProviderPaths = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home
            .appendingPathComponent("Library/Application Support/Malibu", isDirectory: true)
        return ProviderPaths(
            configFile: home.appendingPathComponent(".config/macprovider/config.yaml"),
            controlSocket: FileManager.default.temporaryDirectory
                .appendingPathComponent("macprovider-cli", isDirectory: true)
                .appendingPathComponent("ctl.sock"),
            cliLogFile: home.appendingPathComponent("Library/Logs/malibu/malibu-cli.log"),
            launchdStdoutLog: home.appendingPathComponent("Library/Logs/macprovider/macprovider.out.log"),
            launchdStderrLog: home.appendingPathComponent("Library/Logs/macprovider/macprovider.err.log"),
            appSupport: appSupport,
            appMarkerFile: appSupport.appendingPathComponent(".installed-by-app"),
            onboardingStateFile: appSupport.appendingPathComponent("onboarding.json"),
            downloadsDirectory: appSupport.appendingPathComponent("Downloads", isDirectory: true)
        )
    }()

    var watchdogLog: URL {
        launchdStdoutLog.deletingLastPathComponent().appendingPathComponent("watchdog.log")
    }

    func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: cliLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}
