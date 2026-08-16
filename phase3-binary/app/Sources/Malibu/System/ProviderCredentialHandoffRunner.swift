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
        case statusFailed(Int32)
        case repairFailed(Int32)
        case admissionRecoveryFailed(Int32)
        case invalidOutput(String)
        case timedOut
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "The installed provider does not support this import yet. Update the provider and retry."
            case .invalidCLI:
                return "The installed provider could not be verified. Repair the provider and retry."
            case .importFailed(let code):
                return "The provider could not prepare the saved access for import (exit \(code)); the original setup was preserved."
            case .freshProcessVerificationFailed(let code):
                return "A restarted provider could not read the saved access (exit \(code)); the original setup was preserved."
            case .statusFailed(let code):
                return "The provider could not check saved access (exit \(code))."
            case .repairFailed(let code):
                return "The provider could not repair saved access (exit \(code))."
            case .admissionRecoveryFailed(let code):
                return "The provider could not repair network verification (exit \(code))."
            case .invalidOutput(let reason):
                return "The provider returned an incompatible import result (\(reason))."
            case .timedOut:
                return "Provider import timed out; the original setup was preserved."
            case .launchFailed(let message):
                return "Could not start provider import: \(message)"
            }
        }
    }

    struct CredentialSnapshot: Equatable, Sendable, Decodable {
        let contractVersion: Int
        let credentialStore: String
        let operation: String
        let providerID: String
        let source: String
        let condition: String
        let restartSafe: Bool
        let migrationPending: Bool
        let recoverable: Bool
        let action: String

        enum CodingKeys: String, CodingKey {
            case contractVersion = "contract_version"
            case credentialStore = "credential_store"
            case operation
            case providerID = "provider_id"
            case source
            case condition
            case restartSafe = "restart_safe"
            case migrationPending = "migration_pending"
            case recoverable
            case action
        }
    }

    struct CapturedCommandResult: Equatable, Sendable {
        let exitCode: Int32
        let standardOutput: Data
    }

    struct AdmissionRecoverySnapshot: Equatable, Sendable, Decodable {
        struct AdminRequest: Equatable, Sendable, Decodable {
            struct Body: Equatable, Sendable, Decodable {
                let providerID: String
                let candidatePublicKeySHA256: String
                let requestedUntil: String
                let reason: String
                let incidentID: String

                enum CodingKeys: String, CodingKey {
                    case providerID = "provider_id"
                    case candidatePublicKeySHA256 = "candidate_public_key_sha256"
                    case requestedUntil = "requested_until"
                    case reason
                    case incidentID = "incident_id"
                }
            }

            let method: String
            let path: String
            let body: Body
            let approvalPathTemplate: String

            enum CodingKeys: String, CodingKey {
                case method
                case path
                case body
                case approvalPathTemplate = "approval_path_template"
            }
        }

        let contractVersion: Int
        let operation: String
        let providerID: String
        let state: String
        let candidatePublicKeySHA256: String?
        let publicKeySHA256: String?
        let restartSafe: Bool
        let adminRequest: AdminRequest?
        let nextAction: String?

        enum CodingKeys: String, CodingKey {
            case contractVersion = "contract_version"
            case operation
            case providerID = "provider_id"
            case state
            case candidatePublicKeySHA256 = "candidate_public_key_sha256"
            case publicKeySHA256 = "public_key_sha256"
            case restartSafe = "restart_safe"
            case adminRequest = "admin_request"
            case nextAction = "next_action"
        }

        var approvalInstruction: String? {
            guard let adminRequest else { return nil }
            return "\(adminRequest.method) \(adminRequest.path) for incident \(adminRequest.body.incidentID), then have a distinct second operator approve \(adminRequest.approvalPathTemplate)."
        }

        var operatorRequest: String? {
            guard let adminRequest,
                  let body = try? JSONSerialization.data(withJSONObject: [
                      "provider_id": adminRequest.body.providerID,
                      "candidate_public_key_sha256": adminRequest.body.candidatePublicKeySHA256,
                      "requested_until": adminRequest.body.requestedUntil,
                      "reason": adminRequest.body.reason,
                      "incident_id": adminRequest.body.incidentID,
                  ], options: [.prettyPrinted, .sortedKeys]) else {
                return nil
            }
            return "\(adminRequest.method) \(adminRequest.path)\n\(String(decoding: body, as: UTF8.self))\nThen approve: \(adminRequest.approvalPathTemplate)"
        }
    }

    private struct InstallManifest: Decodable {
        let binaryPath: String
        let installPrefix: String?

        enum CodingKeys: String, CodingKey {
            case binaryPath = "binary_path"
            case installPrefix = "install_prefix"
        }
    }

    private struct ExecutableIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let codeDirectoryHash: Data
    }

    private enum ForcedTermination {
        case timeout
        case cancellation
        case failure(Swift.Error)
    }

    private final class ProcessCancellationBridge: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var action: (@Sendable () -> Void)?

        func register(_ action: @escaping @Sendable () -> Void) {
            lock.lock()
            if cancelled {
                lock.unlock()
                action()
                return
            }
            self.action = action
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return
            }
            cancelled = true
            let action = self.action
            self.action = nil
            lock.unlock()
            action?()
        }
    }

    private final class ProcessCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var forcedTermination: ForcedTermination?
        private let continuation: CheckedContinuation<Int32, Swift.Error>

        init(_ continuation: CheckedContinuation<Int32, Swift.Error>) {
            self.continuation = continuation
        }

        func beginTimeout() -> Bool {
            beginForcedTermination(.timeout)
        }

        func beginCancellation() -> Bool {
            beginForcedTermination(.cancellation)
        }

        func beginFailure(_ error: Swift.Error) -> Bool {
            beginForcedTermination(.failure(error))
        }

        private func beginForcedTermination(_ reason: ForcedTermination) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed, forcedTermination == nil else { return false }
            forcedTermination = reason
            return true
        }

        func finishProcessExit(_ status: Int32) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            let termination = forcedTermination
            lock.unlock()
            switch termination {
            case .timeout:
                continuation.resume(throwing: Error.timedOut)
            case .cancellation:
                continuation.resume(throwing: CancellationError())
            case .failure(let error):
                continuation.resume(throwing: error)
            case nil:
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

    private final class CapturedProcessCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var forcedTermination: ForcedTermination?
        private let continuation: CheckedContinuation<CapturedCommandResult, Swift.Error>

        init(_ continuation: CheckedContinuation<CapturedCommandResult, Swift.Error>) {
            self.continuation = continuation
        }

        func beginTimeout() -> Bool {
            beginForcedTermination(.timeout)
        }

        func beginCancellation() -> Bool {
            beginForcedTermination(.cancellation)
        }

        func beginFailure(_ error: Swift.Error) -> Bool {
            beginForcedTermination(.failure(error))
        }

        private func beginForcedTermination(_ reason: ForcedTermination) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed, forcedTermination == nil else { return false }
            forcedTermination = reason
            return true
        }

        func finishProcessExit(_ result: CapturedCommandResult) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            let termination = forcedTermination
            lock.unlock()
            switch termination {
            case .timeout:
                continuation.resume(throwing: Error.timedOut)
            case .cancellation:
                continuation.resume(throwing: CancellationError())
            case .failure(let error):
                continuation.resume(throwing: error)
            case nil:
                continuation.resume(returning: result)
            }
        }

        func finish(_ result: Result<CapturedCommandResult, Swift.Error>) {
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

    private final class BoundedOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var overflowed = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !overflowed else { return }
            guard data.count + chunk.count <= limit else {
                overflowed = true
                data.removeAll(keepingCapacity: false)
                return
            }
            data.append(chunk)
        }

        func snapshot() -> (data: Data, overflowed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, overflowed)
        }
    }

    typealias CommandRunner = @Sendable (URL, [String]) async throws -> Int32
    typealias CapturedCommandRunner = @Sendable (URL, [String]) async throws -> CapturedCommandResult
    typealias SigningInformationCopier = (
        SecStaticCode,
        SecCSFlags,
        UnsafeMutablePointer<CFDictionary?>
    ) -> OSStatus

    /// One production seam owns every signing-information read. Team ID and
    /// code-directory hash are extended signing metadata, so requesting them
    /// with an empty flag set does not reliably return them on macOS.
    static func signingInformation(
        for staticCode: SecStaticCode,
        copy: SigningInformationCopier = { code, flags, information in
            SecCodeCopySigningInformation(code, flags, information)
        }
    ) throws -> [String: Any] {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard copy(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            throw Error.invalidCLI("code signing metadata is unavailable")
        }
        return dictionary
    }

    static func credentialStatus(configURL: URL, expectedProviderID: String) async throws -> CredentialSnapshot {
        try await runCredentialCommand(
            configURL: configURL,
            operation: "status",
            expectedProviderID: expectedProviderID
        )
    }

    static func repairCredential(
        configURL: URL,
        expectedProviderID: String,
        previousServiceInstanceID: String?
    ) async throws -> CredentialSnapshot {
        try await runCredentialCommand(
            configURL: configURL,
            operation: "repair",
            expectedProviderID: expectedProviderID,
            proveRestart: true,
            previousServiceInstanceID: previousServiceInstanceID
        )
    }

    static func stageAdmissionIdentityRecovery(
        configURL: URL,
        expectedProviderID: String,
        incidentID: String,
        reason: String
    ) async throws -> AdmissionRecoverySnapshot {
        try await runAdmissionIdentityRecoveryCommand(
            configURL: configURL,
            expectedProviderID: expectedProviderID,
            incidentID: incidentID,
            reason: reason,
            activate: false,
            previousServiceInstanceID: nil
        )
    }

    static func activateAdmissionIdentityRecovery(
        configURL: URL,
        expectedProviderID: String,
        previousServiceInstanceID: String?
    ) async throws -> AdmissionRecoverySnapshot {
        try await runAdmissionIdentityRecoveryCommand(
            configURL: configURL,
            expectedProviderID: expectedProviderID,
            incidentID: nil,
            reason: nil,
            activate: true,
            previousServiceInstanceID: previousServiceInstanceID
        )
    }

    static func admissionIdentityRecoveryStatus(
        configURL: URL,
        expectedProviderID: String
    ) async throws -> AdmissionRecoverySnapshot {
        try await runAdmissionIdentityRecoveryStatusCommand(
            configURL: configURL,
            expectedProviderID: expectedProviderID
        )
    }

    static func stageAdmissionIdentityRecovery(
        configURL: URL,
        executableURL: URL,
        expectedProviderID: String,
        incidentID: String,
        reason: String,
        run: @escaping CapturedCommandRunner
    ) async throws -> AdmissionRecoverySnapshot {
        try await runAdmissionIdentityRecoveryCommand(
            configURL: configURL,
            executableURL: executableURL,
            expectedProviderID: expectedProviderID,
            incidentID: incidentID,
            reason: reason,
            activate: false,
            previousServiceInstanceID: nil,
            run: run
        )
    }

    static func activateAdmissionIdentityRecovery(
        configURL: URL,
        executableURL: URL,
        expectedProviderID: String,
        previousServiceInstanceID: String?,
        run: @escaping CapturedCommandRunner
    ) async throws -> AdmissionRecoverySnapshot {
        try await runAdmissionIdentityRecoveryCommand(
            configURL: configURL,
            executableURL: executableURL,
            expectedProviderID: expectedProviderID,
            incidentID: nil,
            reason: nil,
            activate: true,
            previousServiceInstanceID: previousServiceInstanceID,
            run: run
        )
    }

    static func admissionIdentityRecoveryStatus(
        configURL: URL,
        executableURL: URL,
        expectedProviderID: String,
        run: @escaping CapturedCommandRunner
    ) async throws -> AdmissionRecoverySnapshot {
        try decodeAdmissionIdentityRecoveryResult(
            try await run(executableURL, [
                "credentials", "admission-identity-recovery-status",
                "--config", configURL.path,
                "--expected-provider-id", expectedProviderID,
            ]),
            expectedProviderID: expectedProviderID,
            expectedStates: ["not_staged", "approval_required", "expired", "committed_cleanup"],
            expectedOperation: "admission_identity_recovery_status"
        )
    }

    static func credentialStatus(
        configURL: URL,
        executableURL: URL,
        expectedProviderID: String? = nil,
        proveRestart: Bool = false,
        previousServiceInstanceID: String? = nil,
        run: @escaping CapturedCommandRunner
    ) async throws -> CredentialSnapshot {
        try await runCredentialCommand(
            configURL: configURL,
            operation: "status",
            expectedProviderID: expectedProviderID,
            executableURL: executableURL,
            run: run
        )
    }

    static func repairCredential(
        configURL: URL,
        executableURL: URL,
        expectedProviderID: String? = nil,
        proveRestart: Bool = false,
        previousServiceInstanceID: String? = nil,
        run: @escaping CapturedCommandRunner
    ) async throws -> CredentialSnapshot {
        try await runCredentialCommand(
            configURL: configURL,
            operation: "repair",
            expectedProviderID: expectedProviderID,
            proveRestart: proveRestart,
            previousServiceInstanceID: previousServiceInstanceID,
            executableURL: executableURL,
            run: run
        )
    }

    private static func runCredentialCommand(
        configURL: URL,
        operation: String,
        expectedProviderID: String,
        proveRestart: Bool = false,
        previousServiceInstanceID: String? = nil
    ) async throws -> CredentialSnapshot {
        let installed = try resolveInstalledExecutable()
        let expectedIdentity = try validateInstalledExecutable(installed)
        var arguments = [
            "credentials", operation,
            "--config", configURL.path,
            "--expected-provider-id", expectedProviderID,
        ]
        if proveRestart {
            arguments.append("--prove-restart")
            if let previousServiceInstanceID {
                arguments.append(contentsOf: ["--previous-service-instance", previousServiceInstanceID])
            }
        }
        let output = try await runCapturedProcess(
            executableURL: installed,
            arguments: arguments,
            timeout: proveRestart ? 21 * 60 : 15,
            validateProcess: { pid in
                try validateRunningExecutable(pid: pid, expectedIdentity: expectedIdentity)
            }
        )
        guard try validateInstalledExecutable(installed) == expectedIdentity else {
            throw Error.invalidCLI("executable changed during credential \(operation)")
        }
        return try decodeCredentialResult(
            output,
            expectedOperation: operation,
            expectedProviderID: expectedProviderID
        )
    }

    private static func runCredentialCommand(
        configURL: URL,
        operation: String,
        expectedProviderID: String?,
        proveRestart: Bool = false,
        previousServiceInstanceID: String? = nil,
        executableURL: URL,
        run: @escaping CapturedCommandRunner
    ) async throws -> CredentialSnapshot {
        var arguments = ["credentials", operation, "--config", configURL.path]
        if let expectedProviderID {
            arguments.append(contentsOf: ["--expected-provider-id", expectedProviderID])
        }
        if proveRestart {
            arguments.append("--prove-restart")
            if let previousServiceInstanceID {
                arguments.append(contentsOf: ["--previous-service-instance", previousServiceInstanceID])
            }
        }
        let output = try await run(executableURL, arguments)
        return try decodeCredentialResult(
            output,
            expectedOperation: operation,
            expectedProviderID: expectedProviderID
        )
    }

    private static func decodeCredentialResult(
        _ result: CapturedCommandResult,
        expectedOperation: String,
        expectedProviderID: String?
    ) throws -> CredentialSnapshot {
        guard result.exitCode == 0 else {
            throw expectedOperation == "repair"
                ? Error.repairFailed(result.exitCode)
                : Error.statusFailed(result.exitCode)
        }
        guard !result.standardOutput.isEmpty else {
            throw Error.invalidOutput("empty output")
        }
        guard result.standardOutput.count <= 64 * 1024 else {
            throw Error.invalidOutput("output exceeds 64 KiB")
        }
        let snapshot: CredentialSnapshot
        do {
            snapshot = try JSONDecoder().decode(CredentialSnapshot.self, from: result.standardOutput)
        } catch {
            throw Error.invalidOutput("invalid versioned JSON")
        }
        guard snapshot.contractVersion == 1 else {
            throw Error.invalidOutput("unsupported contract version \(snapshot.contractVersion)")
        }
        guard snapshot.operation == expectedOperation,
              !snapshot.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.invalidOutput("operation or provider identity mismatch")
        }
        if let expectedProviderID,
           snapshot.providerID.trimmingCharacters(in: .whitespacesAndNewlines) != expectedProviderID {
            throw Error.invalidOutput("provider identity mismatch")
        }
        return snapshot
    }

    private static func runAdmissionIdentityRecoveryCommand(
        configURL: URL,
        expectedProviderID: String,
        incidentID: String?,
        reason: String?,
        activate: Bool,
        previousServiceInstanceID: String?
    ) async throws -> AdmissionRecoverySnapshot {
        let installed = try resolveInstalledExecutable()
        let expectedIdentity = try validateInstalledExecutable(installed)
        let arguments = admissionIdentityRecoveryArguments(
            configURL: configURL,
            expectedProviderID: expectedProviderID,
            incidentID: incidentID,
            reason: reason,
            activate: activate,
            previousServiceInstanceID: previousServiceInstanceID
        )
        let output = try await runCapturedProcess(
            executableURL: installed,
            arguments: arguments,
            timeout: activate ? 21 * 60 : 15,
            validateProcess: { pid in
                try validateRunningExecutable(pid: pid, expectedIdentity: expectedIdentity)
            }
        )
        guard try validateInstalledExecutable(installed) == expectedIdentity else {
            throw Error.invalidCLI("executable changed during network verification repair")
        }
        return try decodeAdmissionIdentityRecoveryResult(
            output,
            expectedProviderID: expectedProviderID,
            expectedStates: [activate ? "committed" : "approval_required"],
            expectedOperation: "recover_admission_identity"
        )
    }

    private static func runAdmissionIdentityRecoveryStatusCommand(
        configURL: URL,
        expectedProviderID: String
    ) async throws -> AdmissionRecoverySnapshot {
        let installed = try resolveInstalledExecutable()
        let expectedIdentity = try validateInstalledExecutable(installed)
        let output = try await runCapturedProcess(
            executableURL: installed,
            arguments: [
                "credentials", "admission-identity-recovery-status",
                "--config", configURL.path,
                "--expected-provider-id", expectedProviderID,
            ],
            timeout: 15,
            validateProcess: { pid in
                try validateRunningExecutable(pid: pid, expectedIdentity: expectedIdentity)
            }
        )
        guard try validateInstalledExecutable(installed) == expectedIdentity else {
            throw Error.invalidCLI("executable changed while checking network verification repair")
        }
        return try decodeAdmissionIdentityRecoveryResult(
            output,
            expectedProviderID: expectedProviderID,
            expectedStates: ["not_staged", "approval_required", "expired", "committed_cleanup"],
            expectedOperation: "admission_identity_recovery_status"
        )
    }

    private static func runAdmissionIdentityRecoveryCommand(
        configURL: URL,
        executableURL: URL,
        expectedProviderID: String,
        incidentID: String?,
        reason: String?,
        activate: Bool,
        previousServiceInstanceID: String?,
        run: @escaping CapturedCommandRunner
    ) async throws -> AdmissionRecoverySnapshot {
        let arguments = admissionIdentityRecoveryArguments(
            configURL: configURL,
            expectedProviderID: expectedProviderID,
            incidentID: incidentID,
            reason: reason,
            activate: activate,
            previousServiceInstanceID: previousServiceInstanceID
        )
        return try decodeAdmissionIdentityRecoveryResult(
            try await run(executableURL, arguments),
            expectedProviderID: expectedProviderID,
            expectedStates: [activate ? "committed" : "approval_required"],
            expectedOperation: "recover_admission_identity"
        )
    }

    private static func admissionIdentityRecoveryArguments(
        configURL: URL,
        expectedProviderID: String,
        incidentID: String?,
        reason: String?,
        activate: Bool,
        previousServiceInstanceID: String?
    ) -> [String] {
        var arguments = [
            "credentials", "recover-admission-identity",
            "--config", configURL.path,
            "--expected-provider-id", expectedProviderID,
        ]
        if activate {
            arguments.append("--activate")
            if let previousServiceInstanceID {
                arguments.append(contentsOf: ["--previous-service-instance", previousServiceInstanceID])
            }
        } else if let incidentID, let reason {
            arguments.append(contentsOf: [
                "--incident-id", incidentID,
                "--reason", reason,
                "--approval-ttl-minutes", "60",
            ])
        }
        return arguments
    }

    private static func decodeAdmissionIdentityRecoveryResult(
        _ result: CapturedCommandResult,
        expectedProviderID: String,
        expectedStates: Set<String>,
        expectedOperation: String
    ) throws -> AdmissionRecoverySnapshot {
        guard result.exitCode == 0 else {
            throw Error.admissionRecoveryFailed(result.exitCode)
        }
        guard !result.standardOutput.isEmpty, result.standardOutput.count <= 64 * 1024 else {
            throw Error.invalidOutput("invalid admission recovery output size")
        }
        let snapshot: AdmissionRecoverySnapshot
        do {
            snapshot = try JSONDecoder().decode(AdmissionRecoverySnapshot.self, from: result.standardOutput)
        } catch {
            throw Error.invalidOutput("invalid admission recovery JSON")
        }
        guard snapshot.contractVersion == 1,
              snapshot.operation == expectedOperation,
              snapshot.providerID == expectedProviderID,
              expectedStates.contains(snapshot.state),
              snapshot.restartSafe else {
            throw Error.invalidOutput("admission recovery contract mismatch")
        }
        switch snapshot.state {
        case "committed":
            guard snapshot.publicKeySHA256?.count == 64, snapshot.adminRequest == nil else {
                throw Error.invalidOutput("committed admission recovery result is incomplete")
            }
        case "approval_required", "expired", "committed_cleanup":
            guard snapshot.candidatePublicKeySHA256?.count == 64,
                  snapshot.adminRequest?.method == "POST",
                  snapshot.adminRequest?.body.providerID == expectedProviderID,
                  snapshot.adminRequest?.body.candidatePublicKeySHA256 == snapshot.candidatePublicKeySHA256 else {
                throw Error.invalidOutput("staged admission recovery result is incomplete")
            }
        case "not_staged":
            guard snapshot.candidatePublicKeySHA256 == nil,
                  snapshot.publicKeySHA256 == nil,
                  snapshot.adminRequest == nil else {
                throw Error.invalidOutput("unstaged admission recovery result is inconsistent")
            }
        default:
            throw Error.invalidOutput("unsupported admission recovery state")
        }
        return snapshot
    }

    static func migrate(configURL: URL) async throws {
        let installed = try resolveInstalledExecutable()
        let expectedIdentity = try validateInstalledExecutable(installed)
        let runValidated: CommandRunner = { executableURL, arguments in
            guard try validateInstalledExecutable(executableURL) == expectedIdentity else {
                throw Error.invalidCLI("executable changed during handoff")
            }
            let exitCode = try await runProcess(
                executableURL: executableURL,
                arguments: arguments,
                validateProcess: { pid in
                    try validateRunningExecutable(pid: pid, expectedIdentity: expectedIdentity)
                }
            )
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
                guard let data = InstalledProviderMonitor.readOwnerPrivateRegularFile(
                    manifestURL,
                    maxBytes: 64 * 1024,
                    fileManager: fileManager
                ) else {
                    throw Error.invalidCLI("install manifest is not a trusted private file")
                }
                manifest = try JSONDecoder().decode(InstallManifest.self, from: data)
            } catch {
                throw Error.invalidCLI("install manifest is malformed")
            }
            guard manifest.binaryPath.hasPrefix("/"),
                  let installPrefix = manifest.installPrefix,
                  installPrefix.hasPrefix("/") else {
                throw Error.invalidCLI("install manifest binary_path is not absolute")
            }
            let prefix = URL(fileURLWithPath: installPrefix).standardizedFileURL
            let manifestDirectory = manifestURL.deletingLastPathComponent()
            guard InstalledProviderMonitor.isSafePrivateDirectoryChain(
                manifestDirectory,
                under: home
            ), InstalledProviderMonitor.isSupportedProviderInstallDirectory(
                prefix,
                under: home
            ) else {
                throw Error.invalidCLI("install manifest install_prefix is not trusted")
            }
            let resolved = URL(fileURLWithPath: manifest.binaryPath).standardizedFileURL
            guard resolved.deletingLastPathComponent().path == prefix.path else {
                throw Error.invalidCLI("install manifest binary_path does not match install_prefix")
            }
            candidate = resolved
        } else {
            candidate = home.appendingPathComponent("macprovider/macprovider-cli").standardizedFileURL
        }
        guard candidate.lastPathComponent == "macprovider-cli" else {
            throw Error.invalidCLI("unexpected executable name")
        }
        guard InstalledProviderMonitor.isOwnerPrivateExecutable(atPath: candidate.path),
              fileManager.isExecutableFile(atPath: candidate.path) else {
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

        var currentCode: SecCode?
        guard SecCodeCopySelf([], &currentCode) == errSecSuccess,
              let currentCode else {
            throw Error.invalidCLI("Malibu running signing identity is unavailable")
        }
        var currentStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(currentCode, [], &currentStaticCode) == errSecSuccess,
              let currentStaticCode else {
            throw Error.invalidCLI("Malibu static signing identity is unavailable")
        }
        let infoDictionary = try signingInformation(for: currentStaticCode)
        guard let teamID = infoDictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              teamID == "YF7XNRJUG4" else {
            throw Error.invalidCLI("Malibu Team ID is unavailable")
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw Error.invalidCLI("code object could not be created")
        }
        let requirementText = "identifier \"live.malibu.provider.cli\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
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
        let installedInfo = try signingInformation(for: staticCode)
        guard let codeDirectoryHash = installedInfo[kSecCodeInfoUnique as String] as? Data,
              !codeDirectoryHash.isEmpty else {
            throw Error.invalidCLI("CLI code-directory identity is unavailable")
        }
        return ExecutableIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            codeDirectoryHash: codeDirectoryHash
        )
    }

    private static func validateRunningExecutable(
        pid: pid_t,
        expectedIdentity: ExecutableIdentity
    ) throws {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &runningCode) == errSecSuccess,
              let runningCode else {
            throw Error.invalidCLI("running CLI code identity is unavailable")
        }
        var runningStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(runningCode, [], &runningStaticCode) == errSecSuccess,
              let runningStaticCode else {
            throw Error.invalidCLI("running CLI static code identity is unavailable")
        }
        let info = try signingInformation(for: runningStaticCode)
        guard let codeDirectoryHash = info[kSecCodeInfoUnique as String] as? Data,
              codeDirectoryHash == expectedIdentity.codeDirectoryHash else {
            throw Error.invalidCLI("running CLI does not match the validated executable")
        }
    }

    static func validatedInstalledProcessMatches(pid: pid_t) -> Bool {
        do {
            let executable = try resolveInstalledExecutable()
            let identity = try validateInstalledExecutable(executable)
            try validateRunningExecutable(pid: pid, expectedIdentity: identity)
            return true
        } catch {
            return false
        }
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 15,
        validateProcess: (@Sendable (pid_t) throws -> Void)? = nil
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let cancellation = ProcessCancellationBridge()
        let result = try await withTaskCancellationHandler {
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
                if let validateProcess {
                    do {
                        try validateProcess(process.processIdentifier)
                    } catch {
                        guard completion.beginFailure(error) else { return }
                        terminateAndEscalate(process)
                    }
                }
                cancellation.register {
                    guard completion.beginCancellation() else { return }
                    terminateAndEscalate(process)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard completion.beginTimeout() else { return }
                    terminateAndEscalate(process)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    static func runCapturedProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 15,
        outputLimit: Int = 64 * 1024,
        validateProcess: (@Sendable (pid_t) throws -> Void)? = nil
    ) async throws -> CapturedCommandResult {
        try Task.checkCancellation()
        let cancellation = ProcessCancellationBridge()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let completion = CapturedProcessCompletion(continuation)
                let stdout = Pipe()
                let output = BoundedOutputBuffer(limit: outputLimit)

                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.environment = [
                    "HOME": NSHomeDirectory(),
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                ]
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { output.append(chunk) }
                }
                process.terminationHandler = { terminated in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    output.append(stdout.fileHandleForReading.readDataToEndOfFile())
                    let snapshot = output.snapshot()
                    guard !snapshot.overflowed else {
                        completion.finish(.failure(Error.invalidOutput("output exceeds configured limit")))
                        return
                    }
                    completion.finishProcessExit(
                        CapturedCommandResult(
                            exitCode: terminated.terminationStatus,
                            standardOutput: snapshot.data
                        )
                    )
                }
                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    completion.finish(.failure(Error.launchFailed(error.localizedDescription)))
                    return
                }
                if let validateProcess {
                    do {
                        try validateProcess(process.processIdentifier)
                    } catch {
                        guard completion.beginFailure(error) else { return }
                        terminateAndEscalate(process)
                    }
                }
                cancellation.register {
                    guard completion.beginCancellation() else { return }
                    terminateAndEscalate(process)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard completion.beginTimeout() else { return }
                    terminateAndEscalate(process)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private static func terminateAndEscalate(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
