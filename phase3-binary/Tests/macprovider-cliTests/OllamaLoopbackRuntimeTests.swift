import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli
import MacProviderCore

/// Issue #1569 CLI side: `macprovider-cli serve` can run an `ollama_loopback`
/// GGUF on ONE live session, proxy the coordinator synthetic probe to the
/// validated loopback Ollama origin, and relay real tokens back. Non-earning.
final class OllamaLoopbackRuntimeTests: XCTestCase {
    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    /// A fake Ollama store (mirrors BYOMArtifactDigestTests): a manifest naming a
    /// model layer whose digest LOCATES the blob. `locator` may lie to prove the
    /// CLI hashes the bytes, never the manifest digest.
    private func makeStore(
        name: String = "gemma3",
        tag: String = "270m",
        blob: Data = Data("GGUF".utf8) + Data(repeating: 0xab, count: 4096),
        locator: String? = nil
    ) throws -> (root: URL, cacheURL: URL, blob: Data, locatorHex: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("byom-ollama-serve-\(UUID().uuidString)")
        let locatorHex = locator ?? Self.sha256Hex(blob)
        let blobURL = root.appendingPathComponent("blobs/sha256-\(locatorHex)")
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: blobURL)
        let manifestURL = root.appendingPathComponent("manifests/registry.ollama.ai/library/\(name)/\(tag)")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = """
        {"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:\(String(repeating: "0", count: 64))","size":1},"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:\(locatorHex)","size":\(blob.count)}]}
        """
        try Data(manifest.utf8).write(to: manifestURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("cache/artifact-digests.json"), blob, locatorHex)
    }

    private func makeResolver(_ store: (root: URL, cacheURL: URL, blob: Data, locatorHex: String)) -> BYOMArtifactDigestResolver {
        BYOMArtifactDigestResolver(store: BYOMOllamaModelStore(root: store.root), cache: BYOMArtifactDigestCache(url: store.cacheURL))
    }

    private func makeRuntime(
        servedModelRef: String = "ollama:gemma3:270m",
        origin: String = "http://127.0.0.1:11434",
        httpClient: any BYOMDiscoveryHTTPClient,
        store: (root: URL, cacheURL: URL, blob: Data, locatorHex: String)
    ) throws -> OllamaLoopbackRuntime {
        try OllamaLoopbackRuntime(
            servedModelRef: servedModelRef,
            origin: origin,
            httpClient: httpClient,
            digestResolver: makeResolver(store)
        )
    }

    private func makeRequest(model: String, content: String = "Reply with ok.", maxTokens: Int = 4) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "max_tokens": maxTokens,
            "stream": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try ChatCompletionRequest.parse(data: data)
    }

    private static func completionJSON(content: String, completionTokens: Int, promptTokens: Int = 9) -> Data {
        Data("""
        {"id":"chatcmpl-x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"\(content)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":\(promptTokens),"completion_tokens":\(completionTokens),"total_tokens":\(promptTokens + completionTokens)}}
        """.utf8)
    }

    // MARK: Loopback-origin rejection (SPEC-046-R002)

    func testConstructionRejectsNonLoopbackOrigins() throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Data("{}".utf8))
        for origin in [
            "http://192.168.1.5:11434",   // LAN / private-non-loopback
            "http://93.184.216.34:11434", // public
            "http://ollama.local:11434",  // hostname
            "http://0.0.0.0:11434",       // wildcard
            "http://169.254.1.1:11434",   // link-local
            "unix:///tmp/ollama.sock",    // unix-socket
            "https://127.0.0.1:11434",    // non-http scheme
            "http://127.0.0.1:11434/v1",  // path-bearing origin
        ] {
            XCTAssertThrowsError(try makeRuntime(origin: origin, httpClient: client, store: store), origin) { error in
                XCTAssertEqual(error as? OllamaLoopbackRuntimeError, .invalidLoopbackOrigin(origin), origin)
            }
        }
    }

    func testValidLoopbackOriginsAreAccepted() throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Data("{}".utf8))
        for origin in ["http://127.0.0.1:11434", "http://[::1]:11434", "http://127.5.5.5:9999"] {
            XCTAssertNoThrow(try makeRuntime(origin: origin, httpClient: client, store: store), origin)
        }
    }

    func testServeHTTPClientRefusesNonLoopbackURL() async {
        let client = OllamaLoopbackServeHTTPClient()
        let url = URL(string: "http://192.168.1.5:11434/v1/chat/completions")!
        do {
            _ = try await client.post(url, jsonBody: Data("{}".utf8), maxHeaderBytes: 4096, maxBodyBytes: 4096)
            XCTFail("serve HTTP client must refuse a non-loopback URL")
        } catch {
            XCTAssertEqual(error as? BYOMDiscoveryAdapterError, .rejectedNonLoopback)
        }
    }

    // MARK: Identity — hash over file bytes, never the ollama manifest digest

    func testReportedHashIsFileBytesSHA256NotManifestDigest() async throws {
        let blob = Data("GGUF".utf8) + Data(repeating: 0xcd, count: 8192)
        let lyingLocator = String(repeating: "f", count: 64)
        let store = try makeStore(blob: blob, locator: lyingLocator)
        let runtime = try makeRuntime(httpClient: StubLoopbackHTTPClient(responseBody: Data("{}".utf8)), store: store)

        let expectedDigest = Self.sha256Hex(blob)
        let hash = await runtime.loadedModelHash
        let algorithm = await runtime.loadedModelHashAlgorithm
        XCTAssertEqual(hash, expectedDigest, "hash is SHA-256 over the complete GGUF file bytes")
        XCTAssertEqual(algorithm, ModelArtifactIdentity.ggufFileV1)
        XCTAssertEqual(algorithm, "macprovider.gguf-file.v1")
        XCTAssertNotEqual(hash, lyingLocator, "the Ollama manifest layer digest is a locator, never the reported hash")

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.modelID, "ollama:gemma3:270m")
        XCTAssertEqual(snapshot.modelHash, expectedDigest)
        XCTAssertEqual(snapshot.modelHashAlgorithm, ModelArtifactIdentity.ggufFileV1)
    }

    func testConstructionFailsClosedWhenBlobIsNotGGUF() throws {
        // A blob without the GGUF magic must fail closed rather than report a hash.
        let store = try makeStore(blob: Data(repeating: 0x00, count: 4096))
        XCTAssertThrowsError(try makeRuntime(httpClient: StubLoopbackHTTPClient(responseBody: Data("{}".utf8)), store: store)) { error in
            guard case .artifactResolutionFailed = (error as? OllamaLoopbackRuntimeError) else {
                return XCTFail("expected artifactResolutionFailed, got \(error)")
            }
        }
    }

    // MARK: Relay of a stubbed loopback completion onto the wire

    func testCompleteRelaysUpstreamCompletionWithTokens() async throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Self.completionJSON(content: "ok", completionTokens: 3, promptTokens: 11))
        let runtime = try makeRuntime(httpClient: client, store: store)

        let result = try await runtime.complete(try makeRequest(model: "ollama:gemma3:270m"))
        XCTAssertEqual(result.content, "ok")
        XCTAssertGreaterThan(result.completionTokens, 0)
        XCTAssertEqual(result.completionTokens, 3)
        XCTAssertEqual(result.promptTokens, 11)
        XCTAssertEqual(result.finishReason, "stop")

        // Closed allowlist: only POST <origin>/v1/chat/completions, and the
        // upstream body carries the stripped ollama tag, not the served ref.
        XCTAssertEqual(client.lastURL?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        let sentBody = try XCTUnwrap(client.lastBody)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        XCTAssertEqual(sent["model"] as? String, "gemma3:270m")
        XCTAssertEqual(sent["stream"] as? Bool, false)
    }

    func testStreamSurfacesVisibleOutputChunk() async throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Self.completionJSON(content: "ok", completionTokens: 2))
        let runtime = try makeRuntime(httpClient: client, store: store)

        let request = try makeRequest(model: "ollama:gemma3:270m")
        let handle = try await runtime.acquireRequestHandle(request)
        let collector = ChunkCollector()
        let result = try await runtime.stream(request, with: handle) { chunk in
            collector.record(chunk)
        }
        XCTAssertEqual(result.completionTokens, 2)
        // warmupChunkHasOutput needs visible content in a surfaced chunk.
        XCTAssertTrue(collector.hasVisibleContent, "stream must surface visible output for the warm-up probe")
    }

    // MARK: Probe model match — served_model_ref alias, and Gemma != Llama

    func testProbeModelMustEqualServedModelRef() async throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Self.completionJSON(content: "ok", completionTokens: 1))
        let runtime = try makeRuntime(servedModelRef: "ollama:gemma3:270m", httpClient: client, store: store)

        // The served ref matches (probe body uses `"model": served_model_ref`).
        do {
            _ = try await runtime.acquireRequestHandle(try makeRequest(model: "ollama:gemma3:270m"))
        } catch {
            XCTFail("served ref matching the session must be accepted: \(error)")
        }

        // A different served ref (a Llama probe against a Gemma session) is 404,
        // and never reaches the upstream loopback.
        do {
            _ = try await runtime.complete(try makeRequest(model: "ollama:llama3:8b"))
            XCTFail("a mismatched model id must not be served")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "model_not_found")
        }
        XCTAssertEqual(client.postCount, 0, "a rejected model must not reach the loopback origin")
    }

    // MARK: Uncatalogued serve stays up and is NOT buyer-serving

    func testOllamaLoopbackServeSkipsCatalogPreflightAndStaysUncatalogued() async throws {
        var config = AppConfig.defaults()
        config.model = "ollama:gemma3:270m"
        // With no model_artifact_sha256, an MLX model joining the coordinator
        // would exit(2). The loopback path must instead be admitted as an
        // uncatalogued, route-excluded sandbox session: no catalog trust, so no
        // catalog metadata is minted and it never becomes buyer-serving.
        let trust = try await ServeCommand.runModelArtifactPreflight(&config, joiningCoordinator: true)
        XCTAssertNil(trust, "ollama_loopback serve carries no catalog trust (uncatalogued, non-earning)")
    }

    func testServeModelHelpers() {
        XCTAssertTrue(OllamaLoopbackServeModel.isOllamaLoopbackRef("ollama:gemma3:270m"))
        XCTAssertFalse(OllamaLoopbackServeModel.isOllamaLoopbackRef("mlx-community/Qwen3-8B"))
        XCTAssertEqual(OllamaLoopbackServeModel.upstreamModelName(fromServedRef: "ollama:gemma3:270m"), "gemma3:270m")
        XCTAssertEqual(OllamaLoopbackServeModel.runtimeSource, "ollama_loopback")
        XCTAssertEqual(
            OllamaLoopbackServeModel.resolveOrigin(environment: ["MACPROVIDER_OLLAMA_ORIGIN": "http://127.0.0.1:9000"]),
            "http://127.0.0.1:9000"
        )
        XCTAssertEqual(OllamaLoopbackServeModel.resolveOrigin(environment: [:]), "http://127.0.0.1:11434")
    }
}

private final class StubLoopbackHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    let statusCode: Int
    let responseBody: Data
    private let lock = NSLock()
    private var _lastURL: URL?
    private var _lastBody: Data?
    private var _postCount = 0

    init(statusCode: Int = 200, responseBody: Data) {
        self.statusCode = statusCode
        self.responseBody = responseBody
    }

    var lastURL: URL? { lock.lock(); defer { lock.unlock() }; return _lastURL }
    var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return _lastBody }
    var postCount: Int { lock.lock(); defer { lock.unlock() }; return _postCount }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.lock()
        _lastURL = url
        _lastBody = jsonBody
        _postCount += 1
        lock.unlock()
        return BYOMHTTPResponse(statusCode: statusCode, headers: [], body: responseBody)
    }
}

private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String] = []

    func record(_ chunk: StreamChunk) {
        guard case .content(let text) = chunk else { return }
        lock.lock()
        contents.append(text)
        lock.unlock()
    }

    var hasVisibleContent: Bool {
        lock.lock(); defer { lock.unlock() }
        return contents.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
