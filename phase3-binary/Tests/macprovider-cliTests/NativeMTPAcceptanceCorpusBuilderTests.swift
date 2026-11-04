#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class NativeMTPAcceptanceCorpusBuilderTests: XCTestCase {
    func testBudgetedFixturesPreserveTerminalAndFeatureInputs() throws {
        var hasShortAnswer = false
        var hasNearTieInstruction = false
        var hasStop = false
        var hasToolHistoryAndReasoning = false
        var hasGreedy = false
        var hasSampled = false
        for index in 0..<200 {
            let object = NativeMTPAcceptanceCorpusBuilder.requestObject(
                modelID: "zai-org/glm-5.3-flash", index: index, padding: 0
            )
            let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(request.maxTokens, request.stop.isEmpty ? 128 : 256)
            hasShortAnswer = hasShortAnswer || String(describing: object["messages"]).contains("Answer with only OK")
            hasNearTieInstruction = hasNearTieInstruction || String(describing: object["messages"]).contains("Amber and violet are equally valid")
            hasStop = hasStop || !request.stop.isEmpty
            hasToolHistoryAndReasoning = hasToolHistoryAndReasoning || (
                request.templateReasoningEffort(for: request.model) == "high"
                && request.messages.contains { $0.role == .tool }
            )
            hasGreedy = hasGreedy || request.temperature == 0
            hasSampled = hasSampled || (request.temperature == 1 && request.topP == 0.95)
        }
        XCTAssertTrue(hasShortAnswer)
        XCTAssertTrue(hasNearTieInstruction)
        XCTAssertTrue(hasStop)
        XCTAssertTrue(hasToolHistoryAndReasoning)
        XCTAssertTrue(hasGreedy)
        XCTAssertTrue(hasSampled)
    }

    func testOnlyExplicitStopBoundaryCasesUseTheExisting256TokenBudget() throws {
        var stopIndices: [Int] = []
        for index in 0..<200 {
            let object = NativeMTPAcceptanceCorpusBuilder.requestObject(
                modelID: "zai-org/glm-5.3-flash", index: index, padding: 100
            )
            let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: object))
            if request.stop.isEmpty {
                XCTAssertEqual(request.maxTokens, 128, "case \(index)")
                continue
            }
            stopIndices.append(index)
            XCTAssertEqual(request.stop, [";"])
            XCTAssertEqual(request.maxTokens, 256)
            XCTAssertEqual(request.reasoningEffort, "low")
            XCTAssertEqual(request.templateReasoningEffort(for: request.model), "low")
            XCTAssertEqual(request.temperature, 1)
            XCTAssertEqual(request.topP, 0.95)
            XCTAssertNil(request.seed)
            XCTAssertFalse(request.stream)
            XCTAssertEqual(request.messages.count, 1)
            XCTAssertTrue(request.messages[0].content?.hasSuffix(
                "Your entire final answer must be exactly one ASCII semicolon (;). Do not reason or explain; answer immediately."
            ) == true)
        }
        XCTAssertEqual(stopIndices, [0, 51, 102, 153])
    }

    func testFeatureFixturesUseConsumedReasoningAndHistoryControls() throws {
        for index in 0..<3 {
            let data = try JSONSerialization.data(withJSONObject: NativeMTPAcceptanceCorpusBuilder.requestObject(
                modelID: "zai-org/glm-5.3-flash", index: index, padding: 0
            ))
            let request = try ChatCompletionRequest.parse(data: data)
            XCTAssertFalse(request.stream)
            XCTAssertEqual(request.maxTokens, index == 0 ? 256 : 128)
            XCTAssertEqual(request.temperature, index == 1 ? 0 : 1)
            XCTAssertEqual(request.topP, index == 1 ? 1 : 0.95)
            if index != 0 {
                XCTAssertEqual(request.templateReasoningEffort(for: request.model), "high")
                XCTAssertTrue(request.messages.contains { $0.role == .tool })
                XCTAssertTrue(request.messages.contains {
                    $0.role == .assistant && $0.reasoningContent?.isEmpty == false && $0.toolCalls?.isEmpty == false
                })
            }
        }
    }

    /// Qwen signs sampled text. Tool history and reasoning_effort select
    /// ordinary, which is what failed acceptance-short-0 in the 2026-11-04 window.
    func testQwenRequestsStayInsideTheSampledTextSelector() throws {
        let capability = NativeMTPCapability(
            admitted: true, revoked: false, revocationStateAvailable: true,
            supportsCurrentProcessor: true, supportsCurrentStateCache: true,
            supportsStreaming: true, supportsNonStreaming: true, supportsStopSequences: true,
            hasQualifiedRowMappedTransactions: true, maximumProposalDepth: 1,
            maximumPromptTokens: 4096, maximumCompletionTokens: 4096,
            family: "qwen3_5_mtp_v1", supportsSampling: true
        )
        for modelID in ["qwen/qwen3.6-27b", "qwen/qwen3.8-27b"] {
            var sawStop = false
            var sawGreedy = false
            var sawSampled = false
            for index in 0..<200 {
                let object = NativeMTPAcceptanceCorpusBuilder.requestObject(
                    modelID: modelID, index: index, padding: 0
                )
                XCTAssertNil(object["reasoning_effort"], "\(modelID) \(index)")
                XCTAssertNil(object["tools"], "\(modelID) \(index)")
                let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: object))
                XCTAssertFalse(request.messages.contains { $0.role == .tool })
                XCTAssertEqual(NativeMTPSelector.reason(
                    request: request, mode: .auto, nativeCapability: capability
                ), .eligible, "\(modelID) \(index)")
                sawStop = sawStop || request.stop == [";"]
                sawGreedy = sawGreedy || (request.temperature == 0 && request.topP == 1)
                sawSampled = sawSampled || (request.temperature == 1 && request.topP == 0.95)
            }
            XCTAssertTrue(sawStop)
            XCTAssertTrue(sawGreedy)
            XCTAssertTrue(sawSampled)
        }
    }
}
#endif
