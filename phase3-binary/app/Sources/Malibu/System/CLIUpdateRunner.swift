import Foundation

enum CLIUpdateRunner {
    enum Error: Swift.Error, LocalizedError {
        case cliNotFound
        case nonZeroExit(Int32)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "macprovider-cli was not found at the expected install path."
            case let .nonZeroExit(code):
                return "CLI update failed (exit \(code))."
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

    static func run(onLogLine: @escaping @MainActor (String) -> Void) async throws {
        let executable = try resolveExecutableURL()
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = executable
                process.arguments = ["update"]
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
        if exitCode != 0 {
            throw Error.nonZeroExit(exitCode)
        }
    }
}
