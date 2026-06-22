import Darwin
import Foundation

public enum BrowserOpenDecision: Equatable, Sendable {
    case opened
    case skippedNoTTY
    case skippedSSH
    case skippedDisabled
    case rejectedInvalidURL
}

public enum BrowserOpenError: Error, CustomStringConvertible {
    case spawnFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .spawnFailed(errno):
            return "open spawn failed: errno \(errno)"
        }
    }
}

public final class BrowserOpener: @unchecked Sendable {
    public typealias EnvironmentLookup = @Sendable (String) -> String?
    public typealias TTYCheck = @Sendable () -> Bool
    public typealias Spawn = @Sendable (String) throws -> Void

    private let hasControllingTTY: TTYCheck
    private let environment: EnvironmentLookup
    private let spawn: Spawn

    public init(
        hasControllingTTY: @escaping TTYCheck = { isatty(STDOUT_FILENO) == 1 },
        environment: @escaping EnvironmentLookup = { ProcessInfo.processInfo.environment[$0] },
        spawn: @escaping Spawn = { try BrowserOpener.posixSpawnOpen($0) }
    ) {
        self.hasControllingTTY = hasControllingTTY
        self.environment = environment
        self.spawn = spawn
    }

    @discardableResult
    public func openIfAllowed(_ claimURL: String, expectedPortalHost: String? = nil) throws -> BrowserOpenDecision {
        guard Self.isValidClaimURL(claimURL, expectedPortalHost: expectedPortalHost) else {
            return .rejectedInvalidURL
        }
        guard hasControllingTTY() else {
            return .skippedNoTTY
        }
        if let sshTTY = environment("SSH_TTY"), !sshTTY.isEmpty {
            return .skippedSSH
        }
        if environment("MACPROVIDER_NO_BROWSER") == "1" {
            return .skippedDisabled
        }
        try spawn(claimURL)
        return .opened
    }

    public static func isValidClaimURL(_ claimURL: String, expectedPortalHost: String? = nil, expectedPairOT: String? = nil) -> Bool {
        guard !claimURL.isEmpty, claimURL.utf8.count <= 4096 else {
            return false
        }
        if claimURL.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789?=&%_-./:")
        guard claimURL.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        guard let components = URLComponents(string: claimURL),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty
        else {
            return false
        }
        if let expectedPortalHost, host != expectedPortalHost {
            return false
        }
        guard components.path == "/claim",
              let ot = components.queryItems?.first(where: { $0.name == "ot" })?.value,
              !ot.isEmpty
        else {
            return false
        }
        if let expectedPairOT, ot != expectedPairOT {
            return false
        }
        return true
    }

    public static func portalHost(from claimURL: String) -> String? {
        URLComponents(string: claimURL)?.host
    }

    public static func portalHost(fromPortalBaseURL portalBaseURL: String?) -> String? {
        guard let portalBaseURL, !portalBaseURL.isEmpty else {
            return nil
        }
        return URLComponents(string: portalBaseURL)?.host
    }

    public static func posixSpawnOpen(_ claimURL: String) throws {
        var pid = pid_t()
        let executable = strdup("/usr/bin/open")
        let arg0 = strdup("open")
        let arg1 = strdup(claimURL)
        let environment = ProcessInfo.processInfo.environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        defer {
            free(executable)
            free(arg0)
            free(arg1)
            for entry in environment {
                free(entry)
            }
        }
        var argv: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
        var envp = environment
        envp.append(nil)
        let result = posix_spawn(&pid, executable, nil, nil, &argv, envp)
        if result != 0 {
            throw BrowserOpenError.spawnFailed(errno: result)
        }
    }
}
