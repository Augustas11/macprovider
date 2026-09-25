import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli
import MacProviderCore

/// Issue #1569 CLI side: `macprovider-cli serve` can run an `ollama_loopback`
/// GGUF on ONE live session, proxy the coordinator synthetic probe to the
/// validated loopback Ollama origin, and relay real tokens back. Non-earning.
final class OpenAICompatibleLoopbackRuntimeTests: XCTestCase {
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
    ) throws -> OpenAICompatibleLoopbackRuntime {
        try OpenAICompatibleLoopbackRuntime(
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
                XCTAssertEqual(error as? OpenAICompatibleLoopbackRuntimeError, .invalidLoopbackOrigin(origin), origin)
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
        let client = LoopbackServeHTTPClient()
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
            guard case .artifactResolutionFailed = (error as? OpenAICompatibleLoopbackRuntimeError) else {
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
        // Upstream always streams (cancellation + idle deadlines), even for
        // a non-streamed buyer request; the stub answered with one JSON body.
        XCTAssertEqual(sent["stream"] as? Bool, true)
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
    // MARK: #1690 M2 — SSE framing and line splitting (pure)

    func testSSEParserFramesDataEventsAndIgnoresCommentsAndFields() {
        var parser = LoopbackSSEParser()
        var events: [LoopbackSSEParser.Event] = []
        for line in [": keep-alive", "event: message", "id: 7", "data: {\"a\":1}", "", "data:[DONE]", ""] {
            events += parser.consume(line: line)
        }
        XCTAssertEqual(events, [.data("{\"a\":1}"), .data("[DONE]")])

        // Multi-line data joins with \n; a plain JSON line is reported as non-SSE.
        var multi = LoopbackSSEParser()
        XCTAssertEqual(multi.consume(line: "data: a"), [])
        XCTAssertEqual(multi.consume(line: "data: b"), [])
        XCTAssertEqual(multi.consume(line: ""), [.data("a\nb")])
        XCTAssertEqual(multi.consume(line: "{\"choices\":[]}"), [.nonSSELine("{\"choices\":[]}")])
        // An undispatched event at end-of-body is flushed.
        XCTAssertEqual(multi.consume(line: "data: tail"), [])
        XCTAssertEqual(multi.flush(), [.data("tail")])
    }

    func testLineSplitterKeepsBlankLinesStripsCRAndBounds() throws {
        XCTAssertEqual(LoopbackLineSplitter.lines(of: Data("data: x\r\n\r\ndata: y\n\n".utf8)), ["data: x", "", "data: y", ""])
        var lineBound = LoopbackLineSplitter(maxLineBytes: 4, maxTotalBytes: 100)
        for byte in Data("abcd".utf8) { _ = try lineBound.append(byte) }
        XCTAssertThrowsError(try lineBound.append(UInt8(ascii: "e")))
        var totalBound = LoopbackLineSplitter(maxLineBytes: 100, maxTotalBytes: 3)
        for byte in Data("ab\n".utf8) { _ = try totalBound.append(byte) }
        XCTAssertThrowsError(try totalBound.append(UInt8(ascii: "c")))
    }

    // MARK: #1690 M2 — request mapping (pure)

    func testUpstreamRequestForwardsSamplingToolsAndMessageFields() throws {
        let body: [String: Any] = [
            "model": "llamacpp:qwen",
            "messages": [
                ["role": "system", "content": "be terse", "name": "sys"],
                ["role": "user", "content": "weather?"],
                ["role": "assistant", "content": NSNull(), "tool_calls": [
                    ["id": "call_0123456789abcdef", "type": "function", "function": ["name": "get_weather", "arguments": "{\"city\":\"Oslo\"}"]],
                ]],
                ["role": "tool", "tool_call_id": "call_0123456789abcdef", "content": "12C"],
            ],
            "tools": [["type": "function", "function": ["name": "get_weather", "parameters": ["type": "object"]]]],
            "tool_choice": "auto",
            "response_format": ["type": "json_object"],
            "stop": ["END"],
            "top_p": 0.5,
            "seed": 42,
            "presence_penalty": 0.25,
            "frequency_penalty": -0.5,
            "temperature": 0.2,
            "max_tokens": 64,
            "parallel_tool_calls": false,
        ]
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
        let data = try OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(request, upstreamModelName: "qwen")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(sent["model"] as? String, "qwen")
        XCTAssertEqual(sent["stream"] as? Bool, true)
        XCTAssertEqual((sent["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        XCTAssertEqual(sent["max_tokens"] as? Int, 64)
        XCTAssertEqual(sent["temperature"] as? Double, 0.2)
        XCTAssertEqual(sent["top_p"] as? Double, 0.5)
        XCTAssertEqual(sent["seed"] as? Int, 42)
        XCTAssertEqual(sent["presence_penalty"] as? Double, 0.25)
        XCTAssertEqual(sent["frequency_penalty"] as? Double, -0.5)
        XCTAssertEqual(sent["stop"] as? [String], ["END"])
        XCTAssertEqual((sent["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual(sent["tool_choice"] as? String, "auto")
        XCTAssertEqual((sent["tools"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(sent["parallel_tool_calls"] as? Bool, false)

        let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0]["name"] as? String, "sys")
        XCTAssertTrue(messages[2]["content"] is NSNull, "assistant tool-call turn keeps content null")
        let calls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, "call_0123456789abcdef")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_0123456789abcdef")
    }

    func testUpstreamRequestOmitsAbsentOptionalFields() throws {
        let request = try makeRequest(model: "ollama:gemma3:270m")
        let data = try OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(request, upstreamModelName: "gemma3:270m")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["tools", "tool_choice", "response_format", "stop", "seed", "top_p", "presence_penalty", "frequency_penalty", "parallel_tool_calls"] {
            XCTAssertNil(sent[key], key)
        }
    }

    func testUpstreamRequestCapIsAlignedWithIngestCap() {
        XCTAssertEqual(ChatCompletionRequest.rawBodyByteCap, 4 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(OpenAICompatibleLoopbackRuntime.maxRequestBodyBytes, ChatCompletionRequest.rawBodyByteCap)
    }

    // MARK: #1690 M2 — stream and tool-call decoding (pure)

    func testStreamAccumulatorEmitsContentAndToolCallDeltasIncrementally() throws {
        let ids = IDSequence()
        var accumulator = OpenAICompatibleStreamAccumulator(makeToolCallID: { ids.next() })
        let lines = [
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null}}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":3,"type":"function","function":{"name":"get_weather","arguments":"{\"ci"}}]}}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":3,"function":{"arguments":"ty\":\"Oslo\"}"}}]}}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#, "",
            #"data: {"choices":[],"usage":{"prompt_tokens":17,"completion_tokens":9}}"#, "",
            "data: [DONE]", "",
        ]
        var chunks: [StreamChunk] = []
        for line in lines {
            chunks += try accumulator.consume(line: line)
        }
        XCTAssertTrue(accumulator.isDone)
        let (result, late) = try accumulator.finish()
        XCTAssertTrue(late.isEmpty)

        let contents = chunks.compactMap { chunk -> String? in
            if case .content(let text) = chunk { return text }
            return nil
        }
        XCTAssertEqual(contents, ["Hel", "lo"], "each upstream delta is surfaced as its own chunk")
        let toolDeltas = chunks.compactMap { chunk -> StreamToolCallDelta? in
            if case .toolCallDelta(let delta) = chunk { return delta }
            return nil
        }
        XCTAssertEqual(toolDeltas.count, 2)
        XCTAssertEqual(toolDeltas[0].index, 0, "upstream index 3 is re-indexed densely")
        XCTAssertEqual(toolDeltas[0].id, "call_synth00000000000000001", "a missing upstream id is synthesized on the opening delta")
        XCTAssertEqual(toolDeltas[0].type, "function")
        XCTAssertEqual(toolDeltas[0].functionName, "get_weather")
        XCTAssertNil(toolDeltas[1].id)
        XCTAssertEqual(toolDeltas[1].arguments, #"ty":"Oslo"}"#)

        XCTAssertEqual(result.content, "Hello")
        XCTAssertEqual(result.finishReason, "tool_calls")
        XCTAssertEqual(result.promptTokens, 17)
        XCTAssertEqual(result.completionTokens, 9, "usage is copied from upstream")
        XCTAssertEqual(result.toolCalls, [ToolCall(id: "call_synth00000000000000001", functionName: "get_weather", arguments: #"{"city":"Oslo"}"#)])
        XCTAssertEqual(result.settlementDisposition, .notEligible)
    }

    // #1690 final audit R1 CODE-5: settlement never rests on counts the
    // upstream did not report. Missing or partial usage marks the result
    // usage_unattested; complete usage is copied verbatim and does not depend
    // on how the upstream chunked its deltas.
    private static func streamResult(deltas: [String], usage: String?) throws -> CompletionResult {
        var accumulator = OpenAICompatibleStreamAccumulator()
        for text in deltas {
            _ = try accumulator.consume(line: #"data: {"choices":[{"index":0,"delta":{"content":"# + "\"" + text + "\"" + #"}}]}"#)
            _ = try accumulator.consume(line: "")
        }
        if let usage {
            _ = try accumulator.consume(line: "data: " + usage)
            _ = try accumulator.consume(line: "")
        }
        _ = try accumulator.consume(line: "data: [DONE]")
        _ = try accumulator.consume(line: "")
        return try accumulator.finish().result
    }

    func testStreamAccumulatorMissingOrPartialUpstreamUsageIsUnattested() throws {
        for usage in [nil, #"{"choices":[],"usage":{"prompt_tokens":17}}"#, #"{"choices":[],"usage":{"completion_tokens":9}}"#] {
            let result = try Self.streamResult(deltas: ["Hel", "lo"], usage: usage)
            XCTAssertEqual(result.settlementDisposition, .usageUnattested, usage ?? "no usage")
            XCTAssertEqual(result.content, "Hello")
        }
        let complete = try Self.streamResult(deltas: ["Hel", "lo"], usage: #"{"choices":[],"usage":{"prompt_tokens":17,"completion_tokens":9}}"#)
        XCTAssertEqual(complete.settlementDisposition, .notEligible, "complete upstream usage keeps the pool-authorizable marker")
    }

    func testStreamAccumulatorUsageIsChunkBoundaryInvariant() throws {
        let usage = #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3}}"#
        let whole = try Self.streamResult(deltas: ["abc"], usage: usage)
        let split = try Self.streamResult(deltas: ["a", "b", "c"], usage: usage)
        XCTAssertEqual(whole.content, split.content)
        XCTAssertEqual(whole.completionTokens, 3)
        XCTAssertEqual(split.completionTokens, 3)
        XCTAssertEqual(whole.promptTokens, split.promptTokens)
        XCTAssertEqual(whole.settlementDisposition, split.settlementDisposition)
    }

    // #1690 E2E-F3: a buyer that disconnects mid-stream is billed the
    // delivered prefix. llama-server `timings_per_token` attests usage on
    // every chunk, so the buyer_cancel usage is the upstream's prompt tokens
    // (processed + cached) and the completion tokens through exactly the
    // delivered content; anything else is unattested (relayed empty, unsigned).
    private static func cancelledStream(_ chunks: [(text: String, timings: String?)]) throws -> CompletionResult {
        var accumulator = OpenAICompatibleStreamAccumulator()
        _ = try accumulator.consume(line: #"data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null}}]}"#)
        _ = try accumulator.consume(line: "")
        for chunk in chunks {
            let timings = chunk.timings.map { #","timings":"# + $0 } ?? ""
            _ = try accumulator.consume(line: #"data: {"choices":[{"index":0,"delta":{"content":""# + chunk.text + #""}}]"# + timings + "}")
            _ = try accumulator.consume(line: "")
        }
        return accumulator.cancelledResult()
    }

    private static func llamaTimings(prompt: Int, cached: Int, predicted: Int) -> String {
        #"{"cache_n":"# + "\(cached)" + #","prompt_n":"# + "\(prompt)" + #","predicted_n":"# + "\(predicted)" + "}"
    }

    func testCancelledLlamaStreamBindsUsageToDeliveredPrefix() throws {
        let result = try Self.cancelledStream([
            ("Hel", Self.llamaTimings(prompt: 1, cached: 36, predicted: 1)),
            ("lo", Self.llamaTimings(prompt: 1, cached: 36, predicted: 2)),
            (" wor", Self.llamaTimings(prompt: 1, cached: 36, predicted: 4)),
        ])
        XCTAssertEqual(result.settlementDisposition, .notEligible)
        XCTAssertEqual(result.content, "Hello wor")

        let prefix = result.cancelledPrefixUsage(deliveredContent: "Hello")
        XCTAssertEqual(prefix.content, "Hello")
        XCTAssertEqual(prefix.promptTokens, 37)
        XCTAssertEqual(prefix.completionTokens, 2)
        XCTAssertEqual(prefix.generatedCompletionTokens, 2)
        XCTAssertEqual(prefix.settlementDisposition, .notEligible)
        let frameUsage = InferenceRelay.usage(prefix)
        XCTAssertEqual(frameUsage["prompt_tokens"] as? Int, 37)
        XCTAssertEqual(frameUsage["completion_tokens"] as? Int, 2)

        let whole = result.cancelledPrefixUsage(deliveredContent: "Hello wor")
        XCTAssertEqual(whole.completionTokens, 4)
        XCTAssertEqual(whole.settlementDisposition, .notEligible)

        let empty = result.cancelledPrefixUsage(deliveredContent: "")
        XCTAssertEqual(empty.completionTokens, 0)
        XCTAssertEqual(empty.promptTokens, 37)
        XCTAssertEqual(empty.settlementDisposition, .notEligible)

        // Not on a chunk boundary, not a prefix, or unknown delivery: unattested.
        for delivered in ["Hell", "Help", nil] as [String?] {
            let unbound = result.cancelledPrefixUsage(deliveredContent: delivered)
            XCTAssertEqual(unbound.settlementDisposition, .usageUnattested, delivered ?? "unknown")
            XCTAssertNil(InferenceRelay.usage(unbound)["completion_tokens"], delivered ?? "unknown")
        }
    }

    func testCancelledStreamWithoutPerTokenUsageIsUnattested() throws {
        // Ollama / mlx_lm.server: no per-chunk usage.
        let plain = try Self.cancelledStream([("Hel", nil), ("lo", nil)])
        XCTAssertEqual(plain.settlementDisposition, .usageUnattested)
        XCTAssertEqual(plain.cancelledPrefixUsage(deliveredContent: "Hel").settlementDisposition, .usageUnattested)
        // One content chunk without timings breaks the whole chain.
        let gap = try Self.cancelledStream([
            ("Hel", Self.llamaTimings(prompt: 5, cached: 0, predicted: 1)),
            ("lo", nil),
        ])
        XCTAssertEqual(gap.settlementDisposition, .usageUnattested)
        XCTAssertEqual(gap.cancelledPrefixUsage(deliveredContent: "Hel").settlementDisposition, .usageUnattested)
    }

    func testNativeCompletionIsUnchangedByCancelledPrefixUsage() {
        let native = CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: 5,
            completionTokens: 2,
            settlementDisposition: .eligibleOwner
        )
        let same = native.cancelledPrefixUsage(deliveredContent: "ans")
        XCTAssertEqual(same.content, "answer")
        XCTAssertEqual(same.completionTokens, 2)
        XCTAssertEqual(same.settlementDisposition, .eligibleOwner)
    }

    func testUpstreamRequestAsksLlamaServerForPerTokenUsageOnly() throws {
        let request = try makeRequest(model: "llamacpp:qwen")
        let llama = try JSONSerialization.jsonObject(with: OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(
            request, upstreamModelName: "qwen", timingsPerToken: true
        )) as? [String: Any]
        XCTAssertEqual(llama?["timings_per_token"] as? Bool, true)
        let other = try JSONSerialization.jsonObject(with: OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(
            request, upstreamModelName: "qwen"
        )) as? [String: Any]
        XCTAssertNil(other?["timings_per_token"])
    }

    func testDecodeUpstreamResponseWithoutCompleteUsageIsUnattested() throws {
        let noUsage = Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try OpenAICompatibleLoopbackRuntime.decodeUpstreamResponse(noUsage).settlementDisposition, .usageUnattested)
        let partial = Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"completion_tokens":2}}"#.utf8)
        XCTAssertEqual(try OpenAICompatibleLoopbackRuntime.decodeUpstreamResponse(partial).settlementDisposition, .usageUnattested)
        let complete = try OpenAICompatibleLoopbackRuntime.decodeUpstreamResponse(Self.completionJSON(content: "ok", completionTokens: 2))
        XCTAssertEqual(complete.settlementDisposition, .notEligible)
        XCTAssertEqual(complete.completionTokens, 2)
    }

    // #1690 final audit R1 CODE-12: bytes of a line still in flight are
    // progress for the idle watchdog; the timeouts copy carries the clock
    // without changing equality.
    func testGenerationTimeoutsCarryTheByteProgressClock() {
        let clock = LoopbackProgressClock(now: Date(timeIntervalSince1970: 0))
        let base = LoopbackGenerationTimeouts(firstByte: 10, idle: 2, overall: 60)
        let tracked = base.withByteProgress(clock)
        XCTAssertEqual(base, tracked)
        XCTAssertTrue(tracked.byteProgress === clock)
        XCTAssertTrue(clock.hasExpired(base, now: Date(timeIntervalSince1970: 11)), "no byte yet: first-byte deadline")
        tracked.byteProgress?.touch(now: Date(timeIntervalSince1970: 9))
        XCTAssertFalse(clock.hasExpired(base, now: Date(timeIntervalSince1970: 10.5)), "a partial line touched the clock")
    }

    func testStreamAccumulatorFallsBackToPlainJSONBody() throws {
        var accumulator = OpenAICompatibleStreamAccumulator()
        for line in LoopbackLineSplitter.lines(of: Self.completionJSON(content: "ok", completionTokens: 2)) {
            XCTAssertTrue(try accumulator.consume(line: line).isEmpty)
        }
        let (result, late) = try accumulator.finish()
        XCTAssertTrue(accumulator.decodedFromPlainBody)
        XCTAssertEqual(result.content, "ok")
        XCTAssertEqual(late.count, 1)
    }

    func testStreamAccumulatorRejectsUpstreamErrorEventAndEmptyBody() {
        var errored = OpenAICompatibleStreamAccumulator()
        XCTAssertNoThrow(try errored.consume(line: #"data: {"error":{"message":"boom"}}"#))
        XCTAssertThrowsError(try errored.consume(line: ""))
        var empty = OpenAICompatibleStreamAccumulator()
        XCTAssertThrowsError(try empty.finish())
    }

    func testDecodeUpstreamResponseAcceptsNullContentWithToolCalls() throws {
        let body = Data(#"""
        {"choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_9876543210fedcba","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Oslo\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":20,"completion_tokens":12}}
        """#.utf8)
        let result = try OpenAICompatibleLoopbackRuntime.decodeUpstreamResponse(body)
        XCTAssertEqual(result.content, "")
        XCTAssertEqual(result.finishReason, "tool_calls")
        XCTAssertEqual(result.toolCalls, [ToolCall(id: "call_9876543210fedcba", functionName: "get_weather", arguments: #"{"city":"Oslo"}"#)])
        XCTAssertEqual(result.completionTokens, 12)

        // Object-valued arguments (some runtimes) are serialized, not rejected.
        let objectArgs = Data(#"{"choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"f","arguments":{"a":1}}}]}}]}"#.utf8)
        let decoded = try OpenAICompatibleLoopbackRuntime.decodeUpstreamResponse(objectArgs)
        XCTAssertEqual(decoded.toolCalls?.first?.arguments, #"{"a":1}"#)
        XCTAssertTrue(decoded.toolCalls?.first?.id.hasPrefix("call_") == true)

        // A bare upstream id (llama-server) is replaced by one the ingest
        // boundary accepts when the buyer sends it back on the next turn.
        let bareID = Data(#"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"GHXjDsGaYVCqs7k1M7FqlobzmkWQjCyL","function":{"name":"f","arguments":"{}"}}]}}]}"#.utf8)
        let rewritten = try OpenAICompatibleLoopbackRuntime.decodeUpstreamResponse(bareID)
        let rewrittenID = try XCTUnwrap(rewritten.toolCalls?.first?.id)
        XCTAssertTrue(ChatCompletionRequest.isAcceptedToolCallID(rewrittenID), rewrittenID)
    }

    func testCompleteWithToolCallReplyIsNot502() async throws {
        let store = try makeStore()
        let upstream = Data(#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_0123456789abcdef","type":"function","function":{"name":"f","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#.utf8)
        let runtime = try makeRuntime(httpClient: StubLoopbackHTTPClient(responseBody: upstream), store: store)
        let result = try await runtime.complete(try makeRequest(model: "ollama:gemma3:270m"))
        XCTAssertEqual(result.toolCalls?.first?.functionName, "f")
        XCTAssertEqual(result.finishReason, "tool_calls")
    }

    // MARK: #1690 M2 — preflight math and upstream error vocabulary (pure)

    func testContextGateMath() {
        XCTAssertNoThrow(try OpenAICompatibleLoopbackRuntime.contextGate(promptTokens: 100, maxTokens: 28, contextWindow: 128))
        XCTAssertNoThrow(try OpenAICompatibleLoopbackRuntime.contextGate(promptTokens: nil, maxTokens: 128, contextWindow: 128))
        XCTAssertNoThrow(try OpenAICompatibleLoopbackRuntime.contextGate(promptTokens: 127, maxTokens: nil, contextWindow: 128))
        let rejected: [(prompt: Int?, maxTokens: Int?, param: String)] = [(100, 29, "messages"), (128, nil, "messages"), (nil, 129, "max_tokens")]
        for rejection in rejected {
            XCTAssertThrowsError(try OpenAICompatibleLoopbackRuntime.contextGate(promptTokens: rejection.prompt, maxTokens: rejection.maxTokens, contextWindow: 128)) { error in
                let apiError = error as? APIError
                XCTAssertEqual(apiError?.status, 413)
                XCTAssertEqual(apiError?.code, "context_length_exceeded")
                XCTAssertEqual(apiError?.param, rejection.param)
            }
        }
    }

    func testUpstreamErrorMapping() {
        let overContext = Data(#"{"error":{"code":400,"message":"the request exceeds the available context size","type":"exceed_context_size_error","n_prompt_tokens":9000,"n_ctx":4096}}"#.utf8)
        let mapped = OpenAICompatibleLoopbackRuntime.mapUpstreamError(status: 400, body: overContext)
        XCTAssertEqual(mapped.status, 413)
        XCTAssertEqual(mapped.code, "context_length_exceeded")
        XCTAssertFalse(mapped.message.contains("9000"), "upstream text is not echoed")

        let badRequest = OpenAICompatibleLoopbackRuntime.mapUpstreamError(status: 400, body: Data(#"{"error":{"message":"/Users/x/model.gguf: bad"}}"#.utf8))
        XCTAssertEqual(badRequest.status, 400)
        XCTAssertEqual(badRequest.code, "invalid_request")
        XCTAssertFalse(badRequest.message.contains("/Users"))

        let fault = OpenAICompatibleLoopbackRuntime.mapUpstreamError(status: 500, body: Data())
        XCTAssertEqual(fault.status, 502)
        XCTAssertEqual(fault.code, "upstream_error")
    }

    func testGenerationTimeoutsScaleWithTokenBudget() {
        let short = LoopbackGenerationTimeouts.forGeneration(maxTokens: 16, contextWindow: nil)
        let long = LoopbackGenerationTimeouts.forGeneration(maxTokens: 16_384, contextWindow: nil)
        XCTAssertGreaterThan(long.overall, short.overall)
        XCTAssertGreaterThanOrEqual(long.overall, 16_384 / LoopbackGenerationTimeouts.minimumTokensPerSecond)
        XCTAssertGreaterThan(short.overall, 120, "no generation is capped at the old fixed 120s resource timeout")
        XCTAssertLessThanOrEqual(LoopbackGenerationTimeouts.forGeneration(maxTokens: Int.max / 4, contextWindow: nil).overall, LoopbackGenerationTimeouts.overallCapSeconds)
        XCTAssertEqual(
            LoopbackGenerationTimeouts.forGeneration(maxTokens: nil, contextWindow: 4096),
            LoopbackGenerationTimeouts.forGeneration(maxTokens: 4096, contextWindow: nil)
        )

        let start = Date()
        let clock = LoopbackProgressClock(now: start)
        let timeouts = LoopbackGenerationTimeouts(firstByte: 10, idle: 2, overall: 60)
        XCTAssertFalse(clock.hasExpired(timeouts, now: start.addingTimeInterval(9)), "prefill may take up to firstByte")
        XCTAssertTrue(clock.hasExpired(timeouts, now: start.addingTimeInterval(11)))
        clock.touch(now: start.addingTimeInterval(20))
        XCTAssertFalse(clock.hasExpired(timeouts, now: start.addingTimeInterval(21)))
        XCTAssertTrue(clock.hasExpired(timeouts, now: start.addingTimeInterval(23)), "a stalled stream trips the idle deadline")
        clock.touch(now: start.addingTimeInterval(61))
        XCTAssertTrue(clock.hasExpired(timeouts, now: start.addingTimeInterval(61.5)), "the overall deadline holds even while bytes flow")
    }

    // MARK: #1690 M2 — real streaming and cancellation through the runtime

    func testStreamSurfacesEachUpstreamDeltaAsItsOwnChunk() async throws {
        let store = try makeStore()
        let sse = Data("""
        data: {"choices":[{"delta":{"content":"a"}}]}

        data: {"choices":[{"delta":{"content":"b"}}]}

        data: {"choices":[{"delta":{"content":"c"}}],"usage":null}

        data: {"choices":[{"delta":{},"finish_reason":"length"}]}

        data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3}}

        data: [DONE]

        """.utf8)
        let runtime = try makeRuntime(httpClient: StubLoopbackHTTPClient(responseBody: sse), store: store)
        let request = try makeRequest(model: "ollama:gemma3:270m")
        let handle = try await runtime.acquireRequestHandle(request)
        let collector = ChunkCollector()
        let result = try await runtime.stream(request, with: handle) { collector.record($0) }
        XCTAssertEqual(collector.contentChunks, ["a", "b", "c"])
        XCTAssertEqual(result.content, "abc")
        XCTAssertEqual(result.finishReason, "length")
        XCTAssertEqual(result.completionTokens, 3)
    }

    func testShouldCancelCancelsTheUpstreamStream() async throws {
        let store = try makeStore()
        let client = EndlessStreamingLoopbackClient()
        let runtime = try makeRuntime(httpClient: client, store: store)
        let request = try makeRequest(model: "ollama:gemma3:270m", maxTokens: 100_000)
        let handle = try await runtime.acquireRequestHandle(request)
        let cancel = CancelFlag()
        let collector = ChunkCollector()
        do {
            _ = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
                collector.record(chunk)
                if collector.contentChunks.count >= 3 { cancel.set() }
            }
            XCTFail("a cancelled stream must not complete")
        } catch is CancellationError {
            // expected
        }
        // The upstream line stream was terminated (the real client cancels
        // the URLSession task there, which closes the loopback connection).
        for _ in 0..<50 where !client.wasTerminated {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(client.wasTerminated)
        XCTAssertGreaterThanOrEqual(collector.contentChunks.count, 3)
    }

    // MARK: #1690 M2 — llama.cpp selection, identity binding and preflight

    func testLlamaCppSelectionMatchesDiscoveryVocabulary() {
        XCTAssertEqual(LoopbackServeSelection.select("llamacpp:qwen2.5-0.5b-instruct-q4_k_m"), .llamaCpp)
        XCTAssertEqual(LoopbackServeSelection.select("ollama:gemma3:270m"), .ollama)
        XCTAssertNil(LoopbackServeSelection.select("mlx-community/Qwen3-8B"))
        XCTAssertNil(LoopbackServeSelection.select("lmstudio:foo"), "lmstudio: arrives with its identity leg")
        XCTAssertNil(LoopbackServeSelection.select("openai:foo"))
        XCTAssertEqual(LoopbackServeSelection.llamaCpp.runtimeSource, "llamacpp_loopback")
        XCTAssertEqual(LlamaCppLoopbackServeModel.servedRefPrefix, BYOMLlamaCppModelStore.servedModelRefPrefix)
        XCTAssertEqual(LlamaCppLoopbackServeModel.upstreamModelName(fromServedRef: "llamacpp:qwen"), "qwen")
        XCTAssertEqual(LlamaCppLoopbackServeModel.resolveOrigin(configured: " http://127.0.0.1:9191 "), "http://127.0.0.1:9191")
        XCTAssertEqual(LlamaCppLoopbackServeModel.resolveOrigin(configured: nil), BYOMLlamaCppDiscovery.defaultOrigin)
        // Ollama: the legacy env var still wins over the config key.
        XCTAssertEqual(OllamaLoopbackServeModel.resolveOrigin(configured: "http://127.0.0.1:9000", environment: [:]), "http://127.0.0.1:9000")
        XCTAssertEqual(
            OllamaLoopbackServeModel.resolveOrigin(configured: "http://127.0.0.1:9000", environment: ["MACPROVIDER_OLLAMA_ORIGIN": "http://127.0.0.1:9001"]),
            "http://127.0.0.1:9001"
        )
    }

    func testServeHTTPClientPathAllowlist() {
        let base = "http://127.0.0.1:9191"
        XCTAssertTrue(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/v1/chat/completions")!, method: "POST"))
        XCTAssertTrue(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/tokenize")!, method: "POST"))
        XCTAssertTrue(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/apply-template")!, method: "POST"))
        XCTAssertTrue(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/props")!, method: "GET"))
        XCTAssertFalse(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/props")!, method: "POST"))
        XCTAssertFalse(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/slots")!, method: "GET"))
        XCTAssertFalse(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/props?x=1")!, method: "GET"))
        XCTAssertFalse(LoopbackServeHTTPClient.isAllowed(URL(string: "http://192.168.1.5:9191/props")!, method: "GET"))
    }

    func testLlamaCppRuntimeBindsServedFileAndFailsOverContextPreflight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llamacpp-serve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let blob = Data("GGUF".utf8) + Data(repeating: 0x5a, count: 4096)
        let file = root.appendingPathComponent("tiny-q4.gguf")
        try blob.write(to: file)
        let servedPath = file.resolvingSymlinksInPath().path
        let client = LlamaCppStubClient(modelPath: servedPath, nCtx: 64, promptTokens: 40)

        let runtime = try await OpenAICompatibleLoopbackRuntime.llamaCpp(
            servedModelRef: "llamacpp:tiny-q4",
            origin: "http://127.0.0.1:9191",
            selector: BYOMLlamaCppArtifactSelector(root: nil, pinnedFile: file),
            httpClient: client,
            cache: BYOMArtifactDigestCache(url: root.appendingPathComponent("cache.json"))
        )
        let hash = await runtime.loadedModelHash
        XCTAssertEqual(hash, Self.sha256Hex(blob))
        let runtimeSource = await runtime.runtimeSource
        XCTAssertEqual(runtimeSource, "llamacpp_loopback")
        XCTAssertFalse(runtime.isSettlementReceiptEligible, "llama.cpp loopback stays non-earning (#1695)")

        // 40 prompt tokens + 16 fits in 64.
        let fits = try makeRequest(model: "llamacpp:tiny-q4", maxTokens: 16)
        try await runtime.preflight(fits, with: try await runtime.acquireRequestHandle(fits))

        // 40 + 32 does not: 413 before any upstream generation.
        let over = try makeRequest(model: "llamacpp:tiny-q4", maxTokens: 32)
        do {
            try await runtime.preflight(over, with: try await runtime.acquireRequestHandle(over))
            XCTFail("over-context request must fail preflight")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 413)
            XCTAssertEqual(error.code, "context_length_exceeded")
        }
        XCTAssertEqual(client.chatPosts, 0, "preflight never reaches chat completions")

        // The runtime now serving another file fails closed.
        client.setModelPath("/tmp/other-q4.gguf")
        do {
            try await runtime.preflight(fits, with: try await runtime.acquireRequestHandle(fits))
            XCTFail("a re-pointed llama-server must fail closed")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "model_not_loaded")
        }
    }

    func testLlamaCppRuntimeRefusesANonLlamaServerOrigin() async throws {
        let client = StubLoopbackHTTPClient(responseBody: Data("{}".utf8))
        do {
            _ = try await OpenAICompatibleLoopbackRuntime.llamaCpp(
                servedModelRef: "llamacpp:tiny-q4",
                origin: "http://127.0.0.1:9191",
                selector: .none,
                httpClient: client
            )
            XCTFail("an origin that does not fingerprint as llama-server must be refused")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleLoopbackRuntimeError, .upstreamNotRecognized("llamacpp_loopback"))
        }
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

    var contentChunks: [String] {
        lock.lock(); defer { lock.unlock() }
        return contents
    }

    var hasVisibleContent: Bool {
        lock.lock(); defer { lock.unlock() }
        return contents.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private final class IDSequence: @unchecked Sendable {
    private var counter = 0
    func next() -> String {
        counter += 1
        return "call_synth0000000000000000\(counter)"
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// A streaming loopback upstream that never finishes on its own: it yields a
/// content delta every 10ms until its consumer terminates the stream.
private final class EndlessStreamingLoopbackClient: BYOMLoopbackStreamingHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    var wasTerminated: Bool { lock.lock(); defer { lock.unlock() }; return terminated }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }

    func postLines(
        _ url: URL,
        jsonBody: Data,
        maxHeaderBytes: Int,
        maxLineBytes: Int,
        maxTotalBytes: Int,
        timeouts: LoopbackGenerationTimeouts
    ) async throws -> BYOMLoopbackLineResponse {
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let producer = Task {
                while !Task.isCancelled {
                    continuation.yield(#"data: {"choices":[{"delta":{"content":"x"}}]}"#)
                    continuation.yield("")
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                producer.cancel()
                guard let self else { return }
                self.lock.lock()
                self.terminated = true
                self.lock.unlock()
            }
        }
        return BYOMLoopbackLineResponse(statusCode: 200, lines: lines)
    }
}

/// A llama-server stand-in: `/props` (model_path + n_ctx), `/apply-template`
/// and `/tokenize`; chat-completion posts are counted.
private final class LlamaCppStubClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var modelPath: String
    private let nCtx: Int
    private let promptTokens: Int
    private var _chatPosts = 0

    init(modelPath: String, nCtx: Int, promptTokens: Int) {
        self.modelPath = modelPath
        self.nCtx = nCtx
        self.promptTokens = promptTokens
    }

    var chatPosts: Int { lock.lock(); defer { lock.unlock() }; return _chatPosts }
    func setModelPath(_ path: String) { lock.lock(); modelPath = path; lock.unlock() }
    private var currentModelPath: String { lock.lock(); defer { lock.unlock() }; return modelPath }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        guard url.path == "/props" else { return BYOMHTTPResponse(statusCode: 404, headers: [], body: Data()) }
        let path = currentModelPath
        let props: [String: Any] = ["default_generation_settings": ["n_ctx": nCtx], "model_path": path]
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: try JSONSerialization.data(withJSONObject: props))
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        switch url.path {
        case "/apply-template":
            return BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(#"{"prompt":"<|im_start|>user\nhi<|im_end|>\n"}"#.utf8))
        case "/tokenize":
            let tokens = Array(0..<promptTokens)
            return BYOMHTTPResponse(statusCode: 200, headers: [], body: try JSONSerialization.data(withJSONObject: ["tokens": tokens]))
        default:
            lock.lock()
            _chatPosts += 1
            lock.unlock()
            return BYOMHTTPResponse(statusCode: 500, headers: [], body: Data())
        }
    }
}

// #1690 freeze audit R1 CODE-3/4/5.
extension OpenAICompatibleLoopbackRuntimeTests {
    func testLineSplitterTreatsLoneCRAsATerminator() {
        XCTAssertEqual(LoopbackLineSplitter.lines(of: Data("data: a\rdata: b\r\n\rdata: c\n".utf8)), ["data: a", "data: b", "", "data: c"])
        XCTAssertEqual(LoopbackLineSplitter.lines(of: Data("a\r\r\nb".utf8)), ["a", "", "b"])
    }

    func testSSEParserStripsOnlyTheFieldSeparatorColon() {
        var parser = LoopbackSSEParser()
        XCTAssertEqual(parser.consume(line: "data::value"), [])
        XCTAssertEqual(parser.consume(line: "data:  two"), [])
        XCTAssertEqual(parser.consume(line: ""), [.data(":value\n two")])
    }

    func testStreamAccumulatorRejectsATruncatedStream() throws {
        var accumulator = OpenAICompatibleStreamAccumulator()
        for line in [#"data: {"choices":[{"delta":{"content":"par"}}]}"#, ""] {
            _ = try accumulator.consume(line: line)
        }
        XCTAssertFalse(accumulator.isDone)
        XCTAssertThrowsError(try accumulator.finish(), "a clean EOF before [DONE] is truncation")
    }

    func testStreamAccumulatorRejectsMalformedDataObjects() {
        for payload in ["{}", #"{"choices":[]}"#, #"{"usage":{"prompt_tokens":1,"completion_tokens":1}}"#, #"{"choices":{}}"#] {
            var accumulator = OpenAICompatibleStreamAccumulator()
            XCTAssertNoThrow(try accumulator.consume(line: "data: " + payload))
            XCTAssertThrowsError(try accumulator.consume(line: ""), payload)
        }
        var usageOnly = OpenAICompatibleStreamAccumulator()
        XCTAssertNoThrow(try usageOnly.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#))
        XCTAssertNoThrow(try usageOnly.consume(line: ""))
    }

    func testTruncatedUpstreamStreamIsAnUpstreamErrorNotASuccess() async throws {
        let store = try makeStore()
        let sse = Data("""
        data: {"choices":[{"delta":{"content":"a"}}]}

        data: {"choices":[{"delta":{"content":"b"}}]}

        """.utf8)
        let runtime = try makeRuntime(httpClient: StubLoopbackHTTPClient(responseBody: sse), store: store)
        let request = try makeRequest(model: "ollama:gemma3:270m")
        do {
            _ = try await runtime.complete(request, shouldCancel: { false })
            XCTFail("a truncated stream must not complete")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 502)
            XCTAssertEqual(error.code, "upstream_error")
        }
    }

    func testTransportTimeoutMapsLikeTheWatchdog() async throws {
        let store = try makeStore()
        for failure in [ScriptedLoopbackClient.Failure.openTimesOut, .streamTimesOut] {
            let runtime = try makeRuntime(httpClient: ScriptedLoopbackClient(failure: failure), store: store)
            let request = try makeRequest(model: "ollama:gemma3:270m")
            do {
                _ = try await runtime.complete(request, shouldCancel: { false })
                XCTFail("\(failure) must not complete")
            } catch let error as APIError {
                XCTAssertEqual(error.status, 504, "\(failure)")
                XCTAssertEqual(error.code, "provider_timeout", "\(failure)")
            }
        }
        XCTAssertGreaterThan(
            LoopbackServeHTTPClient.backstopSlackSeconds, 0,
            "URLSession backstops fire strictly after the watchdog deadlines"
        )
    }

    func testNon2xxBodyReadFailureKeepsTheStatusMapping() async throws {
        let store = try makeStore()
        let runtime = try makeRuntime(httpClient: ScriptedLoopbackClient(failure: .errorBodyBreaks(status: 400)), store: store)
        let request = try makeRequest(model: "ollama:gemma3:270m")
        do {
            _ = try await runtime.complete(request, shouldCancel: { false })
            XCTFail("an upstream 400 must not complete")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.code, "invalid_request")
        }
    }
}

private final class ScriptedLoopbackClient: BYOMLoopbackStreamingHTTPClient, @unchecked Sendable {
    enum Failure: CustomStringConvertible {
        case openTimesOut
        case streamTimesOut
        case errorBodyBreaks(status: Int)

        var description: String {
            switch self {
            case .openTimesOut: return "openTimesOut"
            case .streamTimesOut: return "streamTimesOut"
            case .errorBodyBreaks(let status): return "errorBodyBreaks(\(status))"
            }
        }
    }

    let failure: Failure

    init(failure: Failure) {
        self.failure = failure
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }

    func postLines(
        _ url: URL,
        jsonBody: Data,
        maxHeaderBytes: Int,
        maxLineBytes: Int,
        maxTotalBytes: Int,
        timeouts: LoopbackGenerationTimeouts
    ) async throws -> BYOMLoopbackLineResponse {
        switch failure {
        case .openTimesOut:
            throw URLError(.timedOut)
        case .streamTimesOut:
            return BYOMLoopbackLineResponse(statusCode: 200, lines: AsyncThrowingStream { continuation in
                continuation.yield(#"data: {"choices":[{"delta":{"content":"a"}}]}"#)
                continuation.yield("")
                continuation.finish(throwing: URLError(.timedOut))
            })
        case .errorBodyBreaks(let status):
            return BYOMLoopbackLineResponse(statusCode: status, lines: AsyncThrowingStream { continuation in
                continuation.yield(#"{"error":{"message":"bad"#)
                continuation.finish(throwing: URLError(.networkConnectionLost))
            })
        }
    }
}
