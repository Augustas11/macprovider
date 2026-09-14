import ArgumentParser
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// Two explicit qualification phases, with signed fixture bytes and journal
/// custody retained between CLI export, actual app caller capture, and replay.
final class ModelCatalogReadBridgeTests: XCTestCase {
    private static let model = "mlx-community/Test-Model-4bit"
    private static let key = "test-model"
    private struct Request: Codable {
        let root: String
        let arguments: [String]
        let port: Int
        let slowHash: Bool
        let failPreparationCleanup: Bool
    }
    private struct Action {
        let id: String
        let generation: String
        let kind: String
    }
    private var qualification: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".omx/qualification/catalog-read")
    }

    func testExportPersistentSignedFixtureForActualAppCaller() async throws {
        guard ProcessInfo.processInfo.environment["BUILD1_CATALOG_BRIDGE_PHASE"] == "export" else { return }
        try FileManager.default.createDirectory(at: qualification, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("b1cr-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Intentionally retained for the app and replay phases. No signing key
        // is persisted; Build1CommandFixtureInputs retains public signed bytes.
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/macprovider/config.yaml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("download-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: source.appendingPathComponent("weights.safetensors"))
        try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: source.appendingPathComponent("config.json"))
        let hash = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
        _ = try Build1CommandFixtureInputs(directory: root.appendingPathComponent("signed-inputs"),
            catalogKey: Self.key, modelID: Self.model, artifactSHA256: hash)
        _ = try Build1FixtureProvider.compile(in: root.appendingPathComponent("provider"))
        let port = try Build1FixtureProvider.unusedPort()
        let configBytes = Data("""
        model: incumbent
        supported_models:
          - incumbent
          - \(Self.key)
        model_artifact_root: \(root.appendingPathComponent("models").path)
        credential_store: protected_file
        ctl_socket_path: \(root.appendingPathComponent("ctl.sock").path)
        """.utf8)
        try configBytes.write(to: config)
        XCTAssertEqual(chmod(config.path, 0o600), 0)
        let quickArgs = readArguments(mode: "quick", config: config)
        let clean = try await runCommand(quickArgs, root: root, port: port)
        let cleanObject = try object(clean)
        let context = try contextDigest(cleanObject)
        let prepare = try action(cleanObject, field: "prepare")
        let prepared = try await runCommand(ownerArguments("prepare", action: prepare, config: config), root: root, port: port)
        XCTAssertEqual(try lines(prepared).last?["state"] as? String, "succeeded")
        let quick = try await runCommand(quickArgs, root: root, port: port)
        XCTAssertEqual(try verificationState(object(quick)), "unverified")
        let verifyArgs = readArguments(mode: "verify", config: config, context: context)
        let started = Date()
        let verifiedStream = try await runCommand(verifyArgs, root: root, port: port, slowHash: true)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 20)
        let events = try lines(verifiedStream)
        XCTAssertEqual(events.first?["kind"] as? String, "accepted")
        XCTAssertGreaterThanOrEqual(events.filter { $0["kind"] as? String == "progress" }.count, 4)
        let verified = try XCTUnwrap(events.last?["projection"] as? [String: Any])
        XCTAssertEqual(events.last?["kind"] as? String, "completed")
        XCTAssertEqual(try verificationState(verified), "verified")
        let evaluate = try action(verified, field: "evaluate")
        let evaluated = try await runCommand(ownerArguments("recommend-prepared", action: evaluate, config: config), root: root, port: port)
        XCTAssertEqual(try lines(evaluated).last?["state"] as? String, "succeeded")
        let resultArgs = resultArguments(action: evaluate, config: config, context: context)
        let recommendation = try await runCommand(resultArgs, root: root, port: port)
        XCTAssertEqual(try object(recommendation)["recommended_model"] as? String, Self.key)
        let finalQuick = try await runCommand(quickArgs, root: root, port: port)
        XCTAssertEqual(try verificationState(object(finalQuick)), "unverified")
        // Repeat the exact post-evaluation verification path. Its result is the
        // fresh projection; no immediate quick replacement discards readiness.
        let afterEvaluation = try await runCommand(verifyArgs, root: root, port: port, slowHash: true)
        let finalVerified = try XCTUnwrap(lines(afterEvaluation).last?["projection"] as? [String: Any])
        XCTAssertEqual(try verificationState(finalVerified), "verified")
        XCTAssertEqual(try Data(contentsOf: config), configBytes)
        let manifest: [String: Any] = [
            "schema": "malibu_catalog_read_input_fixture.v1", "fixture_root": root.path,
            "home": home.path, "home_directory": home.path, "config_path": config.path,
            "target_model_id": Self.model, "model_key": Self.key, "context_sha256": context,
            "transaction_id": evaluate.id, "operation_generation": evaluate.generation,
            "prepare_transaction_id": prepare.id, "prepare_operation_generation": prepare.generation,
            "fixture_port": port, "prepare_verify_elapsed_seconds": elapsed,
            "clean_install_projection": String(decoding: clean, as: UTF8.self),
            "quick_projection": String(decoding: finalQuick, as: UTF8.self),
            "verified_projection": try jsonString(finalVerified),
            "recommendation_json": String(decoding: recommendation, as: UTF8.self),
            "prepare_terminal_jsonl": String(decoding: prepared, as: UTF8.self),
            "evaluate_terminal_jsonl": String(decoding: evaluated, as: UTF8.self),
            "prepare_verify_events_jsonl": String(decoding: verifiedStream, as: UTF8.self),
            "evaluate_verify_events_jsonl": String(decoding: afterEvaluation, as: UTF8.self)
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
            .write(to: qualification.appendingPathComponent("input.json"), options: .atomic)
        // Persist command evidence separately from the app's future exact arrays.
        try Data(verifiedStream).write(to: qualification.appendingPathComponent("prepare-verify-events.jsonl"))
        try Data(afterEvaluation).write(to: qualification.appendingPathComponent("evaluate-verify-events.jsonl"))
    }

    func testReplayUnchangedActualAppCallerArguments() async throws {
        guard ProcessInfo.processInfo.environment["BUILD1_CATALOG_BRIDGE_PHASE"] == "replay" else { return }
        let input = try object(Data(contentsOf: qualification.appendingPathComponent("input.json")))
        let capturedBytes = try Data(contentsOf: qualification.appendingPathComponent("app-argv.json"))
        let captured = try object(capturedBytes)
        XCTAssertEqual(captured["schema"] as? String, "malibu_catalog_read_argv_fixture.v1")
        for key in ["config_path", "target_model_id", "model_key", "context_sha256", "transaction_id", "operation_generation"] {
            XCTAssertEqual(captured[key] as? String, input[key] as? String, key)
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(input["fixture_root"] as? String))
        let port = try XCTUnwrap(input["fixture_port"] as? Int)
        var replay: [String: Any] = ["schema": "malibu_catalog_read_replay_fixture.v1"]
        let quickArguments = try XCTUnwrap(captured["quick"] as? [String])
        try await exerciseFreshFixtureRoot(arguments: quickArguments, input: input, root: root, port: port, evidence: &replay)
        try await exerciseMissingTargetAndCleanup(arguments: quickArguments, input: input, root: root, port: port, evidence: &replay)
        for mode in ["quick", "verify", "result"] {
            let arguments = try XCTUnwrap(captured[mode] as? [String])
            // Pass the exact array through serialization and parseAsRoot. No
            // reconstruction, filtering, substitution, or appended flags.
            let output = try await runCommand(arguments, root: root, port: port)
            replay[mode] = String(decoding: output, as: UTF8.self)
            if mode == "quick" {
                XCTAssertEqual(try verificationState(object(output)), "unverified")
                XCTAssertEqual(try contextDigest(object(output)), input["context_sha256"] as? String)
            } else if mode == "verify" {
                let events = try lines(output)
                XCTAssertEqual(events.last?["kind"] as? String, "completed")
                let projection = try XCTUnwrap(events.last?["projection"] as? [String: Any])
                XCTAssertEqual(try verificationState(projection), "verified")
                XCTAssertEqual(try contextDigest(projection), input["context_sha256"] as? String)
            } else {
                XCTAssertEqual(try object(output)["recommended_model"] as? String, Self.key)
                XCTAssertEqual(output, Data(try XCTUnwrap(input["recommendation_json"] as? String).utf8))
            }
        }
        XCTAssertEqual(try Data(contentsOf: qualification.appendingPathComponent("app-argv.json")), capturedBytes)
        try JSONSerialization.data(withJSONObject: replay, options: [.sortedKeys, .withoutEscapingSlashes])
            .write(to: qualification.appendingPathComponent("cli-replay.json"), options: .atomic)
    }

    func testCatalogReadBridgeSubprocessEntry() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let requestURL = root.appendingPathComponent("catalog-read-request.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else { return }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
        guard request.root == root.path else { _exit(91) }
        let output = open(root.appendingPathComponent("catalog-read-output.jsonl").path,
                          O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard output >= 0, dup2(output, STDOUT_FILENO) >= 0 else { _exit(92) }
        close(output)
        do {
            var context = try Build1CommandBootstrapTests.fixtureContext(root: root, port: request.port,
                preparing: request.arguments.contains("prepare"), catalogKey: Self.key)
            if request.failPreparationCleanup {
                let configure = context.configureTransactionRunner
                context.configureTransactionRunner = { runner in
                    configure(&runner)
                    runner.boundary = { if $0 == "hash_chunk" { throw POSIXError(.EIO) } }
                    runner.cleanupOwned = { _, _ in throw POSIXError(.EACCES) }
                }
            }
            if request.slowHash {
                var delayed = false
                context.catalogReadHashProgress = { delta in
                    if delta > 0, !delayed { delayed = true; usleep(21_000_000) }
                }
            }
            // Test-only installation of actual native descriptors. The shipping
            // CLI validates their exact inode/mode/open-description and direction.
            let lifetime = try installReadDescriptors(home: root.appendingPathComponent("home"))
            defer { close(lifetime); close(199); close(200) }
            let parsed = try MacProviderCLI.parseAsRoot(request.arguments)
            switch parsed {
            case let command as ModelsCatalogEconomicsCommand: try await command.run(context: context)
            case let command as ModelsPrepareCommand: try await command.run(context: context)
            case let command as ModelsRecommendPreparedCommand: try await command.run(context: context)
            case let command as ModelsTransactionResultCommand: try await command.run(context: context)
            default: throw ModelCatalogInspectionError.invalid
            }
            fflush(stdout); _exit(0)
        } catch {
            fflush(stdout)
            FileHandle.standardError.write(Data("catalog fixture command failed: \(error)\n".utf8))
            _exit(2)
        }
    }

    private func installReadDescriptors(home: URL) throws -> Int32 {
        let folder = home.appendingPathComponent("Library/Application Support/Malibu/ModelTransactions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = open(folder.appendingPathComponent("catalog-read.lock").path,
                        O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ModelCatalogInspectionError.incomplete }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0, dup2(lock, 199) == 199 else { throw ModelCatalogInspectionError.incomplete }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw ModelCatalogInspectionError.incomplete }
        guard dup2(descriptors[0], 200) == 200 else {
            close(descriptors[0]); close(descriptors[1]); throw ModelCatalogInspectionError.incomplete
        }
        close(descriptors[0])
        return descriptors[1]
    }

    private func runCommand(_ arguments: [String], root: URL, port: Int, slowHash: Bool = false,
                            failPreparationCleanup: Bool = false, expectedExit: Int32 = 0) async throws -> Data {
        try JSONEncoder().encode(Request(root: root.path, arguments: arguments, port: port, slowHash: slowHash,
                                        failPreparationCleanup: failPreparationCleanup))
            .write(to: root.appendingPathComponent("catalog-read-request.json"), options: .atomic)
        let stderrURL = root.appendingPathComponent("catalog-read-stderr.log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "macprovider_cliTests.ModelCatalogReadBridgeTests/testCatalogReadBridgeSubprocessEntry", Bundle(for: Self.self).bundlePath]
        child.currentDirectoryURL = root
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path, "TMPDIR": root.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = stderr
        try child.run()
        let deadline = Date().addingTimeInterval(75)
        while child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if child.isRunning {
            child.terminate()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            throw NSError(domain: "ModelCatalogReadBridge", code: Int(ETIMEDOUT))
        }
        child.waitUntilExit()
        if arguments.contains("recommend-prepared") {
            let pidURL = root.appendingPathComponent("provider/fixture.pid")
            if let text = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(text), pid > 1 {
                let goneDeadline = Date().addingTimeInterval(2)
                while kill(pid, 0) == 0 && Date() < goneDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
                XCTAssertNotEqual(kill(pid, 0), 0, "Exact fixture candidate survived command exit")
            }
            XCTAssertFalse(MacProviderPortProbe.isOpen(port), "Fixture candidate listener survived command exit")
        }
        guard child.terminationStatus == expectedExit else {
            throw NSError(domain: "ModelCatalogReadBridge", code: Int(child.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: try String(contentsOf: stderrURL, encoding: .utf8)])
        }
        return try Data(contentsOf: root.appendingPathComponent("catalog-read-output.jsonl"))
    }
    private func exerciseFreshFixtureRoot(arguments: [String], input: [String: Any], root: URL, port: Int,
                                          evidence: inout [String: Any]) async throws {
        guard root.lastPathComponent.hasPrefix("b1cr-"), root.path == root.resolvingSymlinksInPath().path else {
            throw ModelCatalogInspectionError.invalid
        }
        let models = root.appendingPathComponent("models")
        let backup = root.appendingPathComponent("catalog-original-models-" + UUID().uuidString)
        let config = URL(fileURLWithPath: try XCTUnwrap(input["config_path"] as? String))
        let originalConfig = try Data(contentsOf: config)
        // The complete dormant fixture durable root and its journal are held
        // aside. This is the actual clean-install case, not an absent target
        // underneath a preexisting transaction history.
        try FileManager.default.moveItem(at: models, to: backup)
        defer {
            do {
                if FileManager.default.fileExists(atPath: models.path) { try FileManager.default.removeItem(at: models) }
                try FileManager.default.moveItem(at: backup, to: models)
            } catch { XCTFail("Failed to restore original fixture root: \(error)") }
        }
        let bytes = try await runCommand(arguments, root: root, port: port)
        let projection = try object(bytes)
        XCTAssertEqual(try verificationState(projection), "missing")
        XCTAssertNotEqual(try contextDigest(projection), input["context_sha256"] as? String)
        let freshPrepare = try action(projection, field: "prepare")
        XCTAssertNotEqual(freshPrepare.id, input["prepare_transaction_id"] as? String)
        XCTAssertEqual((projection["recoveries"] as? [[String: Any]])?.count, 0)
        let configValue = try ConfigLoader.load(cli: CLIOverrides(configPath: config.path), environment: [:])
        let freshStore = ModelCatalogTransactionStore.forConfig(configValue)
        let oldID = try XCTUnwrap(input["transaction_id"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshStore.root.appendingPathComponent(oldID + ".json").path))
        XCTAssertEqual(try Data(contentsOf: config), originalConfig)
        evidence["clean_install_quick"] = String(decoding: bytes, as: UTF8.self)
        evidence["clean_install_context_is_new"] = true
    }

    private func exerciseMissingTargetAndCleanup(arguments: [String], input: [String: Any], root: URL, port: Int,
                                                evidence: inout [String: Any]) async throws {
        let configURL = URL(fileURLWithPath: try XCTUnwrap(input["config_path"] as? String))
        let configBytes = try Data(contentsOf: configURL)
        let config = try ConfigLoader.load(cli: CLIOverrides(configPath: configURL.path), environment: [:])
        guard config.modelArtifactRoot == root.appendingPathComponent("models").path else { throw ModelCatalogInspectionError.invalid }
        let signed = try Build1CommandFixtureInputs(existingDirectory: root.appendingPathComponent("signed-inputs"), catalogKey: Self.key)
        let inputs = await signed.loader().loadRecommendationInputs()
        let authority = try ModelCatalogTransactionAuthority.resolve(target: Self.key, inputs: inputs)
        let artifact = try DurableModelArtifactStore(root: root.appendingPathComponent("models")).artifactURL(
            modelID: Self.model, revision: XCTUnwrap(authority.row.modelRevision), sha256: XCTUnwrap(authority.row.modelSHA256))
        let backup = root.appendingPathComponent("catalog-original-artifact-" + UUID().uuidString)
        try FileManager.default.moveItem(at: artifact, to: backup)
        defer {
            do { try FileManager.default.moveItem(at: backup, to: artifact) }
            catch { XCTFail("Failed to restore exact fixture artifact: \(error)") }
        }
        let missingBytes = try await runCommand(arguments, root: root, port: port)
        let missing = try object(missingBytes)
        XCTAssertEqual(try verificationState(missing), "missing")
        XCTAssertEqual(try contextDigest(missing), input["context_sha256"] as? String)
        let prepare = try action(missing, field: "prepare")
        let terminal = try await runCommand(ownerArguments("prepare", action: prepare, config: configURL),
            root: root, port: port, failPreparationCleanup: true, expectedExit: 2)
        XCTAssertEqual(try lines(terminal).last?["state"] as? String, "failed")
        XCTAssertEqual(try lines(terminal).last?["warning_code"] as? String, "staging_cleanup_required")
        let store = ModelCatalogTransactionStore.forConfig(config)
        let staged = try store.stagingURL(prepare.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        let recoveryBytes = try await runCommand(arguments, root: root, port: port)
        let recovery = try object(recoveryBytes)
        XCTAssertEqual(try contextDigest(recovery), input["context_sha256"] as? String)
        let recoveries = try XCTUnwrap(recovery["recoveries"] as? [[String: Any]])
        let obligation = try XCTUnwrap(recoveries.first { $0["target_model_id"] as? String == Self.model })
        let cleanup = try XCTUnwrap(obligation["action"] as? [String: Any])
        XCTAssertEqual(cleanup["available"] as? Bool, true)
        XCTAssertEqual(cleanup["transaction_kind"] as? String, "cleanup_staging")
        XCTAssertEqual(cleanup["transaction_id"] as? String, prepare.id)
        XCTAssertEqual(try Data(contentsOf: configURL), configBytes)
        evidence["missing_target_quick"] = String(decoding: missingBytes, as: UTF8.self)
        evidence["cleanup_failure_terminal"] = String(decoding: terminal, as: UTF8.self)
        evidence["cleanup_recovery_quick"] = String(decoding: recoveryBytes, as: UTF8.self)
    }

    private func readArguments(mode: String, config: URL, context: String? = nil) -> [String] {
        var args = ["models", "catalog-economics", "--json", "--config", config.path, "--local-activation",
                    "--app-read-request", UUID().uuidString.lowercased(), "--app-read-mode", mode,
                    "--read-lock-fd", "199", "--read-lifetime-fd", "200"]
        if let context { args += ["--verify-local-model", Self.model, "--expected-context-sha256", context] }
        return args
    }
    private func ownerArguments(_ name: String, action: Action, config: URL) -> [String] {
        ["models", name, Self.model, "--transaction-id", action.id, "--operation-generation", action.generation,
         "--confirm", "--json", "--config", config.path]
    }
    private func resultArguments(action: Action, config: URL, context: String) -> [String] {
        ["models", "transaction", "result", action.id, "--model", Self.model, "--expected-kind", action.kind,
         "--operation-generation", action.generation, "--json", "--config", config.path,
         "--app-read-request", UUID().uuidString.lowercased(), "--app-read-mode", "result",
         "--expected-context-sha256", context, "--read-lock-fd", "199", "--read-lifetime-fd", "200"]
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func lines(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").map { try object(Data($0.utf8)) }
    }
    private func row(_ object: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((object["rows"] as? [[String: Any]])?.first { $0["model_key"] as? String == Self.key })
    }
    private func verificationState(_ object: [String: Any]) throws -> String {
        try XCTUnwrap((try row(object)["local_verification"] as? [String: Any])?["state"] as? String)
    }
    private func contextDigest(_ object: [String: Any]) throws -> String {
        try XCTUnwrap((object["source"] as? [String: Any])?["transaction_context_sha256"] as? String)
    }
    private func action(_ object: [String: Any], field: String) throws -> Action {
        let fields = try XCTUnwrap(try row(object)[field] as? [String: Any])
        XCTAssertEqual(fields["available"] as? Bool, true)
        return Action(id: try XCTUnwrap(fields["transaction_id"] as? String),
            generation: try XCTUnwrap(fields["operation_generation"] as? String),
            kind: try XCTUnwrap(fields["transaction_kind"] as? String))
    }
    private func jsonString(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
}
