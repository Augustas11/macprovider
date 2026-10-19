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
        for app in [ConnectedApp.goose, .crush] {
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
                config: URL(fileURLWithPath: "/fake/config/client/config.json"), model: model), as: UTF8.self)
            XCTAssertTrue(text.contains("security find-generic-password -s tech.malibu.connected-apps -a buyer -w"))
            XCTAssertTrue(text.contains("export MALIBU_API_KEY"))
            XCTAssertTrue(text.contains("exec '/fake/cli'\\''with-space'"))
            XCTAssertFalse(text.contains("FAKE_BUYER_KEY"))
            if app == .codex { XCTAssertTrue(text.contains("codex-cli 0.163.0")) }
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
            XCTAssertEqual(try ConnectedConfigTransaction.read(target).mode, 0o600)
            XCTAssertNil(try tx.receipt(named: "test"))
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
