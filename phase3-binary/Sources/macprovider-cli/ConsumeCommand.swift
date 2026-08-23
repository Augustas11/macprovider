import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import Security
@preconcurrency import NIO
@preconcurrency import NIOHTTP1

struct ConsumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "consume",
        abstract: "Start a loopback-only local consumer endpoint.",
        subcommands: [ConsumeRunCommand.self, ConsumeStatusCommand.self],
        defaultSubcommand: ConsumeRunCommand.self
    )
}

struct ConsumeRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the local consumer endpoint shell."
    )

    @Option(help: "Loopback address to bind. Default 127.0.0.1.")
    var bind: String = "127.0.0.1"

    @Option(help: "Local HTTP port to bind. Default 11435; port 0 is rejected.")
    var port: Int = 11435

    @Option(name: .customLong("credential-file"), help: "User-private buyer API key file.")
    var credentialFile: String?

    @Option(name: .customLong("upstream-gateway-url"), help: "HTTPS gateway origin. Default https://api.malibu.tech.")
    var upstreamGatewayURL: String = ConsumeEndpointDefaults.upstreamGatewayOrigin

    @Option(name: .customLong("allow-model"), parsing: .upToNextOption, help: "Allowed model id. Repeat for multiple models.")
    var allowedModels: [String] = []

    var environmentForTesting: [String: String]?
    var homeDirectoryForTesting: URL?

    func run() async throws {
        try await run(stopAfterListeningForTesting: false)
    }

    func run(stopAfterListeningForTesting: Bool) async throws {
        do {
            let normalizedBind = try ConsumeEndpointConfig.normalizeBindAddress(bind)
            let origin = try ConsumeEndpointConfig.normalizeUpstreamOrigin(upstreamGatewayURL)
            guard port != 0, (1...65_535).contains(port) else {
                throw ConsumeStartupError(code: "local_bind_rejected")
            }
            let launchID = UUID().uuidString.lowercased()
            let token = try ConsumeLocalToken.generate()
            var credential = try ConsumeCredentialLoader.load(
                explicitCredentialFile: credentialFile,
                environment: environmentForTesting ?? ProcessInfo.processInfo.environment,
                homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser
            )
            let credentialSourceClass = credential.sourceClass.rawValue
            let credentialStatus = credential.status
            let credentialCustody = ConsumeCredentialCustody(credential: credential)
            credential.zeroize()
            let descriptorStore = ConsumeActiveEndpointStore(
                homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser
            )
            let descriptorLock = try descriptorStore.acquireLock()
            let boundURL = ConsumeEndpointConfig.localBaseURL(bindAddress: normalizedBind, port: port)
            let descriptor = ConsumeEndpointDescriptor(
                boundURL: boundURL,
                processID: Int(getpid()),
                launchID: launchID,
                startedAt: ConsumeEndpointStatus.iso8601(Date()),
                ledgerPathClass: nil,
                localToken: token.value
            )
            let runtime = ConsumeEndpointRuntime(
                launchID: launchID,
                boundURL: descriptor.boundURL,
                upstreamOrigin: origin,
                credentialSourceClass: credentialSourceClass,
                credentialStatus: credentialStatus,
                modelAllowlist: allowedModels,
                tokenVerifier: token.verifier,
                credentialCustody: credentialCustody
            )
            let server = ConsumeLocalServer(
                bindAddress: normalizedBind,
                port: port,
                runtime: runtime,
                onListening: {
                    try descriptorStore.writeDescriptor(descriptor, lock: descriptorLock)
                    ConsumeEndpointStatus.writeStartup(
                        boundURL: descriptor.boundURL,
                        localToken: token.value,
                        upstreamOrigin: origin,
                        modelAllowlist: allowedModels,
                        credentialSourceClass: credentialSourceClass,
                        credentialState: credentialStatus.state.rawValue
                    )
                }
            )
            defer {
                try? descriptorStore.removeDescriptor(lock: descriptorLock)
            }
            try server.run(stopAfterListening: stopAfterListeningForTesting)
        } catch let error as ConsumeStartupError {
            ConsumeEndpointStatus.writeStderr("\(error.code)\n")
            throw error.exitCode
        } catch let error as ConsumeCredentialError {
            ConsumeEndpointStatus.writeStderr("\(error.redactedCode)\n")
            throw error.exitCode
        }
    }
}

struct ConsumeStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print redacted local consumer endpoint status."
    )

    var homeDirectoryForTesting: URL?

    func run() async throws {
        let store = ConsumeActiveEndpointStore(
            homeDirectory: homeDirectoryForTesting ?? FileManager.default.homeDirectoryForCurrentUser
        )
        guard let descriptor = try store.readLiveDescriptor() else {
            ConsumeEndpointStatus.writeStderr("local_endpoint_not_running\n")
            throw ExitCode(4)
        }
        do {
            let status = try await ConsumeStatusClient.fetch(descriptor: descriptor)
            try StatusCommand.writeJSON(status)
        } catch {
            ConsumeEndpointStatus.writeStderr("local_endpoint_not_running\n")
            throw ExitCode(4)
        }
    }
}

enum ConsumeEndpointDefaults {
    static let upstreamGatewayOrigin = "https://api.malibu.tech"
}

struct ConsumeStartupError: Error {
    let code: String
    var exitCode: ExitCode { ExitCode(2) }
}

enum ConsumeACL {
    static func hasExtendedACLEntry(fd: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return false }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        guard result >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return entry != nil
    }

    static func hasExtendedAllowEntry(fd: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == 0 || errno == ENOENT { return false }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        guard let rawText = acl_to_text(acl, &length) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(rawText)) }
        return String(cString: rawText).lowercased().contains("allow")
    }
}

struct ConsumeEndpointConfig {
    static func normalizeBindAddress(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "localhost" { return "127.0.0.1" }
        if value == "::1" { return "::1" }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let first = UInt8(parts[0]),
              first == 127,
              parts.dropFirst().allSatisfy({ UInt8($0) != nil }) else {
            throw ConsumeStartupError(code: "local_bind_rejected")
        }
        return value
    }

    static func normalizeUpstreamOrigin(_ raw: String) throws -> String {
        guard let components = URLComponents(string: raw),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              isGlobalUpstreamHost(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ConsumeStartupError(code: "local_upstream_url_rejected")
        }
        var normalized = "https://\(host)"
        if let port = components.port {
            normalized += ":\(port)"
        }
        return normalized
    }

    private static func isGlobalUpstreamHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalized.isEmpty,
              normalized != "localhost",
              !normalized.hasSuffix(".localhost"),
              !normalized.hasSuffix(".local"),
              normalized != "*" else {
            return false
        }
        if let bytes = ipv4Bytes(normalized) {
            return isGlobalIPv4(bytes)
        }
        if let bytes = ipv6Bytes(normalized) {
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return isGlobalIPv4(Array(bytes[12..<16]))
            }
            return isGlobalIPv6(bytes)
        }
        return true
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address.s_addr) { Array($0) }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isGlobalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        switch first {
        case 0, 10, 127:
            return false
        case 100 where (64...127).contains(second):
            return false
        case 169 where second == 254:
            return false
        case 172 where (16...31).contains(second):
            return false
        case 192 where second == 0 || second == 2 || second == 168:
            return false
        case 198 where second == 18 || second == 19 || second == 51:
            return false
        case 203 where second == 0 && bytes[2] == 113:
            return false
        case 224...255:
            return false
        default:
            return true
        }
    }

    private static func isGlobalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }
        if bytes[0] == 0xfc || bytes[0] == 0xfd { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        return true
    }

    static func localBaseURL(bindAddress: String, port: Int) -> String {
        if bindAddress.contains(":") {
            return "http://[\(bindAddress)]:\(port)"
        }
        return "http://\(bindAddress):\(port)"
    }
}

struct ConsumeLocalToken: Equatable {
    let value: String
    let verifier: ConsumeLocalTokenVerifier

    static func generate() throws -> ConsumeLocalToken {
        let tokenBytes = try randomBytes(count: 32)
        let verifierKey = try randomBytes(count: 32)
        let value = base64URL(tokenBytes)
        return ConsumeLocalToken(
            value: value,
            verifier: ConsumeLocalTokenVerifier(expectedToken: value, key: verifierKey)
        )
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ConsumeStartupError(code: "local_random_unavailable")
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct ConsumeLocalTokenVerifier: Equatable, Sendable {
    private let expectedDigest: Data
    private let key: Data

    init(expectedToken: String, key: Data) {
        self.key = key
        self.expectedDigest = Self.digest(token: expectedToken, key: key)
    }

    func verify(headers: HTTPHeaders) -> Bool {
        let candidates = acceptedTokenCandidates(headers: headers)
        guard candidates.count == 1 else { return false }
        let presentedDigest = Self.digest(token: candidates[0], key: key)
        return Self.constantTimeEqual(expectedDigest, presentedDigest)
    }

    private func acceptedTokenCandidates(headers: HTTPHeaders) -> [String] {
        var candidates: [String] = []
        for value in headers[canonicalForm: "authorization"] {
            guard value.hasPrefix("Bearer "), value.dropFirst("Bearer ".count).contains(" ") == false else {
                return ["", ""]
            }
            candidates.append(String(value.dropFirst("Bearer ".count)))
        }
        candidates.append(contentsOf: headers[canonicalForm: "api-key"].map(String.init))
        candidates.append(contentsOf: headers[canonicalForm: "x-api-key"].map(String.init))
        return candidates.filter { !$0.isEmpty }
    }

    private static func digest(token: String, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: symmetricKey)
        return Data(mac)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let count = max(lhs.count, rhs.count)
        var difference = UInt8(lhs.count ^ rhs.count)
        for index in 0..<count {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            difference |= l ^ r
        }
        return difference == 0
    }
}

enum ConsumeCredentialSourceClass: String {
    case explicitFile = "explicit_file"
    case defaultConfigFile = "default_config_file"
    case environment
    case missing
}

enum ConsumeCredentialState: String {
    case missing
    case loaded
}

struct ConsumeCredential: Equatable {
    var bytes: Data
    let sourceClass: ConsumeCredentialSourceClass
    let status: ConsumeCredentialStatus

    mutating func zeroize() {
        bytes.resetBytes(in: 0..<bytes.count)
    }
}

struct ConsumeCredentialStatus: Equatable, Sendable {
    let state: ConsumeCredentialState
    let fileIdentity: ConsumeFileIdentity?

    static let missing = ConsumeCredentialStatus(state: .missing, fileIdentity: nil)
    static let environmentLoaded = ConsumeCredentialStatus(state: .loaded, fileIdentity: nil)

    func currentState() -> ConsumeCredentialState {
        guard let fileIdentity else { return state }
        return fileIdentity.isStillSafe() ? .loaded : .missing
    }
}

struct ConsumeFileIdentity: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let mode: UInt16
    let uid: UInt32

    init(path: String, info: stat) {
        self.path = path
        self.device = UInt64(info.st_dev)
        self.inode = UInt64(info.st_ino)
        self.size = Int64(info.st_size)
        self.modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        self.modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        self.mode = UInt16(info.st_mode & UInt16.max)
        self.uid = UInt32(info.st_uid)
    }

    func isStillSafe() -> Bool {
        do {
            return try ConsumeCredentialLoader.currentFileIdentity(path: path) == self
        } catch {
            return false
        }
    }
}

enum ConsumeCredentialError: Error {
    case unsafeFile(sourceClass: ConsumeCredentialSourceClass, reason: String)
    case readFailed(sourceClass: ConsumeCredentialSourceClass)
    case rawFlagRejected

    var redactedCode: String {
        switch self {
        case .unsafeFile:
            return "local_credential_file_rejected"
        case .readFailed:
            return "local_credential_missing"
        case .rawFlagRejected:
            return "local_credential_flag_rejected"
        }
    }

    var exitCode: ExitCode { ExitCode(3) }
}

struct ConsumeCredentialLoader {
    static func load(
        explicitCredentialFile: String?,
        environment: [String: String],
        homeDirectory: URL
    ) throws -> ConsumeCredential {
        if let explicitCredentialFile {
            guard !looksLikeRawCredentialFlag(explicitCredentialFile) else {
                throw ConsumeCredentialError.rawFlagRejected
            }
            return try loadFile(path: explicitCredentialFile, sourceClass: .explicitFile)
        }
        if let envFile = nonEmpty(environment["MACPROVIDER_HTTP2_API_KEY_FILE"]) {
            return try loadFile(path: envFile, sourceClass: .explicitFile)
        }
        let defaultFile = homeDirectory
            .appendingPathComponent(".config/macprovider/buyer-api-key")
        if FileManager.default.fileExists(atPath: defaultFile.path) {
            return try loadFile(path: defaultFile.path, sourceClass: .defaultConfigFile)
        }
        for key in ["MACPROVIDER_HTTP2_API_KEY", "MP_API_KEY", "BUYER_TOKEN"] {
            if let value = nonEmpty(environment[key]) {
                return ConsumeCredential(bytes: Data(value.utf8), sourceClass: .environment, status: .environmentLoaded)
            }
        }
        return ConsumeCredential(bytes: Data(), sourceClass: .missing, status: .missing)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func looksLikeRawCredentialFlag(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        if trimmed.hasPrefix("sk-") || trimmed.hasPrefix("mp_") || trimmed.hasPrefix("malibu_") {
            return true
        }
        return trimmed.count >= 32 && trimmed.range(of: #"^[A-Za-z0-9_\-=.]+$"#, options: .regularExpression) != nil
    }

    private static func currentFileIdentity(path: String, sourceClass: ConsumeCredentialSourceClass) throws -> ConsumeFileIdentity {
        let opened = try openCredentialFile(path: path, sourceClass: sourceClass)
        close(opened.fd)
        return opened.identity
    }

    static func currentFileIdentity(path: String) throws -> ConsumeFileIdentity {
        try currentFileIdentity(path: path, sourceClass: .explicitFile)
    }

    private static func openCredentialFile(
        path: String,
        sourceClass: ConsumeCredentialSourceClass
    ) throws -> (fd: Int32, identity: ConsumeFileIdentity) {
        try validatePathHasNoSymlinkAndSafeParents(URL(fileURLWithPath: path), sourceClass: sourceClass)
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw ConsumeCredentialError.readFailed(sourceClass: sourceClass)
        }

        var opened = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == geteuid(),
              (opened.st_mode & (S_IRWXG | S_IRWXO)) == 0,
              (opened.st_mode & S_IRUSR) != 0 else {
            close(fd)
            throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "permission_class")
        }
        do {
            try rejectExtendedACL(fd: fd, sourceClass: sourceClass, reason: "file_acl")
        } catch {
            close(fd)
            throw error
        }
        var named = stat()
        guard lstat(path, &named) == 0,
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino else {
            close(fd)
            throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "file_identity_changed")
        }
        return (fd, ConsumeFileIdentity(path: path, info: opened))
    }

    private static func loadFile(path: String, sourceClass: ConsumeCredentialSourceClass) throws -> ConsumeCredential {
        let opened = try openCredentialFile(path: path, sourceClass: sourceClass)
        let fd = opened.fd
        defer { close(fd) }

        var data = Data()
        defer { data.resetBytes(in: 0..<data.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        defer {
            for index in buffer.indices {
                buffer[index] = 0
            }
        }
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw ConsumeCredentialError.readFailed(sourceClass: sourceClass)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= 16 * 1024 else {
                throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "too_large")
            }
        }
        trimASCIIWhitespace(&data)
        guard !data.isEmpty else {
            throw ConsumeCredentialError.readFailed(sourceClass: sourceClass)
        }
        var credentialBytes = Data()
        credentialBytes.append(data)
        return ConsumeCredential(
            bytes: credentialBytes,
            sourceClass: sourceClass,
            status: ConsumeCredentialStatus(state: .loaded, fileIdentity: opened.identity)
        )
    }

    private static func trimASCIIWhitespace(_ data: inout Data) {
        while let first = data.first, first == 0x20 || first == 0x09 || first == 0x0a || first == 0x0d {
            data.removeFirst()
        }
        while let last = data.last, last == 0x20 || last == 0x09 || last == 0x0a || last == 0x0d {
            data.removeLast()
        }
    }

    private static func validatePathHasNoSymlinkAndSafeParents(_ url: URL, sourceClass: ConsumeCredentialSourceClass) throws {
        let standardized = url.standardizedFileURL
        let components = standardized.pathComponents
        var current = components.first == "/" ? URL(fileURLWithPath: "/") : URL(fileURLWithPath: ".")
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                if current.path == standardized.path { return }
                throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "parent_missing")
            }
            guard (info.st_mode & S_IFMT) != S_IFLNK else {
                throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "symlink_ambiguous")
            }
	            if current.path != standardized.path {
	                guard (info.st_mode & S_IFMT) == S_IFDIR,
	                      (info.st_uid == geteuid() || info.st_uid == 0),
	                      (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
	                    throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "unsafe_parent")
	                }
                let fd = open(current.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else {
                    throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "unsafe_parent")
                }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0,
                      opened.st_dev == info.st_dev,
                      opened.st_ino == info.st_ino,
                      (opened.st_mode & S_IFMT) == S_IFDIR,
                      (opened.st_uid == geteuid() || opened.st_uid == 0),
                      (opened.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                      (try? !ConsumeACL.hasExtendedAllowEntry(fd: fd)) == true else {
                    throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: "unsafe_parent")
                }
	            }
	        }
	    }

	    private static func rejectExtendedACL(fd: Int32, sourceClass: ConsumeCredentialSourceClass, reason: String) throws {
	        guard (try? !ConsumeACL.hasExtendedACLEntry(fd: fd)) == true else {
	            throw ConsumeCredentialError.unsafeFile(sourceClass: sourceClass, reason: reason)
	        }
	    }
}

struct ConsumeEndpointDescriptor: Codable, Equatable {
    static let schemaVersion = "local_consumer_endpoint.descriptor.v1"

    let schemaVersion: String
    let boundURL: String
    let processID: Int
    let launchID: String
    let startedAt: String
    let ledgerPathClass: String?
    let localToken: String

    init(
        boundURL: String,
        processID: Int,
        launchID: String,
        startedAt: String,
        ledgerPathClass: String?,
        localToken: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.boundURL = boundURL
        self.processID = processID
        self.launchID = launchID
        self.startedAt = startedAt
        self.ledgerPathClass = ledgerPathClass
        self.localToken = localToken
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case boundURL = "bound_url"
        case processID = "process_id"
        case launchID = "process_launch_id"
        case startedAt = "started_at"
        case ledgerPathClass = "ledger_path_class"
        case localToken = "local_token"
    }
}

final class ConsumeActiveEndpointLock: @unchecked Sendable {
    let fd: Int32
    let rootFD: Int32
    let url: URL

    init(fd: Int32, rootFD: Int32, url: URL) {
        self.fd = fd
        self.rootFD = rootFD
        self.url = url
    }

    deinit {
        _ = flock(fd, LOCK_UN)
        close(fd)
        close(rootFD)
    }
}

struct ConsumeActiveEndpointStore {
    let root: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.root = homeDirectory
            .appendingPathComponent("Library/Application Support/macprovider/consume", isDirectory: true)
    }

    var descriptorURL: URL { root.appendingPathComponent("active-endpoint.json") }
    var lockURL: URL { root.appendingPathComponent("active-endpoint.lock") }

    func acquireLock() throws -> ConsumeActiveEndpointLock {
        try ensurePrivateRoot()
        let rootFD = try openValidatedRootFD()
        let fd = openat(rootFD, "active-endpoint.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            close(rootFD)
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        var result: Int32
        repeat {
            result = flock(fd, LOCK_EX | LOCK_NB)
        } while result != 0 && errno == EINTR
        guard result == 0 else {
            close(fd)
            close(rootFD)
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0,
              activeEndpointFileIsPrivate(fd: fd),
              rejectExtendedACL(fd: fd) else {
            close(fd)
            close(rootFD)
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        return ConsumeActiveEndpointLock(fd: fd, rootFD: rootFD, url: lockURL)
    }

    func writeDescriptor(_ descriptor: ConsumeEndpointDescriptor, lock: ConsumeActiveEndpointLock) throws {
        guard lock.url == lockURL else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(descriptor)
        data.append(0x0a)
        let temporaryName = ".active-endpoint.json.tmp-\(UUID().uuidString.lowercased())"
        let fd = openat(lock.rootFD, temporaryName, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        var shouldRemove = true
        defer {
            close(fd)
            if shouldRemove { unlinkat(lock.rootFD, temporaryName, 0) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw ConsumeStartupError(code: "local_active_endpoint_exists") }
                offset += written
            }
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0,
              activeEndpointFileIsPrivate(fd: fd),
              rejectExtendedACL(fd: fd),
              fsync(fd) == 0 else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        guard renameat(lock.rootFD, temporaryName, lock.rootFD, "active-endpoint.json") == 0 else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        shouldRemove = false
        try fsyncRoot(fd: lock.rootFD)
    }

    func removeDescriptor(lock: ConsumeActiveEndpointLock) throws {
        guard lock.url == lockURL else { return }
        _ = unlinkat(lock.rootFD, "active-endpoint.json", 0)
    }

    func readLiveDescriptor() throws -> ConsumeEndpointDescriptor? {
        guard let descriptor = try readDescriptor() else { return nil }
        guard activeEndpointLockIsHeld() else {
            return nil
        }
        guard processAppearsLive(pid: descriptor.processID) else {
            return nil
        }
        return descriptor
    }

    private func readDescriptor() throws -> ConsumeEndpointDescriptor? {
        try ensurePrivateRoot()
        let rootFD = try openValidatedRootFD()
        defer { close(rootFD) }
        let fd = openat(rootFD, "active-endpoint.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ConsumeStartupError(code: "local_endpoint_not_running")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              activeEndpointFileIsPrivate(fd: fd),
              rejectExtendedACL(fd: fd) else {
            throw ConsumeStartupError(code: "local_endpoint_not_running")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ConsumeStartupError(code: "local_endpoint_not_running") }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= 16 * 1024 else { throw ConsumeStartupError(code: "local_endpoint_not_running") }
        }
        return try JSONDecoder().decode(ConsumeEndpointDescriptor.self, from: data)
    }

    private func ensurePrivateRoot() throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validatePrivateRootAncestry()
        let fd = try openValidatedRootFD()
        close(fd)
    }

    private func validatePrivateRootAncestry() throws {
        let standardized = root.standardizedFileURL
        let components = standardized.pathComponents
        var current = components.first == "/" ? URL(fileURLWithPath: "/") : URL(fileURLWithPath: ".")
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  (info.st_mode & S_IFMT) != S_IFLNK,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  (info.st_uid == geteuid() || info.st_uid == 0),
                  (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
                throw ConsumeStartupError(code: "local_active_endpoint_exists")
            }
            let fd = open(current.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else {
                throw ConsumeStartupError(code: "local_active_endpoint_exists")
            }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0,
                  opened.st_dev == info.st_dev,
                  opened.st_ino == info.st_ino,
                  (opened.st_mode & S_IFMT) == S_IFDIR,
                  (opened.st_uid == geteuid() || opened.st_uid == 0),
                  (opened.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                  (try? !ConsumeACL.hasExtendedAllowEntry(fd: fd)) == true else {
                throw ConsumeStartupError(code: "local_active_endpoint_exists")
            }
        }
    }

    private func fsyncRoot(fd: Int32) throws {
        guard fsync(fd) == 0 else { throw ConsumeStartupError(code: "local_active_endpoint_exists") }
    }

    private func activeEndpointLockIsHeld() -> Bool {
        guard let rootFD = try? openValidatedRootFD() else { return false }
        defer { close(rootFD) }
        let fd = openat(rootFD, "active-endpoint.lock", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard activeEndpointFileIsPrivate(fd: fd),
              rejectExtendedACL(fd: fd) else {
            return false
        }
        var result: Int32
        repeat {
            result = flock(fd, LOCK_SH | LOCK_NB)
        } while result != 0 && errno == EINTR
        if result == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private func openValidatedRootFD() throws -> Int32 {
        var named = stat()
        guard lstat(root.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              named.st_uid == geteuid(),
              (named.st_mode & 0o777) == S_IRWXU else {
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        let fd = open(root.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ConsumeStartupError(code: "local_active_endpoint_exists") }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              opened.st_uid == geteuid(),
              (opened.st_mode & 0o777) == S_IRWXU,
              rejectExtendedACL(fd: fd) else {
            close(fd)
            throw ConsumeStartupError(code: "local_active_endpoint_exists")
        }
        return fd
    }

    private func activeEndpointFileIsPrivate(fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFREG &&
            info.st_uid == geteuid() &&
            (info.st_mode & (S_IRWXG | S_IRWXO)) == 0 &&
            info.st_nlink == 1
    }

    private func rejectExtendedACL(fd: Int32) -> Bool {
        (try? !ConsumeACL.hasExtendedACLEntry(fd: fd)) == true
    }

    private func processAppearsLive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}

struct ConsumeEndpointRuntime: Sendable {
    let launchID: String
    let boundURL: String
    let upstreamOrigin: String
    let credentialSourceClass: String
    let modelAllowlist: [String]
    let tokenVerifier: ConsumeLocalTokenVerifier
    let credentialCustody: ConsumeCredentialCustody
    let requestCounter: ConsumeEndpointRequestCounter

    init(
        launchID: String,
        boundURL: String,
        upstreamOrigin: String,
        credentialSourceClass: String,
        credentialStatus: ConsumeCredentialStatus,
        modelAllowlist: [String],
        tokenVerifier: ConsumeLocalTokenVerifier,
        credentialCustody: ConsumeCredentialCustody? = nil,
        requestCounter: ConsumeEndpointRequestCounter = ConsumeEndpointRequestCounter()
    ) {
        self.launchID = launchID
        self.boundURL = boundURL
        self.upstreamOrigin = upstreamOrigin
        self.credentialSourceClass = credentialSourceClass
        self.modelAllowlist = modelAllowlist
        self.tokenVerifier = tokenVerifier
        self.credentialCustody = credentialCustody ?? ConsumeCredentialCustody(status: credentialStatus)
        self.requestCounter = requestCounter
    }

    func beginIncompleteConnection() -> Bool {
        requestCounter.beginIncompleteConnection()
    }

    func completePreAuthConnection() {
        requestCounter.completePreAuthConnection()
    }

    func endIncompleteConnection() {
        requestCounter.endIncompleteConnection()
    }

    func beginRequest() -> Bool {
        requestCounter.begin()
    }

    func endRequest() {
        requestCounter.end()
    }

    func reserveBodyBytes(_ count: Int) -> Bool {
        requestCounter.reserveBodyBytes(count)
    }

    func releaseBodyBytes(_ count: Int) {
        requestCounter.releaseBodyBytes(count)
    }

    func statusPayload() -> [String: Any] {
        [
            "schema_version": "local_consumer_endpoint.status.v1",
            "process_launch_id": launchID,
            "bound_url": boundURL,
            "upstream_gateway_origin": upstreamOrigin,
            "credential_source_class": credentialSourceClass,
            "credential_state": credentialCustody.currentState().rawValue,
            "model_allowlist": modelAllowlist,
            "local_auth_state": "required",
            "pricing_trust_state": "unavailable",
            "pricing_warning_codes": [],
            "unpriced_override": false,
            "no_budget": false,
            "budget_configured_micro_usd": NSNull(),
            "budget_used_micro_usd": NSNull(),
            "budget_held_micro_usd": NSNull(),
            "budget_remaining_micro_usd": NSNull(),
            "ledger_path_class": NSNull(),
            "active_request_count": requestCounter.current(),
            "last_successful_upstream_contact_at": NSNull(),
            "error_ring": [],
        ]
    }
}

final class ConsumeCredentialCustody: @unchecked Sendable {
    private let lock = NSLock()
    private let status: ConsumeCredentialStatus

    init(credential: ConsumeCredential) {
        self.status = credential.status
    }

    init(status: ConsumeCredentialStatus) {
        self.status = status
    }

    func currentState() -> ConsumeCredentialState {
        lock.lock()
        defer { lock.unlock() }
        return status.currentState()
    }
}

enum ConsumeLocalLimits {
    static let requestLineBytes = 8 * 1024
    static let requestTargetBytes = 2 * 1024
    static let headerCount = 96
    static let headerBytes = 64 * 1024
    static let bodyBytes = 1 * 1024 * 1024
    static let headerReadTimeout: TimeAmount = .seconds(5)
    static let requestReadTimeout: TimeAmount = .seconds(15)
    static let bodyIdleTimeout: TimeAmount = .seconds(5)

    static var httpDecoderLimitConfiguration: NIOHTTPDecoderLimitConfiguration {
        var configuration = NIOHTTPDecoderLimitConfiguration()
        configuration.maxHeaderFieldSize = headerBytes
        configuration.maxHeaderListSize = headerBytes
        configuration.maxHeaderFieldCount = headerCount
        return configuration
    }
}

enum ConsumeLocalEndpoint: Sendable {
    case status
    case models
    case chatCompletions
}

struct ConsumeValidatedRequest {
    let endpoint: ConsumeLocalEndpoint
}

final class ConsumeEndpointRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let maxIncompleteConnections: Int
    private let maxActiveRequests: Int
    private let maxBufferedBodyBytes: Int
    private var incompleteConnections = 0
    private var value = 0
    private var bufferedBodyBytes = 0

    init(
        maxIncompleteConnections: Int = 16,
        maxActiveRequests: Int = 32,
        maxBufferedBodyBytes: Int = 8 * 1024 * 1024
    ) {
        self.maxIncompleteConnections = maxIncompleteConnections
        self.maxActiveRequests = maxActiveRequests
        self.maxBufferedBodyBytes = maxBufferedBodyBytes
    }

    func beginIncompleteConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard incompleteConnections < maxIncompleteConnections else { return false }
        incompleteConnections += 1
        return true
    }

    func completePreAuthConnection() {
        lock.lock()
        if incompleteConnections > 0 {
            incompleteConnections -= 1
        }
        lock.unlock()
    }

    func endIncompleteConnection() {
        completePreAuthConnection()
    }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value < maxActiveRequests else { return false }
        value += 1
        return true
    }

    func end() {
        lock.lock()
        value = max(0, value - 1)
        lock.unlock()
    }

    func reserveBodyBytes(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count >= 0,
              bufferedBodyBytes <= maxBufferedBodyBytes - count else {
            return false
        }
        bufferedBodyBytes += count
        return true
    }

    func releaseBodyBytes(_ count: Int) {
        lock.lock()
        bufferedBodyBytes = max(0, bufferedBodyBytes - max(0, count))
        lock.unlock()
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct ConsumeEndpointStatus {
    private static let testStderrSink = ConsumeEndpointStatusSink()

    static func writeStartup(
        boundURL: String,
        localToken: String,
        upstreamOrigin: String,
        modelAllowlist: [String],
        credentialSourceClass: String,
        credentialState: String
    ) {
        let sample = modelAllowlist.prefix(5).joined(separator: ",")
        let allowlistSummary = modelAllowlist.isEmpty
            ? "count=0 warning=empty_model_allowlist"
            : "count=\(modelAllowlist.count) sample=\(sample)"
        writeStderr(
            [
                "local_consumer_endpoint=started",
                "base_url=\(boundURL)",
                "local_token=\(localToken)",
                "upstream_gateway_origin=\(upstreamOrigin)",
                "model_allowlist=\(allowlistSummary)",
                "budget_mode=unconfigured",
                "unpriced_override=false",
                "credential_source_class=\(credentialSourceClass)",
                "credential_state=\(credentialState)",
            ].joined(separator: " ") + "\n"
        )
    }

    static func writeStderr(_ text: String) {
        if testStderrSink.write(text) {
            return
        }
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func replaceStderrSinkForTesting(_ sink: ((String) -> Void)?) -> (() -> Void) {
        let previous = testStderrSink.replace(sink)
        return {
            _ = testStderrSink.replace(previous)
        }
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

final class ConsumeEndpointStatusSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((String) -> Void)?

    func replace(_ next: ((String) -> Void)?) -> ((String) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let previous = sink
        sink = next
        return previous
    }

    func write(_ text: String) -> Bool {
        lock.lock()
        let current = sink
        lock.unlock()
        guard let current else { return false }
        current(text)
        return true
    }
}

struct ConsumeLocalServer {
    let bindAddress: String
    let port: Int
    let runtime: ConsumeEndpointRuntime
    let onListening: @Sendable () throws -> Void

    func run(stopAfterListening: Bool = false) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 0)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ConsumeStartLineLimitHandler()).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(
                        withDecoderLimitConfiguration: ConsumeLocalLimits.httpDecoderLimitConfiguration
                    )
                }.flatMap {
                    channel.pipeline.addHandler(ConsumeLocalHandler(runtime: runtime))
                }
            }
        let channel: Channel
        do {
            channel = try bootstrap.bind(host: bindAddress, port: port).wait()
        } catch {
            throw ConsumeStartupError(code: "local_bind_rejected")
        }
        do {
            try onListening()
        } catch {
            try? channel.close().wait()
            throw error
        }
        if stopAfterListening {
            try channel.close().wait()
            return
        }
        try channel.closeFuture.wait()
    }
}

final class ConsumeStartLineLimitHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var startLineComplete = false
    private var bufferedBytes: [UInt8] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !startLineComplete else {
            context.fireChannelRead(data)
            return
        }
        let bytes = Array(unwrapInboundIn(data).readableBytesView)
        for (index, byte) in bytes.enumerated() {
            bufferedBytes.append(byte)
            guard bufferedBytes.count <= ConsumeLocalLimits.requestLineBytes || byte == 0x0A else {
                context.close(promise: nil)
                return
            }
            if byte == 0x0A {
                var line = bufferedBytes
                line.removeLast()
                if line.last == 0x0D {
                    line.removeLast()
                }
                guard Self.isAllowedStartLine(line) else {
                    context.close(promise: nil)
                    return
                }
                startLineComplete = true
                if index + 1 < bytes.count {
                    bufferedBytes.append(contentsOf: bytes[(index + 1)...])
                }
                var forwarded = context.channel.allocator.buffer(capacity: bufferedBytes.count)
                forwarded.writeBytes(bufferedBytes)
                bufferedBytes.removeAll(keepingCapacity: false)
                context.fireChannelRead(wrapInboundOut(forwarded))
                return
            }
        }
    }

    private static func isAllowedStartLine(_ line: [UInt8]) -> Bool {
        guard line.count <= ConsumeLocalLimits.requestLineBytes,
              let methodEnd = line.firstIndex(of: 0x20) else {
            return false
        }
        let method = line[..<methodEnd]
        guard !method.isEmpty,
              method.allSatisfy(isMethodTokenByte) else {
            return false
        }
        let targetStart = methodEnd + 1
        guard targetStart < line.endIndex,
              let targetEnd = line[targetStart...].firstIndex(of: 0x20),
              targetEnd > targetStart,
              targetEnd - targetStart <= ConsumeLocalLimits.requestTargetBytes else {
            return false
        }
        let versionStart = targetEnd + 1
        guard versionStart < line.endIndex,
              !line[versionStart...].contains(0x20) else {
            return false
        }
        return Array(line[versionStart...]) == Array("HTTP/1.0".utf8)
            || Array(line[versionStart...]) == Array("HTTP/1.1".utf8)
    }

    private static func isMethodTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A:
            return true
        default:
            return false
        }
    }
}

final class ConsumeLocalHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let runtime: ConsumeEndpointRuntime
    private var requestHead: HTTPRequestHead?
    private var validatedRequest: ConsumeValidatedRequest?
    private var requestBody = Data()
    private var connectionIsIncompletePreAuth = false
    private var requestIsActive = false
    private var reservedBodyBytes = 0
    private var responseStarted = false
    private var headerDeadlineTask: Scheduled<Void>?
    private var requestDeadlineTask: Scheduled<Void>?
    private var bodyIdleDeadlineTask: Scheduled<Void>?
    private var channelForDeadline: Channel?

    init(runtime: ConsumeEndpointRuntime) {
        self.runtime = runtime
    }

    func channelActive(context: ChannelHandlerContext) {
        guard runtime.beginIncompleteConnection() else {
            context.close(promise: nil)
            return
        }
        connectionIsIncompletePreAuth = true
        channelForDeadline = context.channel
        headerDeadlineTask = context.eventLoop.scheduleTask(in: ConsumeLocalLimits.headerReadTimeout) { [weak self] in
            self?.closeIfHeaderMissing()
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            headerDeadlineTask?.cancel()
            headerDeadlineTask = nil
            requestHead = head
            completeIncompletePreAuthConnection()
            guard runtime.beginRequest() else {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_endpoint_busy")
                return
            }
            requestIsActive = true
            startRequestDeadline(context: context)
            handleHead(head, context: context)
        case .body(var buffer):
            guard !responseStarted else { return }
            guard requestBody.count + buffer.readableBytes <= ConsumeLocalLimits.bodyBytes else {
                writeLocalError(context: context, status: .payloadTooLarge, code: "local_request_too_large")
                return
            }
            let readableBytes = buffer.readableBytes
            guard runtime.reserveBodyBytes(readableBytes) else {
                writeLocalError(context: context, status: .serviceUnavailable, code: "local_endpoint_busy")
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
                reservedBodyBytes += bytes.count
                refreshBodyIdleDeadline(context: context)
            } else {
                runtime.releaseBodyBytes(readableBytes)
            }
        case .end:
            cancelPostHeaderDeadlines()
            guard let head = requestHead else {
                context.close(promise: nil)
                return
            }
            guard !responseStarted else {
                endRequestIfNeeded()
                return
            }
            handleEnd(head: head, context: context)
            endRequestIfNeeded()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        headerDeadlineTask?.cancel()
        headerDeadlineTask = nil
        cancelPostHeaderDeadlines()
        channelForDeadline = nil
        if connectionIsIncompletePreAuth {
            runtime.endIncompleteConnection()
            connectionIsIncompletePreAuth = false
        }
        endRequestIfNeeded()
    }

    private func handleHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        if head.method == .HEAD {
            writeHeadOnly(context: context, status: .methodNotAllowed)
            return
        }
        if let error = validatePreAuthBoundsAndFraming(head) {
            writeLocalError(context: context, status: error.status, code: error.code)
            return
        }
        if let error = validateBrowserOrigin(head) {
            writeLocalError(context: context, status: error.status, code: error.code)
            return
        }
        let statusNoStore = head.method == .GET && head.uri == "/v1/status"
        guard runtime.tokenVerifier.verify(headers: head.headers) else {
            writeLocalError(
                context: context,
                status: .unauthorized,
                code: "local_auth_required",
                extraHeaders: statusNoStore ? [("cache-control", "no-store")] : []
            )
            return
        }
        do {
            validatedRequest = try validateEndpoint(head)
        } catch let error as ConsumeLocalValidationError {
            writeLocalError(context: context, status: error.status, code: error.code)
        } catch {
            writeLocalError(context: context, status: .badRequest, code: "local_invalid_request")
        }
    }

    private func handleEnd(head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard let validatedRequest else {
            return
        }
        switch validatedRequest.endpoint {
        case .status:
            guard requestBody.isEmpty else {
                writeLocalError(context: context, status: .badRequest, code: "local_invalid_request")
                return
            }
            writeJSON(
                context: context,
                status: .ok,
                body: runtime.statusPayload(),
                extraHeaders: [("cache-control", "no-store")]
            )
        case .models:
            guard requestBody.isEmpty else {
                writeLocalError(context: context, status: .badRequest, code: "local_invalid_request")
                return
            }
            writeLocalModels(context: context)
        case .chatCompletions:
            guard validateLocalBody(head: head, body: requestBody, requiresJSONObject: true, context: context) else {
                return
            }
            writeLocalError(context: context, status: .badRequest, code: "local_budget_required")
        }
    }

    private func validatePreAuthBoundsAndFraming(_ head: HTTPRequestHead) -> ConsumeLocalValidationError? {
        let requestLineBytes = "\(head.method.rawValue) \(head.uri) HTTP/\(head.version.major).\(head.version.minor)".utf8.count
        guard requestLineBytes <= ConsumeLocalLimits.requestLineBytes,
              head.uri.utf8.count <= ConsumeLocalLimits.requestTargetBytes else {
            return ConsumeLocalValidationError(status: .payloadTooLarge, code: "local_request_too_large")
        }
        var headerBytes = 0
        var headerCount = 0
        for (name, value) in head.headers {
            headerCount += 1
            headerBytes += name.utf8.count + value.utf8.count + 4
        }
        guard headerCount <= ConsumeLocalLimits.headerCount,
              headerBytes <= ConsumeLocalLimits.headerBytes else {
            return ConsumeLocalValidationError(status: .payloadTooLarge, code: "local_request_too_large")
        }
        let contentLengths = head.headers["content-length"]
        guard contentLengths.count <= 1 else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        for value in contentLengths {
            let normalized = value.trimmingCharacters(in: .whitespaces)
            guard normalized.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil,
                  !value.contains(","),
                  let length = Int(normalized) else {
                return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
            }
            guard length <= ConsumeLocalLimits.bodyBytes else {
                return ConsumeLocalValidationError(status: .payloadTooLarge, code: "local_request_too_large")
            }
        }
        let transferTokens = head.headers["transfer-encoding"]
            .flatMap { value in
                value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
        guard transferTokens.allSatisfy({ !$0.isEmpty }) else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        guard contentLengths.isEmpty || transferTokens.isEmpty else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        guard transferTokens.isEmpty || transferTokens == ["chunked"] else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        return nil
    }

    private func validateBrowserOrigin(_ head: HTTPRequestHead) -> ConsumeLocalValidationError? {
        if head.method == .OPTIONS,
           !head.headers[canonicalForm: "access-control-request-method"].isEmpty {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        var origins: [String] = []
        for (name, value) in head.headers where name.caseInsensitiveCompare("origin") == .orderedSame {
            origins.append(value)
        }
        guard origins.count <= 1 else {
            return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        if let origin = origins.first {
            let normalized = origin.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized == origin,
                  origin != "null",
                  !origin.contains(","),
                  origin == runtime.boundURL else {
                return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
            }
        }
        for site in head.headers[canonicalForm: "sec-fetch-site"] {
            let normalized = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "same-origin" || normalized == "none" else {
                return ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
            }
        }
        return nil
    }

    private func validateEndpoint(_ head: HTTPRequestHead) throws -> ConsumeValidatedRequest {
        let target = try decodeExactRequestTarget(head.uri)
        switch (head.method, target) {
        case (.GET, "/v1/status"):
            return ConsumeValidatedRequest(endpoint: .status)
        case (.GET, "/v1/models"):
            return ConsumeValidatedRequest(endpoint: .models)
        case (.POST, "/v1/chat/completions"):
            return ConsumeValidatedRequest(endpoint: .chatCompletions)
        case (.POST, "/v1/status"), (.POST, "/v1/models"), (.GET, "/v1/chat/completions"):
            throw ConsumeLocalValidationError(status: .methodNotAllowed, code: "local_endpoint_unsupported")
        default:
            throw ConsumeLocalValidationError(status: .notFound, code: "local_endpoint_unsupported")
        }
    }

    private func decodeExactRequestTarget(_ rawTarget: String) throws -> String {
        guard rawTarget.first == "/" else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        if let hash = rawTarget.firstIndex(of: "#"), hash != rawTarget.endIndex {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        if let query = rawTarget.firstIndex(of: "?") {
            let afterQuery = rawTarget.index(after: query)
            guard afterQuery == rawTarget.endIndex else {
                throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
            }
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        guard !rawTarget.contains("\\") else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        let lowercase = rawTarget.lowercased()
        guard !lowercase.contains("%2f"), !lowercase.contains("%5c") else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        let decoded = try percentDecodePath(rawTarget)
        guard decoded == rawTarget else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard !decoded.contains("//"),
              !components.contains("."),
              !components.contains("..") else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        guard decoded == "/v1/status" || decoded == "/v1/models" || decoded == "/v1/chat/completions" else {
            return decoded
        }
        return decoded
    }

    private func percentDecodePath(_ rawPath: String) throws -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rawPath.utf8.count)
        var index = rawPath.utf8.startIndex
        while index < rawPath.utf8.endIndex {
            let byte = rawPath.utf8[index]
            if byte == 0x25 {
                let first = rawPath.utf8.index(after: index)
                guard first < rawPath.utf8.endIndex else {
                    throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
                }
                let second = rawPath.utf8.index(after: first)
                guard second < rawPath.utf8.endIndex,
                      let high = hex(rawPath.utf8[first]),
                      let low = hex(rawPath.utf8[second]) else {
                    throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
                }
                bytes.append(high << 4 | low)
                index = rawPath.utf8.index(after: second)
            } else {
                bytes.append(byte)
                index = rawPath.utf8.index(after: index)
            }
            guard bytes.count <= ConsumeLocalLimits.requestTargetBytes else {
                throw ConsumeLocalValidationError(status: .payloadTooLarge, code: "local_request_too_large")
            }
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else {
            throw ConsumeLocalValidationError(status: .badRequest, code: "local_invalid_request")
        }
        return decoded
    }

    private func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            return byte - 48
        case 65...70:
            return byte - 55
        case 97...102:
            return byte - 87
        default:
            return nil
        }
    }

    private func validateLocalBody(
        head: HTTPRequestHead,
        body: Data,
        requiresJSONObject: Bool,
        context: ChannelHandlerContext
    ) -> Bool {
        let encodings = head.headers[canonicalForm: "content-encoding"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard encodings.isEmpty || encodings == ["identity"] else {
            writeLocalError(context: context, status: HTTPResponseStatus(statusCode: 415), code: "local_content_encoding_unsupported")
            return false
        }
        guard body.count <= ConsumeLocalLimits.bodyBytes else {
            writeLocalError(context: context, status: .payloadTooLarge, code: "local_request_too_large")
            return false
        }
        guard !requiresJSONObject || !body.isEmpty,
              let text = String(data: body, encoding: .utf8),
              let parsed = try? StrictJSONParser.parse(text),
              !requiresJSONObject || parsed.isObject else {
            writeLocalError(context: context, status: .badRequest, code: "local_invalid_request")
            return false
        }
        return true
    }

    private func writeLocalModels(context: ChannelHandlerContext) {
        let models = runtime.modelAllowlist.map { modelID in
            [
                "id": modelID,
                "object": "model",
                "created": 0,
                "owned_by": "macprovider",
            ] as [String: Any]
        }
        writeJSON(
            context: context,
            status: .ok,
            body: [
                "object": "list",
                "data": models,
            ],
            extraHeaders: [("cache-control", "no-store")]
        )
    }

    private func endRequestIfNeeded() {
        cancelPostHeaderDeadlines()
        if reservedBodyBytes > 0 {
            runtime.releaseBodyBytes(reservedBodyBytes)
            reservedBodyBytes = 0
        }
        guard requestIsActive else { return }
        requestIsActive = false
        runtime.endRequest()
    }

    private func completeIncompletePreAuthConnection() {
        guard connectionIsIncompletePreAuth else { return }
        connectionIsIncompletePreAuth = false
        runtime.completePreAuthConnection()
    }

    private func closeIfHeaderMissing() {
        guard requestHead == nil else { return }
        channelForDeadline?.close(promise: nil)
    }

    private func startRequestDeadline(context: ChannelHandlerContext) {
        requestDeadlineTask?.cancel()
        requestDeadlineTask = context.eventLoop.scheduleTask(in: ConsumeLocalLimits.requestReadTimeout) { [weak self] in
            self?.closeIfRequestIncomplete()
        }
        if shouldReadBody {
            refreshBodyIdleDeadline(context: context)
        }
    }

    private var shouldReadBody: Bool {
        guard let endpoint = validatedRequest?.endpoint else { return true }
        return endpoint == .chatCompletions
    }

    private func refreshBodyIdleDeadline(context: ChannelHandlerContext) {
        bodyIdleDeadlineTask?.cancel()
        bodyIdleDeadlineTask = context.eventLoop.scheduleTask(in: ConsumeLocalLimits.bodyIdleTimeout) { [weak self] in
            self?.closeIfRequestIncomplete()
        }
    }

    private func closeIfRequestIncomplete() {
        guard requestIsActive, !responseStarted else { return }
        channelForDeadline?.close(promise: nil)
    }

    private func cancelPostHeaderDeadlines() {
        requestDeadlineTask?.cancel()
        requestDeadlineTask = nil
        bodyIdleDeadlineTask?.cancel()
        bodyIdleDeadlineTask = nil
    }

    private func writeLocalError(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        code: String,
        forwardedUpstream: Bool = false,
        extraHeaders: [(String, String)] = []
    ) {
        writeJSON(
            context: context,
            status: status,
            body: errorEnvelope(code: code, forwardedUpstream: forwardedUpstream),
            extraHeaders: extraHeaders
        )
    }

    private func writeJSON(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: Any,
        extraHeaders: [(String, String)] = []
    ) {
        do {
            let data = try body is NSNull
                ? Data()
                : JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
            var headers = HTTPHeaders()
            if !(body is NSNull) {
                headers.add(name: "content-type", value: "application/json")
            }
            headers.add(name: "content-length", value: "\(data.count)")
            headers.add(name: "connection", value: "close")
            for (name, value) in extraHeaders {
                headers.add(name: name, value: value)
            }
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            responseStarted = true
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if !data.isEmpty {
                var buffer = context.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            context.close(promise: nil)
        } catch {
            context.close(promise: nil)
        }
    }

    private func writeHeadOnly(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        var headers = HTTPHeaders()
        headers.add(name: "content-length", value: "0")
        headers.add(name: "connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        responseStarted = true
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }

    private func errorEnvelope(code: String, forwardedUpstream: Bool) -> [String: Any] {
        [
            "error": [
                "message": code,
                "type": "macprovider_local_error",
                "param": NSNull(),
                "code": code,
                "macprovider": ["forwarded_upstream": forwardedUpstream],
            ],
        ]
    }
}

struct ConsumeLocalValidationError: Error {
    let status: HTTPResponseStatus
    let code: String
}

private extension JSONValue {
    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}

struct ConsumeStatusClient {
    static func fetch(descriptor: ConsumeEndpointDescriptor) async throws -> [String: Any] {
        guard let url = statusURL(from: descriptor.boundURL) else {
            throw ConsumeStartupError(code: "local_endpoint_not_running")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(descriptor.localToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = directLoopbackSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["process_launch_id"] as? String == descriptor.launchID else {
            throw ConsumeStartupError(code: "local_endpoint_not_running")
        }
        return object
    }

    private static func statusURL(from boundURL: String) -> URL? {
        guard var components = URLComponents(string: boundURL),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host,
              isLoopbackLiteral(host),
              components.port.map({ (1...65535).contains($0) }) ?? false else {
            return nil
        }
        components.path = "/v1/status"
        return components.url
    }

    private static func isLoopbackLiteral(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "::1" { return true }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 &&
            UInt8(parts[0]) == 127 &&
            parts.dropFirst().allSatisfy { UInt8($0) != nil }
    }

    private static func directLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }
}
