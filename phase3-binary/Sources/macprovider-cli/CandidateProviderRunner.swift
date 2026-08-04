import Darwin
import Foundation
import MacProviderCore

enum ReadyStatus: Equatable {
    case ready
    case processExited(rc: Int, stderrTail: String)
    case timeout(lastError: String)
}

/// Outcome of `CandidateProviderRunner.stop(graceSeconds:)`. Closes round-1
/// audit A.1 (QUESTION): the prior void return forced Step 7 to discover
/// stuck providers via the next `start()` failing with `alreadyRunning`. The
/// explicit `.stuck` case lets the caller record a clear failure after the
/// runner has already attempted graceful and isolated process-group teardown.
enum StopResult: Equatable {
    case stopped
    case stuck(pid: Int32)
}

enum CandidateProviderRunnerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(pid: Int32)
    case notStarted
    case invalidCurrentExecutable
    case spawnFailed(errno: Int32)
    case invalidKvBits(Int)
    case invalidPort(Int)
    case invalidMaxContext(Int)
    case invalidMaxBatch(Int)
    case invalidArtifactBinding(String)

    var description: String {
        switch self {
        case .alreadyRunning(let pid):
            return "candidate provider already running with pid \(pid)"
        case .notStarted:
            return "candidate provider has not been started"
        case .invalidCurrentExecutable:
            return "could not resolve current macprovider-cli executable path"
        case .spawnFailed(let errno):
            return "could not launch isolated candidate process: errno \(errno)"
        case .invalidKvBits(let value):
            return "--kv-bits \(value) invalid; must be 4 or 8"
        case .invalidPort(let value):
            return "--port \(value) invalid; must be in 1...65535"
        case .invalidMaxContext(let value):
            return "--max-context \(value) must be >= 1"
        case .invalidMaxBatch(let value):
            return "--max-batch \(value) must be >= 1"
        case .invalidArtifactBinding(let reason):
            return "candidate artifact binding invalid: \(reason)"
        }
    }
}

final class CandidateProviderRunner {
    private let providerBinaryPath: String
    private let configPath: String?
    private let ownedCandidateConfigRoot: URL?
    private let logDirectory: URL
    private let session: URLSession
    private let stateLock = NSLock()
    private var current: RunningProvider?

    init(
        providerBinaryPath: String? = nil,
        configPath: String? = nil,
        logDirectory: URL = CandidateProviderRunner.defaultLogDirectory,
        session: URLSession = .shared
    ) throws {
        if let providerBinaryPath {
            self.providerBinaryPath = Self.absolutePath(providerBinaryPath)
        } else {
            self.providerBinaryPath = try Self.defaultProviderBinaryPath()
        }
        if let configPath {
            self.configPath = Self.absolutePath(configPath)
            self.ownedCandidateConfigRoot = nil
        } else {
            let root = try Self.makeCandidateConfigRoot()
            self.configPath = root.appendingPathComponent("candidate.yaml").path
            self.ownedCandidateConfigRoot = root
        }
        self.logDirectory = logDirectory
        self.session = session
    }

    deinit {
        if let ownedCandidateConfigRoot {
            try? FileManager.default.removeItem(at: ownedCandidateConfigRoot)
        }
    }

    func start(
        model: String,
        port: Int,
        kvBits: Int? = nil,
        maxContext: Int? = nil,
        maxBatch: Int? = nil
    ) throws {
        try start(
            model: model,
            port: port,
            kvBits: kvBits,
            maxContext: maxContext,
            maxBatch: maxBatch,
            artifactBinding: nil
        )
    }

    func start(
        model: String,
        port: Int,
        kvBits: Int? = nil,
        maxContext: Int? = nil,
        maxBatch: Int? = nil,
        artifactBinding: CandidateArtifactBinding?
    ) throws {
        let artifactArguments = try Self.artifactArguments(for: model, binding: artifactBinding)
        let arguments = try Self.serveArguments(
            model: model,
            port: port,
            kvBits: kvBits,
            maxContext: maxContext,
            maxBatch: maxBatch,
            configPath: configPath,
            modelArtifactPath: artifactArguments.path,
            modelArtifactSHA256: artifactArguments.sha256
        )

        try prepareForStart()

        stateLock.lock()
        defer { stateLock.unlock() }
        if let current {
            // A concurrent start may have won the ownership race while the
            // stale exited group was being reaped. Never replace that handle.
            throw CandidateProviderRunnerError.alreadyRunning(pid: current.process.processIdentifier)
        }

        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        Self.pruneLogs(in: logDirectory)
        let logFileURL = Self.logFileURL(model: model, port: port, in: logDirectory)
        try Data().write(to: logFileURL, options: .atomic)
        let logFileHandle = try FileHandle(forWritingTo: logFileURL)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process: CandidateChildProcess
        do {
            process = try CandidateChildProcess.spawn(
                executablePath: providerBinaryPath,
                arguments: arguments,
                environment: Self.sanitizedChildEnvironment(),
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        } catch {
            logFileHandle.write(Data("process spawn failed: \(error)\n".utf8))
            logFileHandle.synchronizeFile()
            logFileHandle.closeFile()
            throw error
        }

        let running = RunningProvider(
            process: process,
            port: port,
            logFileURL: logFileURL,
            logFileHandle: logFileHandle,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        running.appendLogLine("$ \(providerBinaryPath) \(arguments.joined(separator: " "))")
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak running] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            running?.appendLog(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak running] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            running?.stderrTail.append(data)
            running?.appendLog(data)
        }
        current = running
    }

    static func sanitizedChildEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // Candidate children must inherit only the portable process
        // environment. In particular, do not pass MACPROVIDER_CONFIG or any
        // credential/identity override from the serving process.
        return (try? ProcessEnvironmentSanitizer.sanitized(from: environment)) ?? [:]
    }

    func waitForReady(timeout: TimeInterval) async throws -> ReadyStatus {
        let provider = try currentProvider()
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = "not checked yet"

        while Date() < deadline {
            if !provider.process.isRunning {
                cleanupExitedProvider(provider)
                return .processExited(
                    rc: Int(provider.process.terminationStatus),
                    stderrTail: provider.stderrTail.snapshot()
                )
            }

            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(provider.port)/v1/models")!)
            request.httpMethod = "GET"
            request.timeoutInterval = 1

            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 200 {
                        // Closes round-1 audit C.1 (MAJOR): the prior code
                        // returned `.ready` immediately on HTTP 200 without
                        // re-checking process state. If the provider serves
                        // /v1/models 200 and then crashes before
                        // `waitForReady` returns, Step 7 would begin
                        // measurement against a dead process and
                        // misclassify the startup failure as a probe failure.
                        // The post-200 isRunning check fails fast as
                        // `.processExited` in that race.
                        if !provider.process.isRunning {
                            cleanupExitedProvider(provider)
                            return .processExited(
                                rc: Int(provider.process.terminationStatus),
                                stderrTail: provider.stderrTail.snapshot()
                            )
                        }
                        return .ready
                    }
                    lastError = "HTTP \(http.statusCode)"
                } else {
                    lastError = "non-HTTP response"
                }
            } catch {
                lastError = error.localizedDescription
            }

            if !provider.process.isRunning {
                cleanupExitedProvider(provider)
                return .processExited(
                    rc: Int(provider.process.terminationStatus),
                    stderrTail: provider.stderrTail.snapshot()
                )
            }

            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        return .timeout(lastError: lastError)
    }

    @discardableResult
    func stop(graceSeconds: Double) -> StopResult {
        guard let provider = currentProviderIfAny() else {
            return .stopped
        }

        if provider.process.isRunning {
            // The process group is the ownership boundary established at
            // spawn time. Graceful teardown must use the same boundary so a
            // helper that does not hold the HTTP port cannot survive a clean
            // leader exit.
            if !provider.process.send(signal: SIGTERM, toProcessGroup: true) {
                provider.process.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while Date() < deadline {
            if !provider.process.isRunning &&
                !MacProviderPortProbe.isOpen(provider.port) &&
                !provider.process.isProcessGroupRunning {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let portHeld = MacProviderPortProbe.isOpen(provider.port)
        let groupHeld = provider.process.isProcessGroupRunning
        if portHeld || groupHeld {
            let warning = "warning: candidate provider remained active after \(graceSeconds)s grace (port_held=\(portHeld) process_group_held=\(groupHeld))"
            provider.appendLogLine(warning)
            FileHandle.standardError.write(Data(("\(warning)\n").utf8))
        }

        if !provider.process.isRunning && !portHeld && !groupHeld {
            clearCurrentIfSame(provider)
            return .stopped
        }

        // A model server can ignore SIGTERM while draining or while blocked
        // in a native inference call. Do not leave a live candidate holding
        // the port: escalate the isolated process group, then verify both the
        // process and the port are gone before clearing runner state.
        let pid = provider.process.processIdentifier
        _ = provider.process.send(signal: SIGKILL, toProcessGroup: true)
        _ = provider.process.send(signal: SIGKILL, toProcessGroup: false)
        let killDeadline = Date().addingTimeInterval(2)
        while Date() < killDeadline {
            if !provider.process.isRunning &&
                !MacProviderPortProbe.isOpen(provider.port) &&
                !provider.process.isProcessGroupRunning {
                clearCurrentIfSame(provider)
                return .stopped
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return .stuck(pid: pid)
    }

    func activeLogFileURL() -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return current?.logFileURL
    }

    func activeProcessGroupIDForTesting() -> Int32? {
        guard let provider = currentProviderIfAny() else { return nil }
        return provider.process.processGroupID
    }

    func activeProcessIdentifierForTesting() -> Int32? {
        currentProviderIfAny()?.process.processIdentifier
    }

    func activeProcessIsRunningForTesting() -> Bool? {
        currentProviderIfAny()?.process.isRunning
    }

    static var defaultLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/macprovider/autotune-logs", isDirectory: true)
    }

    static func defaultProviderBinaryPath() throws -> String {
        if let executablePath = Bundle.main.executablePath, !executablePath.isEmpty {
            return absolutePath(executablePath)
        }
        if let argv0 = CommandLine.arguments.first, !argv0.isEmpty {
            return absolutePath(argv0)
        }
        throw CandidateProviderRunnerError.invalidCurrentExecutable
    }

    static func serveArguments(
        model: String,
        port: Int,
        kvBits: Int?,
        maxContext: Int?,
        maxBatch: Int?,
        configPath: String? = nil,
        modelArtifactPath: String? = nil,
        modelArtifactSHA256: String? = nil
    ) throws -> [String] {
        guard (1...65_535).contains(port) else {
            throw CandidateProviderRunnerError.invalidPort(port)
        }
        if let kvBits, kvBits != 4 && kvBits != 8 {
            throw CandidateProviderRunnerError.invalidKvBits(kvBits)
        }
        if let maxContext, maxContext < 1 {
            throw CandidateProviderRunnerError.invalidMaxContext(maxContext)
        }
        if let maxBatch, maxBatch < 1 {
            throw CandidateProviderRunnerError.invalidMaxBatch(maxBatch)
        }

        var arguments = [
            "serve",
            "--no-join",
            "--autotune-candidate",
            "--model", model,
            "--port", String(port),
        ]
        if let configPath, !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--config", absolutePath(configPath)])
        }
        if let modelArtifactPath, !modelArtifactPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--model-artifact-path", absolutePath(modelArtifactPath)])
        }
        if let modelArtifactSHA256, !modelArtifactSHA256.isEmpty {
            arguments.append(contentsOf: ["--model-artifact-sha256", modelArtifactSHA256])
        }
        if let kvBits {
            arguments.append(contentsOf: ["--kv-bits", String(kvBits)])
        }
        if let maxContext {
            arguments.append(contentsOf: ["--max-context", String(maxContext)])
        }
        if let maxBatch {
            arguments.append(contentsOf: ["--max-batch", String(maxBatch)])
        }
        return arguments
    }

    static func safeModelName(_ model: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = model.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "model" : collapsed
    }

    private static func logFileURL(model: String, port: Int, in directory: URL) -> URL {
        // Round-1 audit I.1 (MINOR) closure: prior filename had only
        // second-resolution timestamp, so two starts of the same
        // model+port within one second collided and the second
        // `.atomic` write truncated the first log. Appending the first
        // 8 chars of a UUID gives ~32 bits of disambiguation per second.
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        return directory.appendingPathComponent("\(safeModelName(model))-\(port)-\(timestamp)-\(suffix).log")
    }

    private static func makeCandidateConfigRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("macprovider-autotune-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard chmod(root.path, mode_t(0o700)) == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw CocoaError(.fileWriteNoPermission)
        }
        let config = root.appendingPathComponent("candidate.yaml")
        let contents = """
        # Generated for an isolated autotune child. No provider credentials,
        # coordinator identity, endpoint, receipt, or production state paths.
        enable_receipts: false
        enable_warm_swap: false
        warmup_enabled: false
        losslessness_probe_enabled: false
        donor_mode: false
        auto_update_enabled: false
        max_concurrency_override: 1
        idle_prewarm:
          enabled: false
        """
        try Data(contents.utf8).write(to: config, options: .atomic)
        guard chmod(config.path, mode_t(0o600)) == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw CocoaError(.fileWriteNoPermission)
        }
        return root
    }

    private static func pruneLogs(in directory: URL, maxFiles: Int = 32, maxBytes: Int64 = 32 * 1024 * 1024) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let logs = urls.filter { $0.pathExtension == "log" }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        var totalBytes: Int64 = 0
        for (index, url) in logs.enumerated() {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if index >= maxFiles || totalBytes + size > maxBytes {
                try? FileManager.default.removeItem(at: url)
            } else {
                totalBytes += size
            }
        }
    }

    private static func artifactSHA256(for model: String) -> String? {
        guard let artifactDirectory = artifactDirectory(for: model) else { return nil }
        return try? ModelArtifactVerifier.canonicalArtifactHash(directory: artifactDirectory)
    }

    private static func artifactArguments(
        for model: String,
        binding: CandidateArtifactBinding?
    ) throws -> (path: String?, sha256: String?) {
        guard let binding else {
            return (
                path: artifactDirectory(for: model)?.path,
                sha256: artifactSHA256(for: model)
            )
        }
        guard binding.path.hasPrefix("/"),
              URL(fileURLWithPath: binding.path).standardizedFileURL.path == binding.path,
              binding.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        else {
            throw CandidateProviderRunnerError.invalidArtifactBinding("path or SHA-256 is not canonical")
        }
        let actual: String
        do {
            actual = try ModelArtifactVerifier.canonicalArtifactHash(
                directory: URL(fileURLWithPath: binding.path, isDirectory: true)
            )
        } catch {
            throw CandidateProviderRunnerError.invalidArtifactBinding("artifact could not be verified")
        }
        guard actual == binding.sha256 else {
            throw CandidateProviderRunnerError.invalidArtifactBinding("artifact SHA-256 changed before candidate launch")
        }
        return (path: binding.path, sha256: binding.sha256)
    }

    private static func artifactDirectory(for model: String) -> URL? {
        let candidatePath = absolutePath(model)
        var info = stat()
        if lstat(candidatePath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
            return URL(fileURLWithPath: candidatePath)
        }
        return try? ModelRuntime.localModelDirectory(for: model)
    }

    /// Test accessor for the log filename derivation; verifies the
    /// UUID-suffix collision resistance from round-1 audit I.1.
    static func logFileURLForTesting(model: String, port: Int) -> URL {
        logFileURL(model: model, port: port, in: defaultLogDirectory)
    }

    private func currentProvider() throws -> RunningProvider {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let current else {
            throw CandidateProviderRunnerError.notStarted
        }
        return current
    }

    private func currentProviderIfAny() -> RunningProvider? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return current
    }

    private func prepareForStart() throws {
        while let stale = currentProviderIfAny() {
            if stale.process.isRunning {
                throw CandidateProviderRunnerError.alreadyRunning(pid: stale.process.processIdentifier)
            }

            // The leader may have exited while a helper remains in the
            // session. Reap the entire ownership group before allowing a new
            // candidate; otherwise the old helper can survive a restart and
            // retain sockets or credentials inherited from the candidate.
            cleanupExitedProvider(stale)

            stateLock.lock()
            let stillOwned = current === stale
            let groupStillRunning = stale.process.isProcessGroupRunning
            if stillOwned && !groupStillRunning {
                current = nil
            }
            stateLock.unlock()

            if stillOwned {
                if groupStillRunning {
                    throw CandidateProviderRunnerError.alreadyRunning(pid: stale.process.processIdentifier)
                }
                stale.finishLogging()
            }
        }
    }

    private func clearCurrentIfSame(_ provider: RunningProvider) {
        stateLock.lock()
        let shouldClear = current === provider
        if shouldClear {
            current = nil
        }
        stateLock.unlock()

        if shouldClear {
            provider.finishLogging()
        }
    }

    private func cleanupExitedProvider(_ provider: RunningProvider) {
        guard !provider.process.isRunning else { return }
        if provider.process.isProcessGroupRunning {
            _ = provider.process.send(signal: SIGKILL, toProcessGroup: true)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, provider.process.isProcessGroupRunning {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        // Keep the provider handle if a detached helper still exists. The
        // caller's defer/stop path can then retry cleanup instead of losing
        // the only process-group handle when the leader exits first.
        if !provider.process.isProcessGroupRunning {
            clearCurrentIfSame(provider)
        }
    }

    private static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }

}

private final class CandidateChildProcess: @unchecked Sendable {
    let processIdentifier: Int32
    private let stateLock = NSLock()
    private var waitStatus: Int32?

    private init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    var isRunning: Bool {
        refreshWaitStatus()
        stateLock.lock()
        defer { stateLock.unlock() }
        return waitStatus == nil
    }

    var terminationStatus: Int32 {
        refreshWaitStatus()
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let waitStatus else { return 0 }
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        if signal != 0x7f {
            return 128 + signal
        }
        return 0
    }

    var processGroupID: Int32? {
        let groupID = getpgid(processIdentifier)
        return groupID >= 0 ? groupID : nil
    }

    func terminate() {
        _ = Darwin.kill(processIdentifier, SIGTERM)
    }

    @discardableResult
    func send(signal: Int32, toProcessGroup: Bool) -> Bool {
        let target = toProcessGroup ? -processIdentifier : processIdentifier
        return Darwin.kill(target, signal) == 0
    }

    var isProcessGroupRunning: Bool {
        let result = Darwin.kill(-processIdentifier, 0)
        return result == 0 || errno == EPERM
    }

    static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) throws -> CandidateChildProcess {
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw CandidateProviderRunnerError.spawnFailed(errno: EINVAL)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let stdoutReadFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWriteFD = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrReadFD = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWriteFD = stderrPipe.fileHandleForWriting.fileDescriptor
        var actionError = posix_spawn_file_actions_adddup2(&actions, stdoutWriteFD, STDOUT_FILENO)
        if actionError == 0 {
            actionError = posix_spawn_file_actions_addclose(&actions, stdoutReadFD)
        }
        if actionError == 0 {
            actionError = posix_spawn_file_actions_addclose(&actions, stdoutWriteFD)
        }
        if actionError == 0 {
            actionError = posix_spawn_file_actions_adddup2(&actions, stderrWriteFD, STDERR_FILENO)
        }
        if actionError == 0 {
            actionError = posix_spawn_file_actions_addclose(&actions, stderrReadFD)
        }
        if actionError == 0 {
            actionError = posix_spawn_file_actions_addclose(&actions, stderrWriteFD)
        }
        guard actionError == 0 else {
            throw CandidateProviderRunnerError.spawnFailed(errno: actionError)
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CandidateProviderRunnerError.spawnFailed(errno: EINVAL)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // Spawn suspended, establish a new session/process group atomically,
        // then resume. Process.run() has no spawn-attribute hook; setting the
        // group after launch races with exec and can silently fail with EPERM.
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETSID)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
            throw CandidateProviderRunnerError.spawnFailed(errno: EINVAL)
        }

        let executable = strdup(executablePath)
        let argvStorage = [executablePath] + arguments
        let argv = argvStorage.map { strdup($0) } + [nil]
        let envStorage = environment.map { "\($0.key)=\($0.value)" }
        let envp = envStorage.map { strdup($0) } + [nil]
        defer {
            free(executable)
            for entry in argv where entry != nil { free(entry) }
            for entry in envp where entry != nil { free(entry) }
        }

        var pid = pid_t()
        var mutableArgv = argv
        var mutableEnvp = envp
        let result = posix_spawn(
            &pid,
            executable,
            &actions,
            &attributes,
            &mutableArgv,
            &mutableEnvp
        )
        guard result == 0 else {
            throw CandidateProviderRunnerError.spawnFailed(errno: result)
        }

        // The child owns the duplicated write ends after spawn. Closing the
        // parent's copies is required for EOF to reach the log readers when
        // the child exits.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let child = CandidateChildProcess(processIdentifier: pid)
        guard child.send(signal: SIGCONT, toProcessGroup: false) else {
            _ = child.send(signal: SIGKILL, toProcessGroup: true)
            _ = child.send(signal: SIGKILL, toProcessGroup: false)
            throw CandidateProviderRunnerError.spawnFailed(errno: Int32(errno))
        }
        return child
    }

    private func refreshWaitStatus() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard waitStatus == nil else { return }
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier {
            waitStatus = status
        } else if result == -1, errno == ECHILD {
            // The child has already been reaped; it is no longer running.
            waitStatus = 0
        }
    }
}

private final class RunningProvider: @unchecked Sendable {
    private static let maxLogBytes = 1_048_576
    let process: CandidateChildProcess
    let port: Int
    let logFileURL: URL
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    let stderrTail = ProcessOutputTail(limit: 8_192)

    private let logFileHandle: FileHandle
    private let logQueue = DispatchQueue(label: "macprovider.autotune.provider-log")
    private var closed = false
    private var logBytesWritten = 0

    init(
        process: CandidateChildProcess,
        port: Int,
        logFileURL: URL,
        logFileHandle: FileHandle,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) {
        self.process = process
        self.port = port
        self.logFileURL = logFileURL
        self.logFileHandle = logFileHandle
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func appendLogLine(_ line: String) {
        appendLog(Data(("\(line)\n").utf8))
    }

    func appendLog(_ data: Data) {
        logQueue.async {
            guard !self.closed else { return }
            self.writeBounded(data)
        }
    }

    func finishLogging() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // A descendant may inherit the pipe and outlive the direct child.
        // Never wait for EOF here: it would deadlock readiness failure and
        // prevent the runner from reaching process-group teardown.
        let stdoutRemainder = drainAvailableData(from: stdoutPipe.fileHandleForReading)
        let stderrRemainder = drainAvailableData(from: stderrPipe.fileHandleForReading)
        if !stderrRemainder.isEmpty {
            stderrTail.append(stderrRemainder)
        }
        logQueue.sync {
            guard !closed else { return }
            if !stdoutRemainder.isEmpty {
                writeBounded(stdoutRemainder)
            }
            if !stderrRemainder.isEmpty {
                writeBounded(stderrRemainder)
            }
            logFileHandle.synchronizeFile()
            logFileHandle.closeFile()
            closed = true
        }
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()
    }

    private func drainAvailableData(from handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        let originalFlags = fcntl(descriptor, F_GETFL, 0)
        guard originalFlags >= 0 else { return Data() }
        _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
        defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                result.append(buffer, count: Int(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            break
        }
        return result
    }

    private func writeBounded(_ data: Data) {
        guard !data.isEmpty, logBytesWritten < Self.maxLogBytes else { return }
        let remaining = Self.maxLogBytes - logBytesWritten
        let bounded = data.count <= remaining ? data : data.prefix(remaining)
        logFileHandle.write(bounded)
        logBytesWritten += bounded.count
    }
}

private final class ProcessOutputTail: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var text = ""

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        let fragment = String(decoding: data, as: UTF8.self)
        lock.lock()
        text += fragment
        if text.count > limit {
            text = String(text.suffix(limit))
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}
