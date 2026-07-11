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
    private let rollbackReplacement: (() throws -> Void)?
    private let restartLaunchd: (() throws -> Void)?
    private let postRestartReadiness: (() async -> Bool)?
    private let markerStore: AutoUpdateMarkerStore

    init(
        currentVersion: String,
        releasesAPIURL: String?,
        session: URLSession = .shared,
        markerStore: AutoUpdateMarkerStore = AutoUpdateMarkerStore(),
        drainBeforeReplace: (() async throws -> Void)? = nil,
        replaceBinary: ((URL) throws -> Void)? = nil,
        rollbackReplacement: (() throws -> Void)? = nil,
        restartLaunchd: (() throws -> Void)? = nil,
        postRestartReadiness: (() async -> Bool)? = nil
    ) {
        self.currentVersion = currentVersion
        self.releasesAPIURL = releasesAPIURL ?? Self.defaultReleasesAPIURL
        self.session = session
        self.markerStore = markerStore
        self.drainBeforeReplace = drainBeforeReplace
        self.replaceBinary = replaceBinary
        self.rollbackReplacement = rollbackReplacement
        self.restartLaunchd = restartLaunchd
        self.postRestartReadiness = postRestartReadiness
    }

    func run(checkOnly: Bool) async throws {
        let release = try await latestRelease()
        let latest = try Self.validateReleaseTag(release.tagName)
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
        try await applyValidatedUpdate(newBinary: prepared.newBinary, targetVersion: latest)
        try await persistSignedPolicyIfPresent(prepared.signedPolicy)
        print("Update complete. Restart macprovider-cli to use v\(latest).")
    }

    func runByTag(tag: String) async throws {
        let release = try await releaseByTag(tag)
        let prepared = try await prepareValidatedUpdate(from: release)
        defer { prepared.cleanup() }
        let target = try AutoUpdateRecommendation.validate(release.tagName).normalized
        try await applyValidatedUpdate(newBinary: prepared.newBinary, targetVersion: target)
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
        let targetVersion = try Self.validateReleaseTag(release.tagName)
        let canonicalTarballName = "macprovider-cli-\(release.tagName)-darwin-arm64.tar.gz"
        guard let tarball = release.assets.first(where: { $0.name == canonicalTarballName }),
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
            try Self.validateExtractedTree(extractDir)
            let newBinary = try Self.findBinary(in: extractDir)
            try ProviderReleasePayloadTransaction.validateReleasePayload(
                at: newBinary.deletingLastPathComponent(),
                newBinary: newBinary
            )

            try runProcess(newBinary.path, arguments: ["self-test"])
            let stagedVersionOutput = try processOutput(newBinary.path, arguments: ["--version"])
            try Self.requireStagedBinaryVersion(stagedVersionOutput, targetVersion: targetVersion)
            return PreparedSelfUpdate(tempDir: tempDir, newBinary: newBinary, signedPolicy: release.signedPolicy)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    func applyValidatedUpdateForTest(newBinary: URL) async throws {
        try await applyValidatedUpdate(newBinary: newBinary, targetVersion: "1.2.1")
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
        let version = try Self.validateReleaseTag(release.tagName)
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

    private func applyValidatedUpdate(newBinary: URL, targetVersion: String) async throws {
        if let drainBeforeReplace {
            try await drainBeforeReplace()
        }

        var pendingMarker: AutoUpdatePendingMarker?
        var updateLock: AutoUpdateLock?
        defer { withExtendedLifetime(updateLock) {} }
        let current = replaceBinary == nil ? Bundle.main.executableURL : nil
        if replaceBinary == nil {
            guard let current else { throw UpdateError.currentBinaryUnknown }
            updateLock = try markerStore.acquireLock()
            let updateID = UUID().uuidString.lowercased()
            let marker = try markerStore.preserveReleaseRollbackBackup(
                binaryURL: current,
                updateID: updateID,
                targetVersion: targetVersion,
                commitOwner: "self_update"
            )
            do {
                try markerStore.writePending(marker)
                pendingMarker = marker
            } catch {
                markerStore.removeRollbackBackups(marker)
                markerStore.clearPendingAndLock(target: nil)
                throw error
            }
        }

        do {
            if let replaceBinary {
                try replaceBinary(newBinary)
            } else if let current {
                try markerStore.activateReleasePayload(
                    from: newBinary.deletingLastPathComponent(),
                    newBinary: newBinary,
                    to: current
                )
            }
        } catch {
            do {
                try restoreAppliedUpdate(pendingMarker)
            } catch let rollbackError {
                throw UpdateError.activationFailedRollbackFailed(
                    update: String(describing: error),
                    rollback: String(describing: rollbackError)
                )
            }
            throw error
        }
        do {
            if let restartLaunchd {
                try restartLaunchd()
            } else {
                try restartLaunchdIfInstalled()
            }
        } catch let restartError {
            do {
                try restoreAppliedUpdate(pendingMarker)
            } catch let rollbackError {
                throw UpdateError.restartFailedRollbackFailed(
                    restart: String(describing: restartError),
                    rollback: String(describing: rollbackError)
                )
            }

            // Restoring bytes is the critical rollback boundary. Best-effort
            // restart of the restored release re-establishes the prior service
            // state when launchctl itself is still available.
            if rollbackReplacement == nil {
                if let restartLaunchd {
                    try? restartLaunchd()
                } else {
                    try? restartLaunchdIfInstalled()
                }
            }
            throw UpdateError.restartFailedRollbackRestored(
                restart: String(describing: restartError),
                recoveryCommand: restartRecoveryCommand()
            )
        }
        let ready = if let postRestartReadiness {
            await postRestartReadiness()
        } else {
            await Self.waitForBuyerServingIfManaged()
        }
        guard ready else {
            do {
                try restoreAppliedUpdate(pendingMarker)
                if let restartLaunchd { try? restartLaunchd() } else { try? restartLaunchdIfInstalled() }
            } catch let rollbackError {
                throw UpdateError.restartFailedRollbackFailed(
                    restart: "buyer-serving readiness timeout",
                    rollback: String(describing: rollbackError)
                )
            }
            throw UpdateError.restartFailedRollbackRestored(
                restart: "buyer-serving readiness timeout",
                recoveryCommand: restartRecoveryCommand()
            )
        }
        if let pendingMarker {
            try markerStore.completeSuccessfulUpdate(pendingMarker)
            try markerStore.finalizeSuccessfulUpdate(pendingMarker)
        }
    }

    private func restoreAppliedUpdate(_ pendingMarker: AutoUpdatePendingMarker?) throws {
        if let rollbackReplacement {
            try rollbackReplacement()
            return
        }
        guard let pendingMarker else {
            throw UpdateError.rollbackUnavailable
        }
        try markerStore.restoreBackup(pendingMarker)
        markerStore.clearPendingAndLock(target: nil)
        markerStore.removeRollbackBackups(pendingMarker)
    }

    private static func waitForBuyerServingIfManaged(timeout: TimeInterval = 90) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return true }
        let config = try? ConfigLoader.load(cli: CLIOverrides())
        guard let port = config?.port else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // /v1/status only emits buyer_serving after the coordinator's
            // public readiness endpoint confirms full routing eligibility.
            if let status = try? await LocalStatusClient.fetch(port: port),
               status["network_state"] as? String == "buyer_serving" {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
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
        let verboseListing = try processOutput("/usr/bin/tar", arguments: ["-tvzf", url.path])
        for line in verboseListing.split(separator: "\n") {
            guard let type = line.utf8.first, type == 0x2D || type == 0x64 else {
                throw UpdateError.unsafeArchiveEntry(String(line))
            }
        }
        var normalizedEntries = Set<String>()
        for rawEntry in listing.split(separator: "\n").map(String.init) {
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            if entry.hasPrefix("/") || entry == ".." || entry.hasPrefix("../") || entry.contains("/../") {
                throw UpdateError.unsafeArchiveEntry(entry)
            }
            let normalized = (entry as NSString).standardizingPath
            guard normalized != ".", !normalized.hasPrefix("../"), normalized != "..",
                  normalizedEntries.insert(normalized).inserted
            else {
                throw UpdateError.unsafeArchiveEntry(entry)
            }
        }
    }

    static func validateExtractedTreeForTest(_ root: URL) throws {
        try validateExtractedTree(root)
    }

    private static func validateExtractedTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw UpdateError.unsafeArchiveEntry(root.path)
        }
        for case let entry as URL in enumerator {
            var info = stat()
            guard lstat(entry.path, &info) == 0,
                  info.st_uid == getuid(),
                  (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
            else { throw UpdateError.unsafeArchiveEntry(entry.path) }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else {
                throw UpdateError.unsafeArchiveEntry(entry.path)
            }
            if type == S_IFREG, info.st_nlink != 1 {
                throw UpdateError.unsafeArchiveEntry(entry.path)
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

    static func validateReleaseTag(_ tag: String) throws -> String {
        guard tag.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw UpdateError.invalidReleaseVersion(tag)
        }
        do {
            return try AutoUpdateRecommendation.validate(tag).normalized
        } catch {
            throw UpdateError.invalidReleaseVersion(tag)
        }
    }

    static func requireStagedBinaryVersion(_ output: String, targetVersion: String) throws {
        let exact = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged: String
        do {
            staged = try validateReleaseTag(exact)
        } catch {
            throw UpdateError.stagedVersionMismatch(expected: targetVersion, actual: exact)
        }
        guard staged == targetVersion else {
            throw UpdateError.stagedVersionMismatch(expected: targetVersion, actual: staged)
        }
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

struct ProviderReleasePayloadTransaction {
    let currentBinary: URL
    let installDirectory: URL
    let backupDirectory: URL
    let markerStore: AutoUpdateMarkerStore
    private let fileManager: FileManager

    init(
        currentBinary: URL,
        markerStore: AutoUpdateMarkerStore,
        fileManager: FileManager = .default
    ) throws {
        self.currentBinary = currentBinary
        installDirectory = currentBinary.deletingLastPathComponent()
        backupDirectory = installDirectory.appendingPathComponent(
            ".macprovider-cli.manual-rollback-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        self.markerStore = markerStore
        self.fileManager = fileManager

        try markerStore.validateTrustedBinaryDirectory(installDirectory)
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let currentEntries = try Self.ownedEntries(in: installDirectory, fileManager: fileManager)
            guard currentEntries.contains(where: { $0.standardizedFileURL == currentBinary.standardizedFileURL }) else {
                throw UpdateError.missingReleaseResource("installed macprovider-cli")
            }
            for entry in currentEntries {
                try fileManager.copyItem(
                    at: entry,
                    to: backupDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
                )
            }
        } catch {
            try? fileManager.removeItem(at: backupDirectory)
            throw error
        }
    }

    static func validateReleasePayload(
        at payloadDirectory: URL,
        newBinary: URL,
        fileManager: FileManager = .default
    ) throws {
        _ = try validatedPayloadEntries(
            in: payloadDirectory,
            newBinary: newBinary,
            fileManager: fileManager
        )
    }

    func activate(from payloadDirectory: URL, newBinary: URL) throws {
        let entries = try Self.validatedPayloadEntries(
            in: payloadDirectory,
            newBinary: newBinary,
            fileManager: fileManager
        )

        let stagingDirectory = installDirectory.appendingPathComponent(
            ".macprovider-cli.activation-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        for entry in entries {
            try fileManager.copyItem(
                at: entry,
                to: stagingDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            )
        }

        try removeCurrentResources()
        for entry in try Self.ownedEntries(in: stagingDirectory, fileManager: fileManager)
            where entry.lastPathComponent != "macprovider-cli"
        {
            try fileManager.moveItem(
                at: entry,
                to: installDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            )
        }
        try markerStore.atomicCopyNoFollow(
            from: stagingDirectory.appendingPathComponent("macprovider-cli"),
            to: currentBinary,
            mode: 0o755
        )
    }

    func restore() throws {
        try removeCurrentResources()
        let backupEntries = try Self.ownedEntries(in: backupDirectory, fileManager: fileManager)
        for entry in backupEntries where entry.lastPathComponent != "macprovider-cli" {
            try fileManager.copyItem(
                at: entry,
                to: installDirectory.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
            )
        }
        let backupBinary = backupDirectory.appendingPathComponent("macprovider-cli")
        guard fileManager.fileExists(atPath: backupBinary.path) else {
            throw UpdateError.missingReleaseResource("rollback macprovider-cli")
        }
        let attributes = try fileManager.attributesOfItem(atPath: backupBinary.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755
        try markerStore.atomicCopyNoFollow(from: backupBinary, to: currentBinary, mode: mode)
    }

    func cleanup() {
        try? fileManager.removeItem(at: backupDirectory)
    }

    private func removeCurrentResources() throws {
        for entry in try Self.ownedEntries(in: installDirectory, fileManager: fileManager)
            where entry.lastPathComponent != "macprovider-cli"
        {
            try fileManager.removeItem(at: entry)
        }
    }

    private static func validatedPayloadEntries(
        in directory: URL,
        newBinary: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        let entries = try ownedEntries(in: directory, fileManager: fileManager)
        guard entries.contains(where: { $0.standardizedFileURL == newBinary.standardizedFileURL }) else {
            throw UpdateError.missingReleaseResource("macprovider-cli")
        }
        guard entries.contains(where: { $0.lastPathComponent == "mlx.metallib" }) else {
            throw UpdateError.missingReleaseResource("mlx.metallib")
        }
        guard entries.contains(where: { $0.pathExtension == "bundle" }) else {
            throw UpdateError.missingReleaseResource("SwiftPM resource bundle")
        }
        guard let catalogDirectory = entries.first(where: { $0.lastPathComponent == "catalog-release" }) else {
            throw UpdateError.missingReleaseResource("catalog-release")
        }
        for requiredName in [
            "release.json",
            "trusted-keys.json",
            "autotune-candidates.json",
            "autotune-candidates.json.sig",
            "demand-rank.json",
            "demand-rank.json.sig",
        ] {
            let requiredURL = catalogDirectory.appendingPathComponent(requiredName)
            let values = try requiredURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw UpdateError.missingReleaseResource("catalog-release/\(requiredName)")
            }
        }
        return entries
    }

    private static func ownedEntries(in directory: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { entry in
            let name = entry.lastPathComponent
            guard name == "macprovider-cli"
                    || name == "mlx.metallib"
                    || name == "THIRD-PARTY-NOTICES.txt"
                    || name == "catalog-release"
                    || entry.pathExtension == "bundle"
            else {
                return false
            }
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true
            else {
                return false
            }
            if entry.pathExtension == "bundle" || name == "catalog-release" {
                return values.isDirectory == true
            }
            return values.isRegularFile == true
        }
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        assets = try container.decode([GitHubAsset].self, forKey: .assets)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        // Release JSON/body metadata is not covered by checksums.txt.sig.
        // Persisting policy from those unsigned fields would let a tampered
        // release response change local trust state before signature proof.
        // Keep the decoded shape for future signed-policy plumbing, but drop
        // unsigned metadata on read.
        signedPolicy = nil
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
    case invalidReleaseVersion(String)
    case stagedVersionMismatch(expected: String, actual: String)
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
    case missingReleaseResource(String)
    case rollbackUnavailable
    case activationFailedRollbackFailed(update: String, rollback: String)
    case restartFailedRollbackRestored(restart: String, recoveryCommand: String)
    case restartFailedRollbackFailed(restart: String, rollback: String)

    var description: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid release API URL: \(url)"
        case .httpStatus(let status):
            return "GitHub API returned HTTP \(status)"
        case .releaseNotFound:
            return "GitHub release tag not found"
        case .missingAsset:
            return "Release is missing the canonical tag-bound darwin-arm64 tarball, checksums.txt, or checksums.txt.sig"
        case .invalidReleaseVersion(let version):
            return "Release tag is not strict semantic version: \(version)"
        case let .stagedVersionMismatch(expected, actual):
            return "Signed release payload version mismatch: expected \(expected), staged binary reported \(actual)"
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
        case .missingReleaseResource(let resource):
            return "Release payload is missing required resource: \(resource)"
        case .rollbackUnavailable:
            return "rollback_failed: no rollback mechanism is available for the applied update"
        case let .activationFailedRollbackFailed(update, rollback):
            return "rollback_failed: update activation failed (\(update)) and rollback failed (\(rollback))"
        case let .restartFailedRollbackRestored(restart, recoveryCommand):
            return "rollback_restored: restart failed (\(restart)); previous provider release restored. If needed, run: \(recoveryCommand)"
        case let .restartFailedRollbackFailed(restart, rollback):
            return "rollback_failed: restart failed (\(restart)) and rollback failed (\(rollback))"
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
    static func format(_ status: [String: Any], latestVersion: String? = nil, ownerLogin: String? = nil, donorMode: Bool = false, staleRecommendationSince: Date? = nil) -> String {
        let capacity = status["capacity"] as? [String: Any] ?? [:]
        let coordinator = status["coordinator"] as? [String: Any] ?? [:]
        let catalog = status["catalog"] as? [String: Any] ?? [:]
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
        let donorBadge = donorMode ? " DONOR MODE" : ""
        let staleBlock = staleRecommendationSince.map {
            "\nRecommendation stale: recommendation inputs changed since \(ISO8601DateFormatter.autotuneInternet.string(from: $0)).\nRun: macprovider-cli autotune --recommend\n"
        } ?? ""

        return """
        macprovider-cli v\(version)

        Local:
          Provider ID:  \(string(status["provider_id"]))
          Owner: \(ownerLine)
          Model:       \(string(status["model"]))\(donorBadge)
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

        Catalog:
          Network:     \(string(status["network_state"]))
          Trust:       \(string(catalog["state"]))
          Release:     \(string(catalog["release_id"]))
          Signer:      \(string(catalog["signer_key_id"]))
          Digest:      \(string(catalog["digest"]))

        Update:
          Current:     v\(version)
          Latest:      \(latestLine)
        \(staleBlock)
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
