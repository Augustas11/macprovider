import CryptoKit
import Darwin
import Foundation

// Read / write the shared ~/.config/macprovider/config.yaml. The CLI Keychain is
// the sole provider-credential authority. Malibu may read and retire a legacy
// App-Keychain item only while handing custody to the installed CLI.

enum ProviderConfig {
    enum LinkState: String, Equatable {
        case pendingLink = "pending_link"
        case linked
        case unlinkPending = "unlink_pending"
    }

    // Malibu recognizes an installed identity from the shared config plus its
    // ownership marker plus the CLI-custody receipt written after a versioned
    // credential handoff succeeds.
    static var isConfigured: Bool {
        get async {
            await isConfigured(paths: .current)
        }
    }

    static func readProviderID(paths: ProviderPaths = .current) -> String? {
        guard let contents = readTrustedConfigContents(paths: paths) else { return nil }
        return parseTopLevelValue(named: "provider_id", from: contents)
    }

    /// Read the shared config through a nonblocking, no-follow descriptor so a
    /// malformed or replaced config path cannot wedge startup before the
    /// caller's trust checks run. The installer applies the same owner/private
    /// regular-file contract before using this identity for repair.
    private static func readTrustedConfigContents(paths: ProviderPaths) -> String? {
        let maxBytes = 1024 * 1024
        let configDirectory = paths.configFile.deletingLastPathComponent()
        let homeDirectory = configDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard InstalledProviderMonitor.isSafePrivateDirectoryChain(
            configDirectory,
            under: homeDirectory
        ) else {
            return nil
        }
        let descriptor = paths.configFile.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == getuid(),
              before.st_nlink == 1,
              before.st_mode & (S_IWGRP | S_IWOTH) == 0,
              before.st_size >= 0,
              before.st_size <= off_t(maxBytes),
              hasNoExtendedACL(descriptor) else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maxBytes))
        while data.count < Int(before.st_size) {
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
        }
        var after = stat()
        var pathInfo = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Darwin.lstat(paths.configFile.path, &pathInfo) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              (pathInfo.st_dev, pathInfo.st_ino) == (before.st_dev, before.st_ino),
              hasNoExtendedACL(descriptor),
              data.count == Int(before.st_size) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    static func hasProviderToken(paths: ProviderPaths = .current) -> Bool {
        guard let contents = readTrustedConfigContents(paths: paths) else { return false }
        return parseTopLevelValue(named: "provider_token", from: contents) != nil
    }

    static func readModel(paths: ProviderPaths = .current) -> String? {
        guard let contents = readTrustedConfigContents(paths: paths) else { return nil }
        return parseTopLevelValue(named: "model", from: contents)
    }

    static func readHTTPPort(paths: ProviderPaths = .current) -> Int? {
        guard let contents = readTrustedConfigContents(paths: paths),
              let value = parseTopLevelValue(named: "port", from: contents),
              let port = Int(value),
              (1024...65535).contains(port) else {
            return nil
        }
        return port
    }

    static func readLinkState(paths: ProviderPaths = .current) -> LinkState? {
        guard let contents = readTrustedConfigContents(paths: paths),
              let value = parseTopLevelValue(named: "link_state", from: contents)
        else {
            return nil
        }
        return LinkState(rawValue: value)
    }

    /// Automatic updates are a whole-provider policy. Any explicit false or
    /// malformed present value disables background updates fail-closed; manual
    /// user-initiated update actions remain available.
    static func automaticUpdatesEnabled(
        paths: ProviderPaths = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let contents = readTrustedConfigContents(paths: paths)
        return automaticUpdatesEnabled(configContents: contents, environment: environment)
    }

    static func automaticUpdatesEnabled(
        configContents: String?,
        environment: [String: String]
    ) -> Bool {
        var values: [Bool] = []
        if let rawEnvironment = environment["MACPROVIDER_AUTOUPDATE"] {
            guard let parsed = parsePolicyBool(rawEnvironment) else { return false }
            values.append(parsed)
        }
        if let configContents {
            var insideLegacyAutoupdate = false
            for rawLine in configContents
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init) {
                let uncommented = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
                let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let isTopLevel = uncommented == uncommented.trimmingCharacters(in: .whitespaces)
                if isTopLevel {
                    insideLegacyAutoupdate = trimmed == "autoupdate:"
                    for key in ["auto_update_enabled", "autoupdate_enabled"] where trimmed.hasPrefix("\(key):") {
                        let value = String(trimmed.dropFirst("\(key):".count))
                        guard let parsed = parsePolicyBool(value) else { return false }
                        values.append(parsed)
                    }
                } else if insideLegacyAutoupdate, trimmed.hasPrefix("enabled:") {
                    let value = String(trimmed.dropFirst("enabled:".count))
                    guard let parsed = parsePolicyBool(value) else { return false }
                    values.append(parsed)
                }
            }
        }
        return !values.contains(false)
    }

    private static func parsePolicyBool(_ raw: String) -> Bool? {
        switch raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased() {
        case "true", "on", "yes", "1": return true
        case "false", "off", "no", "0": return false
        default: return nil
        }
    }

    static func writeLinkState(_ state: LinkState, paths: ProviderPaths = .current) throws {
        let lockFD = try acquireConfigMutationLock(paths: paths)
        defer { releaseConfigMutationLock(lockFD) }
        let contents = (try? String(contentsOf: paths.configFile)) ?? ""
        let rewritten = upsertingTopLevelLine(
            named: "link_state",
            line: "link_state: \(state.rawValue)",
            into: contents
        )
        try atomicWrite0600(Data(rewritten.utf8), to: paths.configFile)
    }

    struct AutotuneServeConfig: Equatable {
        let model: String
        let modelArtifactPath: String
        let modelArtifactSHA256: String
        let modelCatalogKey: String
        let modelCatalogModelID: String
        let modelCatalogRevision: String
        let modelCatalogSHA256: String
        let modelCatalogVersion: String
        let modelCatalogHash: String
        let kvBits: Int?
        let maxContextOverride: Int
        let maxConcurrencyOverride: Int
        let donorMode: Bool
    }

    enum ServeConfigError: Error, LocalizedError, Equatable {
        case missingField(String)
        case invalidField(String)

        var errorDescription: String? {
            switch self {
            case .missingField(let key):
                return "Missing required serve config field: \(key)."
            case .invalidField(let key):
                return "Invalid serve config field: \(key)."
            }
        }
    }

    private static let recommendationOwnedKeys = [
        "model",
        "model_artifact_path",
        "model_artifact_sha256",
        "model_catalog_key",
        "model_catalog_model_id",
        "model_catalog_revision",
        "model_catalog_sha256",
        "model_catalog_version",
        "model_catalog_hash",
        "kv_bits",
        "max_context_override",
        "max_concurrency_override",
        "donor_mode",
    ]

    static func persistAutotuneRecommendation(
        _ config: AutotuneServeConfig,
        paths: ProviderPaths = .current
    ) throws {
        try validate(config)
        try paths.ensureDirectories()
        let lockFD = try acquireConfigMutationLock(paths: paths)
        defer { releaseConfigMutationLock(lockFD) }
        let contents = (try? String(contentsOf: paths.configFile)) ?? ""
        let rewritten = upsertingRecommendationConfigLines(into: contents, config: config)
        try atomicWrite0600(Data(rewritten.utf8), to: paths.configFile)
    }

    static func validateServeConfigShape(paths: ProviderPaths = .current) throws {
        guard let contents = readTrustedConfigContents(paths: paths) else {
            throw ServeConfigError.missingField("config.yaml")
        }
        let config = try AutotuneServeConfig(
            model: required("model", contents),
            modelArtifactPath: required("model_artifact_path", contents),
            modelArtifactSHA256: required("model_artifact_sha256", contents),
            modelCatalogKey: required("model_catalog_key", contents),
            modelCatalogModelID: required("model_catalog_model_id", contents),
            modelCatalogRevision: required("model_catalog_revision", contents),
            modelCatalogSHA256: required("model_catalog_sha256", contents),
            modelCatalogVersion: required("model_catalog_version", contents),
            modelCatalogHash: required("model_catalog_hash", contents),
            kvBits: optionalInt("kv_bits", contents),
            maxContextOverride: requiredInt("max_context_override", contents),
            maxConcurrencyOverride: requiredInt("max_concurrency_override", contents),
            donorMode: optionalBool("donor_mode", contents) ?? false
        )
        try validate(config)
    }

    // AUDIT R1 ARCHITECT A2: raised when the shared config exists on disk
    // without the app's ownership marker. The app must not silently overwrite
    // a config the CLI track may own; onboarding surfaces this and requires an
    // explicit user decision (import into app track vs cancel).
    enum SaveError: Error, LocalizedError {
        case existingConfigNotOwnedByApp
        case missingProviderID
        case missingProviderToken
        case importKeychainVerificationFailed
        case appMarkerCreateFailed
        case savedIdentityNotConfigured
        var errorDescription: String? {
            switch self {
            case .existingConfigNotOwnedByApp:
                return "A macprovider config already exists on this Mac and was not installed by the app. Uninstall the CLI track or import its provider_id manually before continuing."
            case .missingProviderID:
                return "The existing macprovider config does not contain a provider_id."
            case .missingProviderToken:
                return "The existing macprovider config does not contain a provider_token."
            case .importKeychainVerificationFailed:
                return "The imported provider token could not be verified in Keychain."
            case .appMarkerCreateFailed:
                return "The app ownership marker could not be written."
            case .savedIdentityNotConfigured:
                return "The provider identity was not fully persisted."
            }
        }
    }

    static func importExistingCLIConfig() async throws {
        try await importExistingCLIConfig(paths: .current)
    }

    static func importExistingCLIConfig(paths: ProviderPaths) async throws {
        try await importExistingCLIConfig(
            paths: paths,
            importCredentialIntoCLI: { try await ProviderCredentialHandoffRunner.migrate(configURL: $0) }
        )
    }

    static func importExistingCLIConfig(
        paths: ProviderPaths,
        importCredentialIntoCLI: @escaping @Sendable (URL) async throws -> Void,
        readAppCredential: @escaping @Sendable (String) async -> String? = {
            await KeychainStore.readProviderToken(providerID: $0)
        },
        deleteAppCredential: @escaping @Sendable (String) async throws -> Void = {
            try await KeychainStore.deleteProviderToken(providerID: $0)
        }
    ) async throws {
        try paths.ensureDirectories()
        let fm = FileManager.default
        try await recoverPendingImportIfNeeded(
            paths: paths,
            importCredentialIntoCLI: importCredentialIntoCLI
        )
        let lockFD = try acquireConfigMutationLock(paths: paths)
        defer { releaseConfigMutationLock(lockFD) }
        let backup = paths.configFile.appendingPathExtension("import-backup")
        let marker = importPendingMarker(paths: paths)
        var originalData = try Data(contentsOf: paths.configFile)
        var current = String(decoding: originalData, as: UTF8.self)
        guard let providerID = parseTopLevelValue(named: "provider_id", from: current) else {
            throw SaveError.missingProviderID
        }
        var token = parseTopLevelValue(named: "provider_token", from: current)

        // Repair the exact shipped #585 incident state: old Malibu already
        // stripped YAML, while the only surviving bearer is in its App-owned
        // Keychain item. Restore a private launchd-readable rollback source
        // before asking the installed CLI to assume durable custody.
        if token == nil,
           let legacyToken = await readAppCredential(providerID),
           !legacyToken.isEmpty {
            current = upsertingTopLevelLine(
                named: "provider_token",
                line: "provider_token: \(legacyToken)",
                into: current
            )
            originalData = Data(current.utf8)
            try atomicWrite0600(originalData, to: paths.configFile)
            guard parseTopLevelValue(named: "provider_token", from: current) == legacyToken else {
                throw SaveError.importKeychainVerificationFailed
            }
            token = legacyToken
        }

        guard let token else {
            let snapshot = paths.appSupport.appendingPathComponent(
                ".credential-handoff-\(UUID().uuidString).yaml"
            )
            defer { try? fm.removeItem(at: snapshot) }
            try writeExclusive0600(originalData, to: snapshot)
            try await importCredentialIntoCLI(snapshot)
            guard (try? Data(contentsOf: paths.configFile)) == originalData else {
                throw CocoaError(.fileWriteFileExists)
            }
            try writeCredentialCustodyMarker(providerID: providerID, paths: paths)
            try writeAppMarker(paths: paths, fileManager: fm)
            guard readProviderID(paths: paths) == providerID,
                  await isConfigured(paths: paths) else {
                throw SaveError.savedIdentityNotConfigured
            }
            try await deleteAppCredential(providerID)
            guard await readAppCredential(providerID) == nil else {
                throw SaveError.importKeychainVerificationFailed
            }
            return
        }

        let importMarker = ImportPendingMarker(
            from: paths.configFile.path,
            to: "keychain://live.streamvc.macprovider.provider-token.v1/\(providerID)",
            timestamp: importTimestampString(Date()),
            providerID: providerID,
            tokenSHA256: sha256String(token),
            configSHA256: sha256Data(originalData),
            backupPath: backup.path
        )
        let appMarkerExisted = fm.fileExists(atPath: paths.appMarkerFile.path)
        let custodyMarkerExisted = fm.fileExists(atPath: credentialCustodyMarker(paths: paths).path)
        do {
            // A backup without its exact hash-bound marker is stale and never
            // becomes a credential source.
            try? fm.removeItem(at: backup)
            try writeImportMarker(importMarker, to: marker)
            try writeExclusive0600(originalData, to: backup)
            guard (try? Data(contentsOf: paths.configFile)) == originalData else {
                throw CocoaError(.fileWriteFileExists)
            }
            try await importCredentialIntoCLI(backup)
            guard (try? Data(contentsOf: paths.configFile)) == originalData else {
                throw CocoaError(.fileWriteFileExists)
            }
            try writeCredentialCustodyMarker(providerID: providerID, paths: paths)
            try writeAppMarker(paths: paths, fileManager: fm)
            guard readProviderID(paths: paths) == providerID,
                  await isConfigured(paths: paths) else {
                throw SaveError.existingConfigNotOwnedByApp
            }
            try await deleteAppCredential(providerID)
            guard await readAppCredential(providerID) == nil else {
                throw SaveError.importKeychainVerificationFailed
            }
            try cleanupImportArtifacts(backup: backup, marker: marker, fileManager: fm)
        } catch {
            if !appMarkerExisted { try? fm.removeItem(at: paths.appMarkerFile) }
            if !custodyMarkerExisted { try? fm.removeItem(at: credentialCustodyMarker(paths: paths)) }
            // Keep the journal while a secret-bearing artifact remains so
            // startup recovery can retry cleanup deterministically.
            try? cleanupImportArtifacts(backup: backup, marker: marker, fileManager: fm)
            throw error
        }
    }

    static func recoverPendingImportIfNeeded(paths: ProviderPaths) async throws {
        try await recoverPendingImportIfNeeded(
            paths: paths,
            importCredentialIntoCLI: { try await ProviderCredentialHandoffRunner.migrate(configURL: $0) }
        )
    }

    static func recoverPendingImportIfNeeded(
        paths: ProviderPaths,
        importCredentialIntoCLI: @escaping @Sendable (URL) async throws -> Void
    ) async throws {
        _ = importCredentialIntoCLI // Recovery restores a safe source; retry stages it.
        let fm = FileManager.default
        let markerURL = importPendingMarker(paths: paths)
        let expectedBackupURL = paths.configFile.appendingPathExtension("import-backup")
        guard fm.fileExists(atPath: markerURL.path) else { return }
        let lockFD = try acquireConfigMutationLock(paths: paths)
        defer { releaseConfigMutationLock(lockFD) }
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(ImportPendingMarker.self, from: markerData)
        else {
            try? cleanupImportArtifacts(backup: expectedBackupURL, marker: markerURL, fileManager: fm)
            return
        }
        let expectedKeychainDestinations = [
            "keychain://live.streamvc.macprovider.provider-token.v1/\(marker.providerID)",
            "keychain://tech.malibu.provider/\(marker.providerID)",
        ]
        guard marker.from == paths.configFile.path,
              expectedKeychainDestinations.contains(marker.to),
              marker.backupPath == expectedBackupURL.path else {
            try? cleanupImportArtifacts(backup: expectedBackupURL, marker: markerURL, fileManager: fm)
            return
        }

        let currentData = try? Data(contentsOf: paths.configFile)
        let backupData = try? Data(contentsOf: expectedBackupURL)
        let currentConfigMatches = currentData.map(sha256Data) == marker.configSHA256
        let backupConfigMatches = backupData.map(sha256Data) == marker.configSHA256
        let currentProviderID = currentData.flatMap { data in
            parseTopLevelValue(named: "provider_id", from: String(decoding: data, as: UTF8.self))
        }
        let backupProviderID = backupData.flatMap { data in
            parseTopLevelValue(named: "provider_id", from: String(decoding: data, as: UTF8.self))
        }
        guard currentConfigMatches || backupConfigMatches,
              currentProviderID == marker.providerID || backupProviderID == marker.providerID else {
            try? cleanupImportArtifacts(backup: expectedBackupURL, marker: markerURL, fileManager: fm)
            return
        }
        let sourceData: Data?
        if currentConfigMatches {
            sourceData = currentData
        } else if backupConfigMatches {
            sourceData = backupData
        } else {
            sourceData = nil
        }
        guard let sourceData,
              let sourceToken = parseTopLevelValue(
                named: "provider_token",
                from: String(decoding: sourceData, as: UTF8.self)
              ),
              sha256String(sourceToken) == marker.tokenSHA256 else {
            try? cleanupImportArtifacts(backup: expectedBackupURL, marker: markerURL, fileManager: fm)
            return
        }
        if !currentConfigMatches {
            try atomicWrite0600(sourceData, to: paths.configFile)
        }
        try cleanupImportArtifacts(backup: expectedBackupURL, marker: markerURL, fileManager: fm)
    }

    static func startFreshMovingCLIConfigAside(now: Date = Date()) throws -> URL? {
        try startFreshMovingCLIConfigAside(now: now, paths: .current)
    }

    static func startFreshMovingCLIConfigAside(now: Date = Date(), paths: ProviderPaths) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.configFile.path) else { return nil }
        try paths.ensureDirectories()
        let lockFD = try acquireConfigMutationLock(paths: paths)
        defer { releaseConfigMutationLock(lockFD) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let suffix = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let backup = paths.configFile.deletingLastPathComponent()
            .appendingPathComponent("config.yaml.cli-backup-\(suffix)")
        try fm.moveItem(at: paths.configFile, to: backup)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    // AUDIT R1 CODE M2 / SECURITY S3 / ARCHITECT A6 fix: uninstall must complete
    // before we terminate the process. Previously the Keychain delete ran in an
    // unstructured Task and NSApp.terminate raced past it, leaving the payout-
    // bearing token behind. Return a residue report so the caller can surface
    // failures to the user instead of pretending uninstall succeeded.
    struct UninstallResidue {
        var configRemoveFailed: Error?
        var appSupportRemoveFailed: Error?
        var keychainDeleteFailed: Error?
        var cliUninstallWarnings: [String] = []
        var clean: Bool {
            configRemoveFailed == nil
                && appSupportRemoveFailed == nil
                && keychainDeleteFailed == nil
                && cliUninstallWarnings.isEmpty
        }
    }

    static func wipeAppOwnedState() async -> UninstallResidue {
        var residue = UninstallResidue()
        let paths = ProviderPaths.current
        let markerExists = FileManager.default.fileExists(atPath: paths.appMarkerFile.path)
        if markerExists {
            do {
                let lockFD = try acquireConfigMutationLock(paths: paths)
                defer { releaseConfigMutationLock(lockFD) }
                try FileManager.default.removeItem(at: paths.configFile)
            }
            catch {
                let ns = error as NSError
                if !(ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError) {
                    residue.configRemoveFailed = error
                }
            }
        }
        do { try FileManager.default.removeItem(at: paths.appSupport) }
        catch {
            let ns = error as NSError
            if !(ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError) {
                residue.appSupportRemoveFailed = error
            }
        }
        do { try await KeychainStore.deleteAllAppItems() }
        catch { residue.keychainDeleteFailed = error }
        return residue
    }

    static func isConfigured(paths: ProviderPaths) async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.configFile.path),
              fm.fileExists(atPath: paths.appMarkerFile.path),
              let providerID = readProviderID(paths: paths) else {
            return false
        }
        return readCredentialCustodyMarker(paths: paths) == providerID
    }

    private static func writeAppMarker(paths: ProviderPaths, fileManager fm: FileManager) throws {
        if fm.fileExists(atPath: paths.appMarkerFile.path) { return }
        guard fm.createFile(atPath: paths.appMarkerFile.path, contents: Data()) else {
            throw SaveError.appMarkerCreateFailed
        }
    }

    private static func removeAndConfirm(_ url: URL, fileManager fm: FileManager) throws {
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        guard !fm.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func cleanupImportArtifacts(
        backup: URL,
        marker: URL,
        fileManager fm: FileManager
    ) throws {
        // The marker is the only durable pointer to the secret snapshot. Never
        // retire it until backup deletion has been positively confirmed.
        try removeAndConfirm(backup, fileManager: fm)
        try removeAndConfirm(marker, fileManager: fm)
    }

    static func credentialCustodyMarker(paths: ProviderPaths) -> URL {
        paths.appSupport.appendingPathComponent(".cli-credential-custody-v1")
    }

    private static func writeCredentialCustodyMarker(providerID: String, paths: ProviderPaths) throws {
        try atomicWrite0600(Data((providerID + "\n").utf8), to: credentialCustodyMarker(paths: paths))
    }

    private static func readCredentialCustodyMarker(paths: ProviderPaths) -> String? {
        guard let contents = try? String(
            contentsOf: credentialCustodyMarker(paths: paths),
            encoding: .utf8
        ) else {
            return nil
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func importPendingMarker(paths: ProviderPaths) -> URL {
        paths.appSupport.appendingPathComponent(".import_pending")
    }

    private struct ImportPendingMarker: Codable, Equatable {
        let from: String
        let to: String
        let timestamp: String
        let providerID: String
        let tokenSHA256: String
        let configSHA256: String
        let backupPath: String

        enum CodingKeys: String, CodingKey {
            case from
            case to
            case timestamp
            case providerID = "provider_id"
            case tokenSHA256 = "token_sha256"
            case configSHA256 = "config_sha256"
            case backupPath = "backup_path"
        }
    }

    private static func writeImportMarker(_ marker: ImportPendingMarker, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite0600(try encoder.encode(marker), to: url)
    }

    private static func parseTopLevelValue(named key: String, from contents: String) -> String? {
        topLevelLines(contents).compactMap { line -> String? in
            guard line.hasPrefix("\(key):") else { return nil }
            let value = line
                .dropFirst("\(key):".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }.first
    }

    private static func configLines(_ config: AutotuneServeConfig) -> [String] {
        let linesByKey = configLinesByKey(config)
        return recommendationOwnedKeys.compactMap { linesByKey[$0] }
    }

    private static func configLinesByKey(_ config: AutotuneServeConfig) -> [String: String] {
        var lines = [
            "model": "model: \(config.model)",
            "model_artifact_path": "model_artifact_path: \(config.modelArtifactPath)",
            "model_artifact_sha256": "model_artifact_sha256: \(config.modelArtifactSHA256)",
            "model_catalog_key": "model_catalog_key: \(config.modelCatalogKey)",
            "model_catalog_model_id": "model_catalog_model_id: \(config.modelCatalogModelID)",
            "model_catalog_revision": "model_catalog_revision: \(config.modelCatalogRevision)",
            "model_catalog_sha256": "model_catalog_sha256: \(config.modelCatalogSHA256)",
            "model_catalog_version": "model_catalog_version: \(config.modelCatalogVersion)",
            "model_catalog_hash": "model_catalog_hash: \(config.modelCatalogHash)",
            "max_context_override": "max_context_override: \(config.maxContextOverride)",
            "max_concurrency_override": "max_concurrency_override: \(config.maxConcurrencyOverride)",
        ]
        if let kvBits = config.kvBits {
            lines["kv_bits"] = "kv_bits: \(kvBits)"
        }
        if config.donorMode {
            lines["donor_mode"] = "donor_mode: true"
        }
        return lines
    }

    private static func upsertingRecommendationConfigLines(into contents: String, config: AutotuneServeConfig) -> String {
        let newLinesByKey = configLinesByKey(config)
        guard !contents.isEmpty else {
            return configLines(config).joined(separator: "\n") + "\n"
        }

        var seen = Set<String>()
        var output = ""
        for (line, rawLine) in normalizedLineRanges(contents) {
            guard let key = recommendationOwnedKeys.first(where: { topLevelKey($0, matches: line) }) else {
                output += rawLine
                continue
            }
            seen.insert(key)
            guard let newLine = newLinesByKey[key] else {
                continue
            }
            output += newLine + lineTerminator(from: rawLine)
        }

        let missing = recommendationOwnedKeys.compactMap { key -> String? in
            guard !seen.contains(key) else { return nil }
            return newLinesByKey[key]
        }
        if !missing.isEmpty {
            if !output.isEmpty, !output.hasSuffix("\n") {
                output += "\n"
            }
            output += missing.joined(separator: "\n") + "\n"
        }
        return output
    }

    private static func upsertingTopLevelLine(named key: String, line newLine: String, into contents: String) -> String {
        guard !contents.isEmpty else {
            return newLine + "\n"
        }

        var replaced = false
        var output = ""
        for (line, rawLine) in normalizedLineRanges(contents) {
            guard topLevelKey(key, matches: line) else {
                output += rawLine
                continue
            }
            if !replaced {
                output += newLine + lineTerminator(from: rawLine)
                replaced = true
            }
        }

        if !replaced {
            if !output.isEmpty, !output.hasSuffix("\n") {
                output += "\n"
            }
            output += newLine + "\n"
        } else if !output.isEmpty, !output.hasSuffix("\n") {
            output += "\n"
        }
        return output
    }

    private static func validate(_ config: AutotuneServeConfig) throws {
        try validateScalar(config.model, key: "model")
        try validateScalar(config.modelArtifactPath, key: "model_artifact_path")
        guard config.modelArtifactPath.hasPrefix("/") else {
            throw ServeConfigError.invalidField("model_artifact_path")
        }
        try validateHex(config.modelArtifactSHA256, key: "model_artifact_sha256")
        try validateScalar(config.modelCatalogKey, key: "model_catalog_key")
        try validateScalar(config.modelCatalogModelID, key: "model_catalog_model_id")
        try validateScalar(config.modelCatalogRevision, key: "model_catalog_revision")
        try validateHex(config.modelCatalogSHA256, key: "model_catalog_sha256")
        try validateScalar(config.modelCatalogVersion, key: "model_catalog_version")
        try validateHex(config.modelCatalogHash, key: "model_catalog_hash")
        if let kvBits = config.kvBits, kvBits != 4 && kvBits != 8 {
            throw ServeConfigError.invalidField("kv_bits")
        }
        guard config.maxContextOverride > 0 else {
            throw ServeConfigError.invalidField("max_context_override")
        }
        guard config.maxConcurrencyOverride > 0 else {
            throw ServeConfigError.invalidField("max_concurrency_override")
        }
    }

    private static func validateScalar(_ value: String, key: String) throws {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ServeConfigError.invalidField(key)
        }
        if value.unicodeScalars.contains(where: { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }) {
            throw ServeConfigError.invalidField(key)
        }
        for forbidden in ["\n", "\r", "#", ": ", "'", "\"", "\\"] where value.contains(forbidden) {
            throw ServeConfigError.invalidField(key)
        }
    }

    private static func validateHex(_ value: String, key: String) throws {
        try validateScalar(value, key: key)
        guard value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw ServeConfigError.invalidField(key)
        }
    }

    private static func required(_ key: String, _ contents: String) throws -> String {
        guard let value = parseTopLevelValue(named: key, from: contents) else {
            throw ServeConfigError.missingField(key)
        }
        return value
    }

    private static func requiredInt(_ key: String, _ contents: String) throws -> Int {
        guard let value = parseTopLevelValue(named: key, from: contents) else {
            throw ServeConfigError.missingField(key)
        }
        guard let intValue = Int(value) else {
            throw ServeConfigError.invalidField(key)
        }
        return intValue
    }

    private static func optionalInt(_ key: String, _ contents: String) throws -> Int? {
        guard let value = parseTopLevelValue(named: key, from: contents) else {
            return nil
        }
        guard let intValue = Int(value) else {
            throw ServeConfigError.invalidField(key)
        }
        return intValue
    }

    private static func optionalBool(_ key: String, _ contents: String) throws -> Bool? {
        guard let value = parseTopLevelValue(named: key, from: contents) else {
            return nil
        }
        switch value {
        case "true": return true
        case "false": return false
        default: throw ServeConfigError.invalidField(key)
        }
    }

    private static func normalizedLines(_ contents: String) -> [String] {
        contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func topLevelLines(_ contents: String) -> [String] {
        normalizedLineRanges(contents).compactMap { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == line ? trimmed : nil
        }
    }

    private static func normalizedLineRanges(_ contents: String) -> [(line: String, rawLine: String)] {
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [] }
        var lines: [(String, String)] = []
        normalized.enumerateSubstrings(in: normalized.startIndex..<normalized.endIndex, options: .byLines) {
            line, _, enclosingRange, _ in
            guard let line else { return }
            lines.append((line, String(normalized[enclosingRange])))
        }
        return lines
    }

    private static func topLevelKey(_ key: String, matches line: String) -> Bool {
        line.hasPrefix("\(key):")
    }

    private static func lineTerminator(from rawLine: String) -> String {
        rawLine.hasSuffix("\n") ? "\n" : ""
    }

    private static func writeExclusive0600(_ data: Data, to destination: URL) throws {
        let fd = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var closed = false
        do {
            try writeAll(data, fd: fd)
            try fsyncFile(fd)
            try closeFile(fd)
            closed = true
            try fsyncDirectory(destination.deletingLastPathComponent())
        } catch {
            if !closed {
                _ = close(fd)
            }
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func atomicWrite0600(_ data: Data, to destination: URL) throws {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var closed = false
        do {
            try writeAll(data, fd: fd)
            if fchmod(fd, S_IRUSR | S_IWUSR) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            try fsyncFile(fd)
            try closeFile(fd)
            closed = true
            if rename(temp.path, destination.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            try fsyncDirectory(destination.deletingLastPathComponent())
        } catch {
            if !closed {
                _ = close(fd)
            }
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func acquireConfigMutationLock(paths: ProviderPaths) throws -> Int32 {
        let lockURL = paths.configFile.deletingLastPathComponent()
            .appendingPathComponent(".\(paths.configFile.lastPathComponent).lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        if fchmod(fd, S_IRUSR | S_IWUSR) != 0 || flock(fd, LOCK_EX) != 0 {
            _ = close(fd)
            throw CocoaError(.fileWriteUnknown)
        }
        return fd
    }

    private static func releaseConfigMutationLock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        _ = close(fd)
    }

    private static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(fd, base.advanced(by: written), raw.count - written)
                if n <= 0 {
                    if errno == EINTR { continue }
                    throw CocoaError(.fileWriteUnknown)
                }
                written += n
            }
        }
    }

    private static func fsyncFile(_ fd: Int32) throws {
        if fsync(fd) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func closeFile(_ fd: Int32) throws {
        if close(fd) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func fsyncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var closed = false
        do {
            try fsyncFile(fd)
            try closeFile(fd)
            closed = true
        } catch {
            if !closed {
                _ = close(fd)
            }
            throw error
        }
    }

    private static func sha256String(_ value: String) -> String {
        sha256Data(Data(value.utf8))
    }

    private static func sha256Data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func importTimestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
