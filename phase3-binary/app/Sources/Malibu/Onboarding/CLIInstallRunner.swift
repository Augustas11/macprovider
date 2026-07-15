import Foundation

/// Runs the public CLI-track `install.sh` non-interactively from Malibu.app.
/// Option A onboarding: Malibu delegates install/autotune/launchd to the script.
enum CLIInstallRunner {
    enum Error: Swift.Error, LocalizedError {
        case installScriptNotFound
        case invalidPinnedVersion(String)
        case nonZeroExit(Int32)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .installScriptNotFound:
                return "The bundled macprovider installer script was not found."
            case let .invalidPinnedVersion(version):
                return "Provider install version pin is invalid: \(version)."
            case let .nonZeroExit(code):
                return "Provider install failed (exit \(code)). See the log above for details."
            case let .launchFailed(message):
                return "Could not start the provider installer: \(message)"
            }
        }
    }

    /// Invokes `install.sh` with `MACPROVIDER_NO_PROMPT=1`. Delivers stdout/stderr
    /// lines to `onLogLine` on the main actor.
    static func run(
        pinnedVersion: String? = nil,
        onLogLine: @escaping @Sendable @MainActor (String) -> Void
    ) async throws {
        let scriptURL = try resolveInstallScriptURL()
        let runnableURL = try materializeRunnableScript(from: scriptURL)
        defer { try? FileManager.default.removeItem(at: runnableURL) }
        let installPort = resolveInstallPort()
        let environment = try installerEnvironment(
            parentEnvironment: ProcessInfo.processInfo.environment,
            installPort: installPort,
            pinnedVersion: pinnedVersion
        )
        if let installPort {
            await onLogLine("[macprovider-install] Using local HTTP port \(installPort) for provider install.")
        }
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [runnableURL.path]
                process.standardOutput = stdout
                process.standardError = stderr

                process.environment = environment

                let emit: (Pipe) -> Void = { pipe in
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        let text = String(decoding: chunk, as: UTF8.self)
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
                continuation.resume(returning: process.terminationStatus)
            }
        }
        if exitCode == 0 {
            return
        }
        // Every non-zero installer exit leaves the durable transaction
        // uncommitted and triggers rollback. A healthy local process may be
        // the restored previous release, so it cannot prove this install won.
        throw Error.nonZeroExit(exitCode)
    }

    static func installerEnvironment(
        parentEnvironment: [String: String],
        installPort: Int?,
        pinnedVersion: String?
    ) throws -> [String: String] {
        // Deliberately do not inherit the parent environment. install.sh has
        // authority-changing knobs for repositories, public keys, acceptance
        // candidates, emergency rollback, paths, and launchd. Malibu supplies
        // only the values this invocation owns, and never forwards parent
        // tokens or dynamic-loader/shell configuration.
        _ = parentEnvironment
        var explicit = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": "/tmp",
            "LC_ALL": "C",
            "MACPROVIDER_NO_PROMPT": "1",
        ]
        if let installPort {
            explicit["MACPROVIDER_PORT"] = String(installPort)
        }
        if let pinnedVersion {
            guard let normalized = ProviderCLIVersion.strictNormalize(pinnedVersion) else {
                throw Error.invalidPinnedVersion(pinnedVersion)
            }
            explicit["MACPROVIDER_VERSION"] = "v\(normalized)"
        }
        return try ProcessEnvironmentSanitizer.sanitized(
            from: [:],
            extraEnvironment: explicit
        )
    }

    /// Reports whether an already-installed provider is locally healthy. This
    /// is used to resume onboarding, never to override a failed install exit.
    static func localInstallSucceeded() async -> Bool {
        guard let port = ProviderConfig.readHTTPPort(),
              ProviderConfig.readProviderID() != nil else {
            return false
        }
        let manifest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macprovider/install_manifest.json")
        let hasManifest = FileManager.default.isReadableFile(atPath: manifest.path)
        let launchdPlist = FileManager.default.isReadableFile(
            atPath: NSHomeDirectory() + "/Library/LaunchAgents/live.streamvc.macprovider.plist"
        )
        guard hasManifest || launchdPlist else { return false }
        return await InstalledProviderMonitor.isHealthy(port: port)
    }

    /// Human-readable hint for onboarding UI while `install.sh` runs long silent phases.
    enum ActivityMonitor {
        static func snapshot() -> String {
            let lines = macproviderProcessLines()
            if lines.contains(where: { $0.contains("autotune --recommend") }) {
                return "Benchmarking models for your Mac — often 10–30 minutes on first run. The log can look frozen; that is normal."
            }
            if let bench = lines.first(where: { $0.contains("serve --no-join") }) {
                let model = extractFlag("--model", from: bench) ?? "a candidate model"
                return "Testing \(shortModelName(model)) performance…"
            }
            if lines.contains(where: { $0.contains("models pull") || $0.contains("huggingface") }) {
                return "Downloading model weights from Hugging Face…"
            }
            let cliPath = NSHomeDirectory() + "/macprovider/macprovider-cli"
            if FileManager.default.isExecutableFile(atPath: cliPath) {
                return "Provider CLI installed. Running autotune and model checks next…"
            }
            if lines.contains(where: { $0.contains("curl") && $0.contains("github") }) {
                return "Downloading provider release from GitHub…"
            }
            return "Install in progress…"
        }

        private static func macproviderProcessLines() -> [String] {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-ax", "-o", "command="]
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return []
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            return text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.contains("macprovider-cli") && !$0.contains("/bin/ps") }
        }

        private static func extractFlag(_ flag: String, from command: String) -> String? {
            let parts = command.split(separator: " ").map(String.init)
            guard let index = parts.firstIndex(of: flag), index + 1 < parts.count else { return nil }
            return parts[index + 1]
        }

        private static func shortModelName(_ raw: String) -> String {
            if raw.contains("/") {
                return raw.split(separator: "/").last.map(String.init) ?? raw
            }
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw).lastPathComponent
            }
            return raw
        }
    }

    static func resolveInstallScriptURL() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "install", withExtension: "sh") {
            return bundled
        }
        let devRelative = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("dist/install.sh")
        if FileManager.default.isReadableFile(atPath: devRelative.path) {
            return devRelative
        }
        throw Error.installScriptNotFound
    }

    /// Port for `install.sh`: explicit env override, existing config, else a probed free port.
    /// Avoids exit 6 when the default 8080 is occupied (common on dev Macs running Node).
    static func resolveInstallPort(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        if let raw = environment["MACPROVIDER_PORT"], let port = Int(raw), port > 0 {
            return port
        }
        if let configured = ProviderConfig.readHTTPPort() {
            return configured
        }
        return try? FreePortProbe.probe()
    }

    /// Bundle resources are not guaranteed executable; copy to a temp path with +x.
    private static func materializeRunnableScript(from source: URL) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-install-\(UUID().uuidString).sh")
        try FileManager.default.copyItem(at: source, to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
        return temp
    }
}
