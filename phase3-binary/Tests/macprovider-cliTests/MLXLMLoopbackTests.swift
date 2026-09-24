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

// #1690 M8 audit R1: offer pipeline, request-path identity, descriptor-bound
// hashing (CODE H1-H3/M4/L5, SECURITY M1).
final class MLXLMLoopbackAuditR1Tests: XCTestCase {
    private func makeSnapshot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlxlm-r1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
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
