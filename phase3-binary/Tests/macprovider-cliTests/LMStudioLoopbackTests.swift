import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli
import MacProviderCore

/// #1690 M9: `lmstudio_loopback` serving (SPEC-046-R009, SPEC-010-R007(i)).
/// The CLI hashes the one GGUF its LM Studio models root resolves for the
/// model key; LM Studio's `/api/v1/models` must list that key loaded, as a
/// `gguf` with the file's publisher and exact size, at startup and before
/// every request.
final class LMStudioLoopbackTests: XCTestCase {
    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeModelsRoot(blob: Data) throws -> (root: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lmstudio-serve-\(UUID().uuidString)")
        let file = root.appendingPathComponent("lmstudio-community/Tiny-1B-Instruct-GGUF/tiny-1b-instruct-q4_k_m.gguf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("cache.json"))
    }

    private func makeRequest(model: String, maxTokens: Int) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Reply with ok."]],
            "max_tokens": maxTokens,
            "stream": false,
        ]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }

    func testSelectionModelKeyAndOrigin() {
        XCTAssertEqual(LoopbackServeSelection.select("lmstudio:qwen2.5-0.5b-instruct"), .lmStudio)
        XCTAssertEqual(LoopbackServeSelection.lmStudio.runtimeSource, "lmstudio_loopback")
        XCTAssertEqual(LMStudioLoopbackServeModel.servedRefPrefix, BYOMLMStudioModelStore.servedModelRefPrefix)
        XCTAssertEqual(LMStudioLoopbackServeModel.runtimeSource, BYOMLMStudioDiscovery.runtimeSource)
        XCTAssertEqual(LMStudioLoopbackServeModel.modelKey(fromServedRef: " lmstudio:qwen2.5-0.5b-instruct "), "qwen2.5-0.5b-instruct")
        XCTAssertEqual(LMStudioLoopbackServeModel.resolveOrigin(configured: nil), "http://127.0.0.1:1234")
        XCTAssertEqual(LMStudioLoopbackServeModel.resolveOrigin(configured: " http://127.0.0.1:19131 "), "http://127.0.0.1:19131")
        XCTAssertEqual(
            LMStudioLoopbackServeModel.binding(modelKey: "k", locator: "pub/repo/file.gguf", sizeBytes: 9),
            LMStudioLoopbackServeModel.Binding(modelKey: "k", publisher: "pub", sizeBytes: 9)
        )
        XCTAssertNil(LMStudioLoopbackServeModel.binding(modelKey: "k", locator: "file.gguf", sizeBytes: 9))
        XCTAssertNil(LMStudioLoopbackServeModel.binding(modelKey: "k", locator: "pub/repo/file.gguf", sizeBytes: 0))
    }

    func testModelsParserAndBindingState() async throws {
        let binding = LMStudioLoopbackServeModel.Binding(modelKey: "tiny-1b-instruct", publisher: "lmstudio-community", sizeBytes: 4100)
        let origin = URL(string: "http://127.0.0.1:1234")!
        func state(_ body: String) async throws -> LMStudioLoopbackServeModel.BindingState {
            try await LMStudioLoopbackServeModel.bindingState(LMStudioStubClient(body: body), origin: origin, binding: binding)
        }
        let loaded = LMStudioStubClient.modelsBody(size: 4100, instances: [8192, 4096])
        var result = try await state(loaded)
        XCTAssertEqual(result, .bound(contextWindow: 8192), "the context of the instance named by the key")
        // #1690 M9 review L1: the key must be a loaded instance's id, and no
        // other entry may expose an instance with that id.
        result = try await state(LMStudioStubClient.modelsBody(size: 4100, instances: [8192], keyInstance: false))
        XCTAssertEqual(result, .notBound, "loaded only under another identifier")
        result = try await state(LMStudioStubClient.modelsBody(size: 4100, instances: [8192], otherExposesKey: true))
        XCTAssertEqual(result, .notBound, "another model answers to the key")
        result = try await state(LMStudioStubClient.modelsBody(size: 4100, instances: []))
        XCTAssertEqual(result, .notBound, "not loaded")
        result = try await state(LMStudioStubClient.modelsBody(size: 4101, instances: [8192]))
        XCTAssertEqual(result, .notBound, "another size is another file")
        result = try await state(LMStudioStubClient.modelsBody(size: 4100, instances: [8192], publisher: "other"))
        XCTAssertEqual(result, .notBound, "another publisher")
        result = try await state(LMStudioStubClient.modelsBody(size: 4100, instances: [8192], format: "mlx"))
        XCTAssertEqual(result, .notBound, "an MLX model is never a GGUF binding")
        do {
            _ = try await state(#"{"data":[{"id":"tiny-1b-instruct"}]}"#)
            XCTFail("an OpenAI-shaped list is not an LM Studio model list")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleLoopbackRuntimeError, .upstreamNotRecognized("lmstudio_loopback"))
        }
    }

    func testRuntimeBindsTheResolvedFileAndFailsClosed() async throws {
        let blob = Data("GGUF".utf8) + Data(repeating: 0x5a, count: 4096)
        let (root, cache) = try makeModelsRoot(blob: blob)
        let client = LMStudioStubClient(body: LMStudioStubClient.modelsBody(size: blob.count, instances: [64]))
        let runtime = try await OpenAICompatibleLoopbackRuntime.lmStudio(
            servedModelRef: "lmstudio:tiny-1b-instruct",
            origin: "http://127.0.0.1:1234",
            modelsRoot: root,
            httpClient: client,
            cache: BYOMArtifactDigestCache(url: cache)
        )
        let hash = await runtime.loadedModelHash
        XCTAssertEqual(hash, Self.sha256Hex(blob), "the CLI's complete-file digest, never a runtime value")
        let algorithm = await runtime.loadedModelHashAlgorithm
        XCTAssertEqual(algorithm, "macprovider.gguf-file.v1")
        let runtimeSource = await runtime.runtimeSource
        XCTAssertEqual(runtimeSource, "lmstudio_loopback")
        XCTAssertFalse(runtime.isSettlementReceiptEligible, "LM Studio loopback stays non-earning outside a pool (#1695)")

        let fits = try makeRequest(model: "lmstudio:tiny-1b-instruct", maxTokens: 16)
        try await runtime.preflight(fits, with: try await runtime.acquireRequestHandle(fits))
        let over = try makeRequest(model: "lmstudio:tiny-1b-instruct", maxTokens: 65)
        do {
            try await runtime.preflight(over, with: try await runtime.acquireRequestHandle(over))
            XCTFail("max_tokens beyond the loaded context must fail preflight")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 413)
        }

        // LM Studio now lists another file for the key (another size), or
        // the model is unloaded: every request fails closed.
        for body in [
            LMStudioStubClient.modelsBody(size: blob.count + 1, instances: [64]),
            LMStudioStubClient.modelsBody(size: blob.count, instances: []),
        ] {
            client.setBody(body)
            do {
                try await runtime.preflight(fits, with: try await runtime.acquireRequestHandle(fits))
                XCTFail("a re-pointed or unloaded LM Studio model must fail closed")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "model_not_loaded")
            }
        }
        XCTAssertEqual(client.chatPosts, 0, "preflight never reaches chat completions")
    }

    func testRuntimeRefusesAnUnboundOrUnresolvedModel() async throws {
        let blob = Data("GGUF".utf8) + Data(repeating: 0x33, count: 2048)
        let (root, cache) = try makeModelsRoot(blob: blob)
        let cases: [(ref: String, body: String, expected: String)] = [
            ("lmstudio:tiny-1b-instruct", LMStudioStubClient.modelsBody(size: blob.count, instances: [], publisher: "lmstudio-community"), "unloaded"),
            ("lmstudio:tiny-1b-instruct", LMStudioStubClient.modelsBody(size: blob.count, instances: [64], publisher: "someone-else"), "publisher"),
            ("lmstudio:no-such-model", LMStudioStubClient.modelsBody(size: blob.count, instances: [64]), "no file"),
        ]
        for testCase in cases {
            do {
                _ = try await OpenAICompatibleLoopbackRuntime.lmStudio(
                    servedModelRef: testCase.ref,
                    origin: "http://127.0.0.1:1234",
                    modelsRoot: root,
                    httpClient: LMStudioStubClient(body: testCase.body),
                    cache: BYOMArtifactDigestCache(url: cache)
                )
                XCTFail("\(testCase.expected): must fail closed")
            } catch let error as OpenAICompatibleLoopbackRuntimeError {
                switch error {
                case .upstreamNotRecognized, .artifactResolutionFailed: break
                default: XCTFail("\(testCase.expected): unexpected \(error)")
                }
            }
        }
        do {
            _ = try await OpenAICompatibleLoopbackRuntime.lmStudio(
                servedModelRef: "lmstudio:tiny-1b-instruct",
                origin: "http://192.168.1.5:1234",
                modelsRoot: root,
                httpClient: LMStudioStubClient(body: "{}")
            )
            XCTFail("a non-loopback origin must be refused")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleLoopbackRuntimeError, .invalidLoopbackOrigin("http://192.168.1.5:1234"))
        }
    }

    func testUpstreamRequestNamesTheModelKeyAndAsksForLogprobs() throws {
        let request = try makeRequest(model: "lmstudio:tiny-1b-instruct", maxTokens: 4)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(
            request,
            upstreamModelName: LMStudioLoopbackServeModel.modelKey(fromServedRef: "lmstudio:tiny-1b-instruct"),
            logprobsPerToken: OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("lmstudio_loopback")
        )) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "tiny-1b-instruct")
        XCTAssertEqual(body["logprobs"] as? Bool, true)
    }

    // #1690 M9 lab finding: LM Studio answers 400 "logprobs is not supported
    // with tools + stream", which failed every tool-call request (502 or a
    // malformed stream). A request with tools asks LM Studio for no logprobs.
    func testToolRequestsAskLMStudioForNoLogprobs() {
        XCTAssertFalse(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("lmstudio_loopback", hasTools: true))
        XCTAssertTrue(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("lmstudio_loopback", hasTools: false))
        XCTAssertTrue(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("ollama_loopback", hasTools: true), "Ollama streams logprobs with tools")
    }
}

/// An LM Studio stand-in: `GET /api/v1/models` answers the configured body;
/// chat-completion posts are counted and refused.
private final class LMStudioStubClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var body: String
    private var _chatPosts = 0

    init(body: String) {
        self.body = body
    }

    var chatPosts: Int { lock.lock(); defer { lock.unlock() }; return _chatPosts }
    func setBody(_ value: String) { lock.lock(); body = value; lock.unlock() }

    /// The first loaded instance is named by the key unless `keyInstance` is
    /// false; `otherExposesKey` gives another entry an instance with that id.
    static func modelsBody(
        size: Int,
        instances: [Int],
        publisher: String = "lmstudio-community",
        format: String = "gguf",
        keyInstance: Bool = true,
        otherExposesKey: Bool = false
    ) -> String {
        let loaded = instances.enumerated().map { item -> String in
            let id = item.offset == 0 && keyInstance ? "tiny-1b-instruct" : "inst-\(item.offset)"
            return #"{"id":""# + id + #"","config":{"context_length":"# + "\(item.element)" + "}}"
        }.joined(separator: ",")
        let other = otherExposesKey ? #"{"id":"tiny-1b-instruct","config":{"context_length":64}}"# : ""
        return #"{"models":[{"type":"llm","publisher":""# + publisher + #"","key":"tiny-1b-instruct","size_bytes":"# + "\(size)" +
            #","loaded_instances":["# + loaded + #"],"format":""# + format + #""},{"type":"llm","publisher":"other","key":"other-model","size_bytes":10,"loaded_instances":["# +
            other + #"],"format":"gguf"}]}"#
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard url.path == "/api/v1/models" else { return BYOMHTTPResponse(statusCode: 404, headers: [], body: Data()) }
        lock.lock()
        let current = body
        lock.unlock()
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(current.utf8))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.lock()
        _chatPosts += 1
        lock.unlock()
        return BYOMHTTPResponse(statusCode: 500, headers: [], body: Data())
    }
}
