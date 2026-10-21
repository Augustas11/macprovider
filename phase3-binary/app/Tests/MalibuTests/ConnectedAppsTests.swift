import Darwin
import Foundation
import XCTest
@testable import Malibu

final class ConnectedAppsTests: XCTestCase {
    private let model = ConnectedModel(id: "vendor/model", contextWindow: 32768, maxOutputTokens: nil)

    func testOpenCodePreservesUnknownKeysAndUsesCredentialReference() throws {
        let source = Data(#"{"theme":"existing","provider":{"other":{"anything":true}}}"#.utf8)
        let bytes = try ConnectedAppConfiguration.configuration(app: .openCode, model: model, original: source)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(root["theme"] as? String, "existing")
        XCTAssertEqual(root["model"] as? String, "malibu/vendor/model")
        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        XCTAssertNotNil(providers["other"])
        let malibu = try XCTUnwrap(providers["malibu"] as? [String: Any])
        let options = try XCTUnwrap(malibu["options"] as? [String: Any])
        XCTAssertEqual(options["apiKey"] as? String, "{env:MALIBU_API_KEY}")
    }

    func testOpenCodeUsesServedContextAndBoundedOutputInsteadOfClientDefault() throws {
        for (context, declaredOutput, expectedOutput) in [
            (8192, nil as Int?, 1024),
            (512, nil, 512),
            (8192, 256, 256),
            (8192, 32768, 1024)
        ] {
            let selected = ConnectedModel(id: "actual-gateway-model", contextWindow: context, maxOutputTokens: declaredOutput)
            let bytes = try ConnectedAppConfiguration.configuration(app: .openCode, model: selected, original: nil)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let providers = try XCTUnwrap(root["provider"] as? [String: Any])
            let malibu = try XCTUnwrap(providers["malibu"] as? [String: Any])
            let models = try XCTUnwrap(malibu["models"] as? [String: Any])
            let entry = try XCTUnwrap(models[selected.id] as? [String: Any])
            let limits = try XCTUnwrap(entry["limit"] as? [String: Int])
            XCTAssertEqual(limits, ["context": context, "output": expectedOutput])
        }
        let unknown = ConnectedModel(id: "class-alias", contextWindow: 0, maxOutputTokens: nil)
        XCTAssertThrowsError(try ConnectedAppConfiguration.configuration(app: .openCode, model: unknown, original: nil))
    }

    func testOpenCodeQwenSamplingIsModelScopedAndPreservesExistingAgents() throws {
        let original: [String: Any] = [
            "agent": ["build": ["prompt": "Existing prompt", "temperature": 0.2],
                      "review": ["model": "other/model", "top_p": 0.9]],
            "provider": ["other": ["models": ["model": ["options": ["temperature": 0.4]]]]],
            "permission": ["bash": "ask"]
        ]
        for id in [
            "qwen3-coder-30b-a3b-instruct", "qwen3-30b-a3b-instruct-2507",
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
        ] {
            let selected = ConnectedModel(id: id, contextWindow: 16384, maxOutputTokens: 256)
            let bytes = try ConnectedAppConfiguration.configuration(app: .openCode, model: selected,
                original: ConnectedAppConfiguration.json(original))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(root["agent"] as? NSDictionary, original["agent"] as? NSDictionary)
            XCTAssertEqual(root["permission"] as? NSDictionary, original["permission"] as? NSDictionary)
            let providers = try XCTUnwrap(root["provider"] as? [String: Any])
            let existingProviders = try XCTUnwrap(original["provider"] as? [String: Any])
            XCTAssertEqual(providers["other"] as? NSDictionary, existingProviders["other"] as? NSDictionary)
            let malibu = try XCTUnwrap(providers["malibu"] as? [String: Any])
            let models = try XCTUnwrap(malibu["models"] as? [String: Any])
            XCTAssertEqual(Set(models.keys), Set([id]))
            let entry = try XCTUnwrap(models[id] as? [String: Any])
            XCTAssertEqual(entry["temperature"] as? Bool, true)
            XCTAssertEqual(entry["options"] as? [String: Double], ["temperature": 0.7, "top_p": 0.8])
            XCTAssertEqual(entry["limit"] as? [String: Int], ["context": 16384, "output": 256])
            let options = try XCTUnwrap(malibu["options"] as? [String: String])
            XCTAssertEqual(options["apiKey"], "{env:MALIBU_API_KEY}")
            XCTAssertNil(options["temperature"])
            XCTAssertNil(options["top_p"])
            XCTAssertNil(root["tools"])
            XCTAssertNil(root["tool_choice"])
        }
    }

    func testOpenCodeSamplingDoesNotMatchUnrelatedOrNearModelNames() throws {
        for id in [
            "other/model", "qwen3-32b", "qwen/qwen3-30b-a3b-instruct-2507",
            "qwen3-coder-30b-a3b-instruct-extra", "QWEN3-CODER-30B-A3B-INSTRUCT",
            "qwen3-30b-a3b-instruct-2507-extra",
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit",
            "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit-extra"
        ] {
            let selected = ConnectedModel(id: id, contextWindow: 16384, maxOutputTokens: nil)
            let bytes = try ConnectedAppConfiguration.configuration(app: .openCode, model: selected, original: nil)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let providers = try XCTUnwrap(root["provider"] as? [String: Any])
            let malibu = try XCTUnwrap(providers["malibu"] as? [String: Any])
            let models = try XCTUnwrap(malibu["models"] as? [String: Any])
            let entry = try XCTUnwrap(models[id] as? [String: Any])
            XCTAssertNil(entry["temperature"], id)
            XCTAssertNil(entry["options"], id)
            XCTAssertNil(root["agent"], id)
        }
    }

    func testOpenCodePluginIsAppendOnlyAndPreservesCustomAgentsAndPermissions() throws {
        let plugin = URL(fileURLWithPath: "/private/managed path/malibu-qwen-system.mjs")
        let customPlugin: [Any] = ["custom-plugin", ["setting": true]]
        let original: [String: Any] = [
            "plugin": ["existing-plugin", customPlugin] as [Any],
            "agent": ["build": ["prompt": "Custom build"], "review": ["prompt": "Custom review"]],
            "permission": ["bash": "ask"], "provider": ["other": ["name": "Keep"]]
        ]
        let data = try ConnectedAppConfiguration.configuration(app: .openCode, model: model,
            original: ConnectedAppConfiguration.json(original), plugin: plugin)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let plugins = try XCTUnwrap(result["plugin"] as? [Any])
        XCTAssertEqual(Array(plugins.prefix(2)) as NSArray, original["plugin"] as? NSArray)
        XCTAssertEqual(plugins.last as? String, plugin.absoluteString)
        XCTAssertEqual(result["agent"] as? NSDictionary, original["agent"] as? NSDictionary)
        XCTAssertEqual(result["permission"] as? NSDictionary, original["permission"] as? NSDictionary)
        let existingTuple: [Any] = [plugin.absoluteString, ["keep": true]]
        let existingEntries: [[Any]] = [[plugin.absoluteString], [existingTuple]]
        for entries in existingEntries {
            let bytes = try ConnectedAppConfiguration.configuration(app: .openCode, model: model,
                original: ConnectedAppConfiguration.json(["plugin": entries]), plugin: plugin)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            XCTAssertEqual(root["plugin"] as? NSArray, entries as NSArray)
        }
        let invalidTuple: [Any] = ["custom", false]
        let invalidEntries: [Any] = [false, [12], [invalidTuple], [["custom"]]]
        for invalid in invalidEntries {
            XCTAssertThrowsError(try ConnectedAppConfiguration.configuration(app: .openCode, model: model,
                original: ConnectedAppConfiguration.json(["plugin": invalid]), plugin: plugin))
        }
        XCTAssertThrowsError(try ConnectedAppConfiguration.configuration(app: .openCode, model: model,
            original: nil, plugin: URL(string: "https://example.test/plugin.mjs")!))
    }

    @MainActor
    func testManagedOpenCodePluginHasReceiptIntegrityAndReversibleLifecycle() throws {
        try temporary { home in
            let bytes = Data("export const Fixture = async () => ({});\n".utf8)
            let store = ConnectedAppsStore(home: home, keyExists: { true }, readKey: { "test-key" },
                                           loadOpenCodePlugin: { bytes })
            store.models = [model]
            store.modelID = model.id
            store.executable = URL(fileURLWithPath: "/fake/opencode")
            store.preview()
            XCTAssertTrue(store.canSetup, store.status)
            store.setup()
            let root = home.appendingPathComponent("Library/Application Support/Malibu/ConnectedApps")
            let plugin = root.appendingPathComponent("opencode/" + ConnectedAppConfiguration.openCodePluginFilename)
            let receipts = ConnectedConfigTransaction(receiptDirectory: root.appendingPathComponent("backups"))
            XCTAssertEqual(try Data(contentsOf: plugin), bytes)
            XCTAssertEqual(try ConnectedConfigTransaction.read(plugin).mode, 0o600)
            XCTAssertEqual(try receipts.receipt(named: "opencode-plugin")?.installed, bytes)
            try store.validateOpenCodePlugin()
            store.preview()
            store.setup()
            try store.validateOpenCodePlugin()
            store.restore()
            XCTAssertNil(try receipts.receipt(named: "opencode-plugin"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.path))
            XCTAssertThrowsError(try store.validateOpenCodePlugin())
            store.preview()
            store.setup()
            try FileManager.default.removeItem(at: root.appendingPathComponent("backups/opencode-plugin.json"))
            XCTAssertEqual(try Data(contentsOf: plugin), bytes)
            XCTAssertThrowsError(try store.validateOpenCodePlugin(), "bytes without their receipt are not managed")
        }
    }

    @MainActor
    func testManagedOpenCodePluginRefusesUnownedFilesAndEditedInstalledBytes() throws {
        try temporary { home in
            let bytes = Data("managed plugin".utf8)
            let store = ConnectedAppsStore(home: home, keyExists: { true }, readKey: { "test-key" },
                                           loadOpenCodePlugin: { bytes })
            store.models = [model]
            store.modelID = model.id
            store.executable = URL(fileURLWithPath: "/fake/opencode")
            let root = home.appendingPathComponent("Library/Application Support/Malibu/ConnectedApps")
            let plugin = root.appendingPathComponent("opencode/" + ConnectedAppConfiguration.openCodePluginFilename)
            try ConnectedConfigTransaction.replace(plugin, expected: ConnectedConfigSnapshot(bytes: nil, mode: nil),
                                                   bytes: Data("unowned".utf8), mode: 0o600)
            store.preview()
            XCTAssertFalse(store.canSetup)
            XCTAssertEqual(try Data(contentsOf: plugin), Data("unowned".utf8))
            try FileManager.default.removeItem(at: plugin)
            store.preview()
            store.setup()
            try Data("later edit".utf8).write(to: plugin)
            XCTAssertThrowsError(try store.validateOpenCodePlugin())
            store.restore()
            XCTAssertEqual(try Data(contentsOf: plugin), Data("later edit".utf8))
            let receipts = ConnectedConfigTransaction(receiptDirectory: root.appendingPathComponent("backups"))
            XCTAssertNotNil(try receipts.receipt(named: "opencode-plugin"))
        }
    }

    func testAmbiguousJSONAndExistingProviderAreRefused() {
        for source in [#"{"provider":{},"provider":{}}"#, "{// comment\n}", #"{"provider":{"malibu":{}}}"#, #"{"provider":false}"#] {
            XCTAssertThrowsError(try ConnectedAppConfiguration.configuration(app: .openCode, model: model, original: Data(source.utf8)))
        }
    }

    func testArbitraryTOMLAndShellAreNeverRewritten() {
        for app in [ConnectedApp.codex, .crush] {
            XCTAssertThrowsError(try ConnectedAppConfiguration.configuration(app: app, model: model,
                original: Data("unrelated = 'keep'\n".utf8), catalog: URL(fileURLWithPath: "/catalog.json")))
        }
    }

    func testGooseUsesCompleteEndpointAndPublishedContext() throws {
        let bytes = try ConnectedAppConfiguration.configuration(app: .goose, model: model, original: nil)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(root["base_url"] as? String, "https://api.malibu.tech/v1/chat/completions")
        let models = try XCTUnwrap(root["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["context_limit"] as? Int, 32768)
    }

    func testMetadataIsNotFabricatedForUnknownContext() {
        let unknown = ConnectedModel(id: "class-alias", contextWindow: nil, maxOutputTokens: nil)
        XCTAssertThrowsError(try ConnectedAppConfiguration.codexCatalog(model: unknown))
        for app in [ConnectedApp.openCode, .goose, .crush] {
            XCTAssertThrowsError(try ConnectedAppConfiguration.configuration(app: app, model: unknown, original: nil))
        }
    }

    func testCodexCatalogUsesExactGatewayIdentityAndConservativePolicy() throws {
        let bytes = try ConnectedAppConfiguration.codexCatalog(model: model)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let entries = try XCTUnwrap(root["models"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["slug"] as? String, model.id)
        XCTAssertEqual(entry["context_window"] as? Int, model.contextWindow)
        XCTAssertEqual(entry["input_modalities"] as? [String], ["text"])
        XCTAssertEqual(entry["supports_reasoning_summary_parameter"] as? Bool, false)
        XCTAssertEqual(entry["tool_mode"] as? String, "direct")
        XCTAssertNotNil(entry["model_messages"])
        XCTAssertNil(entry["supports_tools"])
    }

    func testCodexConfigUsesResponsesAndRootCatalog() throws {
        let text = String(decoding: try ConnectedAppConfiguration.configuration(app: .codex, model: model,
            original: nil, catalog: URL(fileURLWithPath: "/private/catalog.json")), as: UTF8.self)
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertTrue(text.contains("model = \"vendor/model\""))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "model_catalog_json")?.lowerBound),
                          try XCTUnwrap(text.range(of: "[model_providers")?.lowerBound))
    }

    func testLaunchersActuallyDeliverKeyAndQuotePaths() throws {
        for app in [ConnectedApp.codex, .openCode, .goose, .crush] {
            let text = String(decoding: try ConnectedAppConfiguration.launcher(app: app,
                executable: URL(fileURLWithPath: "/fake/cli'with-space"),
                config: URL(fileURLWithPath: "/fake/config/client/config.json"), model: model,
                keyHandoff: URL(fileURLWithPath: "/fake/handoff/key")), as: UTF8.self)
            // The key arrives through a one-time handoff file, never via
            // /usr/bin/security (which would widen the Keychain ACL).
            XCTAssertFalse(text.contains("security find-generic-password"))
            XCTAssertTrue(text.contains("KEY_FILE='/fake/handoff/key'"))
            let read = try XCTUnwrap(text.range(of: "MALIBU_API_KEY=$(cat -- \"$KEY_FILE\""))
            let remove = try XCTUnwrap(text.range(of: "rm -f -- \"$KEY_FILE\""))
            let exec = try XCTUnwrap(text.range(of: "exec '/fake/cli"))
            XCTAssertLessThan(read.lowerBound, remove.lowerBound)
            XCTAssertLessThan(remove.lowerBound, exec.lowerBound, "the handoff is deleted before the client runs")
            XCTAssertTrue(text.contains("export MALIBU_API_KEY"))
            XCTAssertTrue(text.contains("exec '/fake/cli'\\''with-space'"))
            XCTAssertFalse(text.contains("FAKE_BUYER_KEY"))
            if app == .codex { XCTAssertTrue(text.contains("codex-cli 0.163.0")) }
        }
    }

    func testOpenCodeLauncherIgnoresRepositoryConfiguration() throws {
        let text = String(decoding: try ConnectedAppConfiguration.launcher(app: .openCode,
            executable: URL(fileURLWithPath: "/fake/opencode"),
            config: URL(fileURLWithPath: "/fake/opencode.json"), model: model,
            keyHandoff: URL(fileURLWithPath: "/fake/handoff/key")), as: UTF8.self)
        XCTAssertTrue(text.contains("export OPENCODE_DISABLE_PROJECT_CONFIG=1\n"))
        XCTAssertTrue(text.contains("export OPENCODE_CONFIG_PROJECT_DISABLE=1\n"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "OPENCODE_DISABLE_PROJECT_CONFIG")).lowerBound,
                          try XCTUnwrap(text.range(of: "exec ")).lowerBound)
    }

    func testOpenCodeQwenLauncherRequiresPinnedClientAfterDeletingKeyHandoff() throws {
        for id in [
            "qwen3-coder-30b-a3b-instruct", "qwen3-30b-a3b-instruct-2507",
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
        ] {
            let selected = ConnectedModel(id: id, contextWindow: 16384, maxOutputTokens: nil)
            let text = String(decoding: try ConnectedAppConfiguration.launcher(app: .openCode,
                executable: URL(fileURLWithPath: "/fake/open'code"),
                config: URL(fileURLWithPath: "/fake/opencode.json"), model: selected,
                keyHandoff: URL(fileURLWithPath: "/fake/handoff/key")), as: UTF8.self)
            let remove = try XCTUnwrap(text.range(of: "rm -f -- \"$KEY_FILE\""))
            let version = try XCTUnwrap(text.range(of: "test \"$('/fake/open"))
            XCTAssertTrue(text.contains("test \"$('/fake/open'\\''code' --version)\" = '1.17.9' || { echo 'This Qwen managed profile requires OpenCode 1.17.9.' >&2; exit 1; }"))
            XCTAssertLessThan(remove.lowerBound, version.lowerBound)
            XCTAssertLessThan(version.lowerBound, try XCTUnwrap(text.range(of: "exec ")).lowerBound)
        }
    }

    func testOpenCodeVersionGuardDoesNotApplyToOtherModelsOrClients() throws {
        for id in [
            "other/model", "qwen/qwen3-30b-a3b-instruct-2507",
            "qwen3-coder-30b-a3b-instruct-extra", "QWEN3-CODER-30B-A3B-INSTRUCT",
            "qwen3-30b-a3b-instruct-2507-extra",
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit",
            "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit-extra"
        ] {
            let text = String(decoding: try ConnectedAppConfiguration.launcher(app: .openCode,
                executable: URL(fileURLWithPath: "/fake/opencode"),
                config: URL(fileURLWithPath: "/fake/opencode.json"),
                model: ConnectedModel(id: id, contextWindow: 16384, maxOutputTokens: nil),
                keyHandoff: URL(fileURLWithPath: "/fake/key")), as: UTF8.self)
            XCTAssertFalse(text.contains("--version"), id)
            XCTAssertFalse(text.contains("1.17.9"), id)
        }
        let qwen = ConnectedModel(id: "qwen3-coder-30b-a3b-instruct", contextWindow: 16384, maxOutputTokens: nil)
        for app in [ConnectedApp.codex, .goose, .crush] {
            let text = String(decoding: try ConnectedAppConfiguration.launcher(app: app,
                executable: URL(fileURLWithPath: "/fake/client"), config: URL(fileURLWithPath: "/fake/config"),
                model: qwen, keyHandoff: URL(fileURLWithPath: "/fake/key")), as: UTF8.self)
            XCTAssertFalse(text.contains("1.17.9"))
            XCTAssertEqual(text.contains("codex-cli 0.163.0"), app == .codex)
        }
    }

    func testOpenCodeGuidanceNamesManagedScopeWithoutClaimingProductionVerification() {
        let text = ConnectedAppConfiguration.openCodeToolDisclosure
        XCTAssertTrue(text.contains("Qwen3 Coder 30B A3B Instruct and Qwen3 30B A3B Instruct 2507"))
        XCTAssertTrue(text.contains("OpenCode 1.17.9 and Malibu's managed profile"))
        XCTAssertTrue(text.contains("Custom agent prompts are preserved."))
        XCTAssertTrue(text.contains("actual tool activity"))
        XCTAssertTrue(text.contains("do not verify production gateway tool use"))
        XCTAssertFalse(text.contains("both answered without calling"))
        XCTAssertFalse(text.contains("not yet verified"))
    }

    func testKeyExposureCopyIsHonestAndCrushIsWarned() {
        // SPEC-025-R012: one visible sentence names repository configuration and
        // agent commands and recommends a dedicated, spend-limited key.
        let sentence = ConnectedAppConfiguration.keyExposure
        XCTAssertTrue(sentence.contains("dedicated, spend-limited buyer key"))
        XCTAssertTrue(sentence.contains("repository configuration"))
        XCTAssertTrue(sentence.contains("commands its agent runs can read it"))
        XCTAssertEqual(sentence.filter { $0 == "." }.count, 1, "one sentence")
        // The rest sits behind Details.
        let details = ConnectedAppConfiguration.setupDetails
        XCTAssertTrue(details.contains("private one-time file"))
        XCTAssertTrue(details.contains("send it elsewhere"))
        XCTAssertTrue(details.contains("Project settings or managed policy can override the profile"))
        XCTAssertTrue(details.contains("Desktop apps are not set up."))
        XCTAssertTrue(ConnectedAppConfiguration.crushProjectConfigWarning.contains(".crushrc"))
    }

    func testNotPrivateBannerSaysPrivateModeDoesNotApplyAndPointsToMalibuChat() {
        let banner = ConnectedAppConfiguration.privacy
        XCTAssertTrue(banner.hasPrefix("Not private"))
        XCTAssertTrue(banner.contains("requests that Malibu does not encrypt"))
        XCTAssertTrue(banner.contains("private mode doesn't apply"))
        XCTAssertTrue(banner.contains("gateway and the serving provider can read prompts and responses"))
        XCTAssertTrue(banner.contains("For private requests, use Malibu Chat."))
        for overclaim in ["end-to-end", "confidential", "enclave", "relay-blind"] {
            XCTAssertFalse(banner.lowercased().contains(overclaim))
        }
    }

    @MainActor
    func testGatewayModelsNeedASavedKeyAndLoadAfterSaving() async throws {
        var keyStored = false
        var loads = 0
        var served: [ConnectedModel] = []
        let store = ConnectedAppsStore(
            home: FileManager.default.temporaryDirectory.appendingPathComponent("connected-\(UUID().uuidString)"),
            keyExists: { keyStored },
            loadGatewayModels: { _ in loads += 1; return served },
            readKey: { guard keyStored else { throw ConnectedAppsError.credential }; return "buyer-key" },
            saveKey: { _ in keyStored = true }
        )
        XCTAssertFalse(store.hasBuyerKey)
        store.loadModels()
        XCTAssertEqual(loads, 0, "no gateway call without a saved key")
        XCTAssertEqual(store.modelsMessage, ConnectedAppsStore.saveKeyFirst)

        // Saving a key loads the list; an empty list says so beside the button.
        store.saveKey("buyer-key")
        await store.waitForOperation()
        XCTAssertTrue(store.hasBuyerKey)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(store.modelsMessage, "No models are being served right now. Try again later.")
        XCTAssertTrue(store.modelsLoadFailed)

        served = [model]
        store.loadModels()
        await store.waitForOperation()
        XCTAssertEqual(store.models, [model])
        XCTAssertEqual(store.modelID, model.id)
        XCTAssertEqual(store.modelsMessage, "1 model available.")
        XCTAssertFalse(store.modelsLoadFailed)
    }

    @MainActor
    func testGatewayModelLoadErrorsShowBesideTheButton() async throws {
        let store = ConnectedAppsStore(
            home: FileManager.default.temporaryDirectory.appendingPathComponent("connected-\(UUID().uuidString)"),
            keyExists: { true },
            loadGatewayModels: { _ in throw ConnectedAppsError.http(401) },
            readKey: { "buyer-key" },
            saveKey: { _ in }
        )
        store.loadModels()
        await store.waitForOperation()
        XCTAssertTrue(store.modelsLoadFailed)
        XCTAssertEqual(store.modelsMessage, "The gateway rejected this buyer key.")
        XCTAssertTrue(store.models.isEmpty)
    }

    func testLaunchHandoffIsPrivateAndReplaceable() throws {
        try temporary { root in
            let file = root.appendingPathComponent("handoff/opencode.key")
            try ConnectedBuyerKeychain.writeLaunchHandoff("first", to: file)
            try ConnectedBuyerKeychain.writeLaunchHandoff("second", to: file)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
            let fileMode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
            let dirMode = (try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(fileMode, 0o600)
            XCTAssertEqual(dirMode, 0o700)
            ConnectedBuyerKeychain.removeLaunchHandoff(file)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testCursorHasNoWriterAndDisclosesTransit() {
        XCTAssertThrowsError(try ConnectedAppConfiguration.configuration(app: .cursor, model: model, original: nil))
        XCTAssertTrue(ConnectedAppConfiguration.privacy.contains("Not private"))
        XCTAssertTrue(ConnectedAppConfiguration.cursorDisclosure.contains("Cursor's servers"))
    }

    func testSelectedAPITestBodiesAreBounded() {
        let responses = ConnectedGatewayClient.testBody(api: .responses, model: model.id)
        XCTAssertEqual(responses["model"] as? String, model.id)
        XCTAssertEqual(responses["max_output_tokens"] as? Int, 16)
        XCTAssertEqual(responses["store"] as? Bool, false)
        XCTAssertNil(responses["messages"])
        let chat = ConnectedGatewayClient.testBody(api: .chatCompletions, model: model.id)
        XCTAssertEqual(chat["max_tokens"] as? Int, 16)
        XCTAssertNotNil(chat["messages"])
    }

    func testModelsRequireRealMetadataAndDoNotInferAliasCapabilities() throws {
        let data = Data(#"{"data":[{"id":"class-alias","max_context_tokens":0},{"id":"actual","max_context_tokens":8192},{"id":"actual"}]}"#.utf8)
        let models = try ConnectedGatewayClient.decodeModels(data)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.first?.contextWindow, 8192)
        XCTAssertNil(models.last?.contextWindow)
        XCTAssertNil(models.first?.maxOutputTokens)
    }

    func testSuccessfulModelsListCannotMasqueradeAsInference() {
        let data = Data(#"{"data":[{"id":"actual"}]}"#.utf8)
        for api in [ConnectedAPI.responses, .chatCompletions] {
            XCTAssertThrowsError(try ConnectedGatewayClient.validateCompletion(data, api: api))
        }
        XCTAssertThrowsError(try ConnectedGatewayClient.validateCompletion(Data(#"{"status":"incomplete","output":[]}"#.utf8), api: .responses))
    }

    func testChatCompletionRequiresStoppedNonemptyAnswer() {
        for fixture in [
            #"{"choices":[{"message":{"content":"OK"}}]}"#,
            #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#,
            #"{"choices":[{"finish_reason":"stop","message":{"content":""}}]}"#,
            #"{"choices":[{"finish_reason":"stop","message":{"content":"   "}}]}"#
        ] {
            XCTAssertThrowsError(try ConnectedGatewayClient.validateCompletion(Data(fixture.utf8), api: .chatCompletions))
        }
    }

    func testInferenceCompletionAndRedactedFailureClasses() throws {
        try ConnectedGatewayClient.validateCompletion(Data(#"{"status":"completed","output":[{"content":[{"type":"output_text","text":"OK"}]}]}"#.utf8), api: .responses)
        try ConnectedGatewayClient.validateCompletion(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"OK"}}]}"#.utf8), api: .chatCompletions)
        XCTAssertNotEqual(ConnectedAppsError.http(401).localizedDescription, ConnectedAppsError.http(429).localizedDescription)
        XCTAssertFalse(ConnectedAppsError.http(500).localizedDescription.contains("500"))
    }

    func testTransactionPreservesExactBytesAndTightensRestorePermissions() throws {
        try temporary { root in
            let target = root.appendingPathComponent("config.json")
            let original = Data("{\r\n  \"unrelated\": true\r\n}\r\n".utf8)
            try original.write(to: target)
            XCTAssertEqual(chmod(target.path, 0o644), 0)
            let tx = ConnectedConfigTransaction(receiptDirectory: root.appendingPathComponent("backups"))
            let preview = try tx.preview(target: target, proposed: Data("new".utf8))
            try tx.apply(preview, named: "test")
            XCTAssertEqual(try tx.receipt(named: "test")?.original.bytes, original)
            XCTAssertEqual(try ConnectedConfigTransaction.read(target).mode, 0o600)
            // Repeated setup does not replace the original backup.
            try tx.apply(try tx.preview(target: target, proposed: Data("new".utf8)), named: "test")
            try tx.restore(named: "test")
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(try ConnectedConfigTransaction.read(target).mode, 0o644, "restore keeps the original's mode")
            XCTAssertNil(try tx.receipt(named: "test"))
            XCTAssertEqual(ConnectedConfigTransaction.restoredMode(0o664), 0o644)
            XCTAssertEqual(ConnectedConfigTransaction.restoredMode(0o4755), 0o755)
            XCTAssertEqual(ConnectedConfigTransaction.restoredMode(nil), 0o600)
        }
    }

    func testAbsentFileRestoreAndBackupPermissions() throws {
        try temporary { root in
            let target = root.appendingPathComponent("new/config")
            let backups = root.appendingPathComponent("backups")
            let tx = ConnectedConfigTransaction(receiptDirectory: backups)
            try tx.apply(try tx.preview(target: target, proposed: Data("new".utf8)), named: "test")
            let attributes = try FileManager.default.attributesOfItem(atPath: backups.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(try ConnectedConfigTransaction.read(backups.appendingPathComponent("test.json")).mode, 0o600)
            try tx.restore(named: "test")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testConcurrentEditBeforeSetupAndRestoreIsPreserved() throws {
        try temporary { root in
            let target = root.appendingPathComponent("config")
            let tx = ConnectedConfigTransaction(receiptDirectory: root.appendingPathComponent("backups"))
            let preview = try tx.preview(target: target, proposed: Data("managed".utf8))
            try Data("concurrent".utf8).write(to: target)
            XCTAssertThrowsError(try tx.apply(preview, named: "test"))
            XCTAssertEqual(try Data(contentsOf: target), Data("concurrent".utf8))
            XCTAssertThrowsError(try tx.restore(named: "test"))
            XCTAssertEqual(try Data(contentsOf: target), Data("concurrent".utf8))
        }
    }

    func testRestoreRefusesNewerEditsAfterSuccessfulSetup() throws {
        try temporary { root in
            let target = root.appendingPathComponent("config")
            let tx = ConnectedConfigTransaction(receiptDirectory: root.appendingPathComponent("backups"))
            try tx.apply(try tx.preview(target: target, proposed: Data("managed".utf8)), named: "test")
            try Data("later edit".utf8).write(to: target)
            XCTAssertThrowsError(try tx.restore(named: "test"))
            XCTAssertEqual(try Data(contentsOf: target), Data("later edit".utf8))
        }
    }

    func testRetainedRecoveryTightensPermissionsWithoutChangingBytesOrOriginal() throws {
        try temporary { root in
            let original = root.appendingPathComponent("config")
            let recovery = root.appendingPathComponent(".malibu-recovery-test")
            let bytes = Data("newer concurrent config bytes".utf8)
            try bytes.write(to: recovery)
            try Data("restored original".utf8).write(to: original)
            XCTAssertEqual(chmod(root.path, 0o755), 0)
            XCTAssertEqual(chmod(original.path, 0o644), 0)
            XCTAssertEqual(chmod(recovery.path, 0o644), 0)
            let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(parent, 0)
            defer { close(parent) }
            try ConnectedConfigTransaction.protectRetainedRecovery(parent: parent, name: recovery.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: recovery), bytes)
            XCTAssertEqual(try ConnectedConfigTransaction.read(recovery).mode, 0o600)
            XCTAssertEqual(try ConnectedConfigTransaction.read(original).mode, 0o644)
        }
    }

    func testRetainedRecoveryRejectsSymlinksAndHardlinksWithoutChmodTarget() throws {
        try temporary { root in
            let original = root.appendingPathComponent("config")
            let symlink = root.appendingPathComponent(".malibu-recovery-symlink")
            let hardlink = root.appendingPathComponent(".malibu-recovery-hardlink")
            try Data("unchanged".utf8).write(to: original)
            XCTAssertEqual(chmod(original.path, 0o644), 0)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
            try FileManager.default.linkItem(at: original, to: hardlink)
            let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(parent, 0)
            defer { close(parent) }
            for recovery in [symlink, hardlink] {
                XCTAssertThrowsError(try ConnectedConfigTransaction.protectRetainedRecovery(parent: parent, name: recovery.lastPathComponent))
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: original.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
            XCTAssertEqual(try Data(contentsOf: original), Data("unchanged".utf8))
        }
    }

    func testNoFollowLeafAndAncestorAndReadLimit() throws {
        try temporary { root in
            let real = root.appendingPathComponent("real")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let target = real.appendingPathComponent("config")
            try Data("untouched".utf8).write(to: target)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            XCTAssertThrowsError(try ConnectedConfigTransaction.read(link.appendingPathComponent("config")))
            let leaf = root.appendingPathComponent("leaf")
            try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
            XCTAssertThrowsError(try ConnectedConfigTransaction.read(leaf))
            try Data(repeating: 0, count: ConnectedConfigTransaction.maximumBytes + 1).write(to: target)
            XCTAssertThrowsError(try ConnectedConfigTransaction.read(target))
        }
    }

    func testRedirectNeverForwardsCredentialRequest() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://api.malibu.tech/v1/models")!
        let task = session.dataTask(with: original)
        let redirect = try XCTUnwrap(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        var request = URLRequest(url: URL(string: "https://unrelated.example/receive")!)
        request.setValue("Bearer FAKE_TEST_KEY", forHTTPHeaderField: "Authorization")
        var called = false
        ConnectedRedirectBlocker().urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: request) { allowed in
            called = true
            XCTAssertNil(allowed)
        }
        XCTAssertTrue(called)
    }

    func testOversizedAndDuplicateGatewayResponsesAreRejected() {
        XCTAssertThrowsError(try ConnectedGatewayClient.decodeModels(Data(repeating: 32, count: ConnectedGatewayClient.maximumResponseBytes + 1)))
        XCTAssertThrowsError(try ConnectedGatewayClient.decodeModels(Data(#"{"data":[],"data":[]}"#.utf8)))
    }

    private func temporary(_ body: (URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("connected-apps-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Foundation resolvingSymlinksInPath normalizes /private/var back to
        // /var on macOS. POSIX realpath retains the actual ancestor path needed
        // by the production descriptor walk, which must still reject symlinks.
        let resolved = try XCTUnwrap(realpath(temporary.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        try body(root)
    }
}
