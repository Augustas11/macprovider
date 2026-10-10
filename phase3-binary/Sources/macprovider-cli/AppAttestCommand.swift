import ArgumentParser
import Foundation
import MacProviderCore

// One-time App Attest enrollment transport for Malibu.app. Malibu.app holds the
// App Attest key and produces the attestation; the CLI only carries the
// provider bearer, which never leaves CLI custody and is never accepted on argv.

struct AppAttestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app-attest",
        abstract: "One-time App Attest enrollment transport used by Malibu.app.",
        shouldDisplay: false,
        subcommands: [AppAttestChallengeCommand.self, AppAttestSubmitCommand.self]
    )
}

struct AppAttestChallengeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "challenge",
        abstract: "POST /v1/providers/app-attest/challenge and print the response JSON."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    func run() async throws {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        let outcome = await AppAttestClient(config: resolved).challenge()
        try AppAttestClient.finish(outcome, operation: "challenge")
    }
}

struct AppAttestSubmitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "submit",
        abstract: "POST /v1/providers/app-attest with the attestation read from stdin as standard base64."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "Coordinator challenge (standard base64, 32 bytes).")
    var challenge: String

    @Option(help: "App Attest key id (standard base64, 32 bytes).")
    var keyId: String

    func validate() throws {
        _ = try AppAttestClient.submitBody(challenge: challenge, keyID: keyId, attestation: nil)
    }

    func run() async throws {
        let stdin = try AppAttestClient.readBoundedInput(FileHandle.standardInput)
        let attestation = String(decoding: stdin, as: UTF8.self)
        let body = try AppAttestClient.submitBody(challenge: challenge, keyID: keyId, attestation: attestation)
        let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: config))
        let outcome = await AppAttestClient(config: resolved).submit(body: body)
        try AppAttestClient.finish(outcome, operation: "submit")
    }
}

struct AppAttestClient {
    static let challengePath = "/v1/providers/app-attest/challenge"
    static let submitPath = "/v1/providers/app-attest"
    static let maxStdinBytes = 64 * 1024
    static let maxAttestationBytes = 16 * 1024
    static let keyIDBytes = 32
    static let challengeBytes = 32

    enum Outcome: Equatable {
        /// HTTP 200 with a JSON object carrying a string `status`; one line, newline-terminated.
        case success(Data)
        case failure(exitCode: Int32, message: String)
    }

    enum ExitStatus {
        static let failure: Int32 = 1
        static let unauthorized: Int32 = 3
        static let rateLimited: Int32 = 4
        static let unavailable: Int32 = 5
    }

    var config: AppConfig
    var credentialStore: any ProviderCredentialStoring = KeychainProviderCredentialStore()
    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }()

    func challenge() async -> Outcome {
        await post(path: Self.challengePath, body: Data("{}".utf8))
    }

    func submit(body: Data) async -> Outcome {
        await post(path: Self.submitPath, body: body)
    }

    /// Builds `{"challenge","key_id","attestation"}` after local validation.
    /// `attestation == nil` validates only the argv fields.
    static func submitBody(challenge: String, keyID: String, attestation: String?) throws -> Data {
        let challenge = challenge.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Data(base64Encoded: challenge)?.count == challengeBytes else {
            throw ValidationError("--challenge must be standard base64 of \(challengeBytes) bytes")
        }
        guard Data(base64Encoded: keyID)?.count == keyIDBytes else {
            throw ValidationError("--key-id must be standard base64 of \(keyIDBytes) bytes")
        }
        guard let attestation else { return Data() }
        let trimmed = attestation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(base64Encoded: trimmed), !decoded.isEmpty else {
            throw ValidationError("stdin must carry the attestation object as standard base64")
        }
        guard decoded.count <= maxAttestationBytes else {
            throw ValidationError("attestation object exceeds \(maxAttestationBytes) bytes")
        }
        return try JSONSerialization.data(
            withJSONObject: ["challenge": challenge, "key_id": keyID, "attestation": trimmed],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func readBoundedInput(_ handle: FileHandle, limit: Int = maxStdinBytes) throws -> Data {
        var data = Data()
        while true {
            let chunk = handle.readData(ofLength: 8192)
            if chunk.isEmpty { return data }
            data.append(chunk)
            if data.count > limit {
                throw ValidationError("stdin exceeds \(limit) bytes")
            }
        }
    }

    static func finish(_ outcome: Outcome, operation: String) throws {
        switch outcome {
        case .success(let line):
            FileHandle.standardOutput.write(line)
        case .failure(let code, let message):
            FileHandle.standardError.write(Data("app-attest \(operation) failed: \(message)\n".utf8))
            throw ExitCode(code)
        }
    }

    private func post(path: String, body: Data) async -> Outcome {
        var config = config
        // Same restart-safe credential boundary as hardware-evidence submission.
        let resolvedCredentialStore: any ProviderCredentialStoring = config.credentialStore == .protectedFile
            ? ProviderCredentialStoreFactory.providerStore(for: config)
            : credentialStore
        let credentialStatus: ProviderCredentialStatus
        do {
            credentialStatus = try ProviderCredentialResolver.resolve(
                config: &config,
                store: resolvedCredentialStore,
                authoritativeSource: ProviderCredentialStoreFactory.credentialSource(for: config)
            )
        } catch {
            return .failure(exitCode: ExitStatus.failure, message: "provider credential resolution failed")
        }
        guard credentialStatus.hasRestartSafeCredentialCustody else {
            return .failure(
                exitCode: ExitStatus.failure,
                message: AutotuneHardwareEvidenceSubmitter.credentialUnavailableReason(credentialStatus)
            )
        }
        guard let providerToken = Self.trimmedNonEmpty(config.providerToken) else {
            return .failure(
                exitCode: ExitStatus.failure,
                message: "provider credential unavailable (condition=missing action=restore_or_reenroll)"
            )
        }
        guard let coordinatorURL = Self.trimmedNonEmpty(config.coordinatorURL),
              let endpoint = AutotuneHardwareEvidenceSubmitter.coordinatorEndpoint(from: coordinatorURL, path: path)
        else {
            return .failure(exitCode: ExitStatus.failure, message: "coordinator_url missing or not https/wss")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(providerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .failure(
                exitCode: ExitStatus.failure,
                message: AutotuneHardwareEvidenceSubmitter.transportFailureReason(error)
            )
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(exitCode: ExitStatus.failure, message: "non-HTTP response")
        }
        return Self.outcome(statusCode: http.statusCode, data: data)
    }

    static func outcome(statusCode: Int, data: Data) -> Outcome {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if statusCode == 200 {
            guard let object, object["status"] is String,
                  var line = try? JSONSerialization.data(
                      withJSONObject: object,
                      options: [.sortedKeys, .withoutEscapingSlashes]
                  )
            else {
                return .failure(exitCode: ExitStatus.failure, message: "HTTP 200 with an unexpected response body")
            }
            line.append(0x0a)
            return .success(line)
        }
        let exitCode: Int32
        switch statusCode {
        case 401: exitCode = ExitStatus.unauthorized
        case 429: exitCode = ExitStatus.rateLimited
        case 503: exitCode = ExitStatus.unavailable
        default: exitCode = ExitStatus.failure
        }
        var message = "HTTP \(statusCode)"
        if let code = errorCode(object) {
            message += " \(code)"
        }
        return .failure(exitCode: exitCode, message: message)
    }

    /// Only the coordinator's machine-readable error code reaches stderr; the
    /// free-text message is untrusted and is not echoed to a terminal.
    private static func errorCode(_ object: [String: Any]?) -> String? {
        let raw = (object?["error"] as? String)
            ?? ((object?["error"] as? [String: Any])?["code"] as? String)
        guard let raw, !raw.isEmpty, raw.count <= 64,
              raw.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) })
        else { return nil }
        return raw
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
