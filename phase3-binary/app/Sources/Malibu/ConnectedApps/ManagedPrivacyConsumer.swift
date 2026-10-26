import Combine
import CryptoKit
import Darwin
import Foundation

/// Only the loopback credential crosses from Malibu into a coding agent.
struct ManagedPrivacyEndpoint: Equatable {
    static let baseURL = URL(string: "http://127.0.0.1:11435/v1")!
    let localToken: String

    init(localToken: String) throws {
        guard !localToken.isEmpty, localToken.utf8.count <= 4096,
              !localToken.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { throw ConnectedAppsError.privacyUnavailable }
        self.localToken = localToken
    }
}

/// Owns a buyer endpoint, never the serving provider. An unrelated `consume`
/// process is not reused: it may hold a different buyer key or spend policy.
@MainActor
final class ManagedPrivacyConsumer: ObservableObject {
    static let shared = ManagedPrivacyConsumer()
    nonisolated static let budgetPreference = "connectedAppsPrivacyBudgetUSD"
    // Operator-provisioned public pin, verified through authenticated operator
    // SSH against the effective production directory signer (2026-10-26).
    nonisolated static let productionDirectoryPublicKey = "PW8pQB2pBP80Z5QebgP2Ru1pQ58IWrvgDqdFCsVNPkE"
    @Published private(set) var assuranceSummary = "Private endpoint not started."
    private var process: Process?
    private var endpoint: ManagedPrivacyEndpoint?
    private var configurationDigest: Data?
    private var starting = false
    private var generation = 0
    private var shuttingDown = false
    private var statusTask: Task<Void, Never>?

    nonisolated static func directoryKey(environment: [String: String] = ProcessInfo.processInfo.environment,
                             bundledKey: String? = (Bundle.main.object(forInfoDictionaryKey: "MalibuPrivacyDirectoryPublicKey") as? String) ?? ManagedPrivacyConsumer.productionDirectoryPublicKey) throws -> String {
        // The pin comes from the installed release or an explicit local setting,
        // never from the directory endpoint whose signature it must authenticate.
        guard let value = environment["MACPROVIDER_PRIVACY_DIRECTORY_PUBLIC_KEY"] ?? bundledKey,
              value.utf8.count == 43,
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32,
              base64URL(bytes) == value else { throw ConnectedAppsError.privacyIdentityUnavailable }
        return value
    }

    nonisolated static func budget(_ value: String) throws -> String {
        guard value.range(of: "^[0-9]+(?:\\.[0-9]{1,6})?$", options: .regularExpression) != nil,
              value.utf8.count <= 24,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), amount > 0 else {
            throw ConnectedAppsError.privacyBudgetInvalid
        }
        return value
    }

    func start(buyerKey: String, budgetUSD: String? = nil) async throws -> ManagedPrivacyEndpoint {
        guard !shuttingDown else { throw ConnectedAppsError.privacyUnavailable }
        let key = try Self.directoryKey()
        let budget = try Self.budget(budgetUSD ?? UserDefaults.standard.string(forKey: Self.budgetPreference) ?? "1.00")
        let required = ProcessInfo.processInfo.environment["MACPROVIDER_PRIVACY_ASSURANCE_REQUIRED"]
        guard required == nil || required == "code_bound_attested" else { throw ConnectedAppsError.privacyUnavailable }
        guard !buyerKey.isEmpty, buyerKey.utf8.count <= 4096,
              !buyerKey.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { throw ConnectedAppsError.credential }
        let digest = Data(SHA256.hash(data: Data([buyerKey, key, budget, required ?? ""].joined(separator: "\u{0}").utf8)))
        let requestedGeneration = generation
        while starting {
            try await Task.sleep(for: .milliseconds(50))
            try Task.checkCancellation()
        }
        guard !shuttingDown, requestedGeneration == generation else { throw ConnectedAppsError.privacyUnavailable }
        if let process, process.isRunning {
            guard configurationDigest == digest, let endpoint else { throw ConnectedAppsError.privacyConfigurationChanged }
            return endpoint
        }
        starting = true
        defer { starting = false }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/macprovider-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ConnectedAppsError.privacyUnavailable }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["consume", "run", "--bind", "127.0.0.1", "--port", "11435", "--privacy-class",
                           "--privacy-directory-public-key", key, "--budget-usd", budget]
        if let required { child.arguments?.append(contentsOf: ["--privacy-assurance-required", required]) }
        // No buyer credential in arguments, agent environment, generated profile,
        // launch handoff, or logs. It is handed only to the trusted buyer process.
        child.environment = try ProcessEnvironmentSanitizer.sanitized(extraEnvironment: ["MACPROVIDER_HTTP2_API_KEY": buyerKey])
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard child.isRunning else { throw ConnectedAppsError.privacyUnavailable }
                if let found = try ownedEndpoint(processID: child.processIdentifier, key: key, required: required) {
                    endpoint = found
                    configurationDigest = digest
                    assuranceSummary = "Private endpoint ready · awaiting a verified response."
                    observeAssurance(found)
                    return found
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ConnectedAppsError.privacyUnavailable
        } catch {
            stop()
            throw error
        }
    }

    func shutdown() {
        shuttingDown = true
        stop()
    }

    func stop() {
        generation += 1
        statusTask?.cancel()
        statusTask = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        endpoint = nil
        configurationDigest = nil
        assuranceSummary = "Private endpoint not started."
    }

    private func ownedEndpoint(processID: Int32, key: String, required: String?) throws -> ManagedPrivacyEndpoint? {
        let descriptor = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/macprovider/consume/active-endpoint.json")
        let snapshot = try ConnectedConfigTransaction.read(descriptor)
        guard let bytes = snapshot.bytes else { return nil }
        guard snapshot.mode == 0o600 else { throw ConnectedAppsError.privacyUnavailable }
        try MalibuStrictJSON.rejectDuplicateKeys(bytes)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["process_id"] as? Int32 == processID else { return nil }
        let decoded = Data(base64Encoded: key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")!
        guard object["bound_url"] as? String == "http://127.0.0.1:11435",
              object["privacy_class"] as? String == "operator_constrained_beta_v1",
              object["privacy_directory_key_fingerprint"] as? String == Self.base64URL(Data(SHA256.hash(data: decoded))),
              object["privacy_assurance_required"] as? String == required,
              let token = object["local_token"] as? String else { throw ConnectedAppsError.privacyUnavailable }
        return try ManagedPrivacyEndpoint(localToken: token)
    }

    private func observeAssurance(_ endpoint: ManagedPrivacyEndpoint) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: config, delegate: ConnectedRedirectBlocker(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            while !Task.isCancelled {
                guard let self, self.process?.isRunning == true else { return }
                var request = URLRequest(url: ManagedPrivacyEndpoint.baseURL.appendingPathComponent("status"))
                request.setValue("Bearer " + endpoint.localToken, forHTTPHeaderField: "Authorization")
                do {
                    let (bytes, response) = try await session.data(for: request)
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200, bytes.count <= 65_536 else {
                        throw ConnectedAppsError.privacyUnavailable
                    }
                    try MalibuStrictJSON.rejectDuplicateKeys(bytes)
                    guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          object["privacy_class"] as? String == "operator_constrained_beta_v1" else {
                        throw ConnectedAppsError.privacyUnavailable
                    }
                    if let label = object["privacy_assurance"] as? String,
                       ["device_bound_self_attested_beta", "code_bound_attested"].contains(label) {
                        self.assuranceSummary = "Last verified response: " + label
                    }
                } catch {
                    if !Task.isCancelled { self.assuranceSummary = "Private endpoint status unavailable · no downgrade." }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    nonisolated private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
