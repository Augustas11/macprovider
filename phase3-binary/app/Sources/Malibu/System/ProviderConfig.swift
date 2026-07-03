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

    static func readProviderID() -> String? {
        let paths = ProviderPaths.current
        guard let contents = try? String(contentsOf: paths.configFile) else { return nil }
        // AUDIT R1 CODE M1 fix: split on both CR and LF so CRLF files round-trip.
        // .whitespacesAndNewlines trim covers any stray \r left after the split.
        for rawLine in contents.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
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
        var errorDescription: String? {
            switch self {
            case .existingConfigNotOwnedByApp:
                return "A macprovider config already exists on this Mac and was not installed by the app. Uninstall the CLI track or import its provider_id manually before continuing."
            }
        }
    }

    static func saveProviderIdentity(providerID: String, token: String) async throws {
        let paths = ProviderPaths.current
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
            lines = existing.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
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
}
