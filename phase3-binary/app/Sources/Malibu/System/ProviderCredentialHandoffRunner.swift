import Darwin
import Foundation
import Security

/// Stages compatibility YAML into CLI-owned Keychain custody. Malibu never
/// removes the YAML source; a restarted launchd provider performs the final
/// compare-and-remove only after authenticated coordinator admission.
enum ProviderCredentialHandoffRunner {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case cliNotFound
        case invalidCLI(String)
        case importFailed(Int32)
        case freshProcessVerificationFailed(Int32)
        case timedOut
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "The installed provider CLI does not support secure credential handoff yet. Update the provider and retry."
            case .invalidCLI(let reason):
                return "The installed provider CLI failed identity validation (\(reason)). Repair the provider and retry."
            case .importFailed(let code):
                return "The provider CLI could not stage its credential (exit \(code)); the original config was preserved."
            case .freshProcessVerificationFailed(let code):
                return "A fresh provider CLI process could not read the staged credential (exit \(code)); the original config was preserved."
            case .timedOut:
                return "The provider credential handoff timed out; the original config was preserved."
            case .launchFailed(let message):
                return "Could not start the provider credential handoff: \(message)"
            }
        }
    }

    private struct InstallManifest: Decodable {
        let binaryPath: String

        enum CodingKeys: String, CodingKey {
            case binaryPath = "binary_path"
        }
    }

    private struct ExecutableIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
    }

    private final class ProcessCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var timeoutBegan = false
        private let continuation: CheckedContinuation<Int32, Swift.Error>

        init(_ continuation: CheckedContinuation<Int32, Swift.Error>) {
            self.continuation = continuation
        }

        func beginTimeout() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            timeoutBegan = true
            return true
        }

        func finishProcessExit(_ status: Int32) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            let timedOut = timeoutBegan
            lock.unlock()
            if timedOut {
                continuation.resume(throwing: Error.timedOut)
            } else {
                continuation.resume(returning: status)
            }
        }

        func finish(_ result: Result<Int32, Swift.Error>) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    typealias CommandRunner = @Sendable (URL, [String]) async throws -> Int32

    static func migrate(configURL: URL) async throws {
        let installed = try resolveInstalledExecutable()
        let expectedIdentity = try validateInstalledExecutable(installed)
        let runValidated: CommandRunner = { executableURL, arguments in
            guard try validateInstalledExecutable(executableURL) == expectedIdentity else {
                throw Error.invalidCLI("executable changed during handoff")
            }
            let exitCode = try await runProcess(executableURL: executableURL, arguments: arguments)
            guard try validateInstalledExecutable(executableURL) == expectedIdentity else {
                throw Error.invalidCLI("executable changed during handoff")
            }
            return exitCode
        }
        let text = try String(contentsOf: configURL, encoding: .utf8)
        let containsToken = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.hasPrefix("provider_token:") }
        if containsToken {
            try await migrate(configURL: configURL, executableURL: installed, run: runValidated)
        } else {
            let verifyExit = try await runValidated(
                installed,
                ["credentials", "verify", "--config", configURL.path]
            )
            guard verifyExit == 0 else { throw Error.freshProcessVerificationFailed(verifyExit) }
        }
    }

    static func migrate(
        configURL: URL,
        executableURL: URL,
        run: @escaping CommandRunner
    ) async throws {
        let importExit = try await run(executableURL, ["credentials", "import", "--config", configURL.path])
        guard importExit == 0 else { throw Error.importFailed(importExit) }

        let verifyExit = try await run(executableURL, ["credentials", "verify", "--config", configURL.path])
        guard verifyExit == 0 else { throw Error.freshProcessVerificationFailed(verifyExit) }
    }

    static func resolveInstalledExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        let manifestURL = home.appendingPathComponent(
            "Library/Application Support/macprovider/install_manifest.json"
        )
        let candidate: URL
        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifest: InstallManifest
            do {
                manifest = try JSONDecoder().decode(InstallManifest.self, from: Data(contentsOf: manifestURL))
            } catch {
                throw Error.invalidCLI("install manifest is malformed")
            }
            guard manifest.binaryPath.hasPrefix("/") else {
                throw Error.invalidCLI("install manifest binary_path is not absolute")
            }
            candidate = URL(fileURLWithPath: manifest.binaryPath).standardizedFileURL
        } else {
            candidate = home.appendingPathComponent("macprovider/macprovider-cli").standardizedFileURL
        }
        guard candidate.lastPathComponent == "macprovider-cli" else {
            throw Error.invalidCLI("unexpected executable name")
        }
        guard fileManager.isExecutableFile(atPath: candidate.path) else {
            throw Error.cliNotFound
        }
        return candidate
    }

    private static func validateInstalledExecutable(_ executableURL: URL) throws -> ExecutableIdentity {
        var info = stat()
        guard lstat(executableURL.path, &info) == 0 else { throw Error.cliNotFound }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw Error.invalidCLI("executable is not a regular file")
        }
        guard info.st_uid == geteuid() else {
            throw Error.invalidCLI("executable is not owned by the current user")
        }
        guard info.st_mode & mode_t(0o022) == 0 else {
            throw Error.invalidCLI("executable is group- or world-writable")
        }

        guard let currentCodeURL = Bundle.main.executableURL else {
            throw Error.invalidCLI("Malibu executable path is unavailable")
        }
        var currentStaticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(currentCodeURL as CFURL, [], &currentStaticCode) == errSecSuccess,
              let currentStaticCode else {
            throw Error.invalidCLI("Malibu static signing identity is unavailable")
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(currentStaticCode, [], &signingInfo) == errSecSuccess,
              let infoDictionary = signingInfo as? [String: Any],
              let teamID = infoDictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              teamID.range(of: #"^[A-Z0-9]+$"#, options: .regularExpression) != nil else {
            throw Error.invalidCLI("Malibu Team ID is unavailable")
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw Error.invalidCLI("code object could not be created")
        }
        let requirementText = "identifier \"live.streamvc.macprovider.cli\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                requirement
              ) == errSecSuccess else {
            throw Error.invalidCLI("signature, Team ID, or designated identifier mismatch")
        }
        return ExecutableIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size)
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 15
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let completion = ProcessCompletion(continuation)

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = [
                "HOME": NSHomeDirectory(),
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            process.terminationHandler = { terminated in
                completion.finishProcessExit(terminated.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                completion.finish(.failure(Error.launchFailed(error.localizedDescription)))
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard completion.beginTimeout() else { return }
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    completion.finish(.failure(Error.timedOut))
                }
            }
        }
    }
}
