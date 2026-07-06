import Foundation

/// Runs the public CLI-track `install.sh` non-interactively from Malibu.app.
/// Option A onboarding: Malibu delegates install/autotune/launchd to the script.
enum CLIInstallRunner {
    enum Error: Swift.Error, LocalizedError {
        case installScriptNotFound
        case nonZeroExit(Int32)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .installScriptNotFound:
                return "The bundled macprovider installer script was not found."
            case let .nonZeroExit(code):
                return "Provider install failed (exit \(code)). See the log above for details."
            case let .launchFailed(message):
                return "Could not start the provider installer: \(message)"
            }
        }
    }

    /// Invokes `install.sh` with `MACPROVIDER_NO_PROMPT=1`. Delivers stdout/stderr
    /// lines to `onLogLine` on the main actor.
    static func run(onLogLine: @escaping @MainActor (String) -> Void) async throws {
        let scriptURL = try resolveInstallScriptURL()
        let runnableURL = try materializeRunnableScript(from: scriptURL)
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [runnableURL.path]
                process.standardOutput = stdout
                process.standardError = stderr

                var environment = ProcessInfo.processInfo.environment
                environment["MACPROVIDER_NO_PROMPT"] = "1"
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
        guard exitCode == 0 else {
            throw Error.nonZeroExit(exitCode)
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

    /// Bundle resources are not guaranteed executable; copy to a temp path with +x.
    private static func materializeRunnableScript(from source: URL) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-install-\(UUID().uuidString).sh")
        try FileManager.default.copyItem(at: source, to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
        return temp
    }
}
