import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class CompletionStopSequenceTests: XCTestCase {
    private func request(model: String = "mlx-community/Qwen3-8B-4bit") throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "hello"]], "stop": ["END"],
        ]))
    }

    func testBatchedFinalizationReportsTheRemovedRequestStopWithoutChangingChatFinish() throws {
        let pieces = ["hello", "END", "trailing"]
        // The actual scheduler withholds the stop token from outputTokens,
        // while generatedTokens retains the complete sampling history.
        for (generated, output, expectedStop) in [
            ([0, 1], [0], "END" as String?),
            ([0, 1, 2], [0, 1, 2], "END"),
            ([0], [0], nil),
        ] {
            let result = ContinuousBatchSchedulerResult(
                requestID: "stop-metadata", conversationKey: "", generatedTokens: generated, outputTokens: output,
                promptTokens: 1, completionTokens: generated.count, emittedTokens: output.count, cachedPromptTokens: 0,
                terminalStatus: .stop, errorCode: nil, snapshot: nil,
                settlementDisposition: .eligibleOwner, retainedCache: nil,
                stopCause: expectedStop == nil ? nil : .requestStop
            )
            let finalized = try ModelRuntime.finalizeContinuousBatchRow(
                request: request(), result: result, modelStopTokenIDs: [], promptTokenIDs: [0],
                decode: { $0.map { pieces[$0] }.joined() }, stopTokenFilter: StopTokenFilter(tokens: []),
                generationMilliseconds: 0, modelHash: nil, toolCallPrefill: nil
            )
            XCTAssertEqual(finalized.completion.content, "hello")
            XCTAssertEqual(finalized.completion.finishReason, "stop")
            XCTAssertEqual(finalized.completion.stopSequence, expectedStop)
        }
    }

    func testMetadataMatchesFilterOrderingButExcludesReasoningModelStopsAndTools() {
        let filter = StopTokenFilter(tokens: ["<eos>"])
        XCTAssertEqual(ModelRuntime.matchedRequestStop(in: "aENDxSTOP", stopTokenFilter: filter,
                                                      requestStops: ["STOP", "END", "EN"]), "END")
        XCTAssertEqual(ModelRuntime.matchedRequestStop(in: "aEND", stopTokenFilter: filter,
                                                      requestStops: ["EN", "END"]), "EN")
        XCTAssertNil(ModelRuntime.matchedRequestStop(in: "hidden END", stopTokenFilter: filter,
                                                    requestStops: ["END"], reasoningOpen: true))
        XCTAssertNil(ModelRuntime.matchedRequestStop(in: "hidden END</think>answer", stopTokenFilter: filter,
                                                    requestStops: ["END"], reasoningOpen: true))
        XCTAssertEqual(ModelRuntime.matchedRequestStop(in: "hidden END</think>answer STOP", stopTokenFilter: filter,
                                                      requestStops: ["END", "STOP"], reasoningOpen: true), "STOP")
        XCTAssertNil(ModelRuntime.matchedRequestStop(in: "answer<eos>", stopTokenFilter: filter,
                                                    requestStops: ["<eos>"]))
        XCTAssertNil(ModelRuntime.matchedRequestStop(in: #"{"argument":"END"}"#, stopTokenFilter: filter,
                                                    requestStops: ["END"], hasToolCalls: true))
    }

    func testHarmonyMetadataOnlyMatchesVisibleFinalContent() throws {
        let pieces: [Int: String] = [
            HarmonyResponseParser.channelTokenID: "<|channel|>", HarmonyResponseParser.messageTokenID: "<|message|>",
            HarmonyResponseParser.endTokenID: "<|end|>", HarmonyResponseParser.startTokenID: "<|start|>",
            HarmonyResponseParser.returnTokenID: "<|return|>",
            1: "analysis", 2: "hidden END", 3: "assistant", 4: "final", 5: "helloEND",
        ]
        let ids = [HarmonyResponseParser.channelTokenID, 1, HarmonyResponseParser.messageTokenID, 2,
                   HarmonyResponseParser.endTokenID, HarmonyResponseParser.startTokenID, 3,
                   HarmonyResponseParser.channelTokenID, 4, HarmonyResponseParser.messageTokenID, 5,
                   HarmonyResponseParser.returnTokenID]
        let decode: ([Int]) -> String = { $0.map { pieces[$0]! }.joined() }
        let parsed = try ModelRuntime.parseGeneratedOutput(
            filteredText: decode(ids), generatedTokenIDs: ids, decode: decode,
            request: request(model: "openai/gpt-oss-20b"), mode: .complete(),
            defaultCompletionTokens: ids.count, requestStops: ["END"], toolCallPrefill: nil
        )
        XCTAssertEqual(parsed.content, "hello")
        XCTAssertEqual(parsed.reasoningContent, "hidden END")
        XCTAssertEqual(parsed.stopSequence, "END")
    }

    func testCompletionCopiesPreserveMatchedStopMetadata() {
        let result = CompletionResult(content: "hello", finishReason: "stop", promptTokens: 1,
                                      completionTokens: 1, settlementDisposition: .eligibleOwner,
                                      loopbackPrefixCompletionTokens: [2: 1], stopSequence: "END")
        XCTAssertEqual(result.withContent("changed").stopSequence, "END")
        XCTAssertEqual(result.withToolCalls([]).stopSequence, "END")
        XCTAssertEqual(result.withModelHashObservedIfMissing("observed").stopSequence, "END")
        XCTAssertEqual(result.cancelledPrefixUsage(deliveredContent: "he").stopSequence, "END")
        XCTAssertNil(CompletionResult(content: "hello", finishReason: "stop", promptTokens: 1,
                                     completionTokens: 1, settlementDisposition: .eligibleOwner).stopSequence)
    }
    func testStructuredStreamingValidationPreservesMatchedStopMetadata() throws {
        let structuredRequest = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "fixture-model", "messages": [["role": "user", "content": "JSON"]],
            "response_format": ["type": "json_object"],
        ]))
        let completion = CompletionResult(content: #"{"ok":true}"#, finishReason: "stop", promptTokens: 1,
                                          completionTokens: 1, settlementDisposition: .eligibleOwner,
                                          stopSequence: "END")
        let validated = try ModelRuntime.validateStructuredStreamingCompletion(
            completion, request: structuredRequest, buyerVisibleContent: completion.content
        )
        XCTAssertEqual(validated.stopSequence, "END")
        XCTAssertEqual(validated.content, completion.content)
    }

}
