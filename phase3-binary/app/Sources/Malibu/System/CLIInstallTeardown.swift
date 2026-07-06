import Foundation

/// Stops the launchd-managed CLI install that Malibu onboarding created via install.sh.
enum CLIInstallTeardown {
    struct Result: Equatable {
        var warnings: [String]
        var succeeded: Bool { warnings.isEmpty }
    }

    @MainActor
    static func uninstallBackgroundProvider(
        perform: (@MainActor () async throws -> Void)? = nil
    ) async -> Result {
        do {
            if let perform {
                try await perform()
            } else {
                let cliURL = try MalibuAgent.resolveCLIExecutable()
                try await runBundledUninstall(cliURL: cliURL)
            }
            return Result(warnings: [])
        } catch {
            return Result(warnings: ["CLI uninstall failed: \(error.localizedDescription)"])
        }
    }

    @MainActor
    private static func runBundledUninstall(cliURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let stderr = Pipe()
                process.executableURL = cliURL
                process.arguments = ["uninstall", "--yes"]
                process.environment = try? ProcessEnvironmentSanitizer.sanitized(
                    from: ProcessInfo.processInfo.environment
                )
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderr
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume()
                        return
                    }
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: NSError(
                            domain: "Malibu.CLIInstallTeardown",
                            code: Int(process.terminationStatus),
                            userInfo: [
                                NSLocalizedDescriptionKey: message?.isEmpty == false
                                    ? message!
                                    : "macprovider-cli uninstall exited \(process.terminationStatus)"
                            ]
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
