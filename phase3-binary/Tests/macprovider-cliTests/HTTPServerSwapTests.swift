import Foundation
import MLXLMCommon
import MacProviderCore
import XCTest
@testable import macprovider_cli

final class HTTPServerSwapTests: XCTestCase {
    func testInferenceReturns503WhenLoading() {
        let snapshot = RuntimeSnapshot(state: .loading, container: nil, modelID: "old-model", modelHash: "old-hash")

        let error = RouterHandler.warmSwapRejectionError(for: snapshot)

        XCTAssertEqual(error?.status, 503)
        XCTAssertEqual(error?.code, "provider_loading")
        XCTAssertEqual(error?.type, "service_unavailable")
        XCTAssertEqual(error?.envelopeJSONString, #"{"error":{"code":"provider_loading","message":"Provider is loading a new model and is temporarily unavailable. Retry after the indicated interval.","param":null,"type":"service_unavailable"}}"#)
    }

    func testInferenceReturns503WhenDraining() {
        let snapshot = RuntimeSnapshot(state: .draining, container: nil, modelID: "old-model", modelHash: "old-hash")

        let error = RouterHandler.warmSwapRejectionError(for: snapshot)

        XCTAssertEqual(error?.status, 503)
        XCTAssertEqual(error?.code, "provider_loading")
        XCTAssertEqual(error?.type, "service_unavailable")
    }

    func testInferenceProceedsWhenReady() async throws {
        let runtime = ModelRuntime(
            modelID: "ready-model",
            warmSwapEnabled: true,
            loader: { _ in throw HTTPServerSwapTestError.unexpectedContainerLoader },
            testLoader: { target in (target, "hash") },
            testCompletion: { _, _ in
                CompletionResult(content: "ready", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )
        let snapshot = await runtime.currentSnapshot()

        XCTAssertNil(RouterHandler.warmSwapRejectionError(for: snapshot))
        let completion = try await runtime.complete(try makeRequest(model: "ready-model"))
        XCTAssertEqual(completion.content, "ready")
    }

    private func makeRequest(model: String) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try ChatCompletionRequest.parse(data: data)
    }
}

private enum HTTPServerSwapTestError: Error {
    case unexpectedContainerLoader
}

private extension APIError {
    var envelopeJSONString: String {
        let data = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
