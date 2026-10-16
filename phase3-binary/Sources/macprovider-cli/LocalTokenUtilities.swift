import Foundation
import CoreFoundation
import MacProviderCore

/// Local utilities deliberately accept a smaller, bounded text-only contract.
enum LocalTokenUtilityOperation: String, Sendable {
    case tokenize, detokenize, applyTemplate = "apply-template"
}

struct LocalTokenUtilityRequest: Sendable {
    static let bodyByteLimit = 65_536
    static let tokenLimit = 16_384
    static let outputByteLimit = 262_144
    let operation: LocalTokenUtilityOperation
    let model: String
    let text: String?
    let tokens: [Int]?
    let messages: [[String: String]]?

    static func parse(data: Data, operation: LocalTokenUtilityOperation) throws -> Self {
        guard data.count <= bodyByteLimit else { throw limitError() }
        guard (try? StrictJSONParser.parse(String(decoding: data, as: UTF8.self), maxDepth: 8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              let body = object as? [String: Any] else { throw invalid("Invalid bounded JSON object") }
        let field: String
        switch operation {
        case .tokenize: field = "text"
        case .detokenize: field = "tokens"
        case .applyTemplate: field = "messages"
        }
        guard Set(body.keys).isSubset(of: ["model", field]) else { throw invalid("Unsupported token utility parameter") }
        guard let model = body["model"] as? String, !model.isEmpty else { throw invalid("model is required") }
        var text: String?
        var tokens: [Int]?
        var messages: [[String: String]]?
        switch operation {
        case .tokenize:
            guard let value = body[field] as? String else { throw invalid("text must be a string") }
            text = value
        case .detokenize:
            guard let values = body[field] as? [Any] else { throw invalid("tokens must be a bounded integer array") }
            guard values.count <= tokenLimit else { throw limitError() }
            tokens = try values.map { value in
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let token = Int(number.stringValue), token >= 0, token <= Int(Int32.max) else {
                    throw invalid("tokens must contain nonnegative 32-bit integers")
                }
                return token
            }
        case .applyTemplate:
            guard let values = body[field] as? [[String: String]], !values.isEmpty, values.count <= 128 else {
                throw invalid("messages must contain 1 to 128 text-only messages")
            }
            for message in values {
                guard Set(message.keys) == ["role", "content"],
                      let role = message["role"], ["system", "user", "assistant"].contains(role) else {
                    throw invalid("messages support only role and text content")
                }
            }
            messages = values
        }
        return Self(operation: operation, model: model, text: text, tokens: tokens, messages: messages)
    }

    /// Use ordinary request admission for alias validation and swap ownership.
    func admissionRequest() throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "token utility"]], "max_tokens": 1
        ]))
    }

    static func invalid(_ message: String) -> APIError {
        APIError(status: 400, message: message, code: "invalid_token_utility_request")
    }
    static func limitError() -> APIError {
        APIError(status: 413, message: "Token utility input or output exceeds its limit", code: "token_utility_limit_exceeded")
    }
}

struct LocalTokenUtilityResult: Codable, Sendable {
    let model: String
    let modelHash: String?
    let generation: Int
    let tokens: [Int]?
    let text: String?
    enum CodingKeys: String, CodingKey {
        case model, generation, tokens, text
        case modelHash = "model_hash"
    }
}

struct LocalTokenUtilityCapabilities: Codable, Sendable {
    let model: String?
    let modelHash: String?
    let generation: Int?
    let operations: [String]
    enum CodingKeys: String, CodingKey {
        case model, generation, operations
        case modelHash = "model_hash"
    }
}

/// Immutable identity and the shared gate travel together while a request waits.
/// A later model swap cannot rebind a utility result to the new model.
struct LocalTokenUtilitySession: Sendable {
    let model: String
    let modelHash: String?
    let generation: Int
    let gate: AsyncSemaphore

    func perform(_ operation: @escaping @Sendable () async throws -> ([Int]?, String?)) async throws -> LocalTokenUtilityResult {
        try Task.checkCancellation()
        return try await gate.withPermit {
            try Task.checkCancellation()
            let (tokens, text) = try await operation()
            try Task.checkCancellation()
            return LocalTokenUtilityResult(model: model, modelHash: modelHash, generation: generation,
                                           tokens: tokens, text: text)
        }
    }
}
