import MacProviderCore
import XCTest

final class ChatCompletionRequestTests: XCTestCase {
    func testModelMatchIsAsciiCaseInsensitive() throws {
        let request = try makeRequest(model: "mlx-community/llama-3.2-3b-instruct-4bit")

        XCTAssertNoThrow(try request.validateModelMatches("mlx-community/Llama-3.2-3B-Instruct-4bit"))
    }

    func testModelMismatchStillReturnsNotFound() throws {
        let request = try makeRequest(model: "mlx-community/Other-Model")

        XCTAssertThrowsError(try request.validateModelMatches("mlx-community/Llama-3.2-3B-Instruct-4bit")) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 404)
            XCTAssertEqual(apiError?.code, "model_not_found")
        }
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
