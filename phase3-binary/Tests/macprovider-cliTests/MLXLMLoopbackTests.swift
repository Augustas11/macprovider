import Foundation
import XCTest
@testable import macprovider_cli
import MacProviderCore

/// SPEC-010-R009 / SPEC-046 v0.3.0 (#1690 M8): `mlxlm:` serves through
/// mlx_lm.server as `mlxlm_loopback`, reporting the CLI-computed
/// snapshot-manifest pair of the operator-declared snapshot directory.
final class MLXLMLoopbackTests: XCTestCase {
    private func makeSnapshot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlxlm-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
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
        XCTAssertNil(LoopbackServeSelection.select("omlx:foo"), "oMLX has no identity leg")
        XCTAssertTrue(CoordinatorClient.isBYOMLoopbackRuntimeSource("mlxlm_loopback"))
        XCTAssertEqual(ArtifactFeed.identityMatrix["mlx_safetensors"]?.runtimeSources, ["mlx_cache", "mlxlm_loopback"])
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
