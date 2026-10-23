import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelRuntimeToolSelectionTests: XCTestCase {
    private func request(choice: Any = "required", stream: Bool = false, model: String = ToolSelectionPolicy.supportedNativeModel) throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "Look up 3"]],
            "stream": stream, "tool_choice": choice, "max_tokens": 100, "parallel_tool_calls": false,
            "tools": [["type": "function", "function": ["name": "lookup", "parameters": [
                "type": "object", "properties": ["id": ["type": "integer"]],
                "required": ["id"], "additionalProperties": false,
            ]]]],
        ]))
    }

    private func runtime(
        content: String = "", name: String? = "lookup", arguments: String = #"{"id":3}"#, cancel: Bool = false,
        modelID: String = ToolSelectionPolicy.supportedNativeModel, catalogModelIDAlias: String? = nil,
        warmSwapEnabled: Bool = false
    ) -> ModelRuntime {
        ModelRuntime(
            modelID: modelID, warmSwapEnabled: warmSwapEnabled, catalogModelIDAlias: catalogModelIDAlias,
            loader: { _ in throw CancellationError() },
            testLoader: warmSwapEnabled ? { target in (target, "\(target)-hash") } : nil,
            testCompletion: { _, _ in
                if cancel { throw CancellationError() }
                return CompletionResult(
                    content: content, finishReason: name == nil ? "stop" : "tool_calls",
                    promptTokens: 1, completionTokens: 9,
                    toolCalls: name.map { [ToolCall(id: "call_0123456789abcdef", functionName: $0, arguments: arguments)] },
                    settlementDisposition: .eligibleOwner
                )
            }
        )
    }

    func testNativeNonstreamRequiredRejectsProseAndNamedRejectsOtherFunction() async throws {
        for (runtime, request) in [
            (runtime(content: "ordinary prose", name: nil), try request()),
            (runtime(name: "other"), try request(choice: ["type": "function", "function": ["name": "lookup"]])),
            (runtime(arguments: #"{"id":"wrong"}"#), try request()),
        ] {
            do {
                _ = try await runtime.complete(request)
                XCTFail("invalid tool output succeeded")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "tool_selection_validation_failed")
                XCTAssertTrue(error.inferenceRan)
            }
        }
    }

    func testNativeStreamingWithholdsInvalidOutputAndCancellation() async throws {
        for runtime in [runtime(content: "must stay private", name: nil), runtime(arguments: #"{"id":"wrong"}"#), runtime(cancel: true)] {
            let request = try request(stream: true)
            let handle = try await runtime.acquireRequestHandle(request)
            let chunks = ToolSelectionChunkLog()
            do {
                _ = try await runtime.stream(request, with: handle, onChunk: { chunks.append($0) })
                XCTFail("invalid or cancelled output succeeded")
            } catch is CancellationError {
                // A cancelled held response has delivered no billable output.
            } catch let error as APIError {
                XCTAssertEqual(error.code, "tool_selection_validation_failed")
            }
            XCTAssertEqual(chunks.count, 0)
            await runtime.unregisterInFlight(handle.registrationID)
        }
    }

    func testNativeStreamingReleasesOnlyValidatedFinalCallAndHonorsDisconnect() async throws {
        let runtime = runtime()
        let request = try request(stream: true)
        let handle = try await runtime.acquireRequestHandle(request)
        let chunks = ToolSelectionChunkLog()
        let result = try await runtime.stream(request, with: handle, onChunk: { chunks.append($0) })
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(result.toolCalls?.first?.arguments, #"{"id":3}"#)
        let disconnected = ToolSelectionChunkLog()
        do {
            _ = try await runtime.stream(request, with: handle, shouldCancel: { true }, onChunk: { disconnected.append($0) })
            XCTFail("disconnected request succeeded")
        } catch is CancellationError {}
        XCTAssertEqual(disconnected.count, 0)
        await runtime.unregisterInFlight(handle.registrationID)
    }

    func testAdditionalExactProfilesHoldStreamingUntilSchemaAndSelectionValidate() async throws {
        for model in ["mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"] {
            for choice in ["required", ["type": "function", "function": ["name": "lookup"]]] as [Any] {
                for valid in [true, false] {
                    let runtime = runtime(arguments: valid ? #"{"id":3}"# : #"{"id":"wrong"}"#, modelID: model)
                    let request = try request(choice: choice, stream: true, model: model)
                    let handle = try await runtime.acquireRequestHandle(request)
                    let chunks = ToolSelectionChunkLog()
                    do {
                        let result = try await runtime.stream(request, with: handle, onChunk: { chunks.append($0) })
                        XCTAssertTrue(valid, "invalid schema must not succeed")
                        XCTAssertEqual(result.toolCalls?.first?.functionName, "lookup")
                        XCTAssertEqual(chunks.count, 1)
                    } catch let error as APIError {
                        XCTAssertFalse(valid)
                        XCTAssertEqual(error.code, "tool_selection_validation_failed")
                        XCTAssertEqual(chunks.count, 0, "invalid held output must not escape")
                    }
                    await runtime.unregisterInFlight(handle.registrationID)
                }
            }
        }
    }

    func testNoneStripsToolDescriptorsAndRejectsCalls() async throws {
        let request = try request(choice: "none")
        let input = try ModelRuntime.userInput(for: request)
        XCTAssertNil(input.tools)
        do {
            _ = try await runtime().complete(request)
            XCTFail("none returned calls")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "tool_selection_validation_failed")
        }
        let text = try await runtime(content: "text", name: nil).complete(request)
        XCTAssertEqual(text.content, "text")
    }

    func testGuaranteedSelectionRunsPastFirstCallAndRejectsLaterOutput() throws {
        let request = try request()
        let call = #"<tool_call>{"name":"lookup","arguments":{"id":3}}</tool_call>"#
        XCTAssertFalse(ModelRuntime.serialToolStopApplies(request))
        XCTAssertFalse(ModelRuntime.serialNativeToolStopApplies(request))
        var observer = NativeToolCallStreamEmitter(modelID: request.model, allowedFunctionNames: ["lookup"])
        for prefix in [call, call + #"<tool_call>{"name":"lookup","arguments":{"id":"#] {
            XCTAssertFalse(ModelRuntime.observeSerialToolStop(
                &observer, decoded: prefix, stopTokenFilter: StopTokenFilter(tokens: []),
                requestStops: [], guaranteedSelection: true
            ))
        }
        XCTAssertThrowsError(try ModelRuntime.parseGeneratedOutput(
            filteredText: call + #"<tool_call>{"name":"lookup","arguments":{"id":"#,
            generatedTokenIDs: [], decode: { _ in "" }, request: request,
            mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: nil
        ))
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: call + call, generatedTokenIDs: [], decode: { _ in "" },
            request: request, mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: nil
        )
        XCTAssertEqual(parsed.toolCalls.count, 2, "No call may be silently dropped before cardinality validation")
        XCTAssertThrowsError(try ModelRuntime.validateStructuredCompletion(CompletionResult(
            content: "", finishReason: "tool_calls", promptTokens: 1, completionTokens: 9,
            toolCalls: parsed.toolCalls, settlementDisposition: .eligibleOwner
        ), request: request))
        let auto = try self.request(choice: "auto")
        XCTAssertTrue(ModelRuntime.serialToolStopApplies(auto))
        XCTAssertTrue(ModelRuntime.observeSerialToolStop(
            &observer, decoded: call, stopTokenFilter: StopTokenFilter(tokens: []), requestStops: []
        ))
    }

    func testGuaranteedSelectionAcceptsQwen36TemplateFormatEndToEnd() throws {
        // #2014: the live model answered required/named in its template's
        // function-XML format and every turn failed validation.
        let raw = "<tool_call>\n<function=lookup>\n<parameter=id>\n3\n</parameter>\n</function>\n</tool_call>"
        for choice in ["required", ["type": "function", "function": ["name": "lookup"]]] as [Any] {
            let request = try request(choice: choice)
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: raw, generatedTokenIDs: [], decode: { _ in "" },
                request: request, mode: .complete(), defaultCompletionTokens: 9, toolCallPrefill: nil
            )
            XCTAssertEqual(parsed.content, "")
            XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["lookup"])
            XCTAssertEqual(parsed.toolCalls.first?.arguments, #"{"id":3}"#)
            XCTAssertNoThrow(try ModelRuntime.validateStructuredCompletion(CompletionResult(
                content: "", finishReason: "stop", promptTokens: 1, completionTokens: 9,
                toolCalls: parsed.toolCalls, settlementDisposition: .eligibleOwner
            ), request: request))
        }
    }

    func testSelectionInstructionMergesIntoTheLeadingSystemMessage() throws {
        // Qwen3.6's template raises when a system message is not first.
        let body: [String: Any] = [
            "model": ToolSelectionPolicy.supportedNativeModel,
            "messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": "Look up 3"]],
            "tool_choice": "required", "max_tokens": 100,
            "tools": [["type": "function", "function": ["name": "lookup", "parameters": [
                "type": "object", "properties": ["id": ["type": "integer"]],
                "required": ["id"], "additionalProperties": false,
            ]]]],
        ]
        for choice in ["required", "none", ["type": "function", "function": ["name": "lookup"]]] as [Any] {
            var withChoice = body
            withChoice["tool_choice"] = choice
            let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: withChoice))
            let chat = try ModelRuntime.userInput(for: request).prompt
            guard case .chat(let messages) = chat else { return XCTFail("expected chat input") }
            XCTAssertEqual(messages.map(\.role), [.system, .user])
            XCTAssertTrue(messages[0].content.hasPrefix("Be brief."))
            XCTAssertFalse(messages[0].content.contains("JSON <tool_call>"))
        }
        let lateSystem = ModelRuntime.withLeadingSystemInstruction("rule", to: [
            ChatMessage(role: .user, content: "hi"), ChatMessage(role: .system, content: "late"),
        ])
        XCTAssertEqual(lateSystem.map(\.role), [.system, .user, .system], "a buyer system message is never moved or merged out of place")
        XCTAssertEqual(lateSystem[0].content, "rule")
    }

    func testCapabilitiesOnlyBindTheCurrentLoadedIdentity() {
        let canonical = ToolSelectionPolicy.supportedNativeModel
        // #2014: the runtime's wire identity of an alias-configured model is
        // its catalog id, so the claim is evaluated on that id.
        let supported = CoordinatorClient.toolSelectionCapabilities(wireModelID: canonical, runtimeWireModelID: canonical, runtimeSource: nil)
        XCTAssertEqual(supported.first?["model_id"] as? String, canonical)
        XCTAssertEqual(supported.first?["runtime"] as? String, "mlx_cache")
        XCTAssertEqual(supported.first?["modes"] as? [String], ["auto", "none", "required", "named"])
        // Re-audit r1: the token that lets the coordinator route a non-strict
        // parameters schema here (older CLIs refuse it).
        XCTAssertEqual(supported.first?["schema_profiles"] as? [String], ["ordinary-parameters-v1"])
        // A claim keyed by another id never inherits the allowlisted identity.
        XCTAssertEqual(CoordinatorClient.toolSelectionCapabilities(wireModelID: "catalog-alias", runtimeWireModelID: canonical, runtimeSource: nil).first?["modes"] as? [String], ["auto", "none"])
        // Swap in flight: the advertised id is not the runtime's current one.
        XCTAssertEqual(CoordinatorClient.toolSelectionCapabilities(wireModelID: canonical, runtimeWireModelID: "other", runtimeSource: nil).first?["modes"] as? [String], ["auto", "none"])
        XCTAssertEqual(CoordinatorClient.toolSelectionCapabilities(wireModelID: "other", runtimeWireModelID: "other", runtimeSource: nil).first?["modes"] as? [String], ["auto", "none"])
        XCTAssertEqual(CoordinatorClient.toolSelectionCapabilities(wireModelID: "other", runtimeWireModelID: "other", runtimeSource: "ollama_loopback").first?["modes"] as? [String], ["auto"])
        XCTAssertTrue(CoordinatorClient.toolSelectionCapabilities(wireModelID: canonical, runtimeWireModelID: nil, runtimeSource: nil).isEmpty)
    }

    /// #2014: `model` is a local alias and `model_catalog_model_id` is the
    /// allowlisted catalog id. The loaded identity is the catalog id.
    func testAliasConfiguredCatalogModelAcceptsNamedSelection() async throws {
        let named: [String: Any] = ["type": "function", "function": ["name": "lookup"]]
        for model in [ToolSelectionPolicy.supportedNativeModel, "qwen/qwen3.6-35b-a3b"] {
            let runtime = runtime(modelID: "qwen/qwen3.6-35b-a3b", catalogModelIDAlias: ToolSelectionPolicy.supportedNativeModel)
            let request = try request(choice: named, model: model)
            let handle = try await runtime.acquireRequestHandle(request)
            await runtime.unregisterInFlight(handle.registrationID)
            let result = try await runtime.complete(request)
            XCTAssertEqual(result.toolCalls?.first?.functionName, "lookup")
            let required = try await runtime.complete(try self.request(model: model))
            XCTAssertEqual(required.toolCalls?.count, 1)
        }
    }

    func testAliasConfiguredNonAllowlistedModelKeepsAutoAndNoneOnly() async throws {
        let runtime = runtime(modelID: "local/other", catalogModelIDAlias: "mlx-community/Other-4bit")
        for model in ["mlx-community/Other-4bit", "local/other"] {
            do {
                _ = try await runtime.acquireRequestHandle(try request(model: model))
                XCTFail("non-allowlisted model accepted required")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "unsupported_tool_choice")
            }
        }
        let none = try await runtime.acquireRequestHandle(try request(choice: "none", model: "mlx-community/Other-4bit"))
        await runtime.unregisterInFlight(none.registrationID)
    }

    /// After a warm swap away from the configured model the catalog id no
    /// longer names the loaded model, so guaranteed modes stay refused.
    func testSwapAwayFromAliasConfiguredModelStaysConservative() async throws {
        let runtime = runtime(modelID: "qwen/qwen3.6-35b-a3b", catalogModelIDAlias: ToolSelectionPolicy.supportedNativeModel, warmSwapEnabled: true)
        try await runtime.beginSwap(targetModelID: "local/other").value
        // The swapped-in model is refused by tool selection; the catalog id no
        // longer names the loaded model at all.
        for (model, code) in [("local/other", "unsupported_tool_choice"), (ToolSelectionPolicy.supportedNativeModel, "model_not_found")] {
            do {
                _ = try await runtime.acquireRequestHandle(try request(model: model))
                XCTFail("swapped-in model accepted required")
            } catch let error as APIError {
                XCTAssertEqual(error.code, code, model)
            }
        }
    }

    /// A pool alias is never a catalog identity: it neither qualifies a local
    /// model nor disqualifies a configured allowlisted one.
    func testPoolAliasNeitherGrantsNorRemovesGuaranteedModes() async throws {
        let pool = "pool/abcdefghijklmnopqrstuv/qwen"
        let canonical = runtime(catalogModelIDAlias: pool)
        let handle = try await canonical.acquireRequestHandle(try request())
        await canonical.unregisterInFlight(handle.registrationID)
        let local = runtime(modelID: "qwen/qwen3.6-35b-a3b", catalogModelIDAlias: pool)
        for model in ["qwen/qwen3.6-35b-a3b", pool] {
            do {
                _ = try await local.acquireRequestHandle(try request(model: model))
                XCTFail("pool alias qualified a local model")
            } catch let error as APIError {
                XCTAssertEqual(error.code, "unsupported_tool_choice")
            }
        }
    }
}

private final class ToolSelectionChunkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [StreamChunk] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return chunks.count }
    func append(_ chunk: StreamChunk) { lock.lock(); defer { lock.unlock() }; chunks.append(chunk) }
}
