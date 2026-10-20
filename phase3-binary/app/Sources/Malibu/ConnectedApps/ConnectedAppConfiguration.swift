import Foundation

enum ConnectedApp: String, CaseIterable, Identifiable, Codable {
    case codex = "Codex", openCode = "OpenCode", cursor = "Cursor", goose = "Goose", crush = "Crush"
    var id: String { rawValue }
    var api: ConnectedAPI { self == .codex ? .responses : .chatCompletions }
    var slug: String { rawValue.lowercased() }
    var documentation: URL {
        let address = switch self {
        case .codex: "https://learn.chatgpt.com/docs/enterprise/connect-to-a-gateway"
        case .openCode: "https://opencode.ai/docs/config/"
        case .cursor: "https://cursor.com/help/models-and-usage/api-keys"
        case .goose: "https://github.com/aaif-goose/goose/blob/main/documentation/docs/getting-started/providers.md"
        case .crush: "https://github.com/charmbracelet/crush/blob/main/docs/config/README.md"
        }
        return URL(string: address)!
    }
}

enum ConnectedAPI: String, Codable { case responses = "Responses", chatCompletions = "Chat Completions" }

struct ConnectedModel: Identifiable, Equatable {
    let id: String
    let contextWindow: Int?
    let maxOutputTokens: Int?
}

enum ConnectedAppsError: Error, LocalizedError {
    case unsafeFile, conflict, invalidConfiguration, unavailableMetadata, credential, invalidResponse
    case http(Int), network
    var errorDescription: String? {
        switch self {
        case .unsafeFile: "Configuration is not a bounded, user-owned regular file in a safe directory."
        case .conflict: "Configuration changed since preview or setup. No restore was performed; preserve your newer edits."
        case .invalidConfiguration: "This configuration syntax cannot be changed safely. Use the documented manual setup."
        case .unavailableMetadata: "The gateway does not publish the model metadata this client requires. Automated setup is unavailable."
        case .credential: "The buyer key could not be read or saved in Keychain."
        case .invalidResponse: "The gateway returned an unsupported or incomplete response."
        case .http(401), .http(403): "The gateway rejected this buyer key."
        case .http(402): "The buyer account needs credit."
        case .http(404), .http(405), .http(501): "The selected API or model is unavailable on this gateway."
        case .http(429): "The gateway rate limit or buyer quota was reached."
        case .http: "The gateway could not complete the request."
        case .network: "The request failed, was cancelled, or timed out. No server response details were recorded."
        }
    }
}

/// Strict JSON only: refusing JSONC is intentional, so comments are never lost.
/// Codex and Crush use isolated managed profiles, leaving arbitrary TOML/Bash intact.
enum ConnectedAppConfiguration {
    static let gateway = URL(string: "https://api.malibu.tech/v1")!
    /// SPEC-025-R012: these clients send ordinary gateway requests, which the
    /// SPEC-049 private mode does not cover; local Malibu Chat never leaves
    /// this Mac.
    static let privacy = "Not private: these apps send requests that Malibu does not encrypt, so the network's private mode doesn't apply and the Malibu gateway and the serving provider can read prompts and responses. For private requests, use Malibu Chat. Usage is billed to your buyer account."
    /// The key is in the launched CLI's environment, so anything that CLI
    /// loads or runs can read it. This is the honest scope of "injection".
    static let keyExposure = "Use a dedicated, spend-limited buyer key: the launched app, its repository configuration and the commands its agent runs can read it."
    /// The handoff mechanics and profile scope, behind Details.
    static let setupDetails = "Malibu keeps the key in Keychain and hands it to each Launch through a private one-time file; the launcher puts it in the app's environment, where anything the app loads or runs can read it and send it elsewhere. Setup writes a managed profile and a Terminal launcher for the command-line app, so always launch from here. Project settings or managed policy can override the profile; check the provider and model inside the app. Desktop apps are not set up."
    static let crushProjectConfigWarning = "Crush also loads configuration from the directory you launch it in (for example ./.crushrc) and has no switch to ignore it. A repository's Crush configuration can redirect requests or read your buyer key. Launch Crush only in repositories you trust."
    static let cursorDisclosure = "Cursor also sends your key and prompts through Cursor's servers. BYOK covers supported chat models; Tab uses Cursor models. Verify custom endpoint support in your installed Cursor version."

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    static func configuration(app: ConnectedApp, model: ConnectedModel, original: Data?, catalog: URL? = nil) throws -> Data {
        guard !model.id.isEmpty, model.id.utf8.count < 512,
              !model.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConnectedAppsError.invalidConfiguration
        }
        let base = gateway.absoluteString
        switch app {
        case .cursor: throw ConnectedAppsError.invalidConfiguration
        case .codex:
            // Codex requires its own model-catalog schema, not OpenAI /models.
            // Metadata is generated from the gateway with conservative client policies.
            guard let catalog else { throw ConnectedAppsError.unavailableMetadata }
            guard original == nil || original?.isEmpty == true else { throw ConnectedAppsError.invalidConfiguration }
            return Data("""
            model = \(quoted(model.id))
            model_provider = "malibu"
            model_catalog_json = \(quoted(catalog.path))
            [model_providers.malibu]
            name = "Malibu"
            base_url = \(quoted(base))
            wire_api = "responses"
            env_key = "MALIBU_API_KEY"

            """.utf8)
        case .openCode:
            guard let context = model.contextWindow, context > 0 else { throw ConnectedAppsError.unavailableMetadata }
            // Explicit client policy prevents OpenCode defaulting to a generation
            // budget larger than the served context. It is not a model maximum claim.
            let output = min(context, model.maxOutputTokens ?? 1024, 1024)
            var root: [String: Any] = [:]
            if let original, !original.isEmpty {
                try MalibuStrictJSON.rejectDuplicateKeys(original)
                guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw ConnectedAppsError.invalidConfiguration }
                root = parsed
            }
            if root["provider"] != nil && !(root["provider"] is [String: Any]) { throw ConnectedAppsError.invalidConfiguration }
            var providers = root["provider"] as? [String: Any] ?? [:]
            guard providers["malibu"] == nil else { throw ConnectedAppsError.conflict }
            providers["malibu"] = ["npm": "@ai-sdk/openai-compatible", "name": "Malibu",
                                   "options": ["baseURL": base, "apiKey": "{env:MALIBU_API_KEY}"],
                                   "models": [model.id: ["name": model.id,
                                                         "limit": ["context": context, "output": output]]]]
            root["provider"] = providers
            root["model"] = "malibu/\(model.id)"
            return try json(root)
        case .goose:
            guard original == nil || original?.isEmpty == true else { throw ConnectedAppsError.conflict }
            guard let context = model.contextWindow, context > 0 else { throw ConnectedAppsError.unavailableMetadata }
            return try json(["name": "malibu", "engine": "openai", "display_name": "Malibu",
                             "description": "Malibu buyer gateway", "api_key_env": "MALIBU_API_KEY",
                             "base_url": base + "/chat/completions", "requires_auth": true,
                             "supports_streaming": true, "models": [["name": model.id, "context_limit": context]]])
        case .crush:
            guard original == nil || original?.isEmpty == true else { throw ConnectedAppsError.invalidConfiguration }
            guard let context = model.contextWindow, context > 0 else { throw ConnectedAppsError.unavailableMetadata }
            // This is our client output budget, not a claim about the model capability.
            let output = min(context, model.maxOutputTokens ?? 1024, 1024)
            return Data("""
            provider add malibu --type openai-compat --base-url \(shell(base)) --api-key "$MALIBU_API_KEY"
            model add \(shell("malibu/" + model.id)) --name \(shell(model.id)) --context-window \(context) --default-max-tokens \(output)
            model large \(shell("malibu/" + model.id))

            """.utf8)
        }
    }

    /// Schema verified against Codex CLI 0.163.0. Context is gateway metadata;
    /// truncation and tool mode are conservative client policy, not capability claims.
    static func codexCatalog(model: ConnectedModel) throws -> Data {
        guard let context = model.contextWindow, context > 0 else { throw ConnectedAppsError.unavailableMetadata }
        return try json(["models": [[
            "slug": model.id, "display_name": model.id,
            "description": "Malibu gateway model; client compatibility unverified",
            "model_messages": ["instructions_template": "You are a coding assistant. Use the available tools to complete the user's request and verify your work."],
            "supported_reasoning_levels": [], "shell_type": "unified_exec", "visibility": "list",
            "supported_in_api": true, "priority": 1, "support_verbosity": false,
            "truncation_policy": ["mode": "tokens", "limit": min(10000, context)],
            "experimental_supported_tools": [], "input_modalities": ["text"],
            "context_window": context, "max_context_window": context,
            "upgrade": NSNull(), "apply_patch_tool_type": NSNull(),
            "supports_reasoning_summary_parameter": false, "tool_mode": "direct",
            "node_repl_disabled": true, "use_responses_lite": false
        ]]])
    }

    static func quoted(_ value: String) -> String {
        // JSON strings are valid TOML basic strings for these validated values.
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
    }
    static func shell(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func launcher(app: ConnectedApp, executable: URL, config: URL, model: ConnectedModel, keyHandoff: URL) throws -> Data {
        guard app != .cursor else { throw ConnectedAppsError.invalidConfiguration }
        var environment = ""
        var arguments = ""
        switch app {
        case .codex: environment = "export CODEX_HOME=\(shell(config.deletingLastPathComponent().path))\n"
        case .openCode:
            // Ignore a repository's opencode.json / .opencode so it cannot
            // re-point the Malibu provider and capture the key. OpenCode reads
            // OPENCODE_CONFIG_PROJECT_DISABLE ?? OPENCODE_DISABLE_PROJECT_CONFIG
            // (anomalyco/opencode packages/cli/src/server-process.ts).
            environment = "export OPENCODE_CONFIG=\(shell(config.path))\nexport OPENCODE_DISABLE_PROJECT_CONFIG=1\nexport OPENCODE_CONFIG_PROJECT_DISABLE=1\n"
        case .goose:
            environment = "export XDG_CONFIG_HOME=\(shell(config.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path))\n"
            arguments = " session start --provider malibu --model \(shell(model.id))"
        case .crush: environment = "export XDG_CONFIG_HOME=\(shell(config.deletingLastPathComponent().deletingLastPathComponent().path))\n"
        case .cursor: break
        }
        let versionGuard = app == .codex
            ? "test \"$(\(shell(executable.path)) --version)\" = 'codex-cli 0.163.0' || { echo 'This setup requires Codex CLI 0.163.0.' >&2; exit 1; }\n"
            : ""
        // Malibu's Launch writes the key to a private 0600 file in a 0700
        // directory; this reads it once and deletes it, so no other program
        // needs Keychain access and the key never appears in arguments or here.
        return Data("""
        #!/bin/sh
        set -eu
        KEY_FILE=\(shell(keyHandoff.path))
        if [ ! -f "$KEY_FILE" ] || [ -L "$KEY_FILE" ]; then echo 'Use Launch in Malibu to deliver the buyer key.' >&2; exit 1; fi
        MALIBU_API_KEY=$(cat -- "$KEY_FILE" || true)
        rm -f -- "$KEY_FILE"
        test -n "$MALIBU_API_KEY"
        export MALIBU_API_KEY
        \(versionGuard)\(environment)exec \(shell(executable.path))\(arguments)

        """.utf8)
    }
}
