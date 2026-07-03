import Foundation

// Read / write the shared ~/.config/macprovider/config.yaml. We touch the same
// file the CLI track's install.sh renders, but we own the provider_token via
// Keychain (never persisted to disk in this track). See SPEC-025 §7.

enum ProviderConfig {
    static var isConfigured: Bool {
        get async {
            let paths = ProviderPaths.current
            guard FileManager.default.fileExists(atPath: paths.configFile.path) else {
                return false
            }
            return await KeychainStore.hasProviderToken()
        }
    }

    static func saveProviderIdentity(providerID: String, token: String) async throws {
        let paths = ProviderPaths.current
        try paths.ensureDirectories()

        // Merge into any existing YAML rather than clobbering — a developer who
        // ran install.sh first might have coordinator overrides here.
        var lines: [String] = []
        if let existing = try? String(contentsOf: paths.configFile) {
            lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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

    static func wipeAppOwnedState() throws {
        let paths = ProviderPaths.current
        let markerExists = FileManager.default.fileExists(atPath: paths.appMarkerFile.path)
        if markerExists {
            try? FileManager.default.removeItem(at: paths.configFile)
        }
        try? FileManager.default.removeItem(at: paths.appSupport)
        Task { try? await KeychainStore.deleteAllAppItems() }
    }
}
