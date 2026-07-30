import Foundation

// Owns the macprovider-cli child process: launch, restart with backoff,
// route stdout/stderr to log file, expose an "unexpectedly exited" signal.

@MainActor
final class CLIChildProcess {
    struct Launch {
        let executable: URL
        let configPath: URL
        let controlSocketPath: URL
        let httpPort: Int?
        let logFileURL: URL
        // Merged over an allowlisted parent env. MACPROVIDER_PROVIDER_TOKEN
        // belongs here so the token never touches config.yaml or argv.
        let extraEnvironment: [String: String]
    }

    private let launch: Launch
    private var process: Process?
    private var logHandle: FileHandle?
    // AUDIT R1 CODE H2 fix: set by the owner before an intentional stop so the
    // terminationHandler does not fire onUnexpectedExit and race a reconnect.
    private var isStopping: Bool = false

    var onUnexpectedExit: (@Sendable (Int32) -> Void)?

    init(launch: Launch) {
        self.launch = launch
    }

    // Called by MalibuAgent.shutdown before terminate() to suppress the
    // reconnect scheduling that would otherwise re-launch after "Quit and
    // Uninstall".
    func markStopping() { isStopping = true }

    func start() throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(
            at: launch.logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: launch.logFileURL.path) {
            FileManager.default.createFile(atPath: launch.logFileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: launch.logFileURL)
        try handle.seekToEnd()
        logHandle = handle

        let proc = Process()
        proc.executableURL = launch.executable
        // Flag names must match phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
        // (ArgumentParser derives kebab-case from the camelCase @Option name).
        //
        // --enable-warm-swap is required: the CLI only opens the control socket when
        // warm-swap is enabled (see ServeCommand comment on `enableWarmSwap`).
        var args = [
            "--config", launch.configPath.path,
            "--ctl-socket-path", launch.controlSocketPath.path,
            "--enable-warm-swap",
            "--managed-by", "malibu-app"
        ]
        if let port = launch.httpPort {
            args.append(contentsOf: ["--port", "\(port)"])
        }
        proc.arguments = args

        proc.environment = try ProcessEnvironmentSanitizer.sanitized(extraEnvironment: launch.extraEnvironment)

        proc.standardOutput = handle
        proc.standardError = handle

        proc.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            let code = terminated.terminationStatus
            Task { @MainActor in
                self.process = nil
                // AUDIT R1 CODE H2: an intentional stop must not schedule a
                // reconnect. Otherwise Quit-and-Uninstall re-launches the
                // daemon during the delay before NSApp.terminate lands.
                guard !self.isStopping else { return }
                self.onUnexpectedExit?(code)
            }
        }

        try proc.run()
        process = proc
    }

    func stop(gracePeriod: TimeInterval) async {
        guard let proc = process else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(gracePeriod)
        while proc.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }

}
