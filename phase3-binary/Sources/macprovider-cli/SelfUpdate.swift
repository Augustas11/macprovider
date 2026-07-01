import CryptoKit
import Darwin
import Foundation
import MacProviderCore

struct LaunchdRestartFailure: Error, CustomStringConvertible {
    let error: Error
    let recoveryCommand: String

    var description: String {
        String(describing: error)
    }
}

struct SelfUpdate {
    static let defaultReleasesAPIURL = "https://api.github.com/repos/Augustas11/macprovider/releases/latest"
    static let launchdLabel = "live.streamvc.macprovider"
    static let checksumPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwwd0Vzj35OP8DlZU+0lUa8vI9gHK
    09J48LDizWScsH6rutnZLkKnGQ4X5Q8lT9L5mglF8Ba0DDoUXKrFfSAX4Q==
    -----END PUBLIC KEY-----
    """

    private let currentVersion: String
    private let releasesAPIURL: String
    private let session: URLSession
    private let drainBeforeReplace: (() async throws -> Void)?
    private let replaceBinary: ((URL) throws -> Void)?
    private let restartLaunchd: (() throws -> Void)?
    private let markerStore: AutoUpdateMarkerStore

    init(
        currentVersion: String,
        releasesAPIURL: String?,
        session: URLSession = .shared,
        markerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore(),
        drainBeforeReplace: (() async throws -> Void)? = nil,
        replaceBinary: ((URL) throws -> Void)? = nil,
        restartLaunchd: (() throws -> Void)? = nil
    ) {
        self.currentVersion = currentVersion
        self.releasesAPIURL = releasesAPIURL ?? Self.defaultReleasesAPIURL
        self.session = session
        self.markerStore = markerStore
        self.drainBeforeReplace = drainBeforeReplace
        self.replaceBinary = replaceBinary
        self.restartLaunchd = restartLaunchd
    }

    func run(checkOnly: Bool) async throws {
        let release = try await latestRelease()
        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let comparison = Self.compareSemver(currentVersion, latest)

        if comparison != .orderedAscending {
            print("Already up to date (v\(currentVersion))")
            return
        }

        if checkOnly {
            print("Update available: v\(currentVersion) -> v\(latest)")
            return
        }

        let prepared = try await prepareValidatedUpdate(from: release)
        defer { prepared.cleanup() }
        let restartError = try await applyValidatedUpdate(newBinary: prepared.newBinary)
        try await persistSignedPolicyIfPresent(prepared.signedPolicy)
        if let restartError {
            print("Binary upgraded to v\(latest), but automatic restart failed: \(restartError)")
            print("Run: \(restartError.recoveryCommand)")
            return
        }
        print("Update complete. Restart macprovider-cli to use v\(latest).")
    }

    func runByTag(tag: String) async throws {
        let release = try await releaseByTag(tag)
        let prepared = try await prepareValidatedUpdate(from: release)
        defer { prepared.cleanup() }
        _ = try await applyValidatedUpdate(newBinary: prepared.newBinary)
        try await persistSignedPolicyIfPresent(prepared.signedPolicy)
    }

    func resolveReleaseByTags(normalizedTarget: String) async throws -> GitHubRelease {
        do {
            return try await releaseByTag("v\(normalizedTarget)")
        } catch UpdateError.releaseNotFound {
            return try await releaseByTag(normalizedTarget)
        }
    }

    func prepareValidatedUpdate(from release: GitHubRelease) async throws -> PreparedSelfUpdate {
        guard let tarball = release.assets.first(where: { $0.name.hasSuffix("darwin-arm64.tar.gz") }),
              let checksums = release.assets.first(where: { $0.name == "checksums.txt" }),
              let checksumsSignature = release.assets.first(where: { $0.name == "checksums.txt.sig" })
        else {
            throw UpdateError.missingAsset
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macprovider-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        do {
            try validateDownloadURL(tarball.browserDownloadURL)
            try validateDownloadURL(checksums.browserDownloadURL)
            try validateDownloadURL(checksumsSignature.browserDownloadURL)

            let tarballURL = tempDir.appendingPathComponent(tarball.name)
            let checksumsURL = tempDir.appendingPathComponent(checksums.name)
            let checksumsSignatureURL = tempDir.appendingPathComponent(checksumsSignature.name)
            try await download(from: checksums.browserDownloadURL, to: checksumsURL)
            try await download(from: checksumsSignature.browserDownloadURL, to: checksumsSignatureURL)
            try verifyChecksumSignature(checksumsURL: checksumsURL, signatureURL: checksumsSignatureURL, tempDir: tempDir)
            let checksumsText = try String(contentsOf: checksumsURL, encoding: .utf8)
            let expectedSHA = try Self.expectedSHA256(for: tarball.name, in: checksumsText)
            try await download(from: tarball.browserDownloadURL, to: tarballURL)
            try validateFreeSpace(for: tempDir, requiredForKnownTarballAt: tarballURL)
            let actualSHA = try Self.sha256(file: tarballURL)
            guard actualSHA.lowercased() == expectedSHA.lowercased() else {
                throw UpdateError.checksumMismatch(expected: expectedSHA, actual: actualSHA)
            }

            let extractDir = tempDir.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try validateTarball(tarballURL)
            try runProcess("/usr/bin/tar", arguments: ["-xzf", tarballURL.path, "-C", extractDir.path])
            let newBinary = try Self.findBinary(in: extractDir)

            try runProcess(newBinary.path, arguments: ["self-test"])
            return PreparedSelfUpdate(tempDir: tempDir, newBinary: newBinary, signedPolicy: release.signedPolicy)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    @discardableResult
    func applyValidatedUpdateForTest(newBinary: URL) async throws -> LaunchdRestartFailure? {
        try await applyValidatedUpdate(newBinary: newBinary)
    }

    func persistSignedPolicyIfPresent(_ signedPolicy: GitHubSignedPolicy?) async throws {
        guard let signedPolicy else { return }
        try await markerStore.updateSignedPolicy(minimum: signedPolicy.minimum, revoked: signedPolicy.revoked)
    }

    func resolvedReleasesAPIURLForTest() -> String {
        releasesAPIURL
    }

    static func releaseSigningPublicKeyPEMForTest() -> String {
        checksumPublicKeyPEM
    }

    func latestVersionCached() async throws -> String {
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/macprovider/latest-release.json")
        if let cached = try? Data(contentsOf: cacheURL),
           let object = try? JSONSerialization.jsonObject(with: cached) as? [String: Any],
           let fetchedAt = object["fetched_at"] as? TimeInterval,
           Date().timeIntervalSince1970 - fetchedAt < 3600,
           let version = object["version"] as? String
        {
            return version
        }

        let release = try await latestRelease()
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "fetched_at": Date().timeIntervalSince1970,
            "version": version,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return version
    }

    private func latestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: releasesAPIURL) else {
            throw UpdateError.invalidURL(releasesAPIURL)
        }
        try validateReleaseAPIURL(url)
        var request = URLRequest(url: url)
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("macprovider-cli/\(currentVersion)", forHTTPHeaderField: "user-agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func releaseByTag(_ tag: String) async throws -> GitHubRelease {
        guard let url = releaseTagURL(tag: tag) else {
            throw UpdateError.invalidURL(releasesAPIURL)
        }
        try validateReleaseAPIURL(url)
        var request = URLRequest(url: url)
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.addValue("macprovider-cli/\(currentVersion)", forHTTPHeaderField: "user-agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw UpdateError.releaseNotFound
            }
            if !(200 ..< 300).contains(http.statusCode) {
                throw UpdateError.httpStatus(http.statusCode)
            }
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func releaseTagURL(tag: String) -> URL? {
        guard var components = URLComponents(string: releasesAPIURL) else {
            return nil
        }
        let escapedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        if components.path.hasSuffix("/releases/latest") {
            components.path = String(components.path.dropLast("/latest".count)) + "/tags/\(escapedTag)"
        } else if components.path.contains("/releases/tags/") {
            let prefix = components.path.split(separator: "/").dropLast().joined(separator: "/")
            components.path = "/" + prefix + "/\(escapedTag)"
        } else {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/tags/\(escapedTag)"
            if !components.path.hasPrefix("/") {
                components.path = "/" + components.path
            }
        }
        return components.url
    }

    private func fetchText(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func download(from url: URL, to destination: URL) async throws {
        let (downloaded, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        try FileManager.default.moveItem(at: downloaded, to: destination)
    }

    private func replaceCurrentBinary(with newBinary: URL) throws {
        guard let current = Bundle.main.executableURL else {
            throw UpdateError.currentBinaryUnknown
        }
        let staged = current.deletingLastPathComponent()
            .appendingPathComponent(".\(current.lastPathComponent).update-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.copyItem(at: newBinary, to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        if rename(staged.path, current.path) != 0 {
            let errnoValue = errno
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError.renameFailed(errnoValue)
        }
    }

    private func applyValidatedUpdate(newBinary: URL) async throws -> LaunchdRestartFailure? {
        if let drainBeforeReplace {
            try await drainBeforeReplace()
        }
        if let replaceBinary {
            try replaceBinary(newBinary)
        } else {
            try replaceCurrentBinary(with: newBinary)
        }
        do {
            if let restartLaunchd {
                try restartLaunchd()
            } else {
                try restartLaunchdIfInstalled()
            }
        } catch let failure as LaunchdRestartFailure {
            return failure
        } catch {
            return LaunchdRestartFailure(error: error, recoveryCommand: restartRecoveryCommand())
        }
        return nil
    }

    private func restartLaunchdIfInstalled() throws {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.launchdLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return
        }
        let loaded = launchctlServiceLoaded(label: Self.launchdLabel)
        do {
            try runProcess(
                "/bin/launchctl",
                arguments: Self.launchdRestartArguments(serviceLoaded: loaded, plistPath: plist.path)
            )
        } catch {
            throw LaunchdRestartFailure(
                error: error,
                recoveryCommand: Self.launchdRestartRecoveryCommand(serviceLoaded: loaded, plistPath: plist.path)
            )
        }
    }

    private func restartRecoveryCommand() -> String {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.launchdLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return Self.launchdRestartRecoveryCommand()
        }
        let loaded = launchctlServiceLoaded(label: Self.launchdLabel)
        return Self.launchdRestartRecoveryCommand(serviceLoaded: loaded, plistPath: plist.path)
    }

    private func runProcess(_ executable: String, arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            throw UpdateError.processFailed(executable, process.terminationStatus)
        }
    }

    private func launchctlServiceLoaded(label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", Self.launchdServiceTarget(label: label)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return !output.lowercased().contains("disabled = true")
    }

    static func launchdRestartArguments(serviceLoaded: Bool, uid: uid_t = getuid(), plistPath: String) -> [String] {
        let domain = "gui/\(uid)"
        if serviceLoaded {
            return ["kickstart", "-k", "\(domain)/\(launchdLabel)"]
        }
        return ["bootstrap", domain, plistPath]
    }

    static func launchdRestartRecoveryCommand(serviceLoaded: Bool = true, uid: uid_t = getuid(), plistPath: String? = nil) -> String {
        if serviceLoaded {
            return "launchctl kickstart -k \(launchdServiceTarget(uid: uid))"
        }
        let plist = plistPath ?? "~/Library/LaunchAgents/\(launchdLabel).plist"
        return "launchctl bootstrap gui/\(uid) \(plist)"
    }

    private static func launchdServiceTarget(label: String = launchdLabel, uid: uid_t = getuid()) -> String {
        "gui/\(uid)/\(label)"
    }

    private func validateDownloadURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            throw UpdateError.untrustedDownloadURL(url.absoluteString)
        }
        guard host == "github.com" || host.hasSuffix(".github.com") || host == "objects.githubusercontent.com" else {
            throw UpdateError.untrustedDownloadURL(url.absoluteString)
        }
    }

    private func validateReleaseAPIURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host == "api.github.com" else {
            throw UpdateError.untrustedReleaseAPIURL(url.absoluteString)
        }
    }

    private func validateTarball(_ url: URL) throws {
        let listing = try processOutput("/usr/bin/tar", arguments: ["-tzf", url.path])
        for rawEntry in listing.split(separator: "\n").map(String.init) {
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            if entry.hasPrefix("/") || entry == ".." || entry.hasPrefix("../") || entry.contains("/../") {
                throw UpdateError.unsafeArchiveEntry(entry)
            }
        }
    }

    private func validateFreeSpace(for directory: URL, requiredForKnownTarballAt tarball: URL?) throws {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let tarballSize = tarball.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value } ?? 0
        let required = max(512 * 1024 * 1024, tarballSize * 3)
        guard free >= required else {
            throw UpdateError.insufficientDiskSpace(required: required, available: free)
        }
    }

    private func verifyChecksumSignature(checksumsURL: URL, signatureURL: URL, tempDir _: URL) throws {
        do {
            let publicKey = try P256.Signing.PublicKey(pemRepresentation: Self.checksumPublicKeyPEM)
            let checksums = try Data(contentsOf: checksumsURL)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(contentsOf: signatureURL))
            let digest = SHA256.hash(data: checksums)
            guard publicKey.isValidSignature(signature, for: digest) else {
                throw UpdateError.checksumSignatureInvalid
            }
        } catch {
            throw UpdateError.checksumSignatureInvalid
        }
    }

    private func processOutput(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.processFailed(executable, process.terminationStatus)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    static func compareSemver(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func expectedSHA256(for filename: String, in text: String) throws -> String {
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, parts[1] == filename, parts[0].range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil {
                return parts[0]
            }
        }
        throw UpdateError.checksumMissing(filename)
    }

    private static func sha256(file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func findBinary(in directory: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isExecutableKey]) else {
            throw UpdateError.missingExtractedBinary
        }
        var matches: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "macprovider-cli" {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isExecutableKey])
            if values.isSymbolicLink == false, values.isRegularFile == true, values.isExecutable == true {
                matches.append(url)
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw UpdateError.missingExtractedBinary
        }
        return match
    }
}

struct PreparedSelfUpdate {
    let tempDir: URL
    let newBinary: URL
    let signedPolicy: GitHubSignedPolicy?

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]
    let body: String?
    let signedPolicy: GitHubSignedPolicy?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case body
        case signedPolicyMinimum = "signed_policy_minimum"
        case signedPolicyRevoked = "signed_policy_revoked"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        assets = try container.decode([GitHubAsset].self, forKey: .assets)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        let directMinimum = try container.decodeIfPresent(String.self, forKey: .signedPolicyMinimum)
        let directRevoked = try container.decodeIfPresent([String].self, forKey: .signedPolicyRevoked)
        if directMinimum != nil || directRevoked != nil {
            signedPolicy = GitHubSignedPolicy(minimum: directMinimum, revoked: directRevoked ?? [])
        } else {
            signedPolicy = Self.extractSignedPolicy(from: body)
        }
    }

    private static func extractSignedPolicy(from body: String?) -> GitHubSignedPolicy? {
        guard let body,
              let range = body.range(of: #"```json\s*(\{[\s\S]*?"signed_policy_[\s\S]*?\})\s*```"#, options: .regularExpression)
        else { return nil }
        let block = String(body[range])
            .replacingOccurrences(of: #"^```json\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        guard let data = block.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return GitHubSignedPolicy(
            minimum: object["signed_policy_minimum"] as? String,
            revoked: object["signed_policy_revoked"] as? [String] ?? []
        )
    }
}

struct GitHubSignedPolicy: Equatable {
    let minimum: String?
    let revoked: [String]
}

struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

enum UpdateError: Error, CustomStringConvertible {
    case invalidURL(String)
    case httpStatus(Int)
    case releaseNotFound
    case missingAsset
    case checksumMissing(String)
    case checksumMismatch(expected: String, actual: String)
    case checksumSignatureInvalid
    case missingExtractedBinary
    case currentBinaryUnknown
    case processFailed(String, Int32)
    case renameFailed(Int32)
    case untrustedDownloadURL(String)
    case untrustedReleaseAPIURL(String)
    case unsafeArchiveEntry(String)
    case insufficientDiskSpace(required: Int64, available: Int64)

    var description: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid release API URL: \(url)"
        case .httpStatus(let status):
            return "GitHub API returned HTTP \(status)"
        case .releaseNotFound:
            return "GitHub release tag not found"
        case .missingAsset:
            return "Release is missing darwin-arm64 tarball, checksums.txt, or checksums.txt.sig"
        case .checksumMissing(let filename):
            return "checksums.txt does not contain \(filename)"
        case let .checksumMismatch(expected, actual):
            return "Checksum mismatch: expected \(expected), got \(actual)"
        case .checksumSignatureInvalid:
            return "checksums.txt signature verification failed"
        case .missingExtractedBinary:
            return "Downloaded archive does not contain macprovider-cli"
        case .currentBinaryUnknown:
            return "Unable to locate the running binary path"
        case let .processFailed(executable, status):
            return "\(executable) exited with status \(status)"
        case .renameFailed(let errnoValue):
            return "Atomic binary replacement failed with errno \(errnoValue)"
        case .untrustedDownloadURL(let url):
            return "Untrusted release asset URL: \(url)"
        case .untrustedReleaseAPIURL(let url):
            return "Untrusted release API URL: \(url)"
        case .unsafeArchiveEntry(let entry):
            return "Release archive contains unsafe entry: \(entry)"
        case let .insufficientDiskSpace(required, available):
            return "Insufficient disk space: required \(required), available \(available)"
        }
    }
}

struct LocalStatusClient {
    static func fetch(port: Int) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/status")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.processFailed("status-json", 1)
        }
        return object
    }
}

struct LocalStatusFormatter {
    static func format(_ status: [String: Any], latestVersion: String? = nil, ownerLogin: String? = nil) -> String {
        let capacity = status["capacity"] as? [String: Any] ?? [:]
        let coordinator = status["coordinator"] as? [String: Any] ?? [:]
        let version = status["binary_version"] as? String ?? CoordinatorClient.binaryVersion
        let uptime = humanDuration(status["uptime_s"] as? Int ?? 0)
        let connected = (coordinator["connected"] as? Bool) == true ? "yes" : "no"
        let ownerLine = ownerLogin.map { "\($0) (github.com/\($0))" } ?? "(unclaimed — run `macprovider-cli claim`)"
        let latestLine: String
        if let latestVersion {
            let comparison = SelfUpdate.compareSemver(version, latestVersion)
            latestLine = comparison == .orderedAscending
                ? "v\(latestVersion) (run 'macprovider-cli update' to upgrade)"
                : "v\(latestVersion)"
        } else {
            latestLine = "unknown (run 'macprovider-cli update --check')"
        }

        return """
        macprovider-cli v\(version)

        Local:
          Provider ID:  \(string(status["provider_id"]))
          Owner: \(ownerLine)
          Model:       \(string(status["model"]))
          Status:      \(string(status["status"]))
          Uptime:      \(uptime)
          Requests:    \(status["requests_total"] ?? 0) served, \(status["errors_total"] ?? 0) errors
          Active WS:   \(status["active_request_id_count"] ?? 0) request_ids
          RAM:         \(capacity["ram_gb"] ?? 0) GB (\(string(capacity["ram_tier"])))
          Context cap: \(capacity["max_context_tokens"] ?? 0) tokens

        Coordinator:
          URL:         \(string(coordinator["url"]))
          Connected:   \(connected)
          Session:     \(string(coordinator["session"]))
          Tier:        \(string(coordinator["tier"]))
          Recommended: \(string(coordinator["recommended_binary_version"]))

        Update:
          Current:     v\(version)
          Latest:      \(latestLine)
        """
    }

    private static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<unknown>" }
        return String(describing: value)
    }

    private static func humanDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m \(seconds % 60)s"
    }
}

enum OwnerFileReader {
    static func githubLogin(configPath: String) -> String? {
        let claimURLFile = ClaimURLFile(configPath: configPath)
        guard let body = try? String(contentsOf: claimURLFile.ownerURL, encoding: .utf8) else {
            return nil
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0] == "github_login" {
                let login = String(parts[1])
                return isValidGitHubLogin(login) ? login : nil
            }
        }
        return nil
    }

    private static func isValidGitHubLogin(_ login: String) -> Bool {
        guard (1...39).contains(login.utf8.count),
              !login.hasPrefix("-"),
              !login.hasSuffix("-")
        else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        return login.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
