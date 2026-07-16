import Foundation

enum CLIUpdateRunner {
    // Legacy repair pins exactly the CLI version this app shipped as. The
    // 1.8.40 arming is a cohort-bound recovery exception (Decision Entry 160)
    // for the stranded 1.8.30/1.8.32/1.8.39 test cohort. Later releases MUST
    // leave this constant unchanged — the exact-match interlock in
    // `strategy(...)` then disarms the bridge automatically — unless a new
    // decision entry authorizes re-arming with release-specific proof.
    static let legacyBootstrapTarget = "1.8.40"

    enum Strategy: Equatable {
        case installedCompatibilityCLI
        case pinnedInstaller(version: String)
    }

    enum Error: Swift.Error, LocalizedError {
        case cliNotFound
        case invalidInstalledVersion(String?)
        case legacyBootstrapUnavailable(appVersion: String?)
        case legacyBootstrapWouldDowngrade(installedVersion: String)
        case nonZeroExit(Int32)
        case rollbackRestored(Int32)
        case rollbackFailed(Int32)
        case readinessFailed
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "macprovider-cli was not found at the expected install path."
            case let .invalidInstalledVersion(version):
                return "Installed provider CLI version is invalid: \(version ?? "unknown")."
            case let .legacyBootstrapUnavailable(appVersion):
                return "This legacy provider requires Malibu v\(legacyBootstrapTarget) to install the complete compatibility set (running \(appVersion.map { "v\($0)" } ?? "an unknown app version"))."
            case let .legacyBootstrapWouldDowngrade(installedVersion):
                return "Malibu v\(legacyBootstrapTarget) will not downgrade provider CLI v\(installedVersion)."
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

    static func strategy(
        installedVersion: String?,
        compatibilitySetID: String?,
        bundledAppVersion: String?
    ) throws -> Strategy {
        guard let installedVersion,
              let normalizedInstalled = ProviderCLIVersion.strictNormalize(installedVersion) else {
            throw Error.invalidInstalledVersion(installedVersion)
        }
        let hasCompatibilitySet = compatibilitySetID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false
        let predatesCompatibilityUpdater = ProviderCLIVersion.compare(
            normalizedInstalled,
            ProviderCLIVersion.compatibilitySetReleaseFloor
        ) == .ascending
        guard predatesCompatibilityUpdater || !hasCompatibilitySet else {
            return .installedCompatibilityCLI
        }

        guard ProviderCLIVersion.compare(normalizedInstalled, legacyBootstrapTarget) != .descending else {
            throw Error.legacyBootstrapWouldDowngrade(installedVersion: normalizedInstalled)
        }
        guard let bundledAppVersion,
              ProviderCLIVersion.strictNormalize(bundledAppVersion) == legacyBootstrapTarget else {
            throw Error.legacyBootstrapUnavailable(appVersion: bundledAppVersion)
        }
        return .pinnedInstaller(version: "v\(legacyBootstrapTarget)")
    }

    static func run(
        installedVersion: String?,
        compatibilitySetID: String?,
        onLogLine: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let selectedStrategy = try strategy(
            installedVersion: installedVersion,
            compatibilitySetID: compatibilitySetID,
            bundledAppVersion: appVersion
        )
        try await runStrategyForTest(
            strategy: selectedStrategy,
            installedUpdate: {
                let executable = try resolveExecutableURL()
                try await runCommand(
                    executableURL: executable,
                    arguments: ["update"],
                    onLogLine: onLogLine
                )
            },
            pinnedInstall: { version in
                await onLogLine(
                    "[Malibu] Repairing the complete provider installation with signed \(version)."
                )
                try await CLIInstallRunner.run(
                    pinnedVersion: version,
                    onLogLine: onLogLine
                )
            },
            readinessCheck: { await waitForBuyerServing() }
        )
    }

    static func runStrategyForTest(
        strategy: Strategy,
        installedUpdate: @escaping @Sendable () async throws -> Void,
        pinnedInstall: @escaping @Sendable (String) async throws -> Void,
        readinessCheck: @escaping @Sendable () async -> Bool
    ) async throws {
        switch strategy {
        case .installedCompatibilityCLI:
            try await installedUpdate()
        case let .pinnedInstaller(version):
            try await pinnedInstall(version)
        }
        guard await readinessCheck() else {
            throw Error.readinessFailed
        }
    }

    static func runForTest(
        executableURL: URL,
        arguments: [String],
        onLogLine: @escaping @Sendable @MainActor (String) -> Void,
        readinessCheck: @escaping @Sendable () async -> Bool
    ) async throws {
        try await runCommand(
            executableURL: executableURL,
            arguments: arguments,
            onLogLine: onLogLine
        )
        guard await readinessCheck() else {
            throw Error.readinessFailed
        }
    }

    private static func runCommand(
        executableURL: URL,
        arguments: [String],
        onLogLine: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let environment = try updaterEnvironment(
            parentEnvironment: ProcessInfo.processInfo.environment
        )
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
    }

    static func updaterEnvironment(
        parentEnvironment: [String: String]
    ) throws -> [String: String] {
        // The installed updater owns release selection and mutation. Do not
        // forward app-launch tokens, repository/key overrides, shell startup,
        // dynamic-loader configuration, or test hooks into that authority.
        _ = parentEnvironment
        return try ProcessEnvironmentSanitizer.sanitized(
            from: [:],
            extraEnvironment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "TMPDIR": "/tmp",
                "LC_ALL": "C",
            ]
        )
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
