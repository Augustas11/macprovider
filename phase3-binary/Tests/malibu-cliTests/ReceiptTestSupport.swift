import Foundation
import MacProviderCore

func parseRequest(_ body: [String: Any]) throws -> ChatCompletionRequest {
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    return try ChatCompletionRequest.parse(data: data)
}
