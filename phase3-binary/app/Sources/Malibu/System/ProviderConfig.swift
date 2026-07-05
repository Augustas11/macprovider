import CryptoKit
import Darwin
import Foundation

// Read / write the shared ~/.config/macprovider/config.yaml. We touch the same
// file the CLI track's install.sh renders, but we own the provider_token via
// Keychain (never persisted to disk in this track). See SPEC-025 §7.

enum ProviderConfig {
    enum LinkState: String, Equatable {
        case pendingLink = "pending_link"
        case linked
        case unlinkPending = "unlink_pending"
    }

    // AUDIT R1 CODE H4 / SECURITY S1 / ARCHITECT A2 fix:
    //   * config exists AND
    //   * app-ownership marker exists (we did not inherit a CLI-track config) AND
    //   * a Keychain token is bound to the config-file's provider_id.
    // Missing any of these routes the user to onboarding rather than spawning
    // the CLI unauthenticated or trampling a config the CLI track owns.
    static var isConfigured: Bool {
        get async {
            let paths = ProviderPaths.current
            let fm = FileManager.default
            guard fm.fileExists(atPath: paths.configFile.path),
                  fm.fileExists(atPath: paths.appMarkerFile.path),
                  let providerID = readProviderID() else {
                return false
            }
            return await KeychainStore.readProviderToken(providerID: providerID) != nil
        }
    }

    static func readProviderID(paths: ProviderPaths = .current) -> String? {
        guard let contents = try? String(contentsOf: paths.configFile) else { return nil }
        return parseTopLevelValue(named: "provider_id", from: contents)
    }

    static func readLinkState(paths: ProviderPaths = .current) -> LinkState? {
        guard let contents = try? String(contentsOf: paths.configFile),
              let value = parseTopLevelValue(named: "link_state", from: contents)
        else {
            return nil
        }
        return LinkState(rawValue: value)
    }

    static func writeLinkState(_ state: LinkState, paths: ProviderPaths = .current) throws {
        let contents = (try? String(contentsOf: paths.configFile)) ?? ""
        var lines = normalizedLines(contents)
            .filter { !$0.hasPrefix("link_state:") }
        lines.append("link_state: \(state.rawValue)")
        try atomicWrite0600(Data((lines.joined(separator: "\n") + "\n").utf8), to: paths.configFile)
    }

    // AUDIT R1 ARCHITECT A2: raised when the shared config exists on disk
    // without the app's ownership marker. The app must not silently overwrite
    // a config the CLI track may own; onboarding surfaces this and requires an
    // explicit user decision (import into app track vs cancel).
    enum SaveError: Error, LocalizedError {
        case existingConfigNotOwnedByApp
        case missingProviderID
        case missingProviderToken
        case importBackupProviderMismatch
        case importKeychainVerificationFailed
        case importRollbackFailed(importError: Error, rollbackError: Error)
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
            case .importBackupProviderMismatch:
                return "The import backup does not match the current provider_id."
            case .importKeychainVerificationFailed:
                return "The imported provider token could not be verified in Keychain."
            case let .importRollbackFailed(importError, rollbackError):
                return "Import failed (\(importError.localizedDescription)) and the original config could not be restored (\(rollbackError.localizedDescription))."
            case .appMarkerCreateFailed:
                return "The app ownership marker could not be written."
            case .savedIdentityNotConfigured:
                return "The provider identity was not fully persisted."
            }
        }
    }

    static func saveProviderIdentity(providerID: String, token: String) async throws {
        try await saveProviderIdentity(providerID: providerID, token: token, paths: .current)
    }

    static func saveProviderIdentity(providerID: String, token: String, paths: ProviderPaths) async throws {
        try await saveProviderIdentity(
            providerID: providerID,
            token: token,
            paths: paths,
            readToken: { await KeychainStore.readProviderToken(providerID: $0) },
            saveToken: { try await KeychainStore.saveProviderToken(providerID: $0, token: $1) },
            deleteToken: { try await KeychainStore.deleteProviderToken(providerID: $0) }
        )
    }

    static func saveProviderIdentity(
        providerID: String,
        token: String,
        paths: ProviderPaths,
        readToken: @escaping (String) async -> String?,
        saveToken: @escaping (String, String) async throws -> Void,
        deleteToken: @escaping (String) async throws -> Void,
        createAppMarker: (() throws -> Void)? = nil,
        verifyConfigured: (() async -> Bool)? = nil
    ) async throws {
        try paths.ensureDirectories()
        let fm = FileManager.default

        // AUDIT R1 ARCHITECT A2: fail-fast on config collision instead of
        // silently rewriting a file the CLI track owns.
        let configExists = fm.fileExists(atPath: paths.configFile.path)
        let markerExists = fm.fileExists(atPath: paths.appMarkerFile.path)
        if configExists && !markerExists {
            throw SaveError.existingConfigNotOwnedByApp
        }
        let originalData = configExists ? try Data(contentsOf: paths.configFile) : nil
        let originalToken = await readToken(providerID)

        // Merge into any existing YAML rather than clobbering — a developer who
        // ran install.sh first might have coordinator overrides here.
        var lines: [String] = []
        if let existing = try? String(contentsOf: paths.configFile) {
            // Same CRLF-grapheme note as readProviderID above.
            let normalized = existing
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter {
                    !$0.hasPrefix("provider_id:")
                        && !$0.hasPrefix("provider_token:")
                        && !$0.hasPrefix("link_state:")
                }
        }
        lines.append("provider_id: \(providerID)")
        lines.append("link_state: \(LinkState.pendingLink.rawValue)")
        // We deliberately do NOT write the token to disk. The CLI must be
        // launched with the token in the environment (MACPROVIDER_PROVIDER_TOKEN),
        // which MalibuAgent will set from Keychain before spawning the process.
        // Followup: teach the CLI to read the token from Keychain directly so
        // the environment-variable path can be removed.
        let joined = lines.joined(separator: "\n") + "\n"
        do {
            try await saveToken(providerID, token)
            try Data(joined.utf8).write(to: paths.configFile, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
            if let createAppMarker {
                try createAppMarker()
            } else {
                try writeAppMarker(paths: paths, fileManager: fm)
            }
            let configured: Bool
            if let verifyConfigured {
                configured = await verifyConfigured()
            } else {
                configured = await isConfigured(paths: paths)
            }
            guard configured else { throw SaveError.savedIdentityNotConfigured }
        } catch {
            if let originalToken {
                try? await saveToken(providerID, originalToken)
            } else {
                try? await deleteToken(providerID)
            }
            if let originalData {
                try? originalData.write(to: paths.configFile, options: [.atomic])
            } else {
                try? fm.removeItem(at: paths.configFile)
            }
            if !markerExists {
                try? fm.removeItem(at: paths.appMarkerFile)
            }
            throw error
        }
    }

    static func importExistingCLIConfig() async throws {
        try await importExistingCLIConfig(paths: .current)
    }

    static func importExistingCLIConfig(paths: ProviderPaths) async throws {
        try paths.ensureDirectories()
        let fm = FileManager.default
        try await recoverPendingImportIfNeeded(paths: paths)
        let backup = paths.configFile.appendingPathExtension("import-backup")
        let marker = importPendingMarker(paths: paths)
        let backupExisted = fm.fileExists(atPath: backup.path)
        let originalData = try Data(contentsOf: paths.configFile)
        let current = String(decoding: originalData, as: UTF8.self)
        let backupData = backupExisted ? try Data(contentsOf: backup) : nil
        if backupExisted {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let backupContents = backupData.map { String(decoding: $0, as: UTF8.self) }
        let secretSource = backupContents ?? current

        let currentProviderID = parseTopLevelValue(named: "provider_id", from: current)
        let backupProviderID = backupContents.flatMap { parseTopLevelValue(named: "provider_id", from: $0) }
        if let currentProviderID, let backupProviderID, currentProviderID != backupProviderID {
            throw SaveError.importBackupProviderMismatch
        }
        guard let providerID = currentProviderID ?? backupProviderID else {
            throw SaveError.missingProviderID
        }
        guard let token = parseTopLevelValue(named: "provider_token", from: secretSource) else {
            throw SaveError.missingProviderToken
        }

        let rewritten = removingTopLevelValue(named: "provider_token", from: current)
        let importMarker = ImportPendingMarker(
            from: paths.configFile.path,
            to: "keychain://tech.malibu.provider/\(providerID)",
            timestamp: importTimestampString(Date()),
            providerID: providerID,
            tokenSHA256: sha256String(token),
            configSHA256: sha256Data(originalData),
            backupPath: backup.path
        )
        do {
            try writeImportMarker(importMarker, to: marker)
            try await KeychainStore.saveProviderToken(providerID: providerID, token: token)
            guard await KeychainStore.readProviderToken(providerID: providerID).map(sha256String) == importMarker.tokenSHA256 else {
                throw SaveError.importKeychainVerificationFailed
            }
            if !backupExisted {
                try? fm.removeItem(at: backup)
                try writeExclusive0600(originalData, to: backup)
            }
            try atomicWrite0600(Data(rewritten.utf8), to: paths.configFile)
            try writeAppMarker(paths: paths, fileManager: fm)
            try writeLinkState(.linked, paths: paths)
            guard await isConfigured(paths: paths) else { throw SaveError.existingConfigNotOwnedByApp }
            try? fm.removeItem(at: backup)
            try? fm.removeItem(at: marker)
        } catch {
            try? await KeychainStore.deleteProviderToken(providerID: providerID)
            try? fm.removeItem(at: paths.appMarkerFile)
            do {
                try atomicWrite0600(originalData, to: paths.configFile)
                if !backupExisted {
                    try? fm.removeItem(at: backup)
                }
                try? fm.removeItem(at: marker)
            } catch let rollbackError {
                throw SaveError.importRollbackFailed(importError: error, rollbackError: rollbackError)
            }
            throw error
        }
    }

    static func recoverPendingImportIfNeeded(paths: ProviderPaths) async throws {
        let fm = FileManager.default
        let markerURL = importPendingMarker(paths: paths)
        guard fm.fileExists(atPath: markerURL.path) else { return }
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(ImportPendingMarker.self, from: markerData)
        else {
            try? fm.removeItem(at: markerURL)
            return
        }
        let expectedBackupURL = paths.configFile.appendingPathExtension("import-backup")
        let expectedKeychainDestination = "keychain://tech.malibu.provider/\(marker.providerID)"
        guard marker.from == paths.configFile.path,
              marker.to == expectedKeychainDestination,
              marker.backupPath == expectedBackupURL.path else {
            try? fm.removeItem(at: markerURL)
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
            try? fm.removeItem(at: markerURL)
            return
        }

        if await KeychainStore.readProviderToken(providerID: marker.providerID).map(sha256String) == marker.tokenSHA256 {
            if let current = try? String(contentsOf: paths.configFile), current.contains("provider_token:") {
                try atomicWrite0600(
                    Data(removingTopLevelValue(named: "provider_token", from: current).utf8),
                    to: paths.configFile
                )
            }
            try writeAppMarker(paths: paths, fileManager: fm)
            try writeLinkState(.linked, paths: paths)
            if await isConfigured(paths: paths) {
                try? fm.removeItem(atPath: marker.backupPath)
                try? fm.removeItem(at: markerURL)
            }
            return
        }

        if let backupData, backupConfigMatches, backupProviderID == marker.providerID {
            try atomicWrite0600(backupData, to: paths.configFile)
            try? await KeychainStore.deleteProviderToken(providerID: marker.providerID)
            try? fm.removeItem(at: paths.appMarkerFile)
            try? fm.removeItem(atPath: marker.backupPath)
            try? fm.removeItem(at: markerURL)
            return
        }

        try? await KeychainStore.deleteProviderToken(providerID: marker.providerID)
        try? fm.removeItem(at: paths.appMarkerFile)
        try? fm.removeItem(at: markerURL)
    }

    static func repairMarkerlessAppOwnedConfig(providerID: String, paths: ProviderPaths = .current) async throws {
        try paths.ensureDirectories()
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.configFile.path) else {
            throw SaveError.missingProviderID
        }
        if fm.fileExists(atPath: paths.appMarkerFile.path) {
            guard await isConfigured(paths: paths) else { throw SaveError.savedIdentityNotConfigured }
            return
        }
        guard readProviderID(paths: paths) == providerID else {
            throw SaveError.existingConfigNotOwnedByApp
        }
        guard await KeychainStore.readProviderToken(providerID: providerID) != nil else {
            throw SaveError.missingProviderToken
        }
        try writeAppMarker(paths: paths, fileManager: fm)
        guard await isConfigured(paths: paths) else { throw SaveError.savedIdentityNotConfigured }
    }

    static func startFreshMovingCLIConfigAside(now: Date = Date()) throws -> URL? {
        try startFreshMovingCLIConfigAside(now: now, paths: .current)
    }

    static func startFreshMovingCLIConfigAside(now: Date = Date(), paths: ProviderPaths) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.configFile.path) else { return nil }
        try paths.ensureDirectories()
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
        var clean: Bool {
            configRemoveFailed == nil && appSupportRemoveFailed == nil && keychainDeleteFailed == nil
        }
    }

    static func wipeAppOwnedState() async -> UninstallResidue {
        var residue = UninstallResidue()
        let paths = ProviderPaths.current
        let markerExists = FileManager.default.fileExists(atPath: paths.appMarkerFile.path)
        if markerExists {
            do { try FileManager.default.removeItem(at: paths.configFile) }
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
        return await KeychainStore.readProviderToken(providerID: providerID) != nil
    }

    private static func writeAppMarker(paths: ProviderPaths, fileManager fm: FileManager) throws {
        if fm.fileExists(atPath: paths.appMarkerFile.path) { return }
        guard fm.createFile(atPath: paths.appMarkerFile.path, contents: Data()) else {
            throw SaveError.appMarkerCreateFailed
        }
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
        normalizedLines(contents).compactMap { line -> String? in
            guard line.hasPrefix("\(key):") else { return nil }
            let value = line
                .dropFirst("\(key):".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }.first
    }

    private static func removingTopLevelValue(named key: String, from contents: String) -> String {
        normalizedLines(contents)
            .filter { !$0.hasPrefix("\(key):") }
            .joined(separator: "\n") + "\n"
    }

    private static func normalizedLines(_ contents: String) -> [String] {
        contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
