import Darwin
import Foundation

enum ReadyStatus: Equatable {
    case ready
    case processExited(rc: Int, stderrTail: String)
    case timeout(lastError: String)
}

/// Outcome of `CandidateProviderRunner.stop(graceSeconds:)`. Closes round-1
/// audit A.1 (QUESTION): the prior void return forced Step 7 to discover
/// stuck providers via the next `start()` failing with `alreadyRunning`. The
/// explicit `.stuck` case lets the caller record a clear failure or decide
/// whether to escalate (Step 5's launchd path may, Step 7's iteration will
/// not — v1 forbids SIGKILL).
enum StopResult: Equatable {
    case stopped
    case stuck(pid: Int32)
}

enum CandidateProviderRunnerError: Error, Equatable, CustomStringConvertible {
    case alreadyRunning(pid: Int32)
    case notStarted
    case invalidCurrentExecutable
    case invalidKvBits(Int)
    case invalidPort(Int)
    case invalidMaxContext(Int)
    case invalidMaxBatch(Int)

    var description: String {
        switch self {
        case .alreadyRunning(let pid):
            return "candidate provider already running with pid \(pid)"
        case .notStarted:
            return "candidate provider has not been started"
        case .invalidCurrentExecutable:
            return "could not resolve current macprovider-cli executable path"
        case .invalidKvBits(let value):
            return "--kv-bits \(value) invalid; must be 4 or 8"
        case .invalidPort(let value):
            return "--port \(value) invalid; must be in 1...65535"
        case .invalidMaxContext(let value):
            return "--max-context \(value) must be >= 1"
        case .invalidMaxBatch(let value):
            return "--max-batch \(value) must be >= 1"
        }
    }
}

final class CandidateProviderRunner {
    private let providerBinaryPath: String
    private let logDirectory: URL
    private let session: URLSession
    private let stateLock = NSLock()
    private var current: RunningProvider?

    init(
        providerBinaryPath: String? = nil,
        logDirectory: URL = CandidateProviderRunner.defaultLogDirectory,
        session: URLSession = .shared
    ) throws {
        if let providerBinaryPath {
            self.providerBinaryPath = Self.absolutePath(providerBinaryPath)
        } else {
            self.providerBinaryPath = try Self.defaultProviderBinaryPath()
        }
        self.logDirectory = logDirectory
        self.session = session
    }

    func start(
        model: String,
        port: Int,
        kvBits: Int? = nil,
        maxContext: Int? = nil,
        maxBatch: Int? = nil
    ) throws {
        let arguments = try Self.serveArguments(
            model: model,
            port: port,
            kvBits: kvBits,
            maxContext: maxContext,
            maxBatch: maxBatch
        )

        stateLock.lock()
        defer { stateLock.unlock() }

        if let current {
            if current.process.isRunning {
                throw CandidateProviderRunnerError.alreadyRunning(pid: current.process.processIdentifier)
            }
            current.finishLogging()
            self.current = nil
        }

        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logFileURL = Self.logFileURL(model: model, port: port, in: logDirectory)
        try Data().write(to: logFileURL, options: .atomic)
        let logFileHandle = try FileHandle(forWritingTo: logFileURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: providerBinaryPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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

        do {
            try process.run()
            current = running
        } catch {
            // Closes round-1 audit B.1 (MAJOR): the prior `finishLogging()`
            // call drained pipe read ends via `readDataToEndOfFile()`. When
            // `process.run()` throws BEFORE fork/exec, the pipe write ends
            // are still open in the parent, so the read waits for an EOF
            // that never arrives — a 2-second hang in codex's local repro
            // for a missing-binary case. `discardLogging` does NOT drain
            // the pipes; their FDs close on `Pipe` deinit.
            running.discardLogging(reason: "\(error)")
            throw error
        }
    }

    func waitForReady(timeout: TimeInterval) async throws -> ReadyStatus {
        let provider = try currentProvider()
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = "not checked yet"

        while Date() < deadline {
            if !provider.process.isRunning {
                clearCurrentIfSame(provider)
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
                            clearCurrentIfSame(provider)
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
                clearCurrentIfSame(provider)
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
            provider.process.terminate()
        }

        let deadline = Date().addingTimeInterval(max(0, graceSeconds))
        while Date() < deadline {
            if !provider.process.isRunning && !MacProviderPortProbe.isOpen(provider.port) {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let portHeld = MacProviderPortProbe.isOpen(provider.port)
        if portHeld {
            let warning = "warning: candidate provider port \(provider.port) remained held after \(graceSeconds)s grace"
            provider.appendLogLine(warning)
            FileHandle.standardError.write(Data(("\(warning)\n").utf8))
        }

        if !provider.process.isRunning {
            clearCurrentIfSame(provider)
            return .stopped
        }
        // Closes round-1 audit A.1 (QUESTION): the prior void return left
        // the caller to discover stuck providers via the next start()
        // failing with `alreadyRunning`. Returning .stuck lets Step 7
        // record a clear failure. NO SIGKILL escalation in v1 per the
        // BUILD prompt; `current` intentionally stays set so the next
        // start() honors the single-provider invariant.
        return .stuck(pid: provider.process.processIdentifier)
    }

    func activeLogFileURL() -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return current?.logFileURL
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
        maxBatch: Int?
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
            "--model", model,
            "--port", String(port),
        ]
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

    private static func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
            .standardizedFileURL
            .path
    }

}

private final class RunningProvider: @unchecked Sendable {
    let process: Process
    let port: Int
    let logFileURL: URL
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    let stderrTail = ProcessOutputTail(limit: 8_192)

    private let logFileHandle: FileHandle
    private let logQueue = DispatchQueue(label: "macprovider.autotune.provider-log")
    private var closed = false

    init(
        process: Process,
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
            self.logFileHandle.write(data)
        }
    }

    func finishLogging() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutRemainder = process.isRunning ? Data() : stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrRemainder = process.isRunning ? Data() : stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !stderrRemainder.isEmpty {
            stderrTail.append(stderrRemainder)
        }
        logQueue.sync {
            guard !closed else { return }
            if !stdoutRemainder.isEmpty {
                logFileHandle.write(stdoutRemainder)
            }
            if !stderrRemainder.isEmpty {
                logFileHandle.write(stderrRemainder)
            }
            logFileHandle.synchronizeFile()
            logFileHandle.closeFile()
            closed = true
        }
    }

    /// Cleanup variant for the spawn-failure path: the subprocess never
    /// launched, so the pipe write ends are still open in the parent.
    /// Draining the read ends via `readDataToEndOfFile()` (as
    /// `finishLogging()` would) hangs waiting for an EOF that never
    /// arrives. This variant clears readability handlers and closes the
    /// log file with a short failure note. Pipe FDs close on `Pipe`
    /// deinit when the `RunningProvider` is released.
    /// Closes round-1 audit B.1 (MAJOR).
    func discardLogging(reason: String) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        logQueue.sync {
            guard !closed else { return }
            let line = "process spawn failed: \(reason)\n"
            logFileHandle.write(Data(line.utf8))
            logFileHandle.synchronizeFile()
            logFileHandle.closeFile()
            closed = true
        }
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
