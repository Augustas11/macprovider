import Foundation
import LocalAuthentication
import MacProviderCore
import Security
import Darwin

protocol ProviderCredentialStoring: Sendable {
    func load(providerID: String) throws -> String?
    func importIfAbsentOrMatches(providerID: String, token: String) throws
    func replace(providerID: String, token: String) throws
    func repairCorruptIfStillCorrupt(providerID: String, token: String) throws
    func deleteAll() throws
}

enum ProviderCredentialStoreError: Error, Equatable, CustomStringConvertible {
    case invalidProviderID
    case invalidToken
    case missing(providerID: String)
    case invalidStoredToken(providerID: String)
    case readFailed(providerID: String, status: OSStatus)
    case writeFailed(providerID: String, status: OSStatus)
    case deleteFailed(status: OSStatus)
    case verificationFailed(providerID: String)
    case conflict(providerID: String)
    case custodyLockFailed

    var description: String {
        switch self {
        case .invalidProviderID:
            return "provider credential store requires a non-empty provider_id"
        case .invalidToken:
            return "provider credential store requires a non-empty token"
        case .missing(let providerID):
            return "provider credential Keychain item is missing for \(providerID)"
        case .invalidStoredToken(let providerID):
            return "provider credential store contains invalid data for \(providerID)"
        case .readFailed(let providerID, let status):
            return "provider credential Keychain read failed for \(providerID) (status \(status))"
        case .writeFailed(let providerID, let status):
            return "provider credential Keychain write failed for \(providerID) (status \(status))"
        case .deleteFailed(let status):
            return "provider credential Keychain cleanup failed (status \(status))"
        case .verificationFailed(let providerID):
            return "provider credential Keychain verification failed for \(providerID)"
        case .conflict(let providerID):
            return "provider credential import conflicts with the authoritative Keychain item for \(providerID)"
        case .custodyLockFailed:
            return "provider credential mutation lock is unavailable"
        }
    }
}

/// CLI-owned provider bearer storage.
///
/// The standalone executable uses the login Keychain's default ACL rather than
/// a custom trusted-application ACL. macOS tracks the creator's designated
/// requirement for that default ACL, so release signing pins a stable explicit
/// identifier for update continuity. Every lookup is non-interactive: a locked
/// or inaccessible Keychain becomes an explicit recoverable error, never a
/// password prompt in a launchd session.
struct KeychainProviderCredentialStore: ProviderCredentialStoring {
    static let service = "live.malibu.provider.provider-token.v1"
    static let legacyService = "live.streamvc.macprovider.provider-token.v1"
    private static let mutationLock = NSLock()

    func load(providerID: String) throws -> String? {
        let providerID = try Self.normalizedProviderID(providerID)
        if let token = try load(providerID: providerID, service: Self.service) {
            return token
        }
        guard let legacyToken = try load(providerID: providerID, service: Self.legacyService) else {
            return nil
        }
        try? migrateLegacyTokenIfAbsent(providerID: providerID, token: legacyToken)
        return legacyToken
    }

    private func load(providerID: String, service: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery(providerID: providerID, service: service) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                throw ProviderCredentialStoreError.invalidStoredToken(providerID: providerID)
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw ProviderCredentialStoreError.readFailed(providerID: providerID, status: status)
        }
    }

    private func migrateLegacyTokenIfAbsent(providerID: String, token: String) throws {
        let status = SecItemAdd(
            Self.addQuery(providerID: providerID, tokenData: Data(token.utf8)) as CFDictionary,
            nil
        )
        switch status {
        case errSecSuccess, errSecDuplicateItem:
            return
        default:
            throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: status)
        }
    }

    func replace(providerID: String, token: String) throws {
        let providerID = try Self.normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }
        try Self.withMutationLock {
            try replaceWhileLocked(providerID: providerID, token: token)
        }
    }

    private func replaceWhileLocked(providerID: String, token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            Self.baseQuery(providerID: providerID) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            let addStatus = SecItemAdd(Self.addQuery(providerID: providerID, tokenData: data) as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                break
            case errSecDuplicateItem:
                let retryStatus = SecItemUpdate(
                    Self.baseQuery(providerID: providerID) as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                guard retryStatus == errSecSuccess else {
                    throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: retryStatus)
                }
            default:
                throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: addStatus)
            }
        default:
            throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: updateStatus)
        }

        guard try load(providerID: providerID) == token else {
            throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
        }
    }

    func repairCorruptIfStillCorrupt(providerID: String, token: String) throws {
        let providerID = try Self.normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }

        try Self.withMutationLock {
            do {
                if let current = try load(providerID: providerID) {
                    guard current == token else {
                        throw ProviderCredentialStoreError.conflict(providerID: providerID)
                    }
                    return
                }
                try importWhileLocked(providerID: providerID, token: token)
            } catch ProviderCredentialStoreError.invalidStoredToken {
                try replaceWhileLocked(providerID: providerID, token: token)
            }
        }
    }

    /// Migration-only insertion. An existing Keychain item is authoritative:
    /// compatibility YAML may verify the same value but may never rotate or
    /// overwrite it. Coordinator-authenticated rotation uses `replace`.
    func importIfAbsentOrMatches(providerID: String, token: String) throws {
        let providerID = try Self.normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }

        try Self.withMutationLock {
            try importWhileLocked(providerID: providerID, token: token)
        }
    }

    private func importWhileLocked(providerID: String, token: String) throws {
        if let stored = try load(providerID: providerID) {
            guard stored == token else {
                throw ProviderCredentialStoreError.conflict(providerID: providerID)
            }
            return
        }

        let addStatus = SecItemAdd(
            Self.addQuery(providerID: providerID, tokenData: Data(token.utf8)) as CFDictionary,
            nil
        )
        switch addStatus {
        case errSecSuccess:
            break
        case errSecDuplicateItem:
            guard try load(providerID: providerID) == token else {
                throw ProviderCredentialStoreError.conflict(providerID: providerID)
            }
        default:
            throw ProviderCredentialStoreError.writeFailed(providerID: providerID, status: addStatus)
        }

        guard try load(providerID: providerID) == token else {
            throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
        }
    }

    func deleteAll() throws {
        try Self.withMutationLock {
            for service in [Self.service, Self.legacyService] {
                let status = SecItemDelete(Self.serviceQuery(service: service) as CFDictionary)
                switch status {
                case errSecSuccess, errSecItemNotFound:
                    continue
                default:
                    throw ProviderCredentialStoreError.deleteFailed(status: status)
                }
            }
        }
    }

    static var serviceQuery: [String: Any] {
        serviceQuery(service: service)
    }

    static func serviceQuery(service: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    static func baseQuery(providerID: String) -> [String: Any] {
        baseQuery(providerID: providerID, service: service)
    }

    static func baseQuery(providerID: String, service: String) -> [String: Any] {
        serviceQuery(service: service).merging([
            kSecAttrAccount as String: providerID,
        ]) { _, new in new }
    }

    static func readQuery(providerID: String) -> [String: Any] {
        readQuery(providerID: providerID, service: service)
    }

    static func readQuery(providerID: String, service: String) -> [String: Any] {
        baseQuery(providerID: providerID, service: service).merging([
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
    }

    static func addQuery(providerID: String, tokenData: Data) -> [String: Any] {
        baseQuery(providerID: providerID).merging([
            // Intentionally use the legacy login Keychain rather than the Data
            // Protection Keychain: the default ACL binds access to the signed
            // CLI's stable designated requirement across updates. macOS does
            // not honor kSecAttrAccessible here unless DP Keychain (or sync) is
            // selected, so do not claim an unsupported accessibility policy.
            kSecAttrSynchronizable as String: false,
            kSecAttrLabel as String: "MacProvider provider credential",
            kSecValueData as String: tokenData,
        ]) { _, new in new }
    }

    private static func normalizedProviderID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ProviderCredentialStoreError.invalidProviderID }
        return value
    }

    private static func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        // Keep the mutex inode outside the product-state directory. Uninstall
        // intentionally removes `.../macprovider`; deleting a held lock inode
        // would let a second process create and lock a different inode while
        // the first mutation is still active.
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ProviderCredentialStoreError.custodyLockFailed
        }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & 0o022) == 0 else {
            throw ProviderCredentialStoreError.custodyLockFailed
        }
        let lockURL = directory.appendingPathComponent(".macprovider-provider-credential.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ProviderCredentialStoreError.custodyLockFailed
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw ProviderCredentialStoreError.custodyLockFailed
        }

        let deadline = Date().addingTimeInterval(10)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard (errno == EWOULDBLOCK || errno == EAGAIN), Date() < deadline else {
                throw ProviderCredentialStoreError.custodyLockFailed
            }
            usleep(20_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

struct ProviderCredentialStatus: Equatable, Sendable {
    enum Source: String, Sendable {
        case cliKeychain = "cli_keychain"
        case configFallback = "config_fallback"
        case none
    }

    enum State: String, Sendable {
        case ready
        case degraded
        case conflict
        case unconfigured
        case missing
        case locked
        case notLoggedIn = "not_logged_in"
        case permissionDenied = "permission_denied"
        case corrupt
        case keychainFailure = "keychain_failure"
        case incompatible
        case unavailable
    }

    enum RecoveryAction: String, Sendable {
        case none
        case retry
        case unlockKeychain = "unlock_keychain"
        case login
        case authorizeKeychain = "authorize_keychain"
        case repairKeychain = "repair_keychain"
        case updateOrReinstall = "update_or_reinstall"
        case repairFromProtectedSource = "repair_from_protected_source"
        case restoreOrReenroll = "restore_or_reenroll"
    }

    let source: Source
    let state: State
    let restartSafe: Bool
    let migrationPending: Bool
    let recoveryAction: RecoveryAction

    init(
        source: Source,
        state: State,
        restartSafe: Bool,
        migrationPending: Bool = false,
        recoveryAction: RecoveryAction? = nil
    ) {
        self.source = source
        self.state = state
        self.restartSafe = restartSafe
        self.migrationPending = migrationPending
        self.recoveryAction = recoveryAction ?? Self.defaultRecoveryAction(for: state)
    }

    static let unconfigured = ProviderCredentialStatus(
        source: .none,
        state: .unconfigured,
        restartSafe: false,
        migrationPending: false
    )

    static func failure(_ error: Error, fallbackAvailable: Bool) -> ProviderCredentialStatus {
        let source: Source = fallbackAvailable ? .configFallback : .none
        let state: State
        let action: RecoveryAction
        switch error {
        case ProviderCredentialStoreError.missing:
            state = .missing
            action = .restoreOrReenroll
        case ProviderCredentialStoreError.invalidStoredToken:
            state = .corrupt
            action = fallbackAvailable ? .repairFromProtectedSource : .restoreOrReenroll
        case ProviderCredentialStoreError.conflict:
            state = .conflict
            action = .restoreOrReenroll
        case ProviderCredentialStoreError.readFailed(_, let status):
            switch status {
            case errSecInteractionNotAllowed, errSecInteractionRequired, errSecDatabaseLocked:
                state = .locked
                action = .unlockKeychain
            case errSecNotLoggedIn:
                state = .notLoggedIn
                action = .login
            case errSecNotAvailable:
                state = .unavailable
                action = .retry
            case errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem:
                state = .permissionDenied
                action = .authorizeKeychain
            case errSecMissingEntitlement:
                state = .incompatible
                action = .updateOrReinstall
            case errSecDecode, errSecReadOnly, errSecNoSuchKeychain, errSecInvalidKeychain,
                 errSecNoDefaultKeychain, errSecDataNotAvailable:
                state = .keychainFailure
                action = .repairKeychain
            default:
                state = .unavailable
                action = .retry
            }
        default:
            state = .unavailable
            action = .retry
        }
        return ProviderCredentialStatus(
            source: source,
            state: state,
            restartSafe: false,
            migrationPending: false,
            recoveryAction: action
        )
    }

    private static func defaultRecoveryAction(for state: State) -> RecoveryAction {
        switch state {
        case .ready, .unconfigured:
            return .none
        case .locked:
            return .unlockKeychain
        case .notLoggedIn:
            return .login
        case .permissionDenied:
            return .authorizeKeychain
        case .corrupt:
            return .repairFromProtectedSource
        case .keychainFailure:
            return .repairKeychain
        case .incompatible:
            return .updateOrReinstall
        case .missing, .conflict:
            return .restoreOrReenroll
        case .degraded, .unavailable:
            return .retry
        }
    }
}

actor ProviderCredentialStatusRuntime {
    private var value: ProviderCredentialStatus

    init(_ value: ProviderCredentialStatus) {
        self.value = value
    }

    func snapshot() -> ProviderCredentialStatus { value }

    func update(_ value: ProviderCredentialStatus) {
        self.value = value
    }
}

enum ProviderCredentialResolver {
    static func resolve(
        config: inout AppConfig,
        store: any ProviderCredentialStoring = KeychainProviderCredentialStore()
    ) throws -> ProviderCredentialStatus {
        let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = config.providerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let yamlToken = try yamlCredential(at: config.configPath)
        guard let providerID, !providerID.isEmpty else {
            return fallback?.isEmpty == false
                ? ProviderCredentialStatus(source: .configFallback, state: .degraded, restartSafe: false)
                : .unconfigured
        }

        do {
            if let stored = try store.load(providerID: providerID) {
                config.providerToken = stored
                let layeredConflict = fallback?.isEmpty == false && fallback != stored
                let yamlConflict = yamlToken?.isEmpty == false && yamlToken != stored
                return ProviderCredentialStatus(
                    source: .cliKeychain,
                    state: layeredConflict || yamlConflict ? .conflict : .ready,
                    restartSafe: true,
                    migrationPending: yamlToken == stored
                )
            }
            guard let fallback, !fallback.isEmpty else {
                return ProviderCredentialStatus(
                    source: .none,
                    state: .missing,
                    restartSafe: false,
                    recoveryAction: .restoreOrReenroll
                )
            }
            do {
                try store.importIfAbsentOrMatches(providerID: providerID, token: fallback)
            } catch let conflict as ProviderCredentialStoreError {
                guard conflict == .conflict(providerID: providerID) else { throw conflict }
                guard let authoritative = try store.load(providerID: providerID) else { throw conflict }
                config.providerToken = authoritative
                return ProviderCredentialStatus(
                    source: .cliKeychain,
                    state: .conflict,
                    restartSafe: true,
                    migrationPending: false
                )
            }
            guard let verified = try store.load(providerID: providerID), verified == fallback else {
                throw ProviderCredentialStoreError.verificationFailed(providerID: providerID)
            }
            config.providerToken = verified
            return ProviderCredentialStatus(
                source: .cliKeychain,
                state: yamlToken?.isEmpty == false && yamlToken != verified ? .conflict : .ready,
                restartSafe: true,
                migrationPending: yamlToken == verified
            )
        } catch {
            let fallbackAvailable = fallback?.isEmpty == false
            if let fallback, fallbackAvailable {
                config.providerToken = fallback
            }
            return ProviderCredentialStatus.failure(error, fallbackAvailable: fallbackAvailable)
        }
    }

    private static func yamlCredential(at configPath: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: ConfigLoader.expandTilde(configPath)) else {
            return nil
        }
        return try ConfigLoader.load(
            cli: CLIOverrides(configPath: configPath),
            environment: [:]
        ).providerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
