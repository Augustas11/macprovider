import Foundation
import XCTest
@testable import macprovider_cli
import MacProviderCore

/// SPEC-010-R009 / SPEC-046 v0.5.0 (#1690 M9): `omlx:` serves through an oMLX
/// server as `omlx_loopback`, reporting the CLI-computed snapshot-manifest
/// pair of the operator-declared snapshot directory, bound to the oMLX
/// `GET /v1/models/status` entry whose `model_path` is that directory.
final class OMLXLoopbackTests: XCTestCase {
    private func makeSnapshot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("omlx-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("omlx-snapshot")
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
        XCTAssertEqual(LoopbackServeSelection.select("omlx:Qwen2.5-0.5B-Instruct-4bit"), .oMLX)
        XCTAssertEqual(LoopbackServeSelection.oMLX.runtimeSource, "omlx_loopback")
        XCTAssertTrue(CoordinatorClient.isBYOMLoopbackRuntimeSource("omlx_loopback"))
        XCTAssertTrue(ArtifactFeed.identityMatrix["mlx_safetensors"]?.runtimeSources.contains("omlx_loopback") ?? false)
        XCTAssertFalse(ArtifactFeed.identityMatrix["gguf"]?.runtimeSources.contains("omlx_loopback") ?? true)
        XCTAssertTrue(LoopbackServeHTTPClient.isAllowed(URL(string: "http://127.0.0.1:8000/v1/models/status")!, method: "GET"))
        XCTAssertFalse(LoopbackServeHTTPClient.isAllowed(URL(string: "http://127.0.0.1:8000/v1/models/x/load")!, method: "POST"))
        XCTAssertEqual(OMLXLoopbackServeModel.resolveOrigin(configured: nil, environment: [:]), "http://127.0.0.1:8000")
        XCTAssertEqual(
            OMLXLoopbackServeModel.resolveOrigin(configured: nil, environment: ["MACPROVIDER_OMLX_ORIGIN": "http://127.0.0.1:19142"]),
            "http://127.0.0.1:19142"
        )
        XCTAssertNil(OMLXLoopbackServeModel.snapshotDirectory(environment: ["MACPROVIDER_OMLX_MODEL_PATH": "relative/dir"]))
        XCTAssertTrue(OpenAICompatibleLoopbackRuntime.servesMLXSnapshots("omlx_loopback"))
        XCTAssertFalse(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("omlx_loopback"), "oMLX streams no logprobs")
        XCTAssertEqual(MLXSnapshotLoopbackKind.kind(forRuntimeSource: "omlx_loopback"), .oMLX)
        XCTAssertNil(MLXSnapshotLoopbackKind.kind(forRuntimeSource: "llamacpp_loopback"))
    }

    func testStatusBindingNeedsOneLocalLLMEntryForTheDirectory() async throws {
        let snapshot = try makeSnapshot()
        let origin = URL(string: "http://127.0.0.1:8000")!
        func id(_ entries: [[String: Any]]) async throws -> String? {
            try await OMLXLoopbackServeModel.servedModelID(OMLXStubClient(entries: entries), origin: origin, directory: snapshot)
        }
        var result = try await id([OMLXStubClient.entry(id: "qwen", path: snapshot.path)])
        XCTAssertEqual(result, "qwen")
        result = try await id([OMLXStubClient.entry(id: "qwen", path: "/somewhere/else")])
        XCTAssertNil(result, "another directory")
        result = try await id([OMLXStubClient.entry(id: "qwen", path: snapshot.path, type: "embedding")])
        XCTAssertNil(result, "not an llm")
        result = try await id([OMLXStubClient.entry(id: "qwen", path: snapshot.path, distributed: true)])
        XCTAssertNil(result, "a distributed deployment is not the local snapshot")
        result = try await id([
            OMLXStubClient.entry(id: "a", path: snapshot.path), OMLXStubClient.entry(id: "b", path: snapshot.path),
        ])
        XCTAssertNil(result, "two ids for one directory are ambiguous")
        do {
            _ = try await OMLXLoopbackServeModel.servedModelID(OMLXStubClient(entries: [], status: 401), origin: origin, directory: snapshot)
            XCTFail("an API-key protected oMLX is not usable")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleLoopbackRuntimeError, .upstreamNotRecognized("omlx_loopback"))
        }
    }

    func testRuntimeReportsTheSnapshotPairAndBindsTheStatusEntry() async throws {
        let snapshot = try makeSnapshot()
        let client = OMLXStubClient(entries: [
            OMLXStubClient.entry(id: "omlx-snapshot", path: snapshot.path),
            OMLXStubClient.entry(id: "other", path: "/models/other"),
        ])
        let runtime = try await OpenAICompatibleLoopbackRuntime.oMLX(
            servedModelRef: "omlx:" + snapshot.lastPathComponent,
            origin: "http://127.0.0.1:8000",
            snapshotDirectory: snapshot,
            httpClient: client
        )
        let hash = await runtime.loadedModelHash
        let algorithm = await runtime.loadedModelHashAlgorithm
        XCTAssertEqual(hash, try ModelArtifactVerifier.canonicalArtifactHash(directory: snapshot))
        XCTAssertEqual(algorithm, "macprovider.snapshot-manifest.v1")
        XCTAssertEqual(runtime.settlementRuntimeSource, "omlx_loopback")
        XCTAssertFalse(runtime.isSettlementReceiptEligible)

        let request = try makeRequest(model: "omlx:" + snapshot.lastPathComponent)
        try await runtime.preflight(request, with: try await runtime.acquireRequestHandle(request))

        // oMLX serving the directory under another id, or not at all, fails closed.
        for entries in [[OMLXStubClient.entry(id: "renamed", path: snapshot.path)], [OMLXStubClient.entry(id: "other", path: "/models/other")]] {
            client.setEntries(entries)
            do {
                try await runtime.preflight(request, with: try await runtime.acquireRequestHandle(request))
                XCTFail("an oMLX that stopped serving the snapshot under its id must fail closed")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "model_not_loaded")
            }
        }
    }

    func testRuntimeFailsClosedWithoutADeclaredOrListedSnapshot() async throws {
        let snapshot = try makeSnapshot()
        do {
            _ = try await OpenAICompatibleLoopbackRuntime.oMLX(
                servedModelRef: "omlx:x", origin: "http://127.0.0.1:8000", snapshotDirectory: nil,
                httpClient: OMLXStubClient(entries: [OMLXStubClient.entry(id: "x", path: snapshot.path)])
            )
            XCTFail("no declared snapshot must fail closed")
        } catch let error as OpenAICompatibleLoopbackRuntimeError {
            guard case .artifactResolutionFailed = error else { return XCTFail("unexpected \(error)") }
        }
        do {
            _ = try await OpenAICompatibleLoopbackRuntime.oMLX(
                servedModelRef: "omlx:x", origin: "http://127.0.0.1:8000", snapshotDirectory: snapshot,
                httpClient: OMLXStubClient(entries: [OMLXStubClient.entry(id: "x", path: "/elsewhere")])
            )
            XCTFail("a runtime that does not list the snapshot must be refused")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleLoopbackRuntimeError, .upstreamNotRecognized("omlx_loopback"))
        }
        // omlx_loopback always carries an MLX snapshot and a model id.
        XCTAssertThrowsError(try OpenAICompatibleLoopbackRuntime(
            servedModelRef: "omlx:x", origin: "http://127.0.0.1:8000", runtimeSource: "omlx_loopback",
            mlxSnapshot: try MLXSnapshotIdentity.compute(directory: snapshot)
        ), "no model id")
    }

    func testDiscoveryReportsOnlyTheListedDeclaredSnapshotAsOMLX() async throws {
        let snapshot = try makeSnapshot()
        let listed = await BYOMMLXLMDiscovery(
            origin: "http://127.0.0.1:8000", snapshotDirectory: snapshot, namespace: Data(repeating: 7, count: 32),
            httpClient: OMLXStubClient(entries: [OMLXStubClient.entry(id: "omlx-snapshot", path: snapshot.path)]),
            kind: .oMLX
        ).discover()
        XCTAssertEqual(listed.adapter.status, "ok")
        XCTAssertEqual(listed.adapter.runtimeSource, "omlx_loopback")
        XCTAssertEqual(listed.candidates.map(\.servedModelRef), ["omlx:" + snapshot.lastPathComponent])
        XCTAssertEqual(listed.candidates.first?.runtimeSource, "omlx_loopback")

        let other = await BYOMMLXLMDiscovery(
            origin: "http://127.0.0.1:8000", snapshotDirectory: snapshot, namespace: Data(repeating: 7, count: 32),
            httpClient: OMLXStubClient(entries: [OMLXStubClient.entry(id: "x", path: "/elsewhere")]),
            kind: .oMLX
        ).discover()
        XCTAssertTrue(other.candidates.isEmpty)
    }

    func testPoolUsageGuardAppliesToOMLX() {
        let auth = PoolRuntimeAuthorization(wire: [
            "pool_id": "p", "manifest_core_digest": String(repeating: "a", count: 64), "runtime_source": "omlx_loopback",
            "request_id": "r", "attempt_n": 1, "provider_id": "prov", "route_snapshot_digest": String(repeating: "b", count: 64),
        ])!
        XCTAssertTrue(PoolLoopbackUsageGuard.applies(to: auth))
    }
}

/// An oMLX stand-in: `GET /v1/models/status` answers the configured entries.
private final class OMLXStubClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: Any]]
    private let status: Int

    init(entries: [[String: Any]], status: Int = 200) {
        self.entries = entries
        self.status = status
    }

    static func entry(id: String, path: String, type: String = "llm", distributed: Bool = false) -> [String: Any] {
        ["id": id, "model_path": path, "loaded": false, "model_type": type, "engine_type": "batched", "distributed": distributed]
    }

    func setEntries(_ value: [[String: Any]]) { lock.lock(); entries = value; lock.unlock() }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard url.path == "/v1/models/status" else { return BYOMHTTPResponse(statusCode: 404, headers: [], body: Data()) }
        guard status == 200 else { return BYOMHTTPResponse(statusCode: status, headers: [], body: Data(#"{"detail":"unauthorized"}"#.utf8)) }
        lock.lock()
        let models = entries
        lock.unlock()
        let body: [String: Any] = ["model_count": models.count, "models": models]
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: try JSONSerialization.data(withJSONObject: body))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        BYOMHTTPResponse(statusCode: 500, headers: [], body: Data())
    }
}
