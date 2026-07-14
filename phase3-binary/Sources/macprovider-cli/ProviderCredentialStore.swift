import Foundation
import LocalAuthentication
import MacProviderCore
import Security

protocol ProviderCredentialStoring: Sendable {
    func load(providerID: String) throws -> String?
    func importIfAbsentOrMatches(providerID: String, token: String) throws
    func replace(providerID: String, token: String) throws
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
    static let service = "live.streamvc.macprovider.provider-token.v1"
    private static let mutationLock = NSLock()

    func load(providerID: String) throws -> String? {
        let providerID = try Self.normalizedProviderID(providerID)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery(providerID: providerID) as CFDictionary, &result)
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

    func replace(providerID: String, token: String) throws {
        let providerID = try Self.normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }
        let data = Data(token.utf8)

        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

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

    /// Migration-only insertion. An existing Keychain item is authoritative:
    /// compatibility YAML may verify the same value but may never rotate or
    /// overwrite it. Coordinator-authenticated rotation uses `replace`.
    func importIfAbsentOrMatches(providerID: String, token: String) throws {
        let providerID = try Self.normalizedProviderID(providerID)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProviderCredentialStoreError.invalidToken }

        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

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
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let status = SecItemDelete(Self.serviceQuery as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw ProviderCredentialStoreError.deleteFailed(status: status)
        }
    }

    static var serviceQuery: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    static func baseQuery(providerID: String) -> [String: Any] {
        serviceQuery.merging([
            kSecAttrAccount as String: providerID,
        ]) { _, new in new }
    }

    static func readQuery(providerID: String) -> [String: Any] {
        baseQuery(providerID: providerID).merging([
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
    }

    let source: Source
    let state: State
    let restartSafe: Bool
    let migrationPending: Bool

    init(source: Source, state: State, restartSafe: Bool, migrationPending: Bool = false) {
        self.source = source
        self.state = state
        self.restartSafe = restartSafe
        self.migrationPending = migrationPending
    }

    static let unconfigured = ProviderCredentialStatus(
        source: .none,
        state: .unconfigured,
        restartSafe: false,
        migrationPending: false
    )
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
            guard let fallback, !fallback.isEmpty else { return .unconfigured }
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
            guard let fallback, !fallback.isEmpty else { throw error }
            config.providerToken = fallback
            return ProviderCredentialStatus(source: .configFallback, state: .degraded, restartSafe: false)
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
