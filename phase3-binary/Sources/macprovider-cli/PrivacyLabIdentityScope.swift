import CryptoKit
import Darwin
import Foundation
import MacProviderCore

enum PrivacyLabIdentityScopeError: Error, Equatable, CustomStringConvertible {
    case notRequested
    case privacyClassOff
    case isolateLifecycleRequired
    case protectedFileRequired
    case loopbackLiteralRequired
    case stateRootRequired
    case stateRootDefault
    case stateRootNotCanonical
    case stateRootSymlink(String)
    case stateRootUnsafe(String)

    var description: String {
        switch self {
        case .notRequested: return "lab identity scope not requested"
        case .privacyClassOff: return "privacy class is not enabled"
        case .isolateLifecycleRequired: return "--isolate-lifecycle is required"
        case .protectedFileRequired: return "credential_store must be protected_file"
        case .loopbackLiteralRequired: return "coordinator_url must target 127.0.0.1 or [::1]"
        case .stateRootRequired: return "relay_blind_state_directory must be an absolute lab root"
        case .stateRootDefault: return "relay_blind_state_directory must be an explicit lab root"
        case .stateRootNotCanonical: return "relay_blind_state_directory must be canonical"
        case .stateRootSymlink(let path): return "relay_blind_state_directory contains symlink component \(path)"
        case .stateRootUnsafe(let path): return "relay_blind_state_directory is not an owner-only directory: \(path)"
        }
    }
}

/// Internal-only identity scope for the isolated privacy lab campaign. Nil keeps the
/// production Secure Enclave label and file-backed fallback exactly as before.
struct PrivacyLabIdentityScope: Equatable, Sendable {
    let stateRoot: URL
    let secureEnclaveLabel: String
    let secureEnclaveFileURL: URL

    private static let secureEnclaveBaseLabel = "live.malibu.provider.attestation-signing.v1"

    private init(stateRoot: URL, secureEnclaveLabel: String, secureEnclaveFileURL: URL) {
        self.stateRoot = stateRoot
        self.secureEnclaveLabel = secureEnclaveLabel
        self.secureEnclaveFileURL = secureEnclaveFileURL
    }

    static func validated(
        config: AppConfig,
        isolateLifecycle: Bool
    ) throws -> PrivacyLabIdentityScope {
        guard config.privacyClassBeta else { throw PrivacyLabIdentityScopeError.privacyClassOff }
        guard isolateLifecycle else { throw PrivacyLabIdentityScopeError.isolateLifecycleRequired }
        guard config.credentialStore == .protectedFile else {
            throw PrivacyLabIdentityScopeError.protectedFileRequired
        }
        guard coordinatorIsLiteralLoopback(config.coordinatorURL) else {
            throw PrivacyLabIdentityScopeError.loopbackLiteralRequired
        }
        guard let rawRoot = config.relayBlindStateDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawRoot.hasPrefix("/")
        else {
            throw PrivacyLabIdentityScopeError.stateRootRequired
        }
        let defaultRoot = ConfigLoader.expandTilde(PrivacyAutoEnrollment.defaultStateDirectory)
        guard rawRoot != defaultRoot else { throw PrivacyLabIdentityScopeError.stateRootDefault }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
        guard root.path == rawRoot else { throw PrivacyLabIdentityScopeError.stateRootNotCanonical }
        try rejectSymlinkComponents(root)
        try validateExistingOwnerDirectory(root)

        let fileURL = root.appendingPathComponent("se-attestation-p256.lab.v1", isDirectory: false)
        try validateExistingScopedFallbackFile(fileURL)

        let digest = Data(SHA256.hash(data: Data(root.path.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
        let label = "\(secureEnclaveBaseLabel).privacy-lab.\(digest.prefix(24))"
        return PrivacyLabIdentityScope(
            stateRoot: root,
            secureEnclaveLabel: label,
            secureEnclaveFileURL: fileURL
        )
    }

    static func validatedIfRequested(
        config: AppConfig,
        isolateLifecycle: Bool,
        requested: Bool
    ) throws -> PrivacyLabIdentityScope? {
        guard requested, config.privacyClassBeta else { return nil }
        return try validated(config: config, isolateLifecycle: isolateLifecycle)
    }

    private static func coordinatorIsLiteralLoopback(_ raw: String?) -> Bool {
        guard let raw,
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return false
        }
        guard scheme == "ws" || scheme == "wss" else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func rejectSymlinkComponents(_ root: URL) throws {
        let parts = root.path.split(separator: "/").map(String.init)
        var current = "/"
        for part in parts {
            current = URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(part)
                .path
            var info = stat()
            guard lstat(current, &info) == 0 else {
                throw PrivacyLabIdentityScopeError.stateRootUnsafe(current)
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw PrivacyLabIdentityScopeError.stateRootSymlink(current)
            }
        }
    }

    private static func validateExistingOwnerDirectory(_ root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700 else {
            throw PrivacyLabIdentityScopeError.stateRootUnsafe(root.path)
        }
    }

    private static func validateExistingScopedFallbackFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                return
            }
            throw PrivacyLabIdentityScopeError.stateRootUnsafe(url.path)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
            throw PrivacyLabIdentityScopeError.stateRootUnsafe(url.path)
        }
    }
}
