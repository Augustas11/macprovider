#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class NativeMTPAcceptanceStopCorpusTests: XCTestCase {
    func testCorrectedCorpusSurvivesProductionParsingWithFeatureAndCapacityCoverage() throws {
        // Tokenizer-sized padding stays in the frozen hardware corpus. This
        // source fixture checks the same case order and request controls only.
        var cases: [[String: Any]] = []
        for stratum in NativeMTPAcceptanceCorpus.Stratum.allCases {
            for offset in 0..<(stratum == .short ? 120 : 20) {
                cases.append([
                    "id": "acceptance-\(stratum.rawValue)-\(offset)",
                    "stratum": stratum.rawValue,
                    "expected_native": stratum != .eightK,
                    "request": NativeMTPAcceptanceCorpusBuilder.requestObject(
                        modelID: "zai-org/glm-5.3-flash", index: cases.count, padding: 0
                    ),
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": NativeMTPAcceptanceCorpus.schema,
            "model_id": "zai-org/glm-5.3-flash",
            "max_prompt_tokens": 4096, "qualified_slots": 4,
            "max_native_active_rows": 1, "proposal_depth": 1,
            "minimum_compared_positions": 6400, "cases": cases,
        ], options: [.sortedKeys])
        let corpus = try NativeMTPAcceptanceCorpus.load(data: data)
        XCTAssertEqual(corpus.cases.count, 200)
        XCTAssertEqual(corpus.cases.filter { !$0.request.stop.isEmpty }.map(\.id), [
            "acceptance-short-0", "acceptance-short-51", "acceptance-short-102", "acceptance-4k-13",
        ])
        XCTAssertEqual(corpus.cases.filter { !$0.expectedNative }.count, 20)
        for item in corpus.cases {
            let request = item.request
            XCTAssertEqual(request.requestID, item.id)
            XCTAssertEqual(request.maxTokens, request.stop.isEmpty ? 128 : 256)
            if !request.stop.isEmpty {
                XCTAssertTrue(item.expectedNative)
                XCTAssertEqual(request.reasoningEffort, "low")
                XCTAssertEqual(request.stop, [";"])
            }
        }
        XCTAssertTrue(corpus.cases.contains {
            $0.request.temperature == 0 && $0.request.messages.contains { $0.role == .tool }
                && $0.request.templateReasoningEffort(for: $0.request.model) == "high"
        })
        XCTAssertTrue(corpus.cases.contains {
            $0.request.temperature == 1 && $0.request.topP == 0.95
                && $0.request.messages.contains { $0.role == .tool }
        })
    }

    func testCorrectedStopBudgetReachesVisibleDelimiterAfterHiddenReasoning() throws {
        for index in [0, 51, 102, 153] {
            let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject:
                NativeMTPAcceptanceCorpusBuilder.requestObject(
                    modelID: "zai-org/glm-5.3-flash", index: index, padding: 0
                )
            ))
            // The renderer, rather than the buyer's JSON, supplies this fact.
            request.outputState.resolve(RequestOutputTraits(reasoningOpen: true))
            func decode(_ tokens: [Int]) -> String {
                tokens.map { token in
                    switch token {
                    case 1: "A semicolon; inside reasoning is not the requested stop."
                    case 255: "</think>"
                    case 256: ";"
                    case 257: " discarded draft suffix"
                    default: " x"
                    }
                }.joined()
            }
            var observer = ModelRuntime.SerialDecodeRequestStopObserver(
                modelID: request.model, stopTokenFilter: StopTokenFilter(tokens: []),
                requestStops: request.stop, reasoningOpen: request.outputTraits.reasoningOpen,
                decode: decode
            )
            var generated: [Int] = []
            var stopped = false
            for token in 1...257 {
                generated.append(token)
                if try observer.observe(generatedTokenIDs: generated) {
                    stopped = true
                    break
                }
                XCTAssertLessThan(generated.count, try XCTUnwrap(request.maxTokens))
            }
            XCTAssertTrue(stopped)
            XCTAssertEqual(generated.count, 256)
            XCTAssertFalse(generated.contains(257))
            let filtered = ModelRuntime.applyOutputFilters(
                decode(generated), stopTokenFilter: StopTokenFilter(tokens: []),
                requestStops: request.stop, reasoningOpen: request.outputTraits.reasoningOpen
            )
            XCTAssertTrue(filtered.hitStop)
            let parsed = try ModelRuntime.parseGeneratedOutput(
                filteredText: filtered.text, generatedTokenIDs: generated, decode: decode,
                request: request, mode: .complete(finishReason: "request_stop"),
                defaultCompletionTokens: generated.count, toolCallPrefill: nil
            )
            XCTAssertEqual(parsed.content, "")
            XCTAssertTrue(parsed.reasoningContent?.contains("semicolon;") == true)
            XCTAssertEqual(parsed.completionTokens, 256)
            XCTAssertEqual(parsed.generatedCompletionTokens, 256)
            XCTAssertEqual(parsed.reasoningTokens, 255)
            XCTAssertEqual(NativeMTPLabNumericalOracle.Terminal.classify(
                status: .stop, stopCause: .requestStop, toolBoundaryTokenCount: nil
            ), .stopSequence)
        }
    }
}
#endif
