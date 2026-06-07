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

    func testHTTPReturns503SwapDrainTimeoutEnvelope() throws {
        let data = try JSONSerialization.data(
            withJSONObject: RouterHandler.swapDrainTimeoutEnvelope(),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(json, #"{"error":{"code":"swap_drain_timeout","type":"service_unavailable"}}"#)
    }

    func testInferenceForNewModelSucceedsAfterSwap() async throws {
        let probe = HTTPCompletionProbe()
        let runtime = ModelRuntime(
            modelID: "A",
            modelHash: "hash-a",
            warmSwapEnabled: true,
            loader: { _ in throw HTTPServerSwapTestError.unexpectedContainerLoader },
            testLoader: { target in (target, "hash-b") },
            testCompletion: { snapshot, _ in
                await probe.record(modelID: snapshot.modelID)
                return CompletionResult(content: snapshot.modelID ?? "<nil>", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )

        let swapTask = try await runtime.beginSwap(targetModelID: "B")
        try await swapTask.value
        let snapshot = await runtime.currentSnapshot()
        let request = try makeRequest(model: "B")
        try request.validateModelMatches(RouterHandler.modelIDForValidation(
            warmSwapEnabled: true,
            bootModelID: "A",
            runtimeSnapshot: snapshot
        ))
        let completion = try await runtime.complete(request)
        let reachedModelIDs = await probe.modelIDs

        XCTAssertEqual(completion.content, "B")
        XCTAssertEqual(reachedModelIDs, ["B"])
    }

    func testInferenceForOldModelRejectedAfterSwap() async throws {
        let runtime = ModelRuntime(
            modelID: "A",
            modelHash: "hash-a",
            warmSwapEnabled: true,
            loader: { _ in throw HTTPServerSwapTestError.unexpectedContainerLoader },
            testLoader: { target in (target, "hash-b") }
        )

        let swapTask = try await runtime.beginSwap(targetModelID: "B")
        try await swapTask.value
        let snapshot = await runtime.currentSnapshot()
        let request = try makeRequest(model: "A")

        XCTAssertThrowsError(try request.validateModelMatches(RouterHandler.modelIDForValidation(
            warmSwapEnabled: true,
            bootModelID: "A",
            runtimeSnapshot: snapshot
        ))) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 404)
            XCTAssertEqual(apiError?.code, "model_not_found")
        }
    }

    func testDisabledValidationUsesBootModelWhenRuntimeDiffers() throws {
        let snapshot = RuntimeSnapshot(state: .ready, container: nil, modelID: "B", modelHash: "hash-b")

        let modelID = RouterHandler.modelIDForValidation(
            warmSwapEnabled: false,
            bootModelID: "A",
            runtimeSnapshot: snapshot
        )

        XCTAssertEqual(modelID, "A")
    }

    func testEnabledValidationUsesRuntimeModelWhenBootDiffers() throws {
        let snapshot = RuntimeSnapshot(state: .ready, container: nil, modelID: "B", modelHash: "hash-b")

        let modelID = RouterHandler.modelIDForValidation(
            warmSwapEnabled: true,
            bootModelID: "A",
            runtimeSnapshot: snapshot
        )

        XCTAssertEqual(modelID, "B")
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

private actor HTTPCompletionProbe {
    private(set) var modelIDs: [String?] = []

    func record(modelID: String?) {
        modelIDs.append(modelID)
    }
}

private extension APIError {
    var envelopeJSONString: String {
        let data = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
