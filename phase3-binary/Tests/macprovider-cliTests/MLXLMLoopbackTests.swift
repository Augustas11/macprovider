import Foundation
import XCTest
@testable import macprovider_cli
import MacProviderCore

/// SPEC-010-R009 / SPEC-046 v0.3.0 (#1690 M8): `mlxlm:` serves through
/// mlx_lm.server as `mlxlm_loopback`, reporting the CLI-computed
/// snapshot-manifest pair of the operator-declared snapshot directory.
final class MLXLMLoopbackTests: XCTestCase {
    private func makeSnapshot() throws -> URL {
        // The unique part is the parent: the served ref is the snapshot's
        // last path component, and discovery refuses a credential-shaped one
        // (40+ [A-Za-z0-9_-] characters, such as "mlxlm-snapshot-<UUID>").
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("mlxlm-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("mlxlm-snapshot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try Data(#"{"model_type":"qwen2"}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        try Data(repeating: 0x42, count: 8192).write(to: root.appendingPathComponent("model.safetensors"))
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func makeRequest(model: String) throws -> ChatCompletionRequest {
        let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 4, "stream": false]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }

    func testSelectorAndVocabulary() {
        XCTAssertEqual(LoopbackServeSelection.select("mlxlm:Qwen2.5-0.5B-Instruct-4bit"), .mlxLM)
        XCTAssertEqual(LoopbackServeSelection.mlxLM.runtimeSource, "mlxlm_loopback")
        XCTAssertEqual(LoopbackServeSelection.select("omlx:foo"), .oMLX, "oMLX has its identity leg (#1690 M9)")
        XCTAssertTrue(CoordinatorClient.isBYOMLoopbackRuntimeSource("mlxlm_loopback"))
        XCTAssertEqual(ArtifactFeed.identityMatrix["mlx_safetensors"]?.runtimeSources, ["mlx_cache", "mlxlm_loopback", "omlx_loopback"])
        XCTAssertFalse(ArtifactFeed.identityMatrix["gguf"]?.runtimeSources.contains("mlxlm_loopback") ?? true)
        XCTAssertTrue(LoopbackServeHTTPClient.isAllowed(URL(string: "http://127.0.0.1:9191/v1/models")!, method: "GET"))
        XCTAssertEqual(MLXLMLoopbackServeModel.resolveOrigin(configured: nil, environment: [:]), "http://127.0.0.1:8080")
        XCTAssertEqual(
            MLXLMLoopbackServeModel.resolveOrigin(configured: nil, environment: ["MACPROVIDER_MLXLM_ORIGIN": "http://127.0.0.1:9300"]),
            "http://127.0.0.1:9300"
        )
        XCTAssertNil(MLXLMLoopbackServeModel.snapshotDirectory(environment: ["MACPROVIDER_MLXLM_MODEL_PATH": "relative/dir"]))
    }

    func testRuntimeReportsTheNativeSnapshotPairAndBindsTheListedDirectory() async throws {
        let snapshot = try makeSnapshot()
        let client = MLXLMStubClient(listed: [snapshot.path, "mlx-community/Other-4bit"])
        let runtime = try await OpenAICompatibleLoopbackRuntime.mlxLM(
            servedModelRef: "mlxlm:" + snapshot.lastPathComponent,
            origin: "http://127.0.0.1:9191",
            snapshotDirectory: snapshot,
            httpClient: client
        )
        let hash = await runtime.loadedModelHash
        let algorithm = await runtime.loadedModelHashAlgorithm
        XCTAssertEqual(hash, try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))
        XCTAssertEqual(algorithm, "macprovider.snapshot-manifest.v1")
        XCTAssertEqual(runtime.settlementRuntimeSource, "mlxlm_loopback")
        XCTAssertFalse(runtime.isSettlementReceiptEligible, "loopback stays non-earning outside a pool authorization")

        let request = try makeRequest(model: "mlxlm:" + snapshot.lastPathComponent)
        try await runtime.preflight(request, with: try await runtime.acquireRequestHandle(request))

        // The runtime no longer listing the bound snapshot fails closed.
        client.setListed(["mlx-community/Other-4bit"])
        do {
            try await runtime.preflight(request, with: try await runtime.acquireRequestHandle(request))
            XCTFail("an mlx_lm.server that stopped serving the snapshot must fail closed")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "model_not_loaded")
        }

        // A changed snapshot file withdraws the identity (R009(a)).
        client.setListed([snapshot.path])
        try Data(repeating: 0x43, count: 8192).write(to: snapshot.appendingPathComponent("model.safetensors"))
        let after = await runtime.loadedModelHash
        XCTAssertNil(after)
    }

    func testRuntimeFailsClosedWithoutADeclaredOrListedSnapshot() async throws {
        let snapshot = try makeSnapshot()
        do {
            _ = try await OpenAICompatibleLoopbackRuntime.mlxLM(
                servedModelRef: "mlxlm:x", origin: "http://127.0.0.1:9191", snapshotDirectory: nil,
                httpClient: MLXLMStubClient(listed: [snapshot.path])
            )
            XCTFail("no declared snapshot must fail closed")
        } catch let error as OpenAICompatibleLoopbackRuntimeError {
            guard case .artifactResolutionFailed = error else { return XCTFail("unexpected \(error)") }
        }
        do {
            _ = try await OpenAICompatibleLoopbackRuntime.mlxLM(
                servedModelRef: "mlxlm:x", origin: "http://127.0.0.1:9191", snapshotDirectory: snapshot,
                httpClient: MLXLMStubClient(listed: ["mlx-community/Other-4bit"])
            )
            XCTFail("a runtime that does not list the snapshot must be refused")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleLoopbackRuntimeError, .upstreamNotRecognized("mlxlm_loopback"))
        }
        // A GGUF runtime class never carries an MLX snapshot identity.
        XCTAssertThrowsError(try OpenAICompatibleLoopbackRuntime(
            servedModelRef: "llamacpp:x", origin: "http://127.0.0.1:9191", runtimeSource: "llamacpp_loopback",
            mlxSnapshot: try MLXSnapshotIdentity.compute(directory: snapshot)
        ))
    }

    func testCredentialShapedSnapshotNameIsNotADiscoverableRef() {
        XCTAssertFalse(BYOMDiscoveryPrivacy.isSafeRuntimeModelReference("mlxlm-snapshot-\(UUID().uuidString)"))
        XCTAssertTrue(BYOMDiscoveryPrivacy.isSafeRuntimeModelReference("mlxlm-snapshot"))
        XCTAssertTrue(BYOMDiscoveryPrivacy.isSafeRuntimeModelReference("Qwen2.5-0.5B-Instruct-4bit"))
    }

    func testDiscoveryReportsOnlyTheListedDeclaredSnapshot() async throws {
        let snapshot = try makeSnapshot()
        let listed = await BYOMMLXLMDiscovery(
            origin: "http://127.0.0.1:9191", snapshotDirectory: snapshot, namespace: Data(repeating: 7, count: 32),
            httpClient: MLXLMStubClient(listed: [snapshot.path])
        ).discover()
        XCTAssertEqual(listed.adapter.status, "ok")
        XCTAssertEqual(listed.candidates.map(\.servedModelRef), ["mlxlm:" + snapshot.lastPathComponent])
        XCTAssertEqual(listed.candidates.first?.runtimeSource, "mlxlm_loopback")
        XCTAssertNil(listed.candidates.first?.catalogModelKey)

        let other = await BYOMMLXLMDiscovery(
            origin: "http://127.0.0.1:9191", snapshotDirectory: snapshot, namespace: Data(repeating: 7, count: 32),
            httpClient: MLXLMStubClient(listed: ["mlx-community/Other-4bit"])
        ).discover()
        XCTAssertTrue(other.candidates.isEmpty)

        let rejected = await BYOMMLXLMDiscovery(
            origin: "http://192.168.1.5:9191", snapshotDirectory: snapshot, namespace: nil,
            httpClient: MLXLMStubClient(listed: [snapshot.path])
        ).discover()
        XCTAssertEqual(rejected.adapter.status, "rejected")
    }

    /// Approved roots whose durable model store holds `snapshot`.
    private func roots(holding snapshot: URL) -> MLXLMLoopbackServeModel.ApprovedSnapshotRoots {
        MLXLMLoopbackServeModel.ApprovedSnapshotRoots(
            durableModelRoot: snapshot.deletingLastPathComponent(),
            hubCacheRoot: URL(fileURLWithPath: "/nonexistent/hub")
        )
    }

    func testDiscoveryInfersTheRunningMLXLMServerSnapshotWithoutEnv() async throws {
        let snapshot = try makeSnapshot()
        let base = BYOMDiscoveryEnvironment(
            namespaceURL: URL(fileURLWithPath: "/nonexistent/ns"), mlxCacheRoot: URL(fileURLWithPath: "/nonexistent"), ollamaOrigin: nil,
            durableModelRoot: snapshot.deletingLastPathComponent()
        )
        XCTAssertTrue(base.mlxSnapshotLoopbacks.isEmpty)

        // serve on 8080 lists catalog ids; mlx_lm.server on 8081 lists the HF
        // cache repos plus its --model path.
        let ports = MLXLMPortStubClient(listings: [
            8080: ["qwen/qwen3.6-35b-a3b"],
            8081: ["mlx-community/Other-4bit", snapshot.path],
        ])
        let inferred = try await base.withInferredMLXLMSnapshot(httpClient: ports)
        XCTAssertEqual(inferred.mlxlmOrigin, "http://127.0.0.1:8081")
        XCTAssertEqual(inferred.mlxlmModelPath?.path, snapshot.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(inferred.mlxSnapshotLoopbacks.count, 1)
        let found = await BYOMDiscoveryRunner(environment: inferred, httpClient: ports).discoverIncludingMLXLM()
        XCTAssertEqual(found.candidates.filter { $0.runtimeSource == "mlxlm_loopback" }.map(\.servedModelRef), ["mlxlm:" + snapshot.lastPathComponent])

        // Only repo ids (no --model path), or a serve-only port: nothing inferred.
        let none = try await base.withInferredMLXLMSnapshot(httpClient: MLXLMPortStubClient(listings: [8080: ["qwen/x"], 8081: ["mlx-community/Other-4bit"]]))
        XCTAssertNil(none.mlxlmModelPath)
        // An explicit origin is the only one probed.
        var explicit = base
        explicit.mlxlmOrigin = "http://127.0.0.1:9191"
        let pinned = try await explicit.withInferredMLXLMSnapshot(httpClient: ports)
        XCTAssertNil(pinned.mlxlmModelPath)
        XCTAssertEqual(MLXLMLoopbackServeModel.discoveryOrigins(configured: nil), ["http://127.0.0.1:8080", "http://127.0.0.1:8081"])
        XCTAssertEqual(MLXLMLoopbackServeModel.discoveryOrigins(configured: "http://127.0.0.1:9191"), ["http://127.0.0.1:9191"])
        XCTAssertEqual(MLXLMLoopbackServeModel.discoveryOrigins(configured: nil, excludingPort: 8080), ["http://127.0.0.1:8081"])
    }

    func testServeDetectsTheRunningMLXLMServerSnapshotWhenThePathIsUnset() async throws {
        let snapshot = try makeSnapshot()
        let approved = roots(holding: snapshot)
        let ports = MLXLMPortStubClient(listings: [
            8080: ["qwen/qwen3.6-35b-a3b"],
            8081: ["mlx-community/Other-4bit", snapshot.path],
        ])
        // No path, no origin: the probe finds mlx_lm.server on 8081, not serve on 8080.
        let found = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: nil, client: ports, environment: [:], servePort: 8080, roots: approved)
        XCTAssertEqual(found.origin, "http://127.0.0.1:8081")
        XCTAssertEqual(found.directory?.path, snapshot.resolvingSymlinksInPath().standardizedFileURL.path)
        // A declared directory is used as is, with the configured origin.
        let pinned = try await MLXLMLoopbackServeModel.serveTarget(
            configuredOrigin: "http://127.0.0.1:9191", client: ports,
            environment: ["MACPROVIDER_MLXLM_MODEL_PATH": "/declared/snapshot"], roots: approved
        )
        XCTAssertEqual(pinned.origin, "http://127.0.0.1:9191")
        XCTAssertEqual(pinned.directory, URL(fileURLWithPath: "/declared/snapshot", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL)
        // A configured origin is the only one probed.
        let configured = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: "http://127.0.0.1:8080", client: ports, environment: [:], roots: approved)
        XCTAssertNil(configured.directory)

        // A repo-id server: nothing detected, and serve refuses with the fix.
        let repoOnly = MLXLMPortStubClient(listings: [8081: ["mlx-community/Other-4bit"]])
        let none = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: nil, client: repoOnly, environment: [:], roots: approved)
        XCTAssertNil(none.directory)
        do {
            _ = try await OpenAICompatibleLoopbackRuntime.mlxLM(
                servedModelRef: "mlxlm:Other-4bit", origin: none.origin, snapshotDirectory: none.directory, httpClient: repoOnly
            )
            XCTFail("serve must refuse without a snapshot directory")
        } catch {
            XCTAssertTrue(String(describing: error).contains("--model <path written by macprovider-cli models prepare>"))
        }

        // The detected directory still goes through the listing check and hashing.
        let runtime = try await OpenAICompatibleLoopbackRuntime.mlxLM(
            servedModelRef: "mlxlm:" + snapshot.lastPathComponent, origin: found.origin, snapshotDirectory: found.directory, httpClient: ports
        )
        let hash = await runtime.loadedModelHash
        XCTAssertNotNil(hash)
    }

    /// #1880 audit: an auto-detected directory is a claim by whatever answers
    /// the loopback port, so only approved roots are accepted, a malformed
    /// declared path is an error, and serve never probes its own port.
    func testAutoDetectionRefusesWrongServerOutsideRootSymlinkEscapeAndMalformedPath() async throws {
        let snapshot = try makeSnapshot()
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mlxlm-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storeRoot) }
        let approved = MLXLMLoopbackServeModel.ApprovedSnapshotRoots(durableModelRoot: storeRoot, hubCacheRoot: URL(fileURLWithPath: "/nonexistent/hub"))

        // A wrong server lists one real directory outside the approved roots.
        let wrong = MLXLMPortStubClient(listings: [8081: [snapshot.path]])
        do {
            _ = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: nil, client: wrong, environment: [:], roots: approved)
            XCTFail("an outside-root directory must not be auto-detected")
        } catch let error as MLXLMSnapshotSelectionError {
            guard case .outsideApprovedRoots = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.description.contains("MACPROVIDER_MLXLM_MODEL_PATH="))
        }
        let base = BYOMDiscoveryEnvironment(
            namespaceURL: URL(fileURLWithPath: "/nonexistent/ns"), mlxCacheRoot: URL(fileURLWithPath: "/nonexistent/hub"), ollamaOrigin: nil,
            durableModelRoot: storeRoot
        )
        // #1880: discovery skips that server with a warning instead of
        // aborting every engine; a command that targets mlx_lm still refuses.
        let skippedOutside = try await base.withInferredMLXLMSnapshot(httpClient: wrong)
        XCTAssertNil(skippedOutside.mlxlmModelPath)
        XCTAssertTrue(skippedOutside.mlxSnapshotLoopbacks.isEmpty)
        XCTAssertEqual(skippedOutside.mlxlmSkippedOrigin, "http://127.0.0.1:8081")
        let skippedDocument = await BYOMDiscoveryRunner(environment: skippedOutside, httpClient: wrong).discoverIncludingMLXLM()
        let skippedAdapter = skippedDocument.adapters.first { $0.runtimeSource == "mlxlm_loopback" }
        XCTAssertEqual(skippedAdapter?.status, "unavailable")
        XCTAssertEqual(skippedAdapter?.warningCodes, ["adapter_unavailable"])
        XCTAssertTrue(skippedDocument.warnings.contains("adapter_unavailable"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(skippedDocument), as: UTF8.self).contains(snapshot.path))
        do {
            _ = try await base.withInferredMLXLMSnapshot(httpClient: wrong, requireMLXLM: true)
            XCTFail("a command targeting mlx_lm must refuse an outside-root directory")
        } catch is MLXLMSnapshotSelectionError {}
        do {
            _ = try await base.withLoopbackRuntimeProbes(httpClient: wrong, target: "mlxlm:Some-Snapshot")
            XCTFail("an mlxlm: target must keep the outside-root refusal")
        } catch is MLXLMSnapshotSelectionError {}
        let otherTarget = try await base.withLoopbackRuntimeProbes(httpClient: wrong, target: "ollama:llama3.2")
        XCTAssertNil(otherTarget.mlxlmModelPath)

        // A symlink inside the store that escapes it resolves outside: refused.
        let link = storeRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: snapshot)
        do {
            _ = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: nil, client: MLXLMPortStubClient(listings: [8081: [link.path]]), environment: [:], roots: approved)
            XCTFail("a symlink escaping the store must not be auto-detected")
        } catch is MLXLMSnapshotSelectionError {}

        // Inside the store (or a hub cache snapshot) it is detected.
        XCTAssertTrue(roots(holding: snapshot).contains(snapshot))
        let hub = URL(fileURLWithPath: "/tmp/hub")
        let hubRoots = MLXLMLoopbackServeModel.ApprovedSnapshotRoots(durableModelRoot: URL(fileURLWithPath: "/nonexistent/store"), hubCacheRoot: hub)
        XCTAssertFalse(hubRoots.contains(hub.appendingPathComponent("models--org--m")))
        XCTAssertFalse(hubRoots.contains(hub.appendingPathComponent("models--org--m/blobs/x")))

        // Serve never probes its own port, even for an in-root directory, and
        // not even when an origin names it.
        let selfPort = MLXLMPortStubClient(listings: [8080: [snapshot.path]])
        let skipped = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: nil, client: selfPort, environment: [:], servePort: 8080, roots: roots(holding: snapshot))
        XCTAssertNil(skipped.directory)
        let configuredSelf = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: "http://127.0.0.1:8080", client: selfPort, environment: [:], servePort: 8080, roots: roots(holding: snapshot))
        XCTAssertNil(configuredSelf.directory)
        XCTAssertEqual(MLXLMLoopbackServeModel.discoveryOrigins(configured: "http://127.0.0.1:8080", excludingPort: 8080), [])
        // Discovery excludes the configured serve port too.
        var discovering = BYOMDiscoveryEnvironment(
            namespaceURL: URL(fileURLWithPath: "/nonexistent/ns"), mlxCacheRoot: URL(fileURLWithPath: "/nonexistent/hub"), ollamaOrigin: nil,
            durableModelRoot: snapshot.deletingLastPathComponent()
        )
        discovering.mlxlmExcludedPort = 8080
        let notSelf = try await discovering.withInferredMLXLMSnapshot(httpClient: selfPort)
        XCTAssertNil(notSelf.mlxlmModelPath)
        discovering.mlxlmOrigin = "http://127.0.0.1:8080"
        let configuredNotSelf = try await discovering.withInferredMLXLMSnapshot(httpClient: selfPort)
        XCTAssertNil(configuredNotSelf.mlxlmModelPath)

        // Another OpenAI-compatible server listing one in-root directory is
        // not mlx_lm.server: nothing is auto-detected from it.
        let other = MLXLMPortStubClient(listings: [8081: [snapshot.path]], foreign: [8081])
        let notMLXLM = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: nil, client: other, environment: [:], servePort: 8080, roots: roots(holding: snapshot))
        XCTAssertNil(notMLXLM.directory)

        // A present-but-malformed declared path is an error, never "unset".
        let malformed = ["MACPROVIDER_MLXLM_MODEL_PATH": "relative/dir"]
        XCTAssertEqual(MLXLMLoopbackServeModel.snapshotPathSetting(environment: malformed), .invalid("relative/dir"))
        do {
            _ = try await MLXLMLoopbackServeModel.serveTarget(configuredOrigin: nil, client: MLXLMPortStubClient(listings: [8081: [snapshot.path]]), environment: malformed, roots: roots(holding: snapshot))
            XCTFail("a malformed declared path must not fall back to probing")
        } catch let error as MLXLMSnapshotSelectionError {
            XCTAssertEqual(error, .invalidDeclaredPath("relative/dir"))
        }
        let production = BYOMDiscoveryEnvironment.production(
            namespacePath: "/nonexistent/ns", mlxCacheDir: nil, ollamaOrigin: nil, environment: malformed
        )
        do {
            _ = try await production.withLoopbackRuntimeProbes(httpClient: MLXLMPortStubClient(listings: [8081: [snapshot.path]]))
            XCTFail("discovery must refuse a malformed declared path")
        } catch let error as MLXLMSnapshotSelectionError {
            XCTAssertEqual(error, .invalidDeclaredPath("relative/dir"))
        }
    }

    func testMLXLMServerFingerprintMatchesOnlyMLXLMModelLists() {
        func response(_ server: String?, _ body: String) -> BYOMHTTPResponse {
            BYOMHTTPResponse(statusCode: 200, headers: server.map { [("Server", $0)] } ?? [], body: Data(body.utf8))
        }
        let mlx = #"{"object": "list", "data": [{"id": "mlx-community/x", "object": "model", "created": 1700000000}, {"id": "/m/s", "object": "model", "created": 1700000000}]}"#
        XCTAssertTrue(MLXLMLoopbackServeModel.isMLXLMServerModelList(response("BaseHTTP/0.6 Python/3.12.8", mlx)))
        XCTAssertFalse(MLXLMLoopbackServeModel.isMLXLMServerModelList(response(nil, mlx)), "no Server header")
        XCTAssertFalse(MLXLMLoopbackServeModel.isMLXLMServerModelList(response("uvicorn", mlx)), "not Python http.server")
        XCTAssertFalse(MLXLMLoopbackServeModel.isMLXLMServerModelList(response("BaseHTTP/0.6 Python/3.12.8",
            #"{"object": "list", "data": [{"id": "/m/s", "object": "model", "created": 1, "owned_by": "me"}]}"#)), "owned_by")
        XCTAssertFalse(MLXLMLoopbackServeModel.isMLXLMServerModelList(response("BaseHTTP/0.6 Python/3.12.8",
            #"{"object": "list", "data": [{"id": "a", "object": "model", "created": 1}, {"id": "/m/s", "object": "model", "created": 2}]}"#)), "differing created")
        XCTAssertFalse(MLXLMLoopbackServeModel.isMLXLMServerModelList(response("BaseHTTP/0.6 Python/3.12.8",
            #"{"object": "list", "data": [], "extra": 1}"#)), "extra top-level key")
    }

    func testPoolUsageGuardAppliesToMLXLM() {
        let auth = { (source: String) -> PoolRuntimeAuthorization in
            PoolRuntimeAuthorization(wire: [
                "pool_id": "p", "manifest_core_digest": String(repeating: "a", count: 64), "runtime_source": source,
                "request_id": "r", "attempt_n": 1, "provider_id": "prov", "route_snapshot_digest": String(repeating: "b", count: 64),
            ])!
        }
        XCTAssertTrue(PoolLoopbackUsageGuard.applies(to: auth("mlxlm_loopback")))
        XCTAssertTrue(PoolLoopbackUsageGuard.applies(to: auth("llamacpp_loopback")))
        XCTAssertFalse(PoolLoopbackUsageGuard.applies(to: auth("mlx_cache")))
    }
}

private final class MLXLMStubClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var listed: [String]

    init(listed: [String]) { self.listed = listed }

    func setListed(_ ids: [String]) { lock.lock(); listed = ids; lock.unlock() }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard url.path == "/v1/models" else { return BYOMHTTPResponse(statusCode: 404, headers: [], body: Data()) }
        lock.lock()
        let ids = listed
        lock.unlock()
        let body: [String: Any] = ["object": "list", "data": ids.map { ["id": $0, "object": "model"] }]
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: try JSONSerialization.data(withJSONObject: body))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        BYOMHTTPResponse(statusCode: 500, headers: [], body: Data())
    }
}

// #1690 M8 audit R1: offer pipeline, request-path identity, descriptor-bound
// hashing (CODE H1-H3/M4/L5, SECURITY M1).
final class MLXLMLoopbackAuditR1Tests: XCTestCase {
    private func makeSnapshot() throws -> URL {
        // Unique parent, model-shaped snapshot name (see MLXLMLoopbackTests).
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("mlxlm-r1-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("mlxlm-snapshot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try Data(#"{"model_type":"qwen2"}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 8192).write(to: root.appendingPathComponent("sub/model.safetensors"))
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func makeRequest(model: String, stream: Bool = false) throws -> ChatCompletionRequest {
        let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 4, "stream": stream]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }

    func testDescriptorBoundDigestEqualsTheNativeCanonicalHash() throws {
        let snapshot = try makeSnapshot()
        let identity = try MLXSnapshotIdentity.compute(directory: snapshot)
        XCTAssertEqual(identity.digest, try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))
        XCTAssertTrue(identity.isCurrent())
    }

    func testSnapshotRejectsLinksAndDetectsAddRemoveAndInPlaceRewrites() throws {
        let symlinked = try makeSnapshot()
        try FileManager.default.createSymbolicLink(at: symlinked.appendingPathComponent("link.json"), withDestinationURL: symlinked.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try MLXSnapshotIdentity.compute(directory: symlinked))

        let hardlinked = try makeSnapshot()
        try FileManager.default.linkItem(at: hardlinked.appendingPathComponent("config.json"), to: hardlinked.appendingPathComponent("config-copy.json"))
        XCTAssertThrowsError(try MLXSnapshotIdentity.compute(directory: hardlinked))

        let snapshot = try makeSnapshot()
        let identity = try MLXSnapshotIdentity.compute(directory: snapshot)
        let extra = snapshot.appendingPathComponent("extra.txt")
        try Data("x".utf8).write(to: extra)
        XCTAssertFalse(identity.isCurrent(), "an added file withdraws the identity")
        try FileManager.default.removeItem(at: extra)
        XCTAssertTrue(identity.isCurrent())
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("config.json"))
        XCTAssertFalse(identity.isCurrent(), "a removed file withdraws the identity")

        // Same size, restored mtime: only the ctime shows the rewrite.
        let rewritten = try makeSnapshot()
        let weights = rewritten.appendingPathComponent("sub/model.safetensors")
        let before = try MLXSnapshotIdentity.compute(directory: rewritten)
        let attributes = try FileManager.default.attributesOfItem(atPath: weights.path)
        let handle = try FileHandle(forWritingTo: weights)
        try handle.write(contentsOf: Data([0x43]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate] as Any], ofItemAtPath: weights.path)
        XCTAssertFalse(before.isCurrent(), "a metadata-preserving in-place write withdraws the identity")
    }

    func testStreamingRevalidatesIdentityImmediatelyBeforeProxying() async throws {
        let snapshot = try makeSnapshot()
        let client = MLXLMRecordingClient(listed: [snapshot.path])
        let ref = "mlxlm:" + snapshot.lastPathComponent
        let runtime = try await OpenAICompatibleLoopbackRuntime.mlxLM(
            servedModelRef: ref, origin: "http://127.0.0.1:9191", snapshotDirectory: snapshot, httpClient: client
        )
        let request = try makeRequest(model: ref, stream: true)
        let handle = try await runtime.acquireRequestHandle(request)
        try await runtime.preflight(request, with: handle)
        // The snapshot changes after handle acquisition and preflight.
        try Data(repeating: 0x44, count: 8192).write(to: snapshot.appendingPathComponent("sub/model.safetensors"))
        do {
            _ = try await runtime.stream(request, with: handle, onChunk: { _ in })
            XCTFail("a stream after a snapshot change must fail closed")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "model_not_loaded")
        }
        XCTAssertEqual(client.chatBodies.count, 0, "nothing reached the runtime")

        // A runtime that stops listing the snapshot after preflight also fails closed.
        let fresh = try makeSnapshot()
        let client2 = MLXLMRecordingClient(listed: [fresh.path])
        let runtime2 = try await OpenAICompatibleLoopbackRuntime.mlxLM(
            servedModelRef: ref, origin: "http://127.0.0.1:9191", snapshotDirectory: fresh, httpClient: client2
        )
        let handle2 = try await runtime2.acquireRequestHandle(request)
        try await runtime2.preflight(request, with: handle2)
        client2.setListed([])
        do {
            _ = try await runtime2.stream(request, with: handle2, onChunk: { _ in })
            XCTFail("a stream to a runtime that no longer lists the snapshot must fail closed")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "model_not_loaded")
        }
        XCTAssertEqual(client2.chatBodies.count, 0)
    }

    func testChatRequestNamesDefaultModel() async throws {
        let snapshot = try makeSnapshot()
        let client = MLXLMRecordingClient(listed: [snapshot.path])
        let ref = "mlxlm:" + snapshot.lastPathComponent
        let runtime = try await OpenAICompatibleLoopbackRuntime.mlxLM(
            servedModelRef: ref, origin: "http://127.0.0.1:9191", snapshotDirectory: snapshot, httpClient: client
        )
        _ = try await runtime.complete(try makeRequest(model: ref))
        let body = try XCTUnwrap(client.chatBodies.first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "default_model")
    }

    func testRunnerDryRunAndOfferTargetFormsSeeTheMLXLMCandidate() async throws {
        let snapshot = try makeSnapshot()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mlxlm-r1-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let environment = BYOMDiscoveryEnvironment(
            namespaceURL: home.appendingPathComponent("byom/local_discovery_namespace"),
            mlxCacheRoot: home.appendingPathComponent("hf"),
            ollamaOrigin: nil,
            mlxlmOrigin: "http://127.0.0.1:9191",
            mlxlmModelPath: snapshot,
            artifactDigestCacheURL: home.appendingPathComponent("digests.json")
        )
        BYOMDiscoveryNamespaceStore().provisionNamespaceIfMissing(at: environment.namespaceURL)
        let client = MLXLMRecordingClient(listed: [snapshot.path])
        let ref = "mlxlm:" + snapshot.lastPathComponent

        let plain = await BYOMDiscoveryRunner(environment: environment, httpClient: client).discover()
        XCTAssertFalse(plain.candidates.contains { $0.runtimeSource == "mlxlm_loopback" }, "discover() itself is unchanged")
        let all = await BYOMDiscoveryRunner(environment: environment, httpClient: client).discoverIncludingMLXLM()
        let candidate = try XCTUnwrap(all.candidates.first { $0.runtimeSource == "mlxlm_loopback" })
        XCTAssertEqual(candidate.servedModelRef, ref)
        XCTAssertTrue(all.adapters.contains { $0.runtimeSource == "mlxlm_loopback" && $0.status == "ok" })

        let dryRun = await BYOMOfferDryRunRunner(target: ref, environment: environment, httpClient: client).dryRun()
        XCTAssertEqual(dryRun.servedModelRef, ref)

        let runtime = BYOMModelAdmissionRuntime(environment: environment, client: nil, httpClient: client)
        for target in [candidate.candidateID, ref, candidate.displayName] {
            let resolved = await runtime.mlxlmCandidate(target: target)
            XCTAssertEqual(resolved?.candidateID, candidate.candidateID, "target form \(target)")
        }
        let other = await runtime.mlxlmCandidate(target: "ollama:qwen2.5:0.5b")
        XCTAssertNil(other)
    }
}

private final class MLXLMRecordingClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var listed: [String]
    private var bodies: [Data] = []

    init(listed: [String]) { self.listed = listed }

    func setListed(_ ids: [String]) { lock.lock(); listed = ids; lock.unlock() }
    var chatBodies: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard url.path == "/v1/models" else { return BYOMHTTPResponse(statusCode: 404, headers: [], body: Data()) }
        lock.lock()
        let ids = listed
        lock.unlock()
        let body: [String: Any] = ["object": "list", "data": ids.map { ["id": $0, "object": "model"] }]
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: try JSONSerialization.data(withJSONObject: body))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.lock()
        bodies.append(jsonBody)
        lock.unlock()
        let reply = #"{"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}"#
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(reply.utf8))
    }
}

// #1690 M8 audit R2 CODE M1: every snapshot walk is bounded by the deadline
// and a file-count cap, and fails closed on overrun.
final class MLXLMLoopbackAuditR2Tests: XCTestCase {
    private func makeTree(files: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlxlm-r2-\(UUID().uuidString)")
        for i in 0..<files {
            let dir = root.appendingPathComponent("d\(i % 16)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("\(i)".utf8).write(to: dir.appendingPathComponent("f\(i).json"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    func testExpiredDeadlineFailsTheScanClosed() throws {
        let root = try makeTree(files: 8)
        let past = Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try MLXSnapshotIdentity.stamps(of: root, deadline: past)) { error in
            XCTAssertEqual(error as? AutotuneContextCalibrationError, .deadlineExceeded)
        }
        XCTAssertThrowsError(try MLXSnapshotIdentity.compute(directory: root, deadline: past)) { error in
            XCTAssertEqual(error as? AutotuneContextCalibrationError, .deadlineExceeded)
        }
        let identity = try MLXSnapshotIdentity.compute(directory: root)
        XCTAssertTrue(identity.isCurrent())
        XCTAssertFalse(identity.isCurrent(deadline: past), "an overrun revalidation fails closed")
    }

    func testLargeTreeIsWalkedAndTheFileCapFailsClosed() throws {
        let root = try makeTree(files: 2000)
        let identity = try MLXSnapshotIdentity.compute(directory: root, deadline: Date().addingTimeInterval(120))
        XCTAssertEqual(identity.files.count, 2000)
        XCTAssertTrue(identity.isCurrent())
        XCTAssertThrowsError(try MLXSnapshotIdentity.stamps(of: root, deadline: nil, maxFiles: 1999))
        try Data("x".utf8).write(to: root.appendingPathComponent("d0/extra.json"))
        XCTAssertFalse(identity.isCurrent(), "one file past the hashed set stops the walk and fails closed")
    }
}

// #1690 M8 audit R3: serve-time snapshot hashing is bounded by the BYOM
// artifact hashing budget and fails startup closed on overrun.
final class MLXLMLoopbackAuditR3Tests: XCTestCase {
    func testServeTimeHashingUsesTheArtifactBudgetAndFailsClosedOnOverrun() async throws {
        let now = Date()
        XCTAssertEqual(
            MLXLMLoopbackServeModel.snapshotHashingDeadline(now: now),
            now.addingTimeInterval(BYOMModelAdmissionRuntime.artifactHashBudgetSeconds)
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlxlm-r3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x42, count: 4096).write(to: root.appendingPathComponent("model.safetensors"))
        let snapshot = root.resolvingSymlinksInPath().standardizedFileURL
        let client = MLXLMRecordingClientR3(listed: [snapshot.path])
        do {
            _ = try await OpenAICompatibleLoopbackRuntime.mlxLM(
                servedModelRef: "mlxlm:" + snapshot.lastPathComponent, origin: "http://127.0.0.1:9191",
                snapshotDirectory: snapshot, httpClient: client, deadline: Date().addingTimeInterval(-1)
            )
            XCTFail("an expired serve-time hashing deadline must fail startup closed")
        } catch let OpenAICompatibleLoopbackRuntimeError.artifactResolutionFailed(reason) {
            XCTAssertTrue(reason.contains("artifact hashing budget"), reason)
        }
        // The default deadline serves a normal snapshot.
        let runtime = try await OpenAICompatibleLoopbackRuntime.mlxLM(
            servedModelRef: "mlxlm:" + snapshot.lastPathComponent, origin: "http://127.0.0.1:9191",
            snapshotDirectory: snapshot, httpClient: client
        )
        let hash = await runtime.loadedModelHash
        XCTAssertNotNil(hash)
    }
}

private final class MLXLMRecordingClientR3: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    let listed: [String]
    init(listed: [String]) { self.listed = listed }
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        let body: [String: Any] = ["object": "list", "data": listed.map { ["id": $0, "object": "model"] }]
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: try JSONSerialization.data(withJSONObject: body))
    }
    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        BYOMHTTPResponse(statusCode: 500, headers: [], body: Data())
    }
}

/// Answers `GET /v1/models` per port the way mlx_lm.server 0.31-0.32 does
/// (Python `http.server`, entries of id/object/created only), or, for the
/// ports in `foreign`, the way another OpenAI-compatible server does.
private final class MLXLMPortStubClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let listings: [Int: [String]]
    private let foreign: Set<Int>

    init(listings: [Int: [String]], foreign: Set<Int> = []) {
        self.listings = listings
        self.foreign = foreign
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard url.path == "/v1/models", let port = url.port, let ids = listings[port] else {
            throw URLError(.cannotConnectToHost)
        }
        if foreign.contains(port) {
            let body: [String: Any] = ["object": "list", "data": ids.map { ["id": $0, "object": "model", "created": 1_700_000_000, "owned_by": "organization-owner"] }]
            return BYOMHTTPResponse(statusCode: 200, headers: [("Server", "uvicorn")], body: try JSONSerialization.data(withJSONObject: body))
        }
        let body: [String: Any] = ["object": "list", "data": ids.map { ["id": $0, "object": "model", "created": 1_700_000_000] }]
        return BYOMHTTPResponse(statusCode: 200, headers: [("Server", "BaseHTTP/0.6 Python/3.12.8")], body: try JSONSerialization.data(withJSONObject: body))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        BYOMHTTPResponse(statusCode: 500, headers: [], body: Data())
    }
}
