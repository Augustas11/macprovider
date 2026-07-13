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
        // Merged over an allowlisted parent env. The provider bearer is NOT
        // carried here (see `providerToken`): the environment is captured by
        // KERN_PROCARGS2 and could be serialized to disk by installer recovery.
        let extraEnvironment: [String: String]
        // ADV-C1: the provider bearer, handed to the child over an anonymous
        // stdin pipe (--token-fd 0) so it never appears in argv or the initial
        // environment and is invisible to same-user KERN_PROCARGS2 inspection.
        let providerToken: String?

        init(
            executable: URL,
            configPath: URL,
            controlSocketPath: URL,
            httpPort: Int?,
            logFileURL: URL,
            extraEnvironment: [String: String] = [:],
            providerToken: String? = nil
        ) {
            self.executable = executable
            self.configPath = configPath
            self.controlSocketPath = controlSocketPath
            self.httpPort = httpPort
            self.logFileURL = logFileURL
            self.extraEnvironment = extraEnvironment
            self.providerToken = providerToken
        }
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
        proc.arguments = Self.buildArguments(launch: launch)

        proc.environment = try ProcessEnvironmentSanitizer.sanitized(extraEnvironment: launch.extraEnvironment)

        // ADV-C1: deliver the bearer over an anonymous stdin pipe. The read end
        // becomes the child's fd 0 (--token-fd 0); we write the token to the
        // write end after launch and close it so the CLI reads it to EOF. The
        // pipe is not part of argv or the environment, so KERN_PROCARGS2 (and
        // therefore installer recovery snapshots) never see the token.
        var tokenPipe: Pipe?
        if let token = launch.providerToken, !token.isEmpty {
            let pipe = Pipe()
            proc.standardInput = pipe.fileHandleForReading
            tokenPipe = pipe
        }

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

        // Write the bearer to the child's stdin and close our end so the CLI
        // sees EOF. Done after run() so the read end is already dup'd into the
        // child; closing the read end here (it lives on in the child) avoids
        // leaking the fd into our own process.
        if let tokenPipe, let token = launch.providerToken {
            let writer = tokenPipe.fileHandleForWriting
            try? writer.write(contentsOf: Data(token.utf8))
            try? writer.close()
            try? tokenPipe.fileHandleForReading.close()
        }
    }

    /// Build the CLI argument vector. Flag names must match
    /// phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift (ArgumentParser
    /// derives kebab-case from the camelCase @Option name).
    ///
    /// --enable-warm-swap is required: the CLI only opens the control socket when
    /// warm-swap is enabled (see ServeCommand comment on `enableWarmSwap`).
    /// --token-fd 0 is appended when a bearer is supplied over the stdin pipe.
    static func buildArguments(launch: Launch) -> [String] {
        var args = [
            "--config", launch.configPath.path,
            "--ctl-socket-path", launch.controlSocketPath.path,
            "--enable-warm-swap",
            "--managed-by", "malibu-app"
        ]
        if let port = launch.httpPort {
            args.append(contentsOf: ["--port", "\(port)"])
        }
        if let token = launch.providerToken, !token.isEmpty {
            args.append(contentsOf: ["--token-fd", "0"])
        }
        return args
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
