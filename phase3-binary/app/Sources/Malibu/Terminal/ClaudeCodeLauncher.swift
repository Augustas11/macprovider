import Darwin
import Foundation

struct ClaudeCodeLaunchPlan {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let keyHandoff: URL
    let configurationDirectory: URL
    let cleanupDirectory: URL
}

/// Claude receives only the consumer token; no ~/.claude files are changed.
enum ClaudeCodeLauncher {
    static let modelEnvironmentKeys = [
        "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL"
    ]

    static func prepare(
        executable: URL,
        model: ConnectedModel,
        endpoint: ManagedPrivacyEndpoint,
        loginPath: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ClaudeCodeLaunchPlan {
        guard model.supportsTools, let context = model.contextWindow, context >= 32_768,
              !model.id.isEmpty, model.id.utf8.count < 512,
              ProcessEnvironmentSanitizer.isSafeValue(model.id),
              executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ConnectedAppsError.invalidConfiguration
        }
        let root = home.appendingPathComponent("Library/Application Support/Malibu/clients/claude-code", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let launch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let script = launch.appendingPathComponent("Launch.command")
        let handoff = launch.appendingPathComponent("buyer.key")
        // The existing transaction utility creates every missing ancestor with
        // 0700 and refuses symlink traversal while writing a new regular file.
        let marker = config.appendingPathComponent(".malibu-owned")
        let original = try ConnectedConfigTransaction.read(marker)
        if original.bytes == nil {
            try ConnectedConfigTransaction.replace(marker, expected: original, bytes: Data(), mode: 0o600)
        }
        var configStat = stat()
        guard lstat(config.path, &configStat) == 0, configStat.st_mode & S_IFMT == S_IFDIR,
              configStat.st_uid == getuid(), chmod(config.path, 0o700) == 0 else { throw ConnectedAppsError.unsafeFile }
        var environment = [
            "ANTHROPIC_BASE_URL": ManagedPrivacyEndpoint.baseURL.deletingLastPathComponent().absoluteString,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CONFIG_DIR": config.path,
            "TERM": "xterm-256color"
        ]
        for name in modelEnvironmentKeys { environment[name] = model.id }
        let sanitized = try HarnessCatalog.launchEnvironment(loginPath: loginPath ?? inheritedEnvironment["PATH"] ?? "/usr/bin:/bin",
                                                            inherited: inheritedEnvironment, extra: environment)
        let bytes = Data("""
        #!/bin/sh
        set +x
        set -eu
        KEY_FILE=\(ConnectedAppConfiguration.shell(handoff.path))
        if [ ! -f "$KEY_FILE" ] || [ -L "$KEY_FILE" ]; then exit 1; fi
        ANTHROPIC_AUTH_TOKEN=$(/bin/cat -- "$KEY_FILE") || { /bin/rm -f -- "$KEY_FILE"; exit 1; }
        /bin/rm -f -- "$KEY_FILE"
        test -n "$ANTHROPIC_AUTH_TOKEN"
        export ANTHROPIC_AUTH_TOKEN
        exec \(ConnectedAppConfiguration.shell(executable.path)) --model \(ConnectedAppConfiguration.shell(model.id))

        """.utf8)
        do {
            try ConnectedConfigTransaction.replace(script, expected: ConnectedConfigSnapshot(bytes: nil, mode: nil), bytes: bytes, mode: 0o700)
            try ConnectedBuyerKeychain.writeLaunchHandoff(endpoint.localToken, to: handoff)
        } catch {
            ConnectedBuyerKeychain.removeLaunchHandoff(handoff)
            try? FileManager.default.removeItem(at: launch)
            throw error
        }
        return ClaudeCodeLaunchPlan(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path],
                                    environment: sanitized, keyHandoff: handoff,
                                    configurationDirectory: config, cleanupDirectory: launch)
    }
}
