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
        store: (root: URL, cacheURL: URL, blob: Data, locatorHex: String),
        countTokens: (@Sendable (String) -> Int)? = nil
    ) throws -> OpenAICompatibleLoopbackRuntime {
        var siblingSnapshotSHA256: String?
        var siblingSnapshotDirectories: [URL] = []
        if countTokens != nil {
            let directory = try makeSnapshotDirectory("startup-recount")
            let snapshot = try MLXSnapshotIdentity.compute(directory: directory)
            siblingSnapshotSHA256 = snapshot.digest
            siblingSnapshotDirectories = [directory]
        }
        return try OpenAICompatibleLoopbackRuntime(
            servedModelRef: servedModelRef,
            origin: origin,
            httpClient: httpClient,
            digestResolver: makeResolver(store),
            siblingSnapshotSHA256: siblingSnapshotSHA256,
            siblingSnapshotDirectories: siblingSnapshotDirectories,
            pinRecountTokenizer: { snapshot in
                guard let countTokens else { return nil }
                return PinnedSnapshotTokenizer(snapshot: snapshot, encode: countTokens)
            }
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
        // A stream with neither timings nor logprobs (mlx_lm.server, or an
        // Ollama that ignores `logprobs`) and no external count.
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

    // #1690 M9: Ollama and LM Studio list each streamed token in
    // `choices[0].logprobs.content`, so the running list length is the
    // completion tokens through each chunk. They report no prompt count
    // until the end, so the prefix stays unattested until the upstream's own
    // prompt count for the same request is supplied.
    private static func cancelledLogprobsStream(
        _ chunks: [(text: String, tokens: [String])],
        upstreamPromptTokens: Int?
    ) throws -> CompletionResult {
        var accumulator = OpenAICompatibleStreamAccumulator()
        for chunk in chunks {
            let entries = chunk.tokens.map { #"{"token":""# + $0 + #"","logprob":-0.5}"# }.joined(separator: ",")
            let content = chunk.text.isEmpty ? "" : #""content":""# + chunk.text + #"""#
            _ = try accumulator.consume(line: #"data: {"choices":[{"index":0,"delta":{"# + content + #"},"logprobs":{"content":["# + entries + "]}}]}")
            _ = try accumulator.consume(line: "")
        }
        return accumulator.cancelledResult(upstreamPromptTokens: upstreamPromptTokens)
    }

    func testCancelledLogprobsStreamBindsCompletionPerChunkAndNeedsTheUpstreamPromptCount() throws {
        // "Hello" arrives as one chunk of two tokens; a chunk with a token
        // but no text (a held-back byte) counts toward the next chunk.
        let chunks: [(text: String, tokens: [String])] = [("Hello", ["Hel", "lo"]), ("", ["\u{e3}"]), (" wor", ["x", " wor"])]
        let noPrompt = try Self.cancelledLogprobsStream(chunks, upstreamPromptTokens: nil)
        XCTAssertEqual(noPrompt.settlementDisposition, .usageUnattested, "no prompt count: never signed")
        XCTAssertNil(InferenceRelay.usage(noPrompt.cancelledPrefixUsage(deliveredContent: "Hello"))["completion_tokens"])

        let result = try Self.cancelledLogprobsStream(chunks, upstreamPromptTokens: 35)
        XCTAssertEqual(result.settlementDisposition, .notEligible)
        XCTAssertEqual(result.promptTokens, 35)
        XCTAssertEqual(result.completionTokens, 5)
        let prefix = result.cancelledPrefixUsage(deliveredContent: "Hello")
        XCTAssertEqual(prefix.promptTokens, 35)
        XCTAssertEqual(prefix.completionTokens, 2)
        XCTAssertEqual(prefix.settlementDisposition, .notEligible)
        XCTAssertEqual(result.cancelledPrefixUsage(deliveredContent: "").completionTokens, 0)
        XCTAssertEqual(result.cancelledPrefixUsage(deliveredContent: "Hel").settlementDisposition, .usageUnattested, "off a chunk boundary")

        // A content chunk without a list breaks the chain.
        var gap = OpenAICompatibleStreamAccumulator()
        for line in [
            #"data: {"choices":[{"index":0,"delta":{"content":"Hel"},"logprobs":{"content":[{"token":"Hel","logprob":-1}]}}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#, "",
        ] {
            _ = try gap.consume(line: line)
        }
        XCTAssertEqual(gap.cancelledResult(upstreamPromptTokens: 9).settlementDisposition, .usageUnattested)

        // The two per-token sources never mix within one stream.
        var mixed = OpenAICompatibleStreamAccumulator()
        for line in [
            #"data: {"choices":[{"index":0,"delta":{"content":"Hel"}}],"timings":"# + Self.llamaTimings(prompt: 3, cached: 0, predicted: 1) + "}", "",
            #"data: {"choices":[{"index":0,"delta":{"content":"lo"},"logprobs":{"content":[{"token":"lo","logprob":-1}]}}]}"#, "",
        ] {
            _ = try mixed.consume(line: line)
        }
        XCTAssertEqual(mixed.cancelledResult(upstreamPromptTokens: 9).settlementDisposition, .usageUnattested)
    }

    // #1690: a non-SSE JSON body carries no per-chunk counts, so a cancel
    // that delivered only a prefix of its content never keeps the whole
    // completion's usage: the prefix is unattested and never signed.
    func testPlainBodyPartialCancelPrefixIsUnattested() throws {
        var accumulator = OpenAICompatibleStreamAccumulator()
        let body = try XCTUnwrap(String(data: Self.completionJSON(content: "Once upon a time", completionTokens: 4), encoding: .utf8))
        _ = try accumulator.consume(line: body)
        let (result, late) = try accumulator.finish()
        XCTAssertTrue(accumulator.decodedFromPlainBody)
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(result.completionTokens, 4)
        XCTAssertEqual(result.settlementDisposition, .notEligible)
        XCTAssertEqual(result.loopbackPrefixCompletionTokens, [:])
        for prefix in ["Once upon", ""] {
            let cancelled = result.cancelledPrefixUsage(deliveredContent: prefix)
            XCTAssertEqual(cancelled.settlementDisposition, .usageUnattested, "prefix \(prefix.debugDescription)")
            XCTAssertNil(InferenceRelay.usage(cancelled)["completion_tokens"])
        }
        XCTAssertEqual(result.cancelledPrefixUsage(deliveredContent: nil).settlementDisposition, .usageUnattested)
        XCTAssertEqual(result.cancelledPrefixUsage(deliveredContent: "Once upon a time").completionTokens, 4, "whole content delivered")
    }

    // #1690 M9: mlx_lm.server reports no per-chunk usage, so the cancelled
    // stream's completion tokens are the served snapshot tokenizer's count of
    // the whole received content, bound to that content only.
    func testCancelledStreamRecountBindsOnlyTheWholeReceivedContent() throws {
        var accumulator = OpenAICompatibleStreamAccumulator()
        for line in [#"data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]}"#, "", #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#, ""] {
            _ = try accumulator.consume(line: line)
        }
        XCTAssertEqual(accumulator.receivedContent, "Hello")
        XCTAssertEqual(accumulator.cancelledResult(recountedCompletionTokens: 2).settlementDisposition, .usageUnattested, "a recount alone has no prompt count")
        let result = accumulator.cancelledResult(upstreamPromptTokens: 12, recountedCompletionTokens: 2)
        XCTAssertEqual(result.settlementDisposition, .notEligible)
        XCTAssertEqual(result.promptTokens, 12)
        XCTAssertEqual(result.completionTokens, 2)
        XCTAssertEqual(result.cancelledPrefixUsage(deliveredContent: "Hello").completionTokens, 2)
        XCTAssertEqual(result.cancelledPrefixUsage(deliveredContent: "Hel").settlementDisposition, .usageUnattested)
        XCTAssertEqual(result.cancelledPrefixUsage(deliveredContent: "").completionTokens, 0)

        // A streamed tool call is not covered by a content recount.
        var tool = OpenAICompatibleStreamAccumulator()
        for line in [
            #"data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"f","arguments":"{}"}}]}}]}"#, "",
        ] {
            _ = try tool.consume(line: line)
        }
        XCTAssertEqual(tool.cancelledResult(upstreamPromptTokens: 12, recountedCompletionTokens: 1).settlementDisposition, .usageUnattested)
    }

    /// A huggingface_hub-shaped cache: `snapshots/<rev>/<file>` symlinks
    /// into `blobs/`, holding the same bytes as `source`.
    private func makeHubCacheSnapshot(copying source: URL) throws -> URL {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)/models--mlx-community--Gemma-3-270m-4bit")
        let blobs = repo.appendingPathComponent("blobs")
        let snapshot = repo.appendingPathComponent("snapshots/0123456789abcdef")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: repo.deletingLastPathComponent()) }
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            let blob = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
            try data.write(to: blobs.appendingPathComponent(blob))
            try fm.createSymbolicLink(atPath: snapshot.appendingPathComponent(name).path, withDestinationPath: "../../blobs/" + blob)
        }
        return snapshot.resolvingSymlinksInPath().standardizedFileURL
    }

    private func makeSnapshotDirectory(_ name: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        let directory = parent.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try Data(#"{"model_type":"qwen2"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        return directory.resolvingSymlinksInPath().standardizedFileURL
    }

    // #1690 M9 review CODE HIGH: the recount tokenizer is pinned from a
    // hash-verified snapshot and counts only while that snapshot is current.
    func testPinnedTokenizerCountsOnlyWhileItsSnapshotIsCurrent() async throws {
        let directory = try makeSnapshotDirectory("pinned")
        let snapshot = try MLXSnapshotIdentity.compute(directory: directory)
        let pinned = PinnedSnapshotTokenizer(snapshot: snapshot) { $0.count * 2 }
        XCTAssertEqual(pinned.count("abc"), 6)
        try Data(#"{"swapped":true}"#.utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        XCTAssertNil(pinned.count("abc"), "tokenizer files changed after admission: no count")
        let unloadable = await PinnedSnapshotTokenizer.load(snapshot: try MLXSnapshotIdentity.compute(directory: directory))
        XCTAssertNil(unloadable, "a snapshot without a loadable tokenizer pins nothing")
    }

    func testUpstreamRequestAsksOllamaForPerTokenLogprobsOnly() throws {
        XCTAssertTrue(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("ollama_loopback"))
        XCTAssertTrue(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("lmstudio_loopback"))
        XCTAssertFalse(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("llamacpp_loopback"))
        XCTAssertFalse(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("mlxlm_loopback"))
        let request = try makeRequest(model: "ollama:gemma3:270m")
        let ollama = try JSONSerialization.jsonObject(with: OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(
            request, upstreamModelName: "gemma3:270m", logprobsPerToken: true
        )) as? [String: Any]
        XCTAssertEqual(ollama?["logprobs"] as? Bool, true)
        XCTAssertNil(ollama?["timings_per_token"])
        let plain = try JSONSerialization.jsonObject(with: OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(
            request, upstreamModelName: "gemma3:270m"
        )) as? [String: Any]
        XCTAssertNil(plain?["logprobs"])
    }

    func testPromptCountRequestIsTheSameRequestNonStreamedForOneToken() throws {
        let request = try makeRequest(model: "ollama:gemma3:270m", content: "count me", maxTokens: 700)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAICompatibleLoopbackRuntime.encodePromptCountRequest(
            request, upstreamModelName: "gemma3:270m"
        )) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["max_tokens"] as? Int, 1)
        XCTAssertNil(body["stream_options"])
        XCTAssertNil(body["logprobs"])
        XCTAssertEqual(body["model"] as? String, "gemma3:270m")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "count me")
        XCTAssertEqual(OpenAICompatibleLoopbackRuntime.decodeUsagePromptTokens(Self.completionJSON(content: "B", completionTokens: 1, promptTokens: 35)), 35)
        XCTAssertNil(OpenAICompatibleLoopbackRuntime.decodeUsagePromptTokens(Data(#"{"choices":[]}"#.utf8)))
    }

    // #1690 M9 regression (E2E-F3 on Ollama): a buyer that disconnects
    // mid-stream on Ollama is billed the delivered prefix. Before the fix the
    // cancelled result was unattested, so no buyer_cancel receipt was signed
    // and the partial stream was free.
    func testCancelledOllamaStreamBindsTheUpstreamPromptCountAndPerChunkTokens() async throws {
        let store = try makeStore()
        let client = LogprobsStreamingLoopbackClient(promptTokens: 35)
        let runtime = try makeRuntime(httpClient: client, store: store)
        let request = try makeRequest(model: "ollama:gemma3:270m", maxTokens: 100_000)
        let handle = try await runtime.acquireRequestHandle(request)
        let cancel = CancelFlag()
        let collector = ChunkCollector()
        let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
            collector.record(chunk)
            if collector.contentChunks.count >= 3 { cancel.set() }
        }
        XCTAssertEqual(result.finishReason, "")
        XCTAssertEqual(result.settlementDisposition, .notEligible, "a cancelled Ollama stream is attested")
        XCTAssertEqual(result.promptTokens, 35)
        // Every streamed chunk carries two tokens.
        XCTAssertEqual(result.completionTokens, 2 * result.content.count)
        let delivered = result.cancelledPrefixUsage(deliveredContent: result.content)
        XCTAssertEqual(InferenceRelay.usage(delivered)["prompt_tokens"] as? Int, 35)
        XCTAssertEqual(InferenceRelay.usage(delivered)["completion_tokens"] as? Int, 2 * result.content.count)
        let streamed = try XCTUnwrap(client.streamedBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(streamed["logprobs"] as? Bool, true)
        let counted = try XCTUnwrap(client.countBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(counted["stream"] as? Bool, false)
        XCTAssertEqual(counted["max_tokens"] as? Int, 1)
    }

    func testCancelledOllamaStreamStaysUnattestedWhenThePromptCountFails() async throws {
        let store = try makeStore()
        let client = LogprobsStreamingLoopbackClient(promptTokens: nil)
        let runtime = try makeRuntime(httpClient: client, store: store)
        let request = try makeRequest(model: "ollama:gemma3:270m", maxTokens: 100_000)
        let handle = try await runtime.acquireRequestHandle(request)
        let cancel = CancelFlag()
        let collector = ChunkCollector()
        let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
            collector.record(chunk)
            if collector.contentChunks.count >= 3 { cancel.set() }
        }
        XCTAssertEqual(result.settlementDisposition, .usageUnattested)
    }

    // #1690 M9 review L8: the two per-token sources never mix, in either order.
    func testCancelledStreamRejectsMixedPerChunkCountSources() throws {
        let timings = #","timings":"# + Self.llamaTimings(prompt: 3, cached: 0, predicted: 1) + "}"
        let orders: [[String]] = [
            [#"data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]"# + timings,
             #"data: {"choices":[{"index":0,"delta":{"content":"lo"},"logprobs":{"content":[{"token":"lo","logprob":-1}]}}]}"#],
            [#"data: {"choices":[{"index":0,"delta":{"content":"Hel"},"logprobs":{"content":[{"token":"Hel","logprob":-1}]}}]}"#,
             #"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]"# + timings],
        ]
        for lines in orders {
            var accumulator = OpenAICompatibleStreamAccumulator()
            for line in lines {
                _ = try accumulator.consume(line: line)
                _ = try accumulator.consume(line: "")
            }
            XCTAssertFalse(accumulator.hasPerChunkCompletionCounts)
            XCTAssertEqual(accumulator.cancelledResult(upstreamPromptTokens: 9).settlementDisposition, .usageUnattested)
        }
    }

    // #1690 M9 review M1 / L8: the post-cancel usage work is bounded well
    // under the coordinator's 2 s CancelTerminalWait. A prompt count that
    // answers late leaves the cancel unattested (free), never late.
    func testSlowPromptCountLeavesTheCancelUnattestedWithinTheBudget() async throws {
        XCTAssertLessThan(OpenAICompatibleLoopbackRuntime.cancelUsageBudgetSeconds, 1.5)
        let store = try makeStore()
        let client = LogprobsStreamingLoopbackClient(promptTokens: 35, countDelaySeconds: 3)
        let runtime = try makeRuntime(httpClient: client, store: store)
        let request = try makeRequest(model: "ollama:gemma3:270m", maxTokens: 100_000)
        let handle = try await runtime.acquireRequestHandle(request)
        let cancel = CancelFlag()
        let collector = ChunkCollector()
        let cancelledAt = TimeBox()
        let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
            collector.record(chunk)
            if collector.contentChunks.count >= 3, !cancel.isSet {
                cancelledAt.set(Date())
                cancel.set()
            }
        }
        let elapsed = Date().timeIntervalSince(cancelledAt.value ?? Date())
        XCTAssertEqual(result.settlementDisposition, .usageUnattested, "a late prompt count never bills")
        XCTAssertLessThan(elapsed, 1.9, "the cancelled result is ready inside the coordinator's wait")
    }

    func testBoundedReturnsNilAtTheDeadlineWithoutWaitingForTheWork() async {
        let start = Date()
        let value = await OpenAICompatibleLoopbackRuntime.bounded(until: start.addingTimeInterval(0.2)) { () async -> Int? in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return 1
        }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        let fast = await OpenAICompatibleLoopbackRuntime.bounded(until: Date().addingTimeInterval(1)) { () async -> Int? in 7 }
        XCTAssertEqual(fast, 7)
    }

    // #1690 M9 review M3 and CODE HIGH, verification MEDIUM: without
    // per-chunk counts (an Ollama that ignores logprobs, LM Studio with tools)
    // the delivered content is counted with the catalog sibling tokenizer,
    // pinned from the first verified plain artifact directory (durable store,
    // then macprovider's HF snapshot) whose canonical digest equals the signed
    // row's. A huggingface_hub cache (snapshot files symlinked into blobs/)
    // is refused, as native serving refuses it; else unattested.
    func testCancelWithoutPerChunkCountsFallsBackToTheVerifiedSiblingTokenizer() async throws {
        let store = try makeStore()
        let sibling = try makeSnapshotDirectory("sibling")
        let digest = try MLXSnapshotIdentity.compute(directory: sibling).digest
        let other = try makeSnapshotDirectory("other")
        try Data("other".utf8).write(to: other.appendingPathComponent("README.md"))
        let hubCache = try makeHubCacheSnapshot(copying: sibling)
        let cases: [([URL], String?, Bool, String)] = [
            ([sibling], digest, true, "verified sibling"),
            ([other, sibling], digest, true, "first candidate differs, second verifies"),
            ([sibling], String(repeating: "0", count: 64), false, "sibling digest differs from the catalog row"),
            ([], digest, false, "no local sibling"),
            ([sibling], nil, false, "no catalog digest"),
            ([hubCache], digest, false, "huggingface_hub cache with symlinks into blobs/"),
        ]
        for (directories, expected, attested, label) in cases {
            let client = LogprobsStreamingLoopbackClient(promptTokens: 35, logprobs: false)
            let runtime = try OpenAICompatibleLoopbackRuntime(
                servedModelRef: "ollama:gemma3:270m",
                origin: "http://127.0.0.1:11434",
                catalogModelIDAlias: "mlx-community/Gemma-3-270m-4bit",
                httpClient: client,
                digestResolver: makeResolver(store),
                siblingSnapshotSHA256: expected,
                siblingSnapshotDirectories: directories,
                pinRecountTokenizer: { snapshot in PinnedSnapshotTokenizer(snapshot: snapshot) { $0.count * 3 } }
            )
            let request = try makeRequest(model: "ollama:gemma3:270m", maxTokens: 100_000)
            let handle = try await runtime.acquireRequestHandle(request)
            let cancel = CancelFlag()
            let collector = ChunkCollector()
            let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
                collector.record(chunk)
                if collector.contentChunks.count >= 3 { cancel.set() }
            }
            if attested {
                XCTAssertEqual(result.settlementDisposition, .notEligible, label)
                XCTAssertEqual(result.promptTokens, 35, label)
                XCTAssertEqual(result.completionTokens, result.content.count * 3, label)
            } else {
                XCTAssertEqual(result.settlementDisposition, .usageUnattested, label)
            }
        }
    }

    // #1690 M9 R2 SECURITY: a streamed tool-call delta leaves a cancelled
    // stream unattested even when per-chunk logprobs cover every chunk
    // (Ollama always asks for them).
    func testCancelAfterAStreamedToolCallIsUnattestedOnTheLogprobsPath() async throws {
        let store = try makeStore()
        let client = LogprobsStreamingLoopbackClient(promptTokens: 30, logprobs: true, toolCallAfter: 2)
        let runtime = try makeRuntime(httpClient: client, store: store)
        let request = try makeRequest(model: "ollama:gemma3:270m", maxTokens: 100_000)
        let handle = try await runtime.acquireRequestHandle(request)
        let cancel = CancelFlag()
        let collector = ChunkCollector()
        let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
            collector.record(chunk)
            if collector.contentChunks.count >= 4 { cancel.set() }
        }
        XCTAssertFalse(result.content.isEmpty)
        XCTAssertNotNil(result.toolCalls)
        XCTAssertEqual(result.settlementDisposition, .usageUnattested)
        XCTAssertEqual(result.loopbackPrefixCompletionTokens, [:])

        // The accumulator itself: timings and logprobs tables with a tool call.
        var logprobs = OpenAICompatibleStreamAccumulator()
        for line in [
            #"data: {"choices":[{"index":0,"delta":{"content":"ok"},"logprobs":{"content":[{"token":"ok","logprob":-1}]}}]}"#, "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"f","arguments":"{}"}}]},"logprobs":{"content":[{"token":"t","logprob":-1}]}}]}"#, "",
        ] {
            _ = try logprobs.consume(line: line)
        }
        XCTAssertEqual(logprobs.cancelledResult(upstreamPromptTokens: 12).settlementDisposition, .usageUnattested)
        var timings = OpenAICompatibleStreamAccumulator()
        for line in [
            #"data: {"choices":[{"index":0,"delta":{"content":"ok"}}],"timings":"# + Self.llamaTimings(prompt: 3, cached: 0, predicted: 1) + "}", "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"f","arguments":"{}"}}]}}],"timings":"# + Self.llamaTimings(prompt: 3, cached: 0, predicted: 2) + "}", "",
        ] {
            _ = try timings.consume(line: line)
        }
        XCTAssertEqual(timings.cancelledResult().settlementDisposition, .usageUnattested)
    }

    // #1690 M9 R2 TOCTOU: the pinned tokenizer re-checks its snapshot after
    // the encode; a swap during the encode yields no count.
    func testPinnedTokenizerSwapDuringEncodeYieldsNoCount() throws {
        let directory = try makeSnapshotDirectory("swap-encode")
        let snapshot = try MLXSnapshotIdentity.compute(directory: directory)
        let pinned = PinnedSnapshotTokenizer(snapshot: snapshot) { text in
            try? Data(#"{"swapped":true}"#.utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
            return text.count
        }
        XCTAssertNil(pinned.count("abc"))
    }

    // #1690 M9 R2 TOCTOU: the runtime binding is re-checked after the
    // prompt-count response; mlx_lm.server dropping the snapshot while it
    // answers leaves the cancel unattested.
    func testBindingChangeDuringThePromptCountLeavesTheCancelUnattested() async throws {
        let snapshotDirectory = try makeSnapshotDirectory("mlxlm-count-swap")
        let snapshot = try MLXSnapshotIdentity.compute(directory: snapshotDirectory)
        let client = LogprobsStreamingLoopbackClient(promptTokens: 21, logprobs: false, listedModelPath: snapshot.directory.path, unlistOnCount: true)
        let runtime = try OpenAICompatibleLoopbackRuntime(
            servedModelRef: "mlxlm:snapshot",
            origin: "http://127.0.0.1:9191",
            runtimeSource: "mlxlm_loopback",
            runtimeArtifactPath: snapshot.directory.path,
            httpClient: client,
            mlxSnapshot: snapshot,
            pinRecountTokenizer: { pinned in PinnedSnapshotTokenizer(snapshot: pinned) { $0.count * 2 } }
        )
        let request = try makeRequest(model: "mlxlm:snapshot", maxTokens: 100_000)
        let handle = try await runtime.acquireRequestHandle(request)
        let cancel = CancelFlag()
        let collector = ChunkCollector()
        let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
            collector.record(chunk)
            if collector.contentChunks.count >= 3 { cancel.set() }
        }
        XCTAssertFalse(client.countBodies.isEmpty, "the prompt count was asked")
        XCTAssertEqual(result.settlementDisposition, .usageUnattested)
    }

    // #1690 M9 review L8 / CODE HIGH / CODE MEDIUM: the actor-level
    // mlx_lm.server cancel counts the delivered content with the pinned
    // snapshot tokenizer (a fake encode here). It is unattested when the
    // tokenizer answers late, when a snapshot file changes during the stream,
    // or when the runtime stops listing the snapshot before the prompt count.
    func testCancelledMLXLMStreamRecountsWithThePinnedSnapshotTokenizer() async throws {
        enum Twist: String { case none, slowTokenizer, mutatedSnapshot, unlisted }
        for twist in [Twist.none, .slowTokenizer, .mutatedSnapshot, .unlisted] {
            let snapshotDirectory = try makeSnapshotDirectory("mlxlm-cancel")
            let snapshot = try MLXSnapshotIdentity.compute(directory: snapshotDirectory)
            let client = LogprobsStreamingLoopbackClient(promptTokens: 21, logprobs: false, listedModelPath: snapshot.directory.path)
            let runtime = try OpenAICompatibleLoopbackRuntime(
                servedModelRef: "mlxlm:snapshot",
                origin: "http://127.0.0.1:9191",
                runtimeSource: "mlxlm_loopback",
                runtimeArtifactPath: snapshot.directory.path,
                httpClient: client,
                mlxSnapshot: snapshot,
                pinRecountTokenizer: { pinned in
                    PinnedSnapshotTokenizer(snapshot: pinned) { text in
                        if twist == .slowTokenizer { Thread.sleep(forTimeInterval: 3) }
                        return text.count * 2
                    }
                }
            )
            let request = try makeRequest(model: "mlxlm:snapshot", maxTokens: 100_000)
            let handle = try await runtime.acquireRequestHandle(request)
            let cancel = CancelFlag()
            let collector = ChunkCollector()
            let start = Date()
            let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
                collector.record(chunk)
                guard collector.contentChunks.count >= 3, !cancel.isSet else { return }
                switch twist {
                case .mutatedSnapshot:
                    try? Data(#"{"swapped":true}"#.utf8).write(to: snapshotDirectory.appendingPathComponent("tokenizer.json"))
                case .unlisted:
                    client.unlist()
                default:
                    break
                }
                cancel.set()
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3.0, twist.rawValue)
            if twist == .none {
                XCTAssertEqual(result.settlementDisposition, .notEligible)
                XCTAssertEqual(result.promptTokens, 21)
                XCTAssertEqual(result.completionTokens, result.content.count * 2)
            } else {
                XCTAssertEqual(result.settlementDisposition, .usageUnattested, twist.rawValue)
            }
        }
    }

    // #1690 M9 review SECURITY LOW: `tools: []` is no tools. It is not
    // forwarded, and LM Studio is still asked for per-chunk logprobs.
    func testEmptyToolsArrayIsNoTools() throws {
        let body: [String: Any] = [
            "model": "lmstudio:tiny", "messages": [["role": "user", "content": "hi"]], "max_tokens": 4, "stream": true, "tools": [] as [Any],
        ]
        let request = try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
        XCTAssertFalse(ModelRuntime.hasEnabledTools(request.promptSource.tools))
        XCTAssertTrue(OpenAICompatibleLoopbackRuntime.streamsPerTokenLogprobs("lmstudio_loopback", hasTools: ModelRuntime.hasEnabledTools(request.promptSource.tools)))
        let upstream = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(
            request, upstreamModelName: "tiny", logprobsPerToken: true
        )) as? [String: Any])
        XCTAssertNil(upstream["tools"])
        XCTAssertEqual(upstream["logprobs"] as? Bool, true)
    }

    // #1690 M9 verification LOW: at its deadline `bounded` returns nil and
    // cancels the work's task, so a pending prompt-count POST (URLSession
    // honours task cancellation) is torn down rather than left running.
    func testBoundedCancelsItsWorkAtTheDeadline() async throws {
        let cancelled = CancelFlag()
        let start = Date()
        let value: Int? = await OpenAICompatibleLoopbackRuntime.bounded(until: Date().addingTimeInterval(0.2)) {
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            } onCancel: {
                cancelled.set()
            }
        }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        for _ in 0..<50 where !cancelled.isSet { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(cancelled.isSet)
        XCTAssertLessThan(OpenAICompatibleLoopbackRuntime.cancelUsageBudgetSeconds, OpenAICompatibleLoopbackRuntime.promptCountTimeoutSeconds)
    }

    // #1690 M9 verification LOW: a `tool_choice` beside dropped (empty)
    // tools names no tool; it is dropped with them. With real tools it stays.
    func testToolChoiceIsDroppedWithDroppedTools() throws {
        func upstream(tools: [Any]) throws -> [String: Any] {
            let body: [String: Any] = [
                "model": "lmstudio:tiny", "messages": [["role": "user", "content": "hi"]], "max_tokens": 4, "stream": true,
                "tools": tools, "tool_choice": "auto",
            ]
            let request = try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAICompatibleLoopbackRuntime.encodeUpstreamRequest(
                request, upstreamModelName: "tiny", logprobsPerToken: false
            )) as? [String: Any])
        }
        let dropped = try upstream(tools: [])
        XCTAssertNil(dropped["tools"])
        XCTAssertNil(dropped["tool_choice"])
        let kept = try upstream(tools: [["type": "function", "function": ["name": "f", "parameters": ["type": "object"]]]])
        XCTAssertNotNil(kept["tools"])
        XCTAssertEqual(kept["tool_choice"] as? String, "auto")
    }

    // #1690 M9 review L6: tools stay in the count body (the template renders
    // them into the prompt); a 4xx on a body with response_format is retried
    // once without it.
    func testPromptCountRetriesOnceWithoutResponseFormat() async throws {
        let store = try makeStore()
        let client = LogprobsStreamingLoopbackClient(promptTokens: 40, rejectResponseFormat: true)
        let runtime = try makeRuntime(httpClient: client, store: store)
        let body: [String: Any] = [
            "model": "ollama:gemma3:270m",
            "messages": [["role": "user", "content": "json please"]],
            "max_tokens": 100_000,
            "stream": true,
            "response_format": ["type": "json_object"],
            "tools": [["type": "function", "function": ["name": "f", "parameters": ["type": "object"]]]],
        ]
        let request = try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
        let handle = try await runtime.acquireRequestHandle(request)
        let cancel = CancelFlag()
        let collector = ChunkCollector()
        let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
            collector.record(chunk)
            if collector.contentChunks.count >= 3 { cancel.set() }
        }
        XCTAssertEqual(result.settlementDisposition, .notEligible)
        XCTAssertEqual(result.promptTokens, 40)
        let bodies = client.countBodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotNil(bodies.first?["response_format"])
        XCTAssertNil(bodies.last?["response_format"])
        XCTAssertNotNil(bodies.last?["tools"], "tools are part of the prompt")
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
        // #1690 E2E-F3: like the native runtime, a cancelled stream returns
        // its delivered prefix (empty finish reason) so the relay can sign a
        // buyer_cancel receipt over it, instead of throwing.
        let result = try await runtime.stream(request, with: handle, shouldCancel: { cancel.isSet }) { chunk in
            collector.record(chunk)
            if collector.contentChunks.count >= 3 { cancel.set() }
        }
        XCTAssertEqual(result.finishReason, "", "a cancelled stream must not report a normal finish")
        XCTAssertTrue(collector.contentChunks.joined().hasPrefix(result.content) || result.content.hasPrefix(collector.contentChunks.joined()))
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
        XCTAssertEqual(LoopbackServeSelection.select("lmstudio:foo"), .lmStudio, "lmstudio: arrived with its identity leg (#1690 M9)")
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
        XCTAssertTrue(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/api/v1/models")!, method: "GET"))
        XCTAssertFalse(LoopbackServeHTTPClient.isAllowed(URL(string: base + "/api/v1/models/load")!, method: "POST"))
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

private final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?
    var value: Date? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ date: Date) { lock.lock(); stored = date; lock.unlock() }
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
    private let statusCode: Int
    private let retainsLines: Bool
    private var retainedLines: AsyncThrowingStream<String, Error>?
    var wasTerminated: Bool { lock.lock(); defer { lock.unlock() }; return terminated }

    /// `retainsLines` keeps the stream referenced here, so dropping it does
    /// not close it and only an explicit close by the consumer ends it.
    init(statusCode: Int = 200, retainsLines: Bool = false) {
        self.statusCode = statusCode
        self.retainsLines = retainsLines
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
        if retainsLines {
            lock.lock()
            retainedLines = lines
            lock.unlock()
        }
        return BYOMLoopbackLineResponse(statusCode: statusCode, lines: lines)
    }
}

/// #1690 M9: an Ollama-like upstream. The stream never finishes on its own
/// and every content chunk lists two tokens in `logprobs`; a non-streamed
/// post is the prompt-count call and answers `promptTokens` (a 500 when nil).
private final class LogprobsStreamingLoopbackClient: BYOMLoopbackStreamingHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let promptTokens: Int?
    private let logprobs: Bool
    private let countDelaySeconds: Double
    private let rejectResponseFormat: Bool
    private let unlistOnCount: Bool
    private let toolCallAfter: Int?
    private var listedModelPath: String?
    private var _streamedBody: Data?
    private var _countBody: Data?
    private var _countBodies: [Data] = []

    /// `logprobs: false` streams plain chunks (mlx_lm.server, oMLX, LM Studio
    /// with tools). `countDelaySeconds` delays the prompt-count answer, and
    /// `rejectResponseFormat` answers 400 to a count body that carries one.
    /// `listedModelPath` makes `GET /v1/models` list that path (mlx_lm.server);
    /// `unlistOnCount` stops listing it while answering the prompt count.
    /// `toolCallAfter` streams one tool-call delta (with logprobs when
    /// `logprobs`) after that many content chunks.
    init(promptTokens: Int?, logprobs: Bool = true, countDelaySeconds: Double = 0, rejectResponseFormat: Bool = false, listedModelPath: String? = nil,
         unlistOnCount: Bool = false, toolCallAfter: Int? = nil) {
        self.promptTokens = promptTokens
        self.logprobs = logprobs
        self.countDelaySeconds = countDelaySeconds
        self.rejectResponseFormat = rejectResponseFormat
        self.unlistOnCount = unlistOnCount
        self.toolCallAfter = toolCallAfter
        self.listedModelPath = listedModelPath
    }

    var streamedBody: Data? { lock.lock(); defer { lock.unlock() }; return _streamedBody }
    var countBody: Data? { lock.lock(); defer { lock.unlock() }; return _countBody }
    var countBodies: [Data] { lock.lock(); defer { lock.unlock() }; return _countBodies }
    func unlist() { lock.lock(); listedModelPath = nil; lock.unlock() }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        let listed = lock.withLock { listedModelPath }
        guard url.path == "/v1/models" else { throw BYOMDiscoveryAdapterError.rejectedNonLoopback }
        let ids = listed.map { [["id": $0, "object": "model"]] } ?? [["id": "other-model", "object": "model"]]
        let body = try JSONSerialization.data(withJSONObject: ["object": "list", "data": ids])
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: body)
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        lock.withLock {
            _countBody = jsonBody
            _countBodies.append(jsonBody)
        }
        if countDelaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(countDelaySeconds * 1_000_000_000))
        }
        if unlistOnCount { unlist() }
        if rejectResponseFormat,
           let object = try? JSONSerialization.jsonObject(with: jsonBody) as? [String: Any], object["response_format"] != nil {
            return BYOMHTTPResponse(statusCode: 400, headers: [], body: Data(#"{"error":{"message":"format"}}"#.utf8))
        }
        guard let promptTokens else { return BYOMHTTPResponse(statusCode: 500, headers: [], body: Data()) }
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"x"},"finish_reason":"length"}],"usage":{"prompt_tokens":"# +
            "\(promptTokens)" + #","completion_tokens":1,"total_tokens":"# + "\(promptTokens + 1)" + "}}"
        return BYOMHTTPResponse(statusCode: 200, headers: [], body: Data(body.utf8))
    }

    func postLines(
        _ url: URL,
        jsonBody: Data,
        maxHeaderBytes: Int,
        maxLineBytes: Int,
        maxTotalBytes: Int,
        timeouts: LoopbackGenerationTimeouts
    ) async throws -> BYOMLoopbackLineResponse {
        lock.withLock { _streamedBody = jsonBody }
        let logprobs = self.logprobs
        let toolCallAfter = self.toolCallAfter
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let producer = Task {
                var sent = 0
                while !Task.isCancelled {
                    if sent == toolCallAfter {
                        continuation.yield(logprobs
                            ? #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"f","arguments":"{}"}}]},"logprobs":{"content":[{"token":"<tool_call>","logprob":-1}]}}]}"#
                            : #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"f","arguments":"{}"}}]}}]}"#)
                        continuation.yield("")
                    }
                    sent += 1
                    continuation.yield(logprobs
                        ? #"data: {"choices":[{"index":0,"delta":{"content":"x"},"logprobs":{"content":[{"token":"x","logprob":-1},{"token":"","logprob":-1}]}}]}"#
                        : #"data: {"choices":[{"index":0,"delta":{"content":"x"}}]}"#)
                    continuation.yield("")
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
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
    private var chatResponse: Data?
    private var modelPathAfterChat: String?

    init(modelPath: String, nCtx: Int, promptTokens: Int) {
        self.modelPath = modelPath
        self.nCtx = nCtx
        self.promptTokens = promptTokens
    }

    var chatPosts: Int { lock.lock(); defer { lock.unlock() }; return _chatPosts }
    func setModelPath(_ path: String) { lock.lock(); modelPath = path; lock.unlock() }
    /// Chat completions answer 200 with `body` (default: a bare 500).
    func setChatResponse(_ body: Data) { lock.lock(); chatResponse = body; lock.unlock() }
    /// The next chat completion re-points `/props` to `path` (a reload mid-generation).
    func setModelPathAfterChat(_ path: String) { lock.lock(); modelPathAfterChat = path; lock.unlock() }
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
            let body = chatResponse
            if let next = modelPathAfterChat {
                modelPath = next
                modelPathAfterChat = nil
            }
            lock.unlock()
            guard let body else { return BYOMHTTPResponse(statusCode: 500, headers: [], body: Data()) }
            return BYOMHTTPResponse(statusCode: 200, headers: [], body: body)
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

// MARK: #1690 — loopback startup throughput probe (SPEC-001 FR-20)

extension OpenAICompatibleLoopbackRuntimeTests {
    private static let probeSSE = Data("""
    data: {"choices":[{"delta":{"role":"assistant","content":"Hi"}}]}

    data: {"choices":[{"delta":{"content":" there"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"length"}]}

    data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8}}

    data: [DONE]

    """.utf8)

    func testLoopbackStartupProbeReportsAPositiveRateFromUpstreamUsage() async throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Self.probeSSE)
        let runtime = try makeRuntime(httpClient: client, store: store, countTokens: { _ in 8 })

        let outcome = await runtime.measureStartupThroughput(maxTokens: ModelRuntime.startupThroughputProbeMaxTokens)
        guard case .ok(let tps) = outcome else { return XCTFail("expected ok, got \(outcome)") }
        XCTAssertGreaterThan(tps, 1, "a successful probe clears the coordinator's 1 tok/s routing floor")
        XCTAssertEqual(outcome.tps, tps)
        XCTAssertEqual(client.postCount, 1, "exactly one probe generation")

        // One fixed short generation through the runtime's own leg: the
        // upstream model name, the native token budget, streamed with usage.
        XCTAssertEqual(client.lastURL?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(client.lastBody)) as? [String: Any])
        XCTAssertEqual(sent["model"] as? String, "gemma3:270m")
        XCTAssertEqual(sent["max_tokens"] as? Int, ModelRuntime.startupThroughputProbeMaxTokens)
        XCTAssertEqual(sent["stream"] as? Bool, true)
        XCTAssertEqual((sent["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)

        // The log line names the rate and runtime, never the completion text.
        let line = outcome.logLine(runtimeSource: OllamaLoopbackServeModel.runtimeSource)
        XCTAssertTrue(line.hasPrefix("event=loopback_startup_throughput_probe outcome=ok tps="), line)
        XCTAssertTrue(line.hasSuffix(" runtime_source=ollama_loopback"), line)
        XCTAssertFalse(line.contains("Hi") || line.contains("there") || line.contains("greeting"), line)
    }

    private static let predictedNOnlySSE = Data("""
    data: {"choices":[{"delta":{"content":"Hi"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"length"}],"timings":{"predicted_n":8,"predicted_ms":0.001,"predicted_per_second":1000000000}}

    data: [DONE]

    """.utf8)

    func testLoopbackStartupProbeIgnoresTheUpstreamRateAndCountsPredictedN() async throws {
        // llama-server without `usage`: `timings.predicted_n` is the count;
        // its self-reported `predicted_per_second` is never the result.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llamacpp-predicted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tiny-q4.gguf")
        try (Data("GGUF".utf8) + Data(repeating: 0x5a, count: 4096)).write(to: file)
        let client = LlamaCppStubClient(modelPath: file.resolvingSymlinksInPath().path, nCtx: 64, promptTokens: 40)
        client.setChatResponse(Self.predictedNOnlySSE)
        let recountDirectory = try makeSnapshotDirectory("llamacpp-predicted")
        let recountSnapshot = try MLXSnapshotIdentity.compute(directory: recountDirectory)
        let runtime = try await OpenAICompatibleLoopbackRuntime.llamaCpp(
            servedModelRef: "llamacpp:tiny-q4",
            origin: "http://127.0.0.1:9191",
            selector: BYOMLlamaCppArtifactSelector(root: nil, pinnedFile: file),
            siblingSnapshotSHA256: recountSnapshot.digest,
            siblingSnapshotDirectories: [recountDirectory],
            httpClient: client,
            cache: BYOMArtifactDigestCache(url: root.appendingPathComponent("cache.json")),
            pinRecountTokenizer: { snapshot in PinnedSnapshotTokenizer(snapshot: snapshot, encode: { _ in 8 }) }
        )
        let outcome = await runtime.measureStartupThroughput()
        guard case .ok(let tps) = outcome else { return XCTFail("expected ok, got \(outcome)") }
        XCTAssertGreaterThan(tps, 0)
        XCTAssertNotEqual(tps, 1_000_000_000, "the upstream's own rate claim is ignored")
    }

    func testLoopbackStartupProbeIgnoresPredictedNForANonLlamaRuntime() async throws {
        // `timings.predicted_n` is llama-server's field; any other runtime
        // sending it is not believed, and without `usage` the probe fails closed.
        let store = try makeStore()
        let runtime = try makeRuntime(
            httpClient: StubLoopbackHTTPClient(responseBody: Self.predictedNOnlySSE),
            store: store,
            countTokens: { _ in 8 }
        )
        let runtimeSource = await runtime.runtimeSource
        XCTAssertEqual(runtimeSource, OllamaLoopbackServeModel.runtimeSource)
        let outcome = await runtime.measureStartupThroughput()
        XCTAssertEqual(outcome, .failed(reason: "no_tokens"))
        XCTAssertEqual(outcome.tps, 0)
    }

    func testLoopbackStartupProbeCapsUsageAtTheTrustedTokenizerRecount() async throws {
        // One content fragment with a forged `usage.completion_tokens: 8`.
        let sse = """
        data: {"choices":[{"delta":{"content":"Hi there friend"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"length"}]}

        data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8}}

        data: [DONE]

        """
        var accumulator = OpenAICompatibleStreamAccumulator()
        for line in sse.components(separatedBy: "\n") {
            _ = try accumulator.consume(line: line)
        }
        XCTAssertEqual(accumulator.upstreamCompletionTokens, 8)
        XCTAssertEqual(accumulator.contentDeltaCount, 1)

        // Counted = min(upstream 8, trusted recount 1) = 1: neither source can
        // inflate the rate alone, regardless of stream fragmentation.
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: accumulator.upstreamCompletionTokens,
                recountedCompletionTokens: 1,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .ok(tps: 1)
        )
        // An honest per-token stream keeps its full count.
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: 8,
                recountedCompletionTokens: 8,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .ok(tps: 8)
        )
        // The max_tokens bound applies to the upstream count before the cap.
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: 9,
                recountedCompletionTokens: 1,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .failed(reason: "usage_exceeds_max_tokens")
        )

        // End to end the forged stream still succeeds, counted as one trusted token.
        let store = try makeStore()
        let runtime = try makeRuntime(
            httpClient: StubLoopbackHTTPClient(responseBody: Data(sse.utf8)),
            store: store,
            countTokens: { _ in 1 }
        )
        let outcome = await runtime.measureStartupThroughput(maxTokens: 8)
        XCTAssertGreaterThan(outcome.tps, 0, "\(outcome)")
    }

    func testLoopbackStartupProbeCountsFragmentedStreamByTrustedRecount() throws {
        var accumulator = OpenAICompatibleStreamAccumulator()
        for _ in 0..<8 {
            _ = try accumulator.consume(line: #"data: {"choices":[{"delta":{"content":"x"}}]}"#)
            _ = try accumulator.consume(line: "")
        }
        _ = try accumulator.consume(line: #"data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8}}"#)
        _ = try accumulator.consume(line: "")
        _ = try accumulator.consume(line: "data: [DONE]")
        _ = try accumulator.consume(line: "")
        let (result, _) = try accumulator.finish()
        XCTAssertEqual(result.content, String(repeating: "x", count: 8))
        XCTAssertEqual(accumulator.contentDeltaCount, 8)
        XCTAssertEqual(accumulator.upstreamCompletionTokens, 8)
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: !result.content.isEmpty,
                upstreamCompletionTokens: accumulator.upstreamCompletionTokens,
                recountedCompletionTokens: 1,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .ok(tps: 1)
        )
    }

    func testNativeAndLoopbackStartupProbesShareOneThroughputFormula() {
        // SPEC-002 `throughput_tps_estimate` is one cross-runtime quantity:
        // completion tokens over the whole request's elapsed time. The native
        // probe returns `ModelRuntime.startupThroughputRate` directly; the
        // loopback probe must give the identical value for identical inputs.
        for (tokens, elapsed) in [(8, 32.0), (8, 0.08), (1, 1.0), (5, 2.5), (8, 0.0005)] {
            XCTAssertEqual(
                OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                    contentPresent: true,
                    upstreamCompletionTokens: tokens,
                    recountedCompletionTokens: tokens,
                    maxTokens: 8,
                    elapsedSeconds: elapsed
                ).tps,
                ModelRuntime.startupThroughputRate(completionTokens: tokens, elapsedSeconds: elapsed),
                "tokens \(tokens) elapsed \(elapsed)"
            )
        }
        XCTAssertEqual(ModelRuntime.startupThroughputRate(completionTokens: 8, elapsedSeconds: 32), 0.25)
    }

    func testStartupThroughputIsTokensOverTotalElapsedLikeTheNativeProbe() {
        // 8 tokens; a 30 s cold load + prefill counts, as in the native probe.
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: 8,
                recountedCompletionTokens: 8,
                maxTokens: 8,
                elapsedSeconds: 32
            ),
            .ok(tps: 0.25)
        )
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: 8,
                recountedCompletionTokens: 8,
                maxTokens: 8,
                elapsedSeconds: 0.08
            ).tps,
            100, accuracy: 0.001
        )
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: false,
                upstreamCompletionTokens: 8,
                recountedCompletionTokens: 8,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .failed(reason: "no_content")
        )
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: nil,
                recountedCompletionTokens: 8,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .failed(reason: "no_tokens")
        )
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: 0,
                recountedCompletionTokens: 8,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .failed(reason: "no_tokens")
        )
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: 9,
                recountedCompletionTokens: 8,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .failed(reason: "usage_exceeds_max_tokens")
        )
        XCTAssertEqual(
            OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                contentPresent: true,
                upstreamCompletionTokens: 8,
                recountedCompletionTokens: 9,
                maxTokens: 8,
                elapsedSeconds: 1
            ),
            .failed(reason: "recount_exceeds_max_tokens")
        )
        for elapsed in [0, -1, TimeInterval.nan, TimeInterval.infinity] {
            XCTAssertEqual(
                OpenAICompatibleLoopbackRuntime.startupThroughputOutcome(
                    contentPresent: true,
                    upstreamCompletionTokens: 8,
                    recountedCompletionTokens: 8,
                    maxTokens: 8,
                    elapsedSeconds: elapsed
                ),
                .failed(reason: "no_elapsed_time"),
                "elapsed \(elapsed)"
            )
        }
    }

    func testLoopbackStartupProbeNeverCountsChunksWithoutUpstreamUsage() async throws {
        let store = try makeStore()
        let sse = Data("""
        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: {"choices":[{"delta":{"content":" there"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """.utf8)
        let runtime = try makeRuntime(httpClient: StubLoopbackHTTPClient(responseBody: sse), store: store, countTokens: { _ in 8 })
        let outcome = await runtime.measureStartupThroughput()
        XCTAssertEqual(outcome, .failed(reason: "no_tokens"))
        XCTAssertEqual(outcome.tps, 0)
    }

    func testLoopbackStartupProbeRejectsUsageOnlyAndOverBudgetClaims() async throws {
        let store = try makeStore()
        let usageOnly = Data("""
        data: {"choices":[{"delta":{},"finish_reason":"length"}]}

        data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8}}

        data: [DONE]

        """.utf8)
        let usageOnlyRuntime = try makeRuntime(
            httpClient: StubLoopbackHTTPClient(responseBody: usageOnly),
            store: store,
            countTokens: { _ in 8 }
        )
        let usageOnlyOutcome = await usageOnlyRuntime.measureStartupThroughput()
        XCTAssertEqual(usageOnlyOutcome, .failed(reason: "no_content"))

        let overBudget = Data("""
        data: {"choices":[{"delta":{"content":"Hi"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":100000}}

        data: [DONE]

        """.utf8)
        let overBudgetRuntime = try makeRuntime(
            httpClient: StubLoopbackHTTPClient(responseBody: overBudget),
            store: store,
            countTokens: { _ in 8 }
        )
        let overBudgetOutcome = await overBudgetRuntime.measureStartupThroughput(maxTokens: 8)
        XCTAssertEqual(overBudgetOutcome, .failed(reason: "usage_exceeds_max_tokens"))
        XCTAssertEqual(overBudgetOutcome.tps, 0)
    }

    func testLoopbackStartupProbeRejectsToolBearingResults() async throws {
        let store = try makeStore()
        let toolOnly = Data("""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"f","arguments":"{}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":1}}

        data: [DONE]

        """.utf8)
        let toolOnlyRuntime = try makeRuntime(
            httpClient: StubLoopbackHTTPClient(responseBody: toolOnly),
            store: store,
            countTokens: { _ in 1 }
        )
        let toolOnlyOutcome = await toolOnlyRuntime.measureStartupThroughput()
        XCTAssertEqual(toolOnlyOutcome, .failed(reason: "tool_calls"))

        let mixed = Data("""
        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"f","arguments":"{}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":2}}

        data: [DONE]

        """.utf8)
        let mixedRuntime = try makeRuntime(
            httpClient: StubLoopbackHTTPClient(responseBody: mixed),
            store: store,
            countTokens: { _ in 2 }
        )
        let mixedOutcome = await mixedRuntime.measureStartupThroughput()
        XCTAssertEqual(mixedOutcome, .failed(reason: "tool_calls"))
    }

    func testPoolOnlyGGUFStartupProbeWithoutSiblingUsesBoundedUpstreamUsage() async throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Self.completionJSON(content: "ok", completionTokens: 3, promptTokens: 11))
        let runtime = try makeRuntime(httpClient: client, store: store)

        let outcome = await runtime.measureStartupThroughput()
        XCTAssertGreaterThan(outcome.tps, 0, "pool-only GGUF must not require a catalog sibling: \(outcome)")
        XCTAssertEqual(client.postCount, 1, "one advisory startup probe")

        let served = try await runtime.complete(try makeRequest(model: "ollama:gemma3:270m"))
        XCTAssertEqual(served.content, "ok")
        XCTAssertEqual(served.completionTokens, 3)
        XCTAssertEqual(client.postCount, 2, "ordinary serving is unaffected")
    }

    func testGGUFStartupProbeExpectedButUnavailableSiblingDoesNotDowngrade() async throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Self.completionJSON(content: "ok", completionTokens: 3, promptTokens: 11))
        let runtime = try OpenAICompatibleLoopbackRuntime(
            servedModelRef: "ollama:gemma3:270m",
            origin: "http://127.0.0.1:11434",
            httpClient: client,
            digestResolver: makeResolver(store),
            siblingSnapshotSHA256: String(repeating: "a", count: 64),
            siblingSnapshotDirectories: []
        )
        let outcome = await runtime.measureStartupThroughput()
        XCTAssertEqual(outcome, .failed(reason: "tokenizer_unavailable"))
        XCTAssertEqual(client.postCount, 0)
        let served = try await runtime.complete(try makeRequest(model: "ollama:gemma3:270m"))
        XCTAssertEqual(served.content, "ok")
        XCTAssertEqual(client.postCount, 1, "ordinary serving remains independent of startup capacity")
    }

    func testGGUFStartupProbeWithoutSiblingStillRejectsOverBudgetUsage() async throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Self.completionJSON(content: "ok", completionTokens: 9, promptTokens: 11))
        let runtime = try makeRuntime(httpClient: client, store: store)
        let outcome = await runtime.measureStartupThroughput(maxTokens: 8)
        XCTAssertEqual(outcome, .failed(reason: "usage_exceeds_max_tokens"))
        XCTAssertEqual(client.postCount, 1)
    }

    func testLoopbackStartupProbeRejectsTokenizerIdentityMutation() async throws {
        let store = try makeStore()
        let directory = try makeSnapshotDirectory("startup-recount-mutates")
        let snapshot = try MLXSnapshotIdentity.compute(directory: directory)
        let client = StubLoopbackHTTPClient(responseBody: Self.probeSSE)
        let runtime = try OpenAICompatibleLoopbackRuntime(
            servedModelRef: "ollama:gemma3:270m",
            origin: "http://127.0.0.1:11434",
            httpClient: client,
            digestResolver: makeResolver(store),
            siblingSnapshotSHA256: snapshot.digest,
            siblingSnapshotDirectories: [directory],
            pinRecountTokenizer: { pinned in
                PinnedSnapshotTokenizer(snapshot: pinned) { text in
                    try? Data(#"{"swapped":true}"#.utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
                    return text.count
                }
            }
        )

        let outcome = await runtime.measureStartupThroughput()
        XCTAssertEqual(outcome, .failed(reason: "tokenizer_identity_changed"))
        XCTAssertEqual(client.postCount, 1)
    }

    func testLoopbackStartupProbeAcceptsPlainBodyWithTrustedRecount() async throws {
        let store = try makeStore()
        let client = StubLoopbackHTTPClient(responseBody: Self.completionJSON(content: "ok!", completionTokens: 3))
        let runtime = try makeRuntime(httpClient: client, store: store, countTokens: { _ in 3 })

        let outcome = await runtime.measureStartupThroughput(maxTokens: 8)
        guard case .ok(let tps) = outcome else { return XCTFail("expected ok, got \(outcome)") }
        XCTAssertGreaterThan(tps, 0)
        XCTAssertEqual(client.postCount, 1)
    }

    func testLoopbackStartupProbeChecksLlamaServerServesTheBoundFileBeforeAndAfter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("llamacpp-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tiny-q4.gguf")
        try (Data("GGUF".utf8) + Data(repeating: 0x5a, count: 4096)).write(to: file)
        let servedPath = file.resolvingSymlinksInPath().path
        let client = LlamaCppStubClient(modelPath: servedPath, nCtx: 64, promptTokens: 40)
        client.setChatResponse(Self.probeSSE)
        let recountDirectory = try makeSnapshotDirectory("llamacpp-probe")
        let recountSnapshot = try MLXSnapshotIdentity.compute(directory: recountDirectory)
        let runtime = try await OpenAICompatibleLoopbackRuntime.llamaCpp(
            servedModelRef: "llamacpp:tiny-q4",
            origin: "http://127.0.0.1:9191",
            selector: BYOMLlamaCppArtifactSelector(root: nil, pinnedFile: file),
            siblingSnapshotSHA256: recountSnapshot.digest,
            siblingSnapshotDirectories: [recountDirectory],
            httpClient: client,
            cache: BYOMArtifactDigestCache(url: root.appendingPathComponent("cache.json")),
            pinRecountTokenizer: { snapshot in PinnedSnapshotTokenizer(snapshot: snapshot, encode: { _ in 8 }) }
        )

        let bound = await runtime.measureStartupThroughput()
        XCTAssertGreaterThan(bound.tps, 0, "\(bound)")
        XCTAssertEqual(client.chatPosts, 1)

        // llama-server reloaded another GGUF during the generation.
        client.setModelPathAfterChat("/tmp/other-q4.gguf")
        let swappedDuring = await runtime.measureStartupThroughput()
        XCTAssertEqual(swappedDuring, .failed(reason: "identity_unbound"))
        XCTAssertEqual(client.chatPosts, 2)

        // Already serving another GGUF: no generation at all.
        let swappedBefore = await runtime.measureStartupThroughput()
        XCTAssertEqual(swappedBefore, .failed(reason: "identity_unbound"))
        XCTAssertEqual(client.chatPosts, 2, "an unbound upstream is never probed")
    }

    func testLoopbackStartupProbeFailureReportsZeroAndServingContinues() async throws {
        let store = try makeStore()
        let client = FailFirstPostLoopbackClient(
            failStatus: 503,
            then: Self.completionJSON(content: "ok", completionTokens: 3, promptTokens: 11)
        )
        let runtime = try makeRuntime(httpClient: client, store: store, countTokens: { _ in 8 })

        let outcome = await runtime.measureStartupThroughput()
        XCTAssertEqual(outcome, .failed(reason: "upstream_status_503"))
        XCTAssertEqual(outcome.tps, 0)
        XCTAssertEqual(
            outcome.logLine(runtimeSource: OllamaLoopbackServeModel.runtimeSource),
            "event=loopback_startup_throughput_probe outcome=failed reason=upstream_status_503 runtime_source=ollama_loopback"
        )

        // The failed probe leaves the runtime serving.
        let result = try await runtime.complete(try makeRequest(model: "ollama:gemma3:270m"))
        XCTAssertEqual(result.content, "ok")
        XCTAssertEqual(result.completionTokens, 3)

        // Transport failures map to closed reason codes, never a throw.
        let timedOut = try makeRuntime(
            httpClient: ScriptedLoopbackClient(failure: .openTimesOut),
            store: store,
            countTokens: { _ in 8 }
        )
        let timedOutOutcome = await timedOut.measureStartupThroughput()
        XCTAssertEqual(timedOutOutcome, .failed(reason: "timeout"))
        let empty = try makeRuntime(httpClient: StubLoopbackHTTPClient(responseBody: Data()), store: store, countTokens: { _ in 8 })
        let emptyOutcome = await empty.measureStartupThroughput()
        XCTAssertEqual(emptyOutcome, .failed(reason: "malformed_response"))
    }

    func testLoopbackStartupProbeClosesTheUpstreamStreamOnANon2xxStatus() async throws {
        let store = try makeStore()
        let client = EndlessStreamingLoopbackClient(statusCode: 503, retainsLines: true)
        let runtime = try makeRuntime(httpClient: client, store: store, countTokens: { _ in 8 })
        let outcome = await runtime.measureStartupThroughput(maxTokens: 8, timeoutSeconds: 30)
        XCTAssertEqual(outcome, .failed(reason: "upstream_status_503"))
        XCTAssertTrue(client.wasTerminated, "the error body stream is closed before the probe returns")
    }

    func testLoopbackStartupProbeIsBoundedByItsHardTimeout() async throws {
        let store = try makeStore()
        let client = EndlessStreamingLoopbackClient()
        let runtime = try makeRuntime(httpClient: client, store: store, countTokens: { _ in 8 })
        let start = Date()
        let outcome = await runtime.measureStartupThroughput(maxTokens: 8, timeoutSeconds: 0.3)
        XCTAssertEqual(outcome, .failed(reason: "timeout"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the probe never holds serve startup past its bound")
        for _ in 0..<50 where !client.wasTerminated {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(client.wasTerminated, "the abandoned probe closes the upstream stream")
    }

    func testLoopbackStartupProbeEndsPromptlyWhenTheCallerIsCancelled() async throws {
        let store = try makeStore()
        let client = EndlessStreamingLoopbackClient()
        let runtime = try makeRuntime(httpClient: client, store: store, countTokens: { _ in 8 })
        let start = Date()
        let probe = Task { await runtime.measureStartupThroughput(maxTokens: 8, timeoutSeconds: 30) }
        try await Task.sleep(nanoseconds: 200_000_000)
        probe.cancel()
        let outcome = await probe.value
        XCTAssertEqual(outcome, .failed(reason: "cancelled"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "caller cancellation ends the probe well before its 30 s deadline")
        for _ in 0..<50 where !client.wasTerminated {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(client.wasTerminated, "caller cancellation closes the upstream stream")
    }

    func testLoopbackStartupProbeIsNeverCountedAsUsage() async throws {
        let store = try makeStore()
        let runtime = try makeRuntime(
            httpClient: StubLoopbackHTTPClient(responseBody: Self.probeSSE),
            store: store,
            countTokens: { _ in 8 }
        )
        let status = ProviderStatus(
            modelID: "ollama:gemma3:270m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        await runtime.setProviderStatus(status)
        let before = await status.snapshot()

        let outcome = await runtime.measureStartupThroughput()
        XCTAssertGreaterThan(outcome.tps, 0)

        let after = await status.snapshot()
        XCTAssertEqual(after.requestsTotal, before.requestsTotal)
        XCTAssertEqual(after.inputTokensAllTime, before.inputTokensAllTime)
        XCTAssertEqual(after.outputTokensAllTime, before.outputTokensAllTime)
        XCTAssertEqual(after.errorsTotal, before.errorsTotal)
    }
}

/// The first post answers `failStatus`; every later post answers `then`.
private final class FailFirstPostLoopbackClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let failStatus: Int
    private let body: Data
    private var posts = 0

    init(failStatus: Int, then body: Data) {
        self.failStatus = failStatus
        self.body = body
    }

    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }

    func post(_ url: URL, jsonBody: Data, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        return nextIsFirst()
            ? BYOMHTTPResponse(statusCode: failStatus, headers: [], body: Data(#"{"error":{"message":"loading"}}"#.utf8))
            : BYOMHTTPResponse(statusCode: 200, headers: [], body: body)
    }

    private func nextIsFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        posts += 1
        return posts == 1
    }
}
