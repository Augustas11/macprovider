import Foundation

enum CLIUpdateRunner {
    enum Error: Swift.Error, LocalizedError {
        case cliNotFound
        case nonZeroExit(Int32)
        case rollbackRestored(Int32)
        case rollbackFailed(Int32)
        case readinessFailed
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "macprovider-cli was not found at the expected install path."
            case let .nonZeroExit(code):
                return "CLI update failed (exit \(code))."
            case let .rollbackRestored(code):
                return "Provider update failed; the previous release was restored (rollback_restored, exit \(code))."
            case let .rollbackFailed(code):
                return "Provider update and rollback both failed (rollback_failed, exit \(code))."
            case .readinessFailed:
                return "Provider update installed but did not reach buyer-serving readiness."
            case let .launchFailed(message):
                return "Could not start CLI update: \(message)"
            }
        }
    }

    static func installedCLIPath() -> String {
        NSHomeDirectory() + "/macprovider/macprovider-cli"
    }

    static func resolveExecutableURL() throws -> URL {
        let installed = URL(fileURLWithPath: installedCLIPath())
        if FileManager.default.isExecutableFile(atPath: installed.path) {
            return installed
        }
        if let override = ProcessInfo.processInfo.environment["MALIBU_CLI_PATH"], !override.isEmpty {
            #if DEBUG
            return URL(fileURLWithPath: override)
            #endif
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/macprovider-cli")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        throw Error.cliNotFound
    }

    static func run(onLogLine: @escaping @Sendable @MainActor (String) -> Void) async throws {
        let executable = try resolveExecutableURL()
        try await runForTest(
            executableURL: executable,
            arguments: ["update"],
            onLogLine: onLogLine,
            readinessCheck: { await waitForBuyerServing() }
        )
    }

    static func runForTest(
        executableURL: URL,
        arguments: [String],
        onLogLine: @escaping @Sendable @MainActor (String) -> Void,
        readinessCheck: @escaping @Sendable () async -> Bool
    ) async throws {
        let outputState = CLIUpdateOutputState()
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr

                var environment = ProcessInfo.processInfo.environment
                environment["HOME"] = NSHomeDirectory()
                if environment["PATH"]?.isEmpty != false {
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                }
                process.environment = environment

                let emit: (Pipe) -> Void = { pipe in
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        let text = String(decoding: chunk, as: UTF8.self)
                        outputState.append(text)
                        for line in text.split(whereSeparator: \.isNewline) {
                            let trimmed = String(line)
                            guard !trimmed.isEmpty else { continue }
                            Task { @MainActor in onLogLine(trimmed) }
                        }
                    }
                }
                emit(stdout)
                emit(stderr)

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Error.launchFailed(error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                for pipe in [stdout, stderr] {
                    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !tail.isEmpty {
                        let text = String(decoding: tail, as: UTF8.self)
                        outputState.append(text)
                        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                            Task { @MainActor in onLogLine(String(line)) }
                        }
                    }
                }
                continuation.resume(returning: process.terminationStatus)
            }
        }
        if exitCode != 0 {
            if outputState.containsRollbackRestored {
                throw Error.rollbackRestored(exitCode)
            }
            if outputState.containsRollbackFailed {
                throw Error.rollbackFailed(exitCode)
            }
            throw Error.nonZeroExit(exitCode)
        }
        guard await readinessCheck() else {
            throw Error.readinessFailed
        }
    }

    private static func waitForBuyerServing(timeout: TimeInterval = 90) async -> Bool {
        guard let port = ProviderConfig.readHTTPPort() else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            async let health = InstalledProviderMonitor.fetchHealth(port: port)
            async let status = InstalledProviderMonitor.fetchStatus(port: port)
            if await health?.ready == true, await status?.networkState == "buyer_serving" {
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                try await Task.sleep(nanoseconds: UInt64(min(2, remaining) * 1_000_000_000))
            } catch {
                return false
            }
        }
        return false
    }
}

private final class CLIUpdateOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""

    func append(_ text: String) {
        lock.lock()
        output.append(text)
        lock.unlock()
    }

    var containsRollbackRestored: Bool {
        lock.lock()
        defer { lock.unlock() }
        return output.contains("rollback_restored")
    }

    var containsRollbackFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return output.contains("rollback_failed")
    }
}
