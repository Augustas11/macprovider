import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

struct CredentialsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "credentials",
        abstract: "Manage CLI-owned provider credentials.",
        subcommands: [
            CredentialsImportCommand.self,
            CredentialsVerifyCommand.self,
            CredentialsStatusCommand.self,
            CredentialsRepairCommand.self,
            CredentialsRotateAdmissionIdentityCommand.self,
            CredentialsRecoverAdmissionIdentityCommand.self,
            CredentialsAdmissionIdentityRecoveryStatusCommand.self,
        ]
    )
}

struct CredentialCommandResult: Equatable {
    static let contractVersion = 1

    let providerID: String
    let status: ProviderCredentialStatus

    func jsonObject(operation: String) -> [String: Any] {
        [
            "contract_version": Self.contractVersion,
            "credential_store": KeychainProviderCredentialStore.service,
            "operation": operation,
            "provider_id": providerID,
            "source": status.source.rawValue,
            "condition": status.state.rawValue,
            "restart_safe": status.restartSafe,
            "migration_pending": status.migrationPending,
            "recoverable": status.recoveryAction != .none,
            "action": status.recoveryAction.rawValue,
        ]
    }

    func printJSON(operation: String) {
        let payload = jsonObject(operation: operation)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            print("credential \(operation) condition=\(status.state.rawValue) provider_id=\(providerID)")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }
}

struct CredentialsImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import the provider token from a private config file into CLI-owned Keychain storage."
    )

    @Option(help: "YAML config path containing provider_id and provider_token.")
    var config: String

    func run() throws {
        let providerID = try Self.importCredential(
            configPath: config,
            store: KeychainProviderCredentialStore()
        )
        Self.printResult(operation: "import", providerID: providerID)
    }

    static func importCredential(
        configPath: String,
        store: any ProviderCredentialStoring
    ) throws -> String {
        let loaded = try loadConfig(configPath: configPath)
        let providerID = try requiredProviderID(loaded)
        guard let token = loaded.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw ValidationError("credential import requires provider_token in the selected config")
        }
        try store.importIfAbsentOrMatches(providerID: providerID, token: token)
        guard try store.load(providerID: providerID) == token else {
            throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
        }
        return providerID
    }

    static func loadConfig(configPath: String) throws -> AppConfig {
        try ConfigLoader.load(
            cli: CLIOverrides(configPath: configPath),
            environment: [:]
        )
    }

    static func requiredProviderID(_ config: AppConfig) throws -> String {
        guard let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty else {
            throw ValidationError("credential operation requires provider_id in the selected config")
        }
        return providerID
    }

    fileprivate static func printResult(operation: String, providerID: String) {
        let payload: [String: Any] = [
            "credential_store": KeychainProviderCredentialStore.service,
            "operation": operation,
            "provider_id": providerID,
            "restart_safe": true,
            "status": "ok",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            print("credential \(operation) succeeded for \(providerID)")
            return
        }
        print(String(decoding: data, as: UTF8.self))
    }
}

struct CredentialsVerifyCommand: ParsableCommand {
    /// Installer contract: tokenless verification returns this code only when
    /// no item exists. Locked, denied, corrupt, and other Keychain failures
    /// retain their ordinary nonzero error so callers never bootstrap over an
    /// unavailable authoritative store.
    static let missingCredentialExitCode = ExitCode(3)

    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify a fresh CLI process can read the exact credential in a private config file."
    )

    @Option(help: "YAML config path containing provider_id and provider_token.")
    var config: String

    func run() throws {
        do {
            let providerID = try Self.verifyCredential(
                configPath: config,
                store: KeychainProviderCredentialStore()
            )
            CredentialsImportCommand.printResult(operation: "verify", providerID: providerID)
        } catch ProviderCredentialStoreError.missing(let providerID) {
            let message = "provider credential Keychain item is missing for \(providerID)\n"
            FileHandle.standardError.write(Data(message.utf8))
            throw Self.missingCredentialExitCode
        }
    }

    static func verifyCredential(
        configPath: String,
        store: any ProviderCredentialStoring
    ) throws -> String {
        let loaded = try CredentialsImportCommand.loadConfig(configPath: configPath)
        let providerID = try CredentialsImportCommand.requiredProviderID(loaded)
        let stored = try store.load(providerID: providerID)
        if let expected = loaded.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty {
            guard stored == expected else {
                throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
            }
            return providerID
        }
        guard let stored else {
            throw ProviderCredentialStoreError.missing(providerID: providerID)
        }
        guard !stored.isEmpty else {
            throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
        }
        return providerID
    }
}

struct CredentialsStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report a versioned, redacted CLI credential condition without mutating it."
    )

    @Option(help: "YAML config path containing provider_id and an optional protected recovery token.")
    var config: String

    @Option(help: "Refuse the operation unless config contains this exact provider_id.")
    var expectedProviderID: String?

    func run() throws {
        try Self.inspect(
            configPath: config,
            expectedProviderID: expectedProviderID,
            store: KeychainProviderCredentialStore()
        )
            .printJSON(operation: "status")
    }

    static func inspect(
        configPath: String,
        expectedProviderID: String? = nil,
        store: any ProviderCredentialStoring
    ) throws -> CredentialCommandResult {
        do {
            return try CredentialsRepairCommand.withProtectedSource(configPath: configPath) { loaded in
                try inspect(
                    loaded: loaded,
                    expectedProviderID: expectedProviderID,
                    protectedFallback: true,
                    store: store
                )
            }
        } catch is CredentialsRepairCommand.ProtectedSourceError {
            let loaded = try CredentialsImportCommand.loadConfig(configPath: configPath)
            return try inspect(
                loaded: loaded,
                expectedProviderID: expectedProviderID,
                protectedFallback: false,
                store: store
            )
        }
    }

    fileprivate static func inspect(
        loaded: AppConfig,
        expectedProviderID: String? = nil,
        protectedFallback: Bool,
        store: any ProviderCredentialStoring
    ) throws -> CredentialCommandResult {
        let providerID = try CredentialsImportCommand.requiredProviderID(loaded)
        try validateExpectedProviderID(expectedProviderID, actual: providerID)
        let fallback = loaded.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAvailable = protectedFallback && fallback?.isEmpty == false
        let status: ProviderCredentialStatus
        do {
            if let stored = try store.load(providerID: providerID) {
                let conflict = fallbackAvailable && fallback != stored
                status = ProviderCredentialStatus(
                    source: .cliKeychain,
                    state: conflict ? .conflict : .ready,
                    restartSafe: true,
                    migrationPending: fallback == stored,
                    recoveryAction: conflict
                        ? .restoreOrReenroll
                        : ProviderCredentialStatus.RecoveryAction.none
                )
            } else {
                status = ProviderCredentialStatus(
                    source: fallbackAvailable ? .configFallback : .none,
                    state: .missing,
                    restartSafe: false,
                    migrationPending: false,
                    recoveryAction: fallbackAvailable ? .repairFromProtectedSource : .restoreOrReenroll
                )
            }
        } catch {
            status = ProviderCredentialStatus.failure(error, fallbackAvailable: fallbackAvailable)
        }
        return CredentialCommandResult(providerID: providerID, status: status)
    }

    static func validateExpectedProviderID(_ expected: String?, actual: String) throws {
        guard let expected else { return }
        let normalized = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == actual else {
            throw ValidationError("credential operation provider_id does not match the expected provider identity")
        }
    }
}

struct CredentialsRepairCommand: AsyncParsableCommand {
    fileprivate struct ProtectedSourceIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    enum ProtectedSourceError: Error, LocalizedError {
        case unavailable
        case notRegular
        case wrongOwner
        case insecurePermissions
        case hardLinked
        case extendedACL
        case tooLarge
        case invalidEncoding
        case changed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "credential recovery source is unavailable"
            case .notRegular:
                return "credential recovery source must be a regular file, not a symlink"
            case .wrongOwner:
                return "credential recovery source must be owned by the current user"
            case .insecurePermissions:
                return "credential recovery source must not be accessible by group or other users"
            case .hardLinked:
                return "credential recovery source must not have hard links"
            case .extendedACL:
                return "credential recovery source must not have an extended ACL"
            case .tooLarge:
                return "credential recovery source exceeds the maximum supported size"
            case .invalidEncoding:
                return "credential recovery source must be valid UTF-8"
            case .changed:
                return "protected credential recovery source changed while it was being inspected"
            }
        }
    }

    enum RepairError: Error, Equatable, LocalizedError {
        case noProtectedSource
        case blocked(ProviderCredentialStatus.State)

        var errorDescription: String? {
            switch self {
            case .noProtectedSource:
                return "credential repair requires an exact protected recovery source; restore one or re-enroll"
            case .blocked(let state):
                return "credential repair refused while condition is \(state.rawValue)"
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Repair CLI credential custody from an exact protected config source."
    )

    @Option(help: "Private 0600 YAML config path containing provider_id and provider_token.")
    var config: String

    @Option(help: "Refuse the operation unless config contains this exact provider_id.")
    var expectedProviderID: String?

    @Flag(help: "Restart the launchd provider and return success only after a new instance is buyer-serving from CLI Keychain custody.")
    var proveRestart = false

    @Option(help: "Previously observed service instance that the restart proof must replace.")
    var previousServiceInstance: String?

    func run() async throws {
        do {
            let staged = try Self.repair(
                configPath: config,
                expectedProviderID: expectedProviderID,
                store: KeychainProviderCredentialStore()
            )
            let result: CredentialCommandResult
            if proveRestart {
                guard let expectedProviderID else {
                    throw ValidationError("restart proof requires --expected-provider-id")
                }
                result = try await CredentialRestartProver.restartAndProve(
                    configPath: config,
                    expectedProviderID: expectedProviderID,
                    previousServiceInstance: previousServiceInstance
                )
            } else {
                result = staged
            }
            result.printJSON(operation: "repair")
        } catch let error as RepairError {
            if let result = try? CredentialsStatusCommand.inspect(
                configPath: config,
                store: KeychainProviderCredentialStore()
            ) {
                result.printJSON(operation: "repair_refused")
            }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            throw ExitCode(4)
        }
    }

    static func repair(
        configPath: String,
        expectedProviderID: String? = nil,
        store: any ProviderCredentialStoring
    ) throws -> CredentialCommandResult {
        try withProtectedSource(configPath: configPath) { loaded in
            let providerID = try CredentialsImportCommand.requiredProviderID(loaded)
            try CredentialsStatusCommand.validateExpectedProviderID(expectedProviderID, actual: providerID)
            guard let token = loaded.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                throw RepairError.noProtectedSource
            }
            let before = try CredentialsStatusCommand.inspect(
                loaded: loaded,
                expectedProviderID: expectedProviderID,
                protectedFallback: true,
                store: store
            )
            switch before.status.state {
            case .ready:
                break
            case .missing:
                try store.importIfAbsentOrMatches(providerID: providerID, token: token)
            case .corrupt:
                try store.repairCorruptIfStillCorrupt(providerID: providerID, token: token)
            case .conflict, .locked, .notLoggedIn, .permissionDenied, .keychainFailure,
                 .incompatible, .unavailable, .degraded, .unconfigured:
                throw RepairError.blocked(before.status.state)
            }
            guard try store.load(providerID: providerID) == token else {
                throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
            }
            return CredentialCommandResult(
                providerID: providerID,
                status: ProviderCredentialStatus(
                    source: .cliKeychain,
                    state: .ready,
                    restartSafe: true,
                    migrationPending: true
                )
            )
        }
    }

    fileprivate static func withProtectedSource<T>(
        configPath: String,
        _ operation: (AppConfig) throws -> T
    ) throws -> T {
        let resolvedPath = ConfigLoader.expandTilde(configPath)
        let descriptor = open(resolvedPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProtectedSourceError.unavailable }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ProtectedSourceError.unavailable }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProtectedSourceError.notRegular
        }
        guard info.st_uid == geteuid() else {
            throw ProtectedSourceError.wrongOwner
        }
        guard (info.st_mode & 0o077) == 0 else {
            throw ProtectedSourceError.insecurePermissions
        }
        guard info.st_nlink == 1 else { throw ProtectedSourceError.hardLinked }
        try validateNoExtendedACL(descriptor)
        let initialIdentity = protectedSourceIdentity(info)

        let maximumBytes = 1_048_576
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ProtectedSourceError.unavailable }
            guard count > 0 else { break }
            guard bytes.count + count <= maximumBytes else { throw ProtectedSourceError.tooLarge }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard let contents = String(data: bytes, encoding: .utf8) else {
            throw ProtectedSourceError.invalidEncoding
        }
        let loaded = try ConfigLoader.load(
            cli: CLIOverrides(configPath: resolvedPath),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in contents }
        )

        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              protectedSourceIdentity(finalInfo) == initialIdentity else {
            throw ProtectedSourceError.changed
        }
        return try operation(loaded)
    }

    private static func validateNoExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw ProtectedSourceError.unavailable }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == 0 else {
            if result == 1 { throw ProtectedSourceError.extendedACL }
            throw ProtectedSourceError.unavailable
        }
    }

    private static func protectedSourceIdentity(_ info: stat) -> ProtectedSourceIdentity {
        return ProtectedSourceIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
            changedSeconds: Int(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int(info.st_ctimespec.tv_nsec)
        )
    }
}

enum CredentialRestartProver {
    static let launchdLabel = "live.streamvc.macprovider"

    /// Validates the versioned status envelope emitted by the exact
    /// launchd-managed CLI process. Callers must separately prove that the
    /// same launchd PID owns the configured listener before trusting fields
    /// that authorize a disruptive local recovery action.
    static func validateCLIAuthoredLocalStatus(
        _ object: [String: Any],
        requiredCapabilities: Set<String>,
        launchdPID: Int,
        now: Date,
        currentBootSession: String?
    ) -> Bool {
        guard launchdPID > 0,
              let expectedBootSession = currentBootSession?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedBootSession.isEmpty,
              let binaryVersion = object["binary_version"] as? String,
              !binaryVersion.isEmpty,
              let contract = object["local_status_contract"] as? [String: Any],
              contract["version"] as? Int == 1,
              contract["minimum_reader_version"] as? Int == 1,
              contract["lifecycle_owner"] as? String == "macprovider_cli",
              let capabilities = contract["capabilities"] as? [String],
              requiredCapabilities.isSubset(of: Set(capabilities)),
              let observation = object["observation"] as? [String: Any],
              let observationID = observation["id"] as? String,
              !observationID.isEmpty,
              let observedAtText = observation["observed_at"] as? String,
              let observedAt = parseISO8601(observedAtText),
              let validForMS = observation["valid_for_ms"] as? Int,
              (1...60_000).contains(validForMS),
              observedAt <= now.addingTimeInterval(1),
              observedAt.addingTimeInterval(Double(validForMS) / 1_000) >= now,
              let service = object["service_instance"] as? [String: Any],
              let instanceID = service["instance_id"] as? String,
              !instanceID.isEmpty,
              service["pid"] as? Int == launchdPID,
              service["role"] as? String == "serve",
              let serviceStartedAtText = service["started_at"] as? String,
              let serviceStartedAt = parseISO8601(serviceStartedAtText),
              serviceStartedAt <= now.addingTimeInterval(1),
              let bootSession = service["boot_session"] as? String,
              bootSession.lowercased() == expectedBootSession.lowercased() else {
            return false
        }
        return true
    }

    static func restartAndProve(
        configPath: String,
        expectedProviderID: String,
        previousServiceInstance: String?,
        timeout: TimeInterval = 20 * 60,
        pollInterval: TimeInterval = 2,
        restart: () throws -> Void = restartLaunchdProvider,
        fetchStatus: ((Int) async -> Data?)? = nil,
        launchdPID: () -> Int? = currentLaunchdPID,
        listenerOwnerPID: (Int) -> Int? = currentListenerOwnerPID,
        bootSession: () -> String? = currentBootSessionUUID
    ) async throws -> CredentialCommandResult {
        let config = try CredentialsImportCommand.loadConfig(configPath: configPath)
        let providerID = try CredentialsImportCommand.requiredProviderID(config)
        try CredentialsStatusCommand.validateExpectedProviderID(expectedProviderID, actual: providerID)
        let port = config.port
        guard (1...65_535).contains(port) else {
            throw ValidationError("credential restart proof requires a valid local provider port")
        }

        let restartRequestedAt = Date()
        try restart()
        let statusFetcher = fetchStatus ?? fetchLocalStatus
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let exactLaunchdPID = launchdPID()
            if let exactLaunchdPID,
               listenerOwnerPID(port) == exactLaunchdPID,
               let data = await statusFetcher(port),
               let result = validateBuyerServingProof(
                   data,
                   expectedProviderID: providerID,
                   previousServiceInstance: previousServiceInstance,
                   launchdPID: exactLaunchdPID,
                   now: Date(),
                   restartRequestedAt: restartRequestedAt,
                   currentBootSession: bootSession()
               ) {
                return result
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            try await Task.sleep(nanoseconds: UInt64(min(pollInterval, remaining) * 1_000_000_000))
        }
        throw ValidationError(
            "credential custody was restored, but a new buyer-serving launchd instance was not proven before timeout"
        )
    }

    static func validateBuyerServingProof(
        _ data: Data,
        expectedProviderID: String,
        previousServiceInstance: String?,
        launchdPID: Int?,
        now: Date,
        restartRequestedAt: Date,
        currentBootSession: String?
    ) -> CredentialCommandResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contract = object["local_status_contract"] as? [String: Any],
              contract["version"] as? Int == 1,
              contract["minimum_reader_version"] as? Int == 1,
              contract["lifecycle_owner"] as? String == "macprovider_cli",
              let capabilities = contract["capabilities"] as? [String],
              Set([
                "buyer_serving_authority_v1", "credential_status_v1",
                "service_instance_v1", "status_observation_v1",
              ]).isSubset(of: Set(capabilities)),
              object["provider_id"] as? String == expectedProviderID,
              object["network_state"] as? String == "buyer_serving",
              let coordinator = object["coordinator"] as? [String: Any],
              coordinator["connected"] as? Bool == true,
              let observation = object["observation"] as? [String: Any],
              let observationID = observation["id"] as? String,
              !observationID.isEmpty,
              let observedAtText = observation["observed_at"] as? String,
              let observedAt = parseISO8601(observedAtText),
              let validForMS = observation["valid_for_ms"] as? Int,
              (1...60_000).contains(validForMS),
              observedAt <= now.addingTimeInterval(1),
              observedAt.addingTimeInterval(Double(validForMS) / 1_000) >= now,
              let service = object["service_instance"] as? [String: Any],
              let instanceID = service["instance_id"] as? String,
              !instanceID.isEmpty,
              instanceID != previousServiceInstance,
              let servicePID = service["pid"] as? Int,
              servicePID > 0,
              servicePID == launchdPID,
              service["role"] as? String == "serve",
              let serviceStartedAtText = service["started_at"] as? String,
              let serviceStartedAt = parseISO8601(serviceStartedAtText),
              serviceStartedAt >= restartRequestedAt.addingTimeInterval(-5),
              serviceStartedAt <= now.addingTimeInterval(1),
              let bootSession = service["boot_session"] as? String,
              bootSession.lowercased() == currentBootSession?.lowercased(),
              let credential = object["credential"] as? [String: Any],
              credential["source"] as? String == ProviderCredentialStatus.Source.cliKeychain.rawValue,
              credential["state"] as? String == ProviderCredentialStatus.State.ready.rawValue,
              credential["restart_safe"] as? Bool == true,
              credential["migration_pending"] as? Bool == false else {
            return nil
        }
        return CredentialCommandResult(
            providerID: expectedProviderID,
            status: ProviderCredentialStatus(
                source: .cliKeychain,
                state: .ready,
                restartSafe: true,
                migrationPending: false,
                recoveryAction: ProviderCredentialStatus.RecoveryAction.none
            )
        )
    }

    private static func restartLaunchdProvider() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(launchdLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ValidationError("launchd provider restart failed with status \(process.terminationStatus)")
        }
    }

    static func currentLaunchdPID() -> Int? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(launchdLabel)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 64 * 1024 else { return nil }
            var parsedPID: Int?
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count == 3, fields[0] == "pid", fields[1] == "=",
                   let pid = Int(fields[2]), pid > 0 {
                    guard parsedPID == nil else { return nil }
                    parsedPID = pid
                }
            }
            return parsedPID
        } catch {
            return nil
        }
    }

    static func currentListenerOwnerPID(port: Int) -> Int? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 64 * 1024 else { return nil }
            let pids = Set(String(decoding: data, as: UTF8.self)
                .split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
                .compactMap { Int($0) }
                .filter { $0 > 0 })
            guard pids.count == 1 else { return nil }
            return pids.first
        } catch {
            return nil
        }
    }

    static func fetchLocalStatus(port: Int) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/status") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  data.count <= 256 * 1024 else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    static func currentBootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value.lowercased()
    }

    static func parseISO8601(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
