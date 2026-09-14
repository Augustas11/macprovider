import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// Parsed commands in separate, isolated XCTest subprocesses. Fixture SSE timings
/// establish command composition only; no MLX model or operator provider is used.
final class Build1CommandBootstrapTests: XCTestCase {
    private static let key = "qwen3-coder-30b-a3b-instruct"
    private static let model = "mlx-community/Test-Model-4bit"

    func testFixtureIdentityProofRejectsWrongProviderAndKeyAndBindsAttempt() throws {
        let key = Curve25519.Signing.PrivateKey()
        let initial: [String: Any] = ["type": "auth_request", "stage": "initial", "version": 2,
            "provider_id": "fixture-provider", "binary_version": "fixture-version",
            "provider_ecdh_public_key": "fixture-ephemeral-public"]
        var challenge: [String: Any] = ["type": "auth_challenge", "auth_attempt_id": "attempt-one",
            "assigned_id": "session-one", "admission_identity_public_key": key.publicKey.rawRepresentation.base64EncodedString()]
        let request: [String: Any] = ["initial": initial, "challenge": challenge]
        XCTAssertThrowsError(try Build1LocalServiceBridge.signIdentityProof(request: request, providerID: "other-provider", identity: key))
        XCTAssertThrowsError(try Build1LocalServiceBridge.signIdentityProof(request: request, providerID: "fixture-provider", identity: Curve25519.Signing.PrivateKey()))
        let proof = try Build1LocalServiceBridge.signIdentityProof(request: request, providerID: "fixture-provider", identity: key)
        let signature = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(proof["identity_signature"])))
        let transcript = try XCTUnwrap(proof["identity_signature_transcript_sha256"])
        func payload(attempt: String, ecdh: String) throws -> Data {
            try CanonicalJSON.encode(CanonicalJSON.fromJSONLike([
                "auth_attempt_id": attempt, "provider_id": "fixture-provider", "binary_version": "fixture-version",
                "provider_ecdh_public_key": ecdh, "transcript_sha256": transcript]))
        }
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: try payload(attempt: "attempt-one", ecdh: "fixture-ephemeral-public")))
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: try payload(attempt: "attempt-two", ecdh: "fixture-ephemeral-public")))
        XCTAssertFalse(key.publicKey.isValidSignature(signature, for: try payload(attempt: "attempt-one", ecdh: "other-session-ephemeral")))
        challenge["assigned_id"] = ""
        XCTAssertThrowsError(try Build1LocalServiceBridge.signIdentityProof(request: ["initial": initial, "challenge": challenge], providerID: "fixture-provider", identity: key))
    }

    func testParsedPrepareRestartDiscoverRecommendReadbackAndOriginalAdoption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b1-" + String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let owned = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: owned) }
        XCTAssertLessThan(owned.appendingPathComponent("ctl.sock").path.utf8.count, 104)
        let config = owned.appendingPathComponent("home/.config/macprovider/config.yaml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = owned.appendingPathComponent("download-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: source.appendingPathComponent("weights.safetensors"))
        try Data(#"{"max_position_embeddings":4096}"#.utf8).write(to: source.appendingPathComponent("config.json"))
        let sha = try ModelArtifactVerifier.canonicalArtifactHash(directory: source)
        let signed = try Build1CommandFixtureInputs(directory: owned.appendingPathComponent("signed-inputs"),
            catalogKey: Self.key, modelID: Self.model, artifactSHA256: sha)
        let provider = try Build1FixtureProvider.compile(in: owned.appendingPathComponent("provider"))
        let port = try Build1FixtureProvider.unusedPort()
        let configBytes = Data("""
        model: incumbent
        supported_models:
          - incumbent
          - \(Self.key)
        model_artifact_root: \(owned.appendingPathComponent("models").path)
        credential_store: protected_file
        ctl_socket_path: \(owned.appendingPathComponent("ctl.sock").path)
        """.utf8)
        try configBytes.write(to: config)
        XCTAssertEqual(chmod(config.path, 0o600), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.appendingPathComponent("hf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.appendingPathComponent("models").path))
        let projection = ["models", "catalog-economics", "--local-activation", "--skip-coordinator-status"] + discoveryArguments(root: owned, config: config)
        let before = try await runCommand(projection, root: owned, port: port)
        let prepare = try action(from: before, name: "prepare")
        let prepared = try await runCommand(ownerArguments("prepare", action: prepare, config: config), root: owned, port: port)
        XCTAssertEqual(try jsonLines(prepared).last?["state"] as? String, "succeeded")
        XCTAssertEqual(try Data(contentsOf: config), configBytes)
        let discoverArgs = ["models", "discover"] + discoveryArguments(root: owned, config: config)
        let discovery = try await runCommand(discoverArgs, root: owned, port: port)
        let rediscovery = try await runCommand(discoverArgs, root: owned, port: port)
        let first = try discoveredCandidate(discovery)
        let second = try discoveredCandidate(rediscovery)
        XCTAssertEqual(first["candidate_id"] as? String, second["candidate_id"] as? String)
        XCTAssertEqual(first["readiness_state"] as? String, "ready")
        let preparedStatus = try await runCommand(readArguments("status", action: prepare, config: config), root: owned, port: port)
        XCTAssertEqual(try jsonLines(preparedStatus).last?["state"] as? String, "succeeded")
        let after = try await runCommand(projection, root: owned, port: port)
        let evaluate = try action(from: after, name: "evaluate")
        XCTAssertNotEqual(prepare.id, evaluate.id)
        let measured = try await runCommand(ownerArguments("recommend-prepared", action: evaluate, config: config), root: owned, port: port)
        XCTAssertEqual(try jsonLines(measured).last?["state"] as? String, "succeeded")
        XCTAssertEqual(try Data(contentsOf: config), configBytes)
        let measuredStatus = try await runCommand(readArguments("status", action: evaluate, config: config), root: owned, port: port)
        XCTAssertEqual(try jsonLines(measuredStatus).last?["state"] as? String, "succeeded")
        let result = try await runCommand(readArguments("result", action: evaluate, config: config), root: owned, port: port)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(document["recommended_model"] as? String, Self.key)
        let serve = try XCTUnwrap(document["serve_config"] as? [String: Any])
        XCTAssertEqual(serve["model_artifact_sha256"] as? String, sha)
        XCTAssertEqual(serve["model_catalog_hash"] as? String, signed.candidateSHA256)
        let configLoaded = try ConfigLoader.load(cli: CLIOverrides(configPath: config.path), environment: [:])
        let storedResult = ModelCatalogTransactionStore.forConfig(configLoaded).root.appendingPathComponent(evaluate.id + ".result")
        let committed = try Data(contentsOf: storedResult)
        XCTAssertEqual(result, committed + Data([10]))
        let original = owned.appendingPathComponent("original-owner-result.json")
        try committed.write(to: original)
        let parsed = try ModelsAdoptRecommendationCommand.loadRecommendation(pathOrStdin: original.path)
        let runtime = ModelRuntime(modelID: "incumbent", warmSwapEnabled: true,
            targetAuthorities: [parsed.targetModelID: .init(modelArgument: parsed.core.modelArtifactPath!, artifactSHA256: sha,
                                                          catalogRevision: parsed.core.modelCatalogRevision!)],
            authorizedSwitchModelIDs: [parsed.targetModelID],
            loader: { _ in throw URLError(.unsupportedURL) }, testLoader: { target in (target, sha) })
        let socket = owned.appendingPathComponent("ctl.sock")
        let server = ControlSocketServer(socketPath: socket, modelRuntime: runtime, supportedModels: ["incumbent", Self.key])
        try await server.start()
        do {
            let adopted = try await runCommand(["models", "adopt-recommendation", "--json", "--config", config.path,
                "--recommendation-json", original.path, "--ctl-socket-path", socket.path,
                "--switch-state-path", owned.appendingPathComponent("switch-state").path], root: owned, port: port)
            XCTAssertEqual(try jsonLines(adopted).last?["type"] as? String, "completed")
            await server.stop()
        } catch { await server.stop(); throw error }
        XCTAssertEqual(try Data(contentsOf: original), committed)
        let loaded = try ConfigLoader.load(cli: CLIOverrides(configPath: config.path), environment: [:])
        XCTAssertEqual(loaded.modelCatalogKey, Self.key)
        XCTAssertEqual(loaded.modelCatalogModelID, Self.model)
        XCTAssertEqual(loaded.modelArtifactSHA256, sha)
        let bridge = try await Build1LocalServiceBridge.start(root: owned, inputs: signed, modelID: Self.model, artifactSHA256: sha)
        do {
            let auth = ["--coordinator-url", bridge.coordinatorURL, "--provider-id", bridge.providerID]
            let offered = try await runCommand(["models", "offer", Self.model, "--yes",
                "--requested-disclosure-class", "catalog_binding_requested",
                "--evaluation-digest-sha256", SHA256.hash(data: committed).map { String(format: "%02x", $0) }.joined()]
                + auth + discoveryArguments(root: owned, config: config), root: owned, port: port)
            XCTAssertEqual(try jsonLines(offered).last?["admission_state"] as? String, "offer_submitted")
            let pending = try await runCommand(["models", "admission", "status", Self.model] + auth
                + discoveryArguments(root: owned, config: config), root: owned, port: port)
            XCTAssertEqual(try jsonLines(pending).last?["admission_state"] as? String, "offer_submitted")
            try await bridge.connectProvider()
            let retried = try await runCommand(["models", "admission", "retry", Self.model, "--yes", "--json",
                "--config", config.path, "--local-discovery-namespace-path", owned.appendingPathComponent("byom/namespace").path]
                + auth, root: owned, port: port)
            XCTAssertEqual(try jsonLines(retried).last?["admission_state"] as? String, "settlement_capable")
            let admitted = try await runCommand(["models", "admission", "status", Self.model] + auth
                + discoveryArguments(root: owned, config: config), root: owned, port: port)
            XCTAssertEqual(try jsonLines(admitted).last?["admission_state"] as? String, "settlement_capable")
            let settlement = try await bridge.verifySettlement()
            XCTAssertEqual(settlement["receipt"] as? String, "valid")
            XCTAssertEqual(settlement["ledger_rows"] as? Int, 1)
            XCTAssertEqual(settlement["buyer_tokens"] as? Int, 20)
            XCTAssertEqual(settlement["gross_credits"] as? Int, 16)
            XCTAssertEqual(settlement["provider_credits"] as? Int, 14)
            XCTAssertEqual(settlement["physical_mlx"] as? Bool, false)
            await bridge.stop()
            guard !bridge.process.isRunning else { throw URLError(.timedOut) }
            XCTAssertEqual(bridge.process.terminationStatus, 0)
        } catch { await bridge.stop(); throw error }
        let observations = try provider.observations()
        XCTAssertGreaterThanOrEqual(observations.filter { $0["event"] as? String == "chat" }.count, 2)
        let startedPIDs = Set(observations.compactMap { event -> Int32? in
            guard event["event"] as? String == "start", let pid = event["pid"] as? Int else { return nil }
            return Int32(exactly: pid)
        })
        XCTAssertFalse(startedPIDs.isEmpty)
        let events = observations.compactMap { $0["event"] as? String }.joined(separator: ",")
        for pid in startedPIDs {
            let processResult = kill(pid, 0), processError = errno
            let groupResult = kill(-pid, 0), groupError = errno
            XCTAssertEqual(processResult, -1, "fixture PID remains; events=" + events)
            XCTAssertEqual(processError, ESRCH)
            XCTAssertEqual(groupResult, -1, "fixture process group remains; events=" + events)
            XCTAssertEqual(groupError, ESRCH)
        }
        XCTAssertFalse(MacProviderPortProbe.isOpen(port), "fixture listener remains; events=" + events)
        let downloads = try String(contentsOf: owned.appendingPathComponent("downloads.log"), encoding: .utf8)
        XCTAssertEqual(downloads.split(separator: "\n").count, 3, "one metadata and two file transfers, all in preparation")
    }

    /// Selected only by xcrun xctest with its working directory set to a private
    /// request root. There is no shipping CLI or environment trust override.
    func testCommandFixtureSubprocessEntry() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let requestURL = root.appendingPathComponent("command-request.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else { return }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
        guard request.root == root.path else { _exit(91) }
        guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { _exit(93) }
        let output = root.appendingPathComponent("command-output.jsonl")
        let descriptor = open(output.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, dup2(descriptor, STDOUT_FILENO) >= 0 else { _exit(92) }
        close(descriptor)
        do {
            let context = try Self.fixtureContext(root: root, port: request.port, preparing: request.arguments.contains("prepare"))
            var parsed = try MacProviderCLI.parseAsRoot(request.arguments)
            switch parsed {
            case let command as ModelsCatalogEconomicsCommand: try await command.run(context: context)
            case let command as ModelsDiscoverCommand: try await command.run(context: context)
            case let command as ModelsPrepareCommand: try await command.run(context: context)
            case let command as ModelsRecommendPreparedCommand: try await command.run(context: context)
            case let command as ModelsAdoptRecommendationCommand: try await command.run(context: context)
            case let command as ModelsOfferCommand: try await command.run(context: context)
            case let command as ModelsAdmissionStatusCommand: try await command.run(context: context)
            case let command as ModelsAdmissionRetryCommand: try await command.run(context: context)
            default:
                if var command = parsed as? any AsyncParsableCommand { try await command.run() }
                else { try parsed.run() }
            }
            fflush(stdout)
            _exit(0)
        } catch {
            FileHandle.standardError.write(Data("fixture command failed: \(error)\n".utf8))
            _exit(2)
        }
    }

    func testServiceBridgeSubprocessEntry() throws { try Build1LocalServiceBridge.runSubprocess() }

    private struct Request: Codable { let root: String; let arguments: [String]; let port: Int }
    private struct Action { let id: String; let generation: String; let target: String; let kind: String }

    private func runCommand(_ arguments: [String], root: URL, port: Int) async throws -> Data {
        try JSONEncoder().encode(Request(root: root.path, arguments: arguments, port: port))
            .write(to: root.appendingPathComponent("command-request.json"), options: .atomic)
        let errorURL = root.appendingPathComponent("command-stderr.log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "macprovider_cliTests.Build1CommandBootstrapTests/testCommandFixtureSubprocessEntry", Bundle(for: Self.self).bundlePath]
        child.currentDirectoryURL = root
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path, "TMPDIR": root.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = errors
        try child.run()
        let deadline = Date().addingTimeInterval(45)
        while child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if child.isRunning {
            let pid = child.processIdentifier
            if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { child.terminate() }
            try await Task.sleep(nanoseconds: 100_000_000)
            if child.isRunning {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
        let timedOut = Date() >= deadline
        let completionDeadline = Date().addingTimeInterval(3)
        while child.isRunning && Date() < completionDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard !timedOut, !child.isRunning else {
            throw NSError(domain: "Build1CommandBootstrap", code: Int(ETIMEDOUT),
                          userInfo: [NSLocalizedDescriptionKey: "Command deadline exceeded: " + arguments.joined(separator: " ")])
        }
        guard child.terminationStatus == 0 else {
            throw NSError(domain: "Build1CommandBootstrap", code: Int(child.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: arguments.joined(separator: " ") + "\n" + (try String(contentsOf: errorURL, encoding: .utf8))])
        }
        return try Data(contentsOf: root.appendingPathComponent("command-output.jsonl"))
    }

    static func fixtureContext(root: URL, port: Int, preparing: Bool, catalogKey: String? = nil) throws -> ModelCommandExecutionContext {
        let inputs = try Build1CommandFixtureInputs(existingDirectory: root.appendingPathComponent("signed-inputs"), catalogKey: catalogKey ?? Self.key)
        let provider = try Build1FixtureProvider.existing(in: root.appendingPathComponent("provider"))
        let config = root.appendingPathComponent("home/.config/macprovider/config.yaml")
        var context = ModelCommandExecutionContext.production
        context.inputs = { inputs.loader() }
        context.projectionHome = root.appendingPathComponent("home")
        context.projectionEnvironment = ["HOME": root.appendingPathComponent("home").path]
        context.adoptionJournalRoot = root.appendingPathComponent("adoption-journals")
        context.discoveryEnvironment = { original in
            BYOMDiscoveryEnvironment(namespaceURL: original.namespaceURL, mlxCacheRoot: root.appendingPathComponent("hf"),
                ollamaOrigin: nil, openAICompatibleOrigin: nil, durableArtifactRoot: original.durableArtifactRoot,
                catalogMatcher: original.catalogMatcher)
        }
        let custody = root.appendingPathComponent("home/.config/macprovider/protected-credentials")
        context.providerStore = { _ in ProtectedFileProviderCredentialStore(rootDirectory: custody) }
        context.identityStore = { _ in ProtectedFileReceiptKeyStore(rootDirectory: custody) }
        let readyURL = root.appendingPathComponent("service-ready.json")
        if FileManager.default.fileExists(atPath: readyURL.path) {
            let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: readyURL)) as? [String: Any])
            let transport = try Build1LocalServiceBridge.transportURLs(endpoint: XCTUnwrap(ready["coordinator_url"] as? String))
            context.admissionClient = { logical in
                guard logical == transport.logical else { throw BYOMModelAdmissionError.invalidCoordinatorURL }
                return BYOMModelAdmissionClient(baseURL: transport.actual)
            }
            XCTAssertEqual(try context.admissionClient(transport.logical).baseURL, transport.actual)
            XCTAssertThrowsError(try context.admissionClient(transport.logical + "/unexpected"))
            XCTAssertThrowsError(try context.admissionClient("https://localhost:" + String(transport.actual.port!)))
        }
        context.configureTransactionRunner = { runner in
            let capturedRoot = runner.boundArtifactResolver?.durableRoot ?? CachedModelArtifactResolver.forConfig(runner.config).durableRoot
            precondition(capturedRoot.resolvingSymlinksInPath().path == root.appendingPathComponent("models").path)
            runner.boundArtifactResolver = CachedModelArtifactResolver(hubRoot: root.appendingPathComponent("home/.cache/huggingface/hub"), durableRoot: capturedRoot)
            runner.port = port
            runner.timeoutSeconds = 30
            runner.adoptionLockRoot = root.appendingPathComponent("adoption-journals")
            runner.detectConflict = { .none }
            runner.downloader = HuggingFaceSnapshotDownloader(fetch: { request in
                guard preparing else { throw URLError(.resourceUnavailable) }
                try Self.recordDownload(root: root, label: "metadata")
                return (Data(#"{"siblings":[{"rfilename":"weights.safetensors"},{"rfilename":"config.json"}]}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, download: { request in
                guard preparing else { throw URLError(.resourceUnavailable) }
                let name = request.url!.lastPathComponent
                guard ["weights.safetensors", "config.json"].contains(name) else { throw URLError(.badURL) }
                try Self.recordDownload(root: root, label: name)
                let transfer = root.appendingPathComponent("transfer-" + UUID().uuidString)
                let data = try Data(contentsOf: root.appendingPathComponent("download-source/" + name))
                try data.write(to: transfer)
                return (transfer, URLResponse(url: request.url!, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil))
            })
            runner.benchmarker = { resolver, logs, check in
                let forbidden = HuggingFaceSnapshotDownloader(fetch: { _ in throw URLError(.resourceUnavailable) }, download: { _ in throw URLError(.resourceUnavailable) })
                let offline = CachedModelArtifactResolver(hubRoot: root.appendingPathComponent("hf"), durableRoot: resolver.durableRoot, downloader: forbidden)
                return AutotuneRecommendationBenchmarker(telemetryDirectory: logs, artifactResolver: offline,
                    runnerFactory: { try CandidateProviderRunner(providerBinaryPath: provider.binaryURL.path, configPath: config.path, logDirectory: logs, publicationCheck: check) },
                    prober: Stage1Prober(readyTimeoutSec: 5, stopGraceSeconds: 0.2, probeIdleTimeoutSec: 10, probeTotalTimeoutSec: 10),
                    safetySampler: Build1CommandSafetySampler())
            }
        }
        return context
    }

    private static func recordDownload(root: URL, label: String) throws {
        let fd = open(root.appendingPathComponent("downloads.log").path, O_CREAT | O_APPEND | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw URLError(.cannotWriteToFile) }
        defer { close(fd) }
        let bytes = Data((label + "\n").utf8)
        bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    private func discoveryArguments(root: URL, config: URL) -> [String] {
        ["--json", "--config", config.path, "--skip-ollama", "--skip-openai-compatible",
         "--local-discovery-namespace-path", root.appendingPathComponent("byom/namespace").path,
         "--mlx-cache-dir", root.appendingPathComponent("hf").path]
    }
    private func action(from data: Data, name: String) throws -> Action {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(root["rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { $0["model_key"] as? String == Self.key })
        let action = try XCTUnwrap(row[name] as? [String: Any])
        XCTAssertEqual(action["available"] as? Bool, true, "\(action)")
        XCTAssertEqual(action["requires_confirmation"] as? Bool, true)
        return Action(id: try XCTUnwrap(action["transaction_id"] as? String),
                      generation: try XCTUnwrap(action["operation_generation"] as? String),
                      target: try XCTUnwrap(row["action_model_id"] as? String),
                      kind: try XCTUnwrap(action["transaction_kind"] as? String))
    }
    private func ownerArguments(_ name: String, action: Action, config: URL) -> [String] {
        ["models", name, action.target, "--transaction-id", action.id, "--operation-generation", action.generation,
         "--confirm", "--json", "--config", config.path]
    }
    private func readArguments(_ name: String, action: Action, config: URL) -> [String] {
        ["models", "transaction", name, action.id, "--model", action.target, "--expected-kind", action.kind,
         "--operation-generation", action.generation, "--json", "--config", config.path]
    }
    private func discoveredCandidate(_ data: Data) throws -> [String: Any] {
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let candidates = try XCTUnwrap(document["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.count, 1)
        return try XCTUnwrap(candidates.first)
    }
    private func jsonLines(_ data: Data) throws -> [[String: Any]] {
        try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}

private struct Build1CommandSafetySampler: ProbeSafetySampling {
    func sample() -> ProbeSafetySample { .init(pressureLevel: .normal, thermalState: .nominal) }
}
