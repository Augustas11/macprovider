import Foundation

public struct ChatCompletionRequest: Sendable {
    public let model: String
    public let messages: [ChatMessage]
    public let maxTokens: Int?
    public let temperature: Double
    public let topP: Double
    public let stream: Bool
    public let stop: [String]
    public let presencePenalty: Double
    public let frequencyPenalty: Double
    public let seed: Int?
    public let responseFormat: ResponseFormat

    public static func parse(data: Data) throws -> ChatCompletionRequest {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw APIError(status: 400, message: "Invalid JSON", type: "invalid_request_error", code: "invalid_json")
        }

        guard let dict = json as? [String: Any] else {
            throw APIError(status: 400, message: "Request body must be a JSON object", code: "invalid_request")
        }

        guard let model = dict["model"] as? String, !model.isEmpty else {
            throw APIError(status: 400, message: "Missing or invalid model", code: "invalid_request")
        }

        guard let rawMessages = dict["messages"] as? [Any], !rawMessages.isEmpty else {
            throw APIError(status: 400, message: "Missing or invalid messages", code: "invalid_request")
        }

        let maxTokens = try optionalInt(dict["max_tokens"], key: "max_tokens")
        if let maxTokens, maxTokens <= 0 {
            throw APIError(status: 400, message: "max_tokens must be > 0", code: "invalid_request")
        }

        let temperature = try optionalDouble(dict["temperature"], key: "temperature") ?? 1.0
        guard (0.0 ... 2.0).contains(temperature) else {
            throw APIError(status: 400, message: "temperature must be between 0.0 and 2.0", code: "invalid_request")
        }

        let topP = try optionalDouble(dict["top_p"], key: "top_p") ?? 1.0
        guard (0.0 ... 1.0).contains(topP) else {
            throw APIError(status: 400, message: "top_p must be between 0.0 and 1.0", code: "invalid_request")
        }

        let n = try optionalInt(dict["n"], key: "n") ?? 1
        guard n == 1 else {
            throw APIError(status: 400, message: "n must be 1", code: "invalid_request")
        }

        let stream = try optionalBool(dict["stream"], key: "stream") ?? false

        if let streamOptions = dict["stream_options"], !(streamOptions is NSNull), !(streamOptions is [String: Any]) {
            throw APIError(status: 400, message: "stream_options must be an object", code: "invalid_request")
        }

        let stop = try parseStop(dict["stop"])
        let presencePenalty = try optionalDouble(dict["presence_penalty"], key: "presence_penalty") ?? 0.0
        guard (-2.0 ... 2.0).contains(presencePenalty) else {
            throw APIError(status: 400, message: "presence_penalty must be between -2.0 and 2.0", code: "invalid_request")
        }

        let frequencyPenalty = try optionalDouble(dict["frequency_penalty"], key: "frequency_penalty") ?? 0.0
        guard (-2.0 ... 2.0).contains(frequencyPenalty) else {
            throw APIError(status: 400, message: "frequency_penalty must be between -2.0 and 2.0", code: "invalid_request")
        }

        let seed = try optionalInt(dict["seed"], key: "seed")
        if let user = dict["user"], !(user is NSNull), !(user is String) {
            throw APIError(status: 400, message: "user must be a string", code: "invalid_request")
        }

        let responseFormat = try parseResponseFormat(dict["response_format"])
        let messages = try rawMessages.enumerated().map { index, raw in
            try ChatMessage.parse(raw, index: index)
        }

        try validateTools(dict["tools"])
        try validateToolChoice(dict["tool_choice"])

        return ChatCompletionRequest(
            model: model,
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            stream: stream,
            stop: stop,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            seed: seed,
            responseFormat: responseFormat
        )
    }

    public func validateModelMatches(_ loadedModel: String?) throws {
        guard let loadedModel else {
            throw APIError(status: 503, message: "Model not loaded", type: "server_error", code: "model_not_loaded")
        }
        guard Self.asciiCaseInsensitiveEquals(model, loadedModel) else {
            throw APIError(status: 404, message: "Model not found", code: "model_not_found")
        }
    }

    private static func asciiCaseInsensitiveEquals(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == rhs.utf8.count else { return false }
        return zip(lhs.utf8, rhs.utf8).allSatisfy { asciiFold($0) == asciiFold($1) }
    }

    private static func asciiFold(_ byte: UInt8) -> UInt8 {
        if byte >= 65, byte <= 90 {
            return byte + 32
        }
        return byte
    }
}

public enum ChatRole: String, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct ChatMessage: Sendable {
    public let role: ChatRole
    public let content: String?

    static func parse(_ raw: Any, index: Int) throws -> ChatMessage {
        guard let dict = raw as? [String: Any] else {
            throw APIError(status: 400, message: "messages[\(index)] must be an object", code: "invalid_request")
        }
        guard let roleValue = dict["role"] as? String, let role = ChatRole(rawValue: roleValue) else {
            throw APIError(status: 400, message: "messages[\(index)].role is invalid", code: "invalid_request")
        }

        switch role {
        case .system, .user:
            guard let content = dict["content"] as? String, !content.isEmpty else {
                throw APIError(status: 400, message: "messages[\(index)].content must be a non-empty string", code: "invalid_request")
            }
            return ChatMessage(role: role, content: content)
        case .assistant:
            let content = dict["content"] as? String
            if let toolCalls = dict["tool_calls"], !(toolCalls is NSNull) {
                try validateAssistantToolCalls(toolCalls, messageIndex: index)
            } else if content == nil {
                throw APIError(status: 400, message: "assistant message requires content or tool_calls", code: "invalid_request")
            }
            return ChatMessage(role: role, content: content)
        case .tool:
            guard dict["tool_call_id"] is String else {
                throw APIError(status: 400, message: "tool message requires tool_call_id", code: "invalid_request")
            }
            guard let content = dict["content"] as? String else {
                throw APIError(status: 400, message: "tool message requires content", code: "invalid_request")
            }
            return ChatMessage(role: role, content: content)
        }
    }
}

public enum ResponseFormat: String, Sendable {
    case text
    case jsonObject = "json_object"
}

public struct APIError: Error, Sendable {
    public let status: Int
    public let message: String
    public let type: String
    public let code: String
    public let param: String?

    public init(status: Int, message: String, type: String = "invalid_request_error", code: String, param: String? = nil) {
        self.status = status
        self.message = message
        self.type = type
        self.code = code
        self.param = param
    }

    public var envelope: [String: Any] {
        let paramValue: Any = param ?? NSNull()
        return [
            "error": [
                "message": message,
                "type": type,
                "param": paramValue,
                "code": code,
            ]
        ]
    }
}

private func optionalInt(_ raw: Any?, key: String) throws -> Int? {
    guard let raw, !(raw is NSNull) else { return nil }
    guard let int = raw as? Int else {
        throw APIError(status: 400, message: "\(key) must be an integer", code: "invalid_request")
    }
    return int
}

private func optionalDouble(_ raw: Any?, key: String) throws -> Double? {
    guard let raw, !(raw is NSNull) else { return nil }
    if let double = raw as? Double {
        return double
    }
    if let int = raw as? Int {
        return Double(int)
    }
    throw APIError(status: 400, message: "\(key) must be a number", code: "invalid_request")
}

private func optionalBool(_ raw: Any?, key: String) throws -> Bool? {
    guard let raw, !(raw is NSNull) else { return nil }
    guard let bool = raw as? Bool else {
        throw APIError(status: 400, message: "\(key) must be a boolean", code: "invalid_request")
    }
    return bool
}

private func parseStop(_ raw: Any?) throws -> [String] {
    guard let raw, !(raw is NSNull) else { return [] }
    let stops: [String]
    if let stop = raw as? String {
        stops = [stop]
    } else if let stopList = raw as? [Any] {
        stops = try stopList.map { rawStop in
            guard let stop = rawStop as? String else {
                throw APIError(status: 400, message: "stop entries must be strings", code: "invalid_request")
            }
            return stop
        }
    } else {
        throw APIError(status: 400, message: "stop must be a string or array", code: "invalid_request")
    }
    guard stops.count <= 4 else {
        throw APIError(status: 400, message: "stop may contain at most 4 sequences", code: "invalid_request")
    }
    return stops
}

private func parseResponseFormat(_ raw: Any?) throws -> ResponseFormat {
    guard let raw, !(raw is NSNull) else { return .text }
    guard let dict = raw as? [String: Any], let type = dict["type"] as? String,
          let format = ResponseFormat(rawValue: type)
    else {
        throw APIError(status: 400, message: "response_format.type must be text or json_object", code: "invalid_request")
    }
    return format
}

private func validateTools(_ raw: Any?) throws {
    guard let raw, !(raw is NSNull) else { return }
    guard let tools = raw as? [Any] else {
        throw APIError(status: 400, message: "tools must be an array", code: "invalid_tools")
    }
    for (index, rawTool) in tools.enumerated() {
        guard let tool = rawTool as? [String: Any] else {
            throw APIError(status: 400, message: "Invalid tools[\(index)]: must be an object", code: "invalid_tools")
        }
        guard tool["type"] as? String == "function" else {
            throw APIError(status: 400, message: "Invalid tools[\(index)]: type must be function", code: "invalid_tools")
        }
        guard let function = tool["function"] as? [String: Any] else {
            throw APIError(status: 400, message: "Invalid tools[\(index)]: missing function", code: "invalid_tools")
        }
        guard function["name"] is String else {
            throw APIError(status: 400, message: "Invalid tools[\(index)]: missing function.name", code: "invalid_tools")
        }
        guard function["parameters"] is [String: Any] else {
            throw APIError(status: 400, message: "Invalid tools[\(index)]: missing function.parameters", code: "invalid_tools")
        }
    }
}

private func validateToolChoice(_ raw: Any?) throws {
    guard let raw, !(raw is NSNull) else { return }
    guard raw is String || raw is [String: Any] else {
        throw APIError(status: 400, message: "tool_choice must be a string or object", code: "invalid_tools")
    }
}

private func validateAssistantToolCalls(_ raw: Any, messageIndex: Int) throws {
    guard let calls = raw as? [Any], !calls.isEmpty else {
        throw APIError(status: 400, message: "messages[\(messageIndex)].tool_calls must be a non-empty array", code: "invalid_tools")
    }
    for (index, rawCall) in calls.enumerated() {
        guard let call = rawCall as? [String: Any] else {
            throw APIError(status: 400, message: "Invalid messages[\(messageIndex)].tool_calls[\(index)]", code: "invalid_tools")
        }
        guard call["id"] is String, call["type"] as? String == "function",
              let function = call["function"] as? [String: Any],
              function["name"] is String,
              let arguments = function["arguments"] as? String
        else {
            throw APIError(status: 400, message: "Invalid messages[\(messageIndex)].tool_calls[\(index)]", code: "invalid_tools")
        }
        guard let data = arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            throw APIError(status: 400, message: "Invalid tool_call arguments JSON", code: "invalid_tools")
        }
    }
}
