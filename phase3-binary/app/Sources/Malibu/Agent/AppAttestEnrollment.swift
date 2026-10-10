import CryptoKit
import DeviceCheck
import Foundation

// One-time App Attest enrollment per provider id. Malibu.app owns the App
// Attest key; the CLI carries the provider bearer (`app-attest challenge` /
// `app-attest submit`). Best effort: it never blocks provider start or
// serving, persists nothing until the coordinator confirms, and backs off
// between failed attempts across launches.

protocol AppAttestKeyService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// `DCAppAttestService`, used only on macOS 27 or later.
struct DeviceCheckAppAttestKeyService: AppAttestKeyService {
    static let minimumMajorVersion = 27

    var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: Self.minimumMajorVersion, minorVersion: 0, patchVersion: 0)
        ) && DCAppAttestService.shared.isSupported
    }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }
}

struct AppAttestCLIResult: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

/// Runs the provider CLI with `arguments`, writing `stdin` (if any) to its standard input.
typealias AppAttestCLIRunner = @Sendable (_ arguments: [String], _ stdin: Data?) async throws -> AppAttestCLIResult

/// Per-provider enrollment state. Only "done" and the retry schedule are kept.
struct AppAttestEnrollmentStore: @unchecked Sendable {
    static let backoff: [TimeInterval] = [15 * 60, 60 * 60, 4 * 60 * 60, 12 * 60 * 60, 24 * 60 * 60]

    let defaults: UserDefaults

    func isDone(_ providerID: String) -> Bool {
        defaults.bool(forKey: key("done", providerID))
    }

    func nextAttempt(_ providerID: String) -> Date? {
        defaults.object(forKey: key("nextAttemptAt", providerID)) as? Date
    }

    func markDone(_ providerID: String) {
        defaults.set(true, forKey: key("done", providerID))
        defaults.removeObject(forKey: key("failures", providerID))
        defaults.removeObject(forKey: key("nextAttemptAt", providerID))
    }

    func recordFailure(_ providerID: String, now: Date) {
        let failures = defaults.integer(forKey: key("failures", providerID))
        let delay = Self.backoff[min(failures, Self.backoff.count - 1)]
        defaults.set(failures + 1, forKey: key("failures", providerID))
        defaults.set(now.addingTimeInterval(delay), forKey: key("nextAttemptAt", providerID))
    }

    private func key(_ field: String, _ providerID: String) -> String {
        "appAttestEnrollment.\(field).\(providerID)"
    }
}

struct AppAttestEnrollment: Sendable {
    enum Outcome: Equatable {
        case unsupported
        case alreadyDone
        case backingOff(until: Date)
        case recorded
        case alreadyRecorded
        case failed(String)
    }

    let keyService: any AppAttestKeyService
    let runCLI: AppAttestCLIRunner
    let store: AppAttestEnrollmentStore
    var now: @Sendable () -> Date = { Date() }

    static let live = AppAttestEnrollment(
        keyService: DeviceCheckAppAttestKeyService(),
        runCLI: AppAttestEnrollment.runProviderCLI,
        store: AppAttestEnrollmentStore(defaults: .standard)
    )

    func run(providerID: String) async -> Outcome {
        guard keyService.isSupported else { return .unsupported }
        guard !store.isDone(providerID) else { return .alreadyDone }
        if let next = store.nextAttempt(providerID), now() < next {
            return .backingOff(until: next)
        }
        do {
            let outcome = try await enroll(providerID: providerID)
            store.markDone(providerID)
            NSLog("[malibu] app_attest_enrollment outcome=%@", String(describing: outcome))
            return outcome
        } catch {
            let reason = (error as? EnrollmentError)?.reason ?? "app_attest_\(type(of: error))"
            store.recordFailure(providerID, now: now())
            NSLog("[malibu] app_attest_enrollment failed reason=%@", reason)
            return .failed(reason)
        }
    }

    private struct EnrollmentError: Error {
        let reason: String
    }

    private func enroll(providerID: String) async throws -> Outcome {
        let challengeResult = try await runCLI(["app-attest", "challenge"], nil)
        let challenge = try Self.response(challengeResult, step: "challenge", providerID: providerID)
        switch challenge["status"] as? String {
        case "already_recorded":
            return .alreadyRecorded
        case "challenge":
            break
        default:
            throw EnrollmentError(reason: "challenge_unexpected_status")
        }
        guard let challengeB64 = challenge["challenge"] as? String, !challengeB64.isEmpty,
              let clientData = challenge["client_data"] as? String, !clientData.isEmpty
        else {
            throw EnrollmentError(reason: "challenge_malformed")
        }
        // clientDataHash covers the exact client_data bytes the coordinator sent.
        let clientDataHash = Data(SHA256.hash(data: Data(clientData.utf8)))
        let keyID: String
        let attestation: Data
        do {
            keyID = try await keyService.generateKey()
            attestation = try await keyService.attestKey(keyID, clientDataHash: clientDataHash)
        } catch {
            let code = (error as NSError).domain == DCError.errorDomain ? "\((error as NSError).code)" : "other"
            throw EnrollmentError(reason: "device_check_error_\(code)")
        }
        let submitResult = try await runCLI(
            ["app-attest", "submit", "--challenge", challengeB64, "--key-id", keyID],
            Data(attestation.base64EncodedString().utf8)
        )
        let submit = try Self.response(submitResult, step: "submit", providerID: providerID)
        switch submit["status"] as? String {
        case "recorded":
            return .recorded
        case "already_recorded":
            return .alreadyRecorded
        default:
            throw EnrollmentError(reason: "submit_unexpected_status")
        }
    }

    private static func response(
        _ result: AppAttestCLIResult,
        step: String,
        providerID: String
    ) throws -> [String: Any] {
        guard result.status == 0 else {
            throw EnrollmentError(reason: "\(step)_exit_\(result.status)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            throw EnrollmentError(reason: "\(step)_unparseable")
        }
        guard object["provider_id"] as? String == providerID else {
            throw EnrollmentError(reason: "\(step)_provider_mismatch")
        }
        return object
    }

    /// Spawns the same provider CLI the payout flow uses. The provider bearer
    /// stays in CLI custody; only public enrollment values cross argv/stdin.
    static let runProviderCLI: AppAttestCLIRunner = { arguments, stdin in
        let executable = try CLIUpdateRunner.resolveExecutableURL()
        // stdin is written into the pipe buffer before launch so a child that
        // exits early can never SIGPIPE Malibu. 32 KiB fits any pipe buffer.
        if let stdin, stdin.count > 32 * 1024 {
            throw EnrollmentError(reason: "stdin_too_large")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let input = Pipe()
                let output = Pipe()
                let errors = Pipe()
                if let stdin {
                    input.fileHandleForWriting.write(stdin)
                }
                try? input.fileHandleForWriting.close()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
                    if process.isRunning { process.terminate() }
                }
                let stderr = StderrBox()
                let stderrRead = DispatchGroup()
                stderrRead.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderr.data = errors.fileHandleForReading.readDataToEndOfFile()
                    stderrRead.leave()
                }
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                stderrRead.wait()
                process.waitUntilExit()
                continuation.resume(returning: AppAttestCLIResult(
                    stdout: stdout,
                    stderr: stderr.data,
                    status: process.terminationStatus
                ))
            }
        }
    }

    /// Written once by the reader before `DispatchGroup.leave`, read after `wait`.
    private final class StderrBox: @unchecked Sendable {
        var data = Data()
    }
}
