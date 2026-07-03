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
        // Merged over the parent process's env (which supplies PATH/HOME/etc).
        // MACPROVIDER_PROVIDER_TOKEN belongs here so the token never touches
        // config.yaml or the argv (which is visible in `ps`).
        let extraEnvironment: [String: String]
    }

    private let launch: Launch
    private var process: Process?
    private var logHandle: FileHandle?
    private var restartAttempts: Int = 0
    private var restartBackoffSeconds: [TimeInterval] = [1, 2, 5, 15, 60]

    var onUnexpectedExit: (@Sendable (Int32) -> Void)?

    init(launch: Launch) {
        self.launch = launch
    }

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

        var env = ProcessInfo.processInfo.environment
        for (k, v) in launch.extraEnvironment { env[k] = v }
        proc.environment = env

        proc.standardOutput = handle
        proc.standardError = handle

        proc.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            let code = terminated.terminationStatus
            Task { @MainActor in
                self.process = nil
                self.onUnexpectedExit?(code)
            }
        }

        try proc.run()
        process = proc
        restartAttempts = 0
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

    func scheduleRestartWithBackoff(_ launcher: @Sendable @escaping () async -> Void) async {
        let delay = restartBackoffSeconds[min(restartAttempts, restartBackoffSeconds.count - 1)]
        restartAttempts += 1
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        await launcher()
    }
}
