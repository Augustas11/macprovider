import Foundation

// Read / write the shared ~/.config/macprovider/config.yaml. We touch the same
// file the CLI track's install.sh renders, but we own the provider_token via
// Keychain (never persisted to disk in this track). See SPEC-025 §7.

enum ProviderConfig {
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
        // AUDIT R1 CODE M1 fix, corrected in E2E:
        // Swift's Character treats `\r\n` as a single grapheme cluster, so a
        // predicate `$0 == "\n" || $0 == "\r"` on Character never matches
        // inside CRLF sequences. Normalize CRLF → LF first, then split.
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("provider_id:") else { continue }
            let value = line
                .dropFirst("provider_id:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
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
        case importRollbackFailed(importError: Error, rollbackError: Error)
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
            case let .importRollbackFailed(importError, rollbackError):
                return "Import failed (\(importError.localizedDescription)) and the original config could not be restored (\(rollbackError.localizedDescription))."
            }
        }
    }

    static func saveProviderIdentity(providerID: String, token: String) async throws {
        try await saveProviderIdentity(providerID: providerID, token: token, paths: .current)
    }

    static func saveProviderIdentity(providerID: String, token: String, paths: ProviderPaths) async throws {
        try paths.ensureDirectories()

        // AUDIT R1 ARCHITECT A2: fail-fast on config collision instead of
        // silently rewriting a file the CLI track owns.
        let configExists = FileManager.default.fileExists(atPath: paths.configFile.path)
        let markerExists = FileManager.default.fileExists(atPath: paths.appMarkerFile.path)
        if configExists && !markerExists {
            throw SaveError.existingConfigNotOwnedByApp
        }

        // Merge into any existing YAML rather than clobbering — a developer who
        // ran install.sh first might have coordinator overrides here.
        var lines: [String] = []
        if let existing = try? String(contentsOf: paths.configFile) {
            // Same CRLF-grapheme note as readProviderID above.
            let normalized = existing
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.hasPrefix("provider_id:") && !$0.hasPrefix("provider_token:") }
        }
        lines.append("provider_id: \(providerID)")
        // We deliberately do NOT write the token to disk. The CLI must be
        // launched with the token in the environment (MACPROVIDER_PROVIDER_TOKEN),
        // which MalibuAgent will set from Keychain before spawning the process.
        // Followup: teach the CLI to read the token from Keychain directly so
        // the environment-variable path can be removed.
        let joined = lines.joined(separator: "\n") + "\n"
        try joined.data(using: .utf8)?.write(to: paths.configFile, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)

        try await KeychainStore.saveProviderToken(providerID: providerID, token: token)

        FileManager.default.createFile(atPath: paths.appMarkerFile.path, contents: Data())
    }

    static func importExistingCLIConfig() async throws {
        try await importExistingCLIConfig(paths: .current)
    }

    static func importExistingCLIConfig(paths: ProviderPaths) async throws {
        try paths.ensureDirectories()
        let fm = FileManager.default
        let backup = paths.configFile.appendingPathExtension("import-backup")
        let backupExisted = fm.fileExists(atPath: backup.path)
        let originalData = try Data(contentsOf: paths.configFile)
        let current = String(decoding: originalData, as: UTF8.self)
        let backupData = backupExisted ? try Data(contentsOf: backup) : nil
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
        do {
            try await KeychainStore.saveProviderToken(providerID: providerID, token: token)
            if !backupExisted {
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: paths.configFile, to: backup)
            }
            try rewritten.data(using: .utf8)?.write(to: paths.configFile, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
            fm.createFile(atPath: paths.appMarkerFile.path, contents: Data())
            guard await isConfigured(paths: paths) else { throw SaveError.existingConfigNotOwnedByApp }
            try? fm.removeItem(at: backup)
        } catch {
            try? await KeychainStore.deleteProviderToken(providerID: providerID)
            try? fm.removeItem(at: paths.appMarkerFile)
            do {
                try originalData.write(to: paths.configFile, options: [.atomic])
                if !backupExisted {
                    try? fm.removeItem(at: backup)
                }
            } catch let rollbackError {
                throw SaveError.importRollbackFailed(importError: error, rollbackError: rollbackError)
            }
            throw error
        }
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
}
