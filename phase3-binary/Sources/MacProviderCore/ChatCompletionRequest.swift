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
    public let promptSource: ChatCompletionPromptSource

    public static func parse(data: Data) throws -> ChatCompletionRequest {
        guard data.count <= RequestValidation.rawBodyByteCap else {
            throw APIError(status: 413, message: "Request body exceeds 4 MiB", code: "request_body_too_large")
        }

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
        try RequestValidation.validate(messages)

        try validateTools(dict["tools"])
        try validateToolChoice(dict["tool_choice"])
        try validateOptionalJSONBool(dict["logprobs"], key: "logprobs")
        _ = try optionalInt(dict["top_logprobs"], key: "top_logprobs")
        _ = try optionalJSONValue(dict["logit_bias"])

        let promptSource = try ChatCompletionPromptSource(dict: dict, rawMessages: rawMessages)

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
            responseFormat: responseFormat,
            promptSource: promptSource
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

public struct ChatCompletionPromptSource: Equatable, Sendable {
    public let model: JSONValue
    public let messages: [JSONValue]
    public let tools: JSONValue?
    public let temperature: JSONValue?
    public let topP: JSONValue?
    public let maxTokens: JSONValue?
    public let stop: JSONValue?
    public let seed: JSONValue?
    public let responseFormat: JSONValue?
    public let toolChoice: JSONValue?
    public let presencePenalty: JSONValue?
    public let frequencyPenalty: JSONValue?
    public let logitBias: JSONValue?
    public let logprobs: JSONValue?
    public let topLogprobs: JSONValue?
    public let n: JSONValue?

    init(dict: [String: Any], rawMessages: [Any]) throws {
        self.model = try JSONValue.parse(dict["model"] as Any)
        self.messages = try rawMessages.map { try JSONValue.parse($0) }
        self.tools = try optionalJSONValue(dict["tools"])
        self.temperature = try optionalJSONValue(dict["temperature"])
        self.topP = try optionalJSONValue(dict["top_p"])
        self.maxTokens = try optionalJSONValue(dict["max_tokens"])
        self.stop = try optionalJSONValue(dict["stop"])
        self.seed = try optionalJSONValue(dict["seed"])
        self.responseFormat = try optionalJSONValue(dict["response_format"])
        self.toolChoice = try optionalJSONValue(dict["tool_choice"])
        self.presencePenalty = try optionalJSONValue(dict["presence_penalty"])
        self.frequencyPenalty = try optionalJSONValue(dict["frequency_penalty"])
        self.logitBias = try optionalJSONValue(dict["logit_bias"])
        self.logprobs = try optionalJSONValue(dict["logprobs"])
        self.topLogprobs = try optionalJSONValue(dict["top_logprobs"])
        self.n = try optionalJSONValue(dict["n"])
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
    public let toolCallID: String?
    public let toolCalls: [ToolCall]?

    static func parse(_ raw: Any, index: Int) throws -> ChatMessage {
        guard let dict = raw as? [String: Any] else {
            throw APIError(status: 400, message: "messages[\(index)] must be an object", code: "invalid_request")
        }
        guard let roleValue = dict["role"] as? String, let role = ChatRole(rawValue: roleValue) else {
            throw APIError(status: 400, message: "messages[\(index)].role is invalid", code: "invalid_request")
        }

        switch role {
        case .system, .user:
            let content = try textProjection(from: dict["content"], messageIndex: index, allowNull: false)
            guard let content, !content.isEmpty else {
                throw APIError(status: 400, message: "messages[\(index)].content must be non-empty", code: "invalid_request")
            }
            return ChatMessage(role: role, content: content, toolCallID: nil, toolCalls: nil)
        case .assistant:
            let content = try textProjection(from: dict["content"], messageIndex: index, allowNull: true)
            let parsedToolCalls: [ToolCall]?
            if let toolCalls = dict["tool_calls"], !(toolCalls is NSNull) {
                parsedToolCalls = try parseAssistantToolCalls(toolCalls, messageIndex: index)
            } else if content == nil {
                throw APIError(status: 400, message: "assistant message requires content or tool_calls", code: "invalid_request")
            } else {
                parsedToolCalls = nil
            }
            return ChatMessage(role: role, content: content, toolCallID: nil, toolCalls: parsedToolCalls)
        case .tool:
            guard let toolCallID = dict["tool_call_id"] as? String, !toolCallID.isEmpty else {
                throw APIError(status: 400, message: "tool message requires tool_call_id", code: "invalid_tool_call_id", param: "messages[\(index)].tool_call_id")
            }
            guard !(dict["content"] is NSNull) else {
                throw APIError(status: 400, message: "tool message requires content", code: "invalid_request", param: "messages[\(index)].content")
            }
            guard let content = try textProjection(from: dict["content"], messageIndex: index, allowNull: false) else {
                throw APIError(status: 400, message: "tool message requires content", code: "invalid_request", param: "messages[\(index)].content")
            }
            return ChatMessage(role: role, content: content, toolCallID: toolCallID, toolCalls: nil)
        }
    }
}

public struct ToolCall: Equatable, Sendable {
    public let id: String
    public let functionName: String
    public let arguments: String

    public init(id: String, functionName: String, arguments: String) {
        self.id = id
        self.functionName = functionName
        self.arguments = arguments
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
                "retryable": false,
                "request_id": NSNull(),
                "inference_ran": false,
                "settlement_ran": false,
            ]
        ]
    }
}

private func optionalInt(_ raw: Any?, key: String) throws -> Int? {
    guard let raw, !(raw is NSNull) else { return nil }
    if let number = raw as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            throw APIError(status: 400, message: "\(key) must be an integer", code: "invalid_request")
        }
        let objCType = String(cString: number.objCType)
        if objCType == "f" || objCType == "d" {
            let double = number.doubleValue
            guard double.rounded(.towardZero) == double,
                  double >= Double(Int.min),
                  double <= Double(Int.max) else {
                throw APIError(status: 400, message: "\(key) must be an integer", code: "invalid_request")
            }
            return number.intValue
        }
        return number.intValue
    }
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

private func optionalJSONValue(_ raw: Any?) throws -> JSONValue? {
    guard let raw else { return nil }
    return try JSONValue.parse(raw)
}

private func validateOptionalJSONBool(_ raw: Any?, key: String) throws {
    guard let raw, !(raw is NSNull) else { return }
    guard raw is Bool else {
        throw APIError(status: 400, message: "\(key) must be a boolean", code: "invalid_request")
    }
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

private func parseAssistantToolCalls(_ raw: Any, messageIndex: Int) throws -> [ToolCall] {
    guard let calls = raw as? [Any], !calls.isEmpty else {
        throw APIError(status: 400, message: "messages[\(messageIndex)].tool_calls must be a non-empty array", code: "invalid_tools")
    }
    return try calls.enumerated().map { index, rawCall in
        guard let call = rawCall as? [String: Any] else {
            throw APIError(status: 400, message: "Invalid messages[\(messageIndex)].tool_calls[\(index)]", code: "invalid_tools")
        }
        guard let id = call["id"] as? String, call["type"] as? String == "function",
              let function = call["function"] as? [String: Any],
              let name = function["name"] as? String,
              !name.isEmpty,
              let arguments = function["arguments"] as? String
        else {
            throw APIError(status: 400, message: "Invalid messages[\(messageIndex)].tool_calls[\(index)]", code: "invalid_tools")
        }
        guard arguments.utf8.count <= RequestValidation.toolCallArgumentsPerCallByteCap else {
            throw APIError(status: 413, message: "tool_call arguments exceed 1 MiB", code: "tool_call_arguments_too_large", param: "messages[\(messageIndex)].tool_calls[\(index)].function.arguments")
        }
        guard let data = arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else {
            throw APIError(status: 400, message: "Invalid tool_call arguments JSON", code: "invalid_tools")
        }
        return ToolCall(id: id, functionName: name, arguments: arguments)
    }
}

private func textProjection(from raw: Any?, messageIndex: Int, allowNull: Bool) throws -> String? {
    guard let raw, !(raw is NSNull) else {
        if allowNull {
            return nil
        }
        throw APIError(status: 400, message: "messages[\(messageIndex)].content is invalid", code: "invalid_request")
    }
    if let string = raw as? String {
        return string
    }
    guard let parts = raw as? [Any] else {
        throw APIError(status: 400, message: "messages[\(messageIndex)].content is invalid", code: "invalid_request")
    }
    var textParts: [String] = []
    for (partIndex, rawPart) in parts.enumerated() {
        guard let part = rawPart as? [String: Any], let type = part["type"] as? String else {
            throw APIError(status: 400, message: "messages[\(messageIndex)].content[\(partIndex)] is invalid", code: "invalid_request")
        }
        switch type {
        case "text":
            guard let text = part["text"] as? String else {
                throw APIError(status: 400, message: "messages[\(messageIndex)].content[\(partIndex)].text is invalid", code: "invalid_request")
            }
            textParts.append(text)
        case "image_url":
            guard let imageURL = part["image_url"] as? [String: Any],
                  imageURL["url"] is String,
                  imageURL["detail"] == nil || imageURL["detail"] is NSNull || imageURL["detail"] is String else {
                throw APIError(status: 400, message: "messages[\(messageIndex)].content[\(partIndex)].image_url is invalid", code: "invalid_request")
            }
        case "input_audio":
            guard let inputAudio = part["input_audio"] as? [String: Any],
                  inputAudio["data"] is String,
                  inputAudio["format"] is String else {
                throw APIError(status: 400, message: "messages[\(messageIndex)].content[\(partIndex)].input_audio is invalid", code: "invalid_request")
            }
        default:
            throw APIError(status: 400, message: "messages[\(messageIndex)].content[\(partIndex)].type is invalid", code: "invalid_request")
        }
    }
    return textParts.joined(separator: "\n")
}

private enum RequestValidation {
    static let rawBodyByteCap = 4 * 1024 * 1024
    static let toolResultPerMessageByteCap = 256 * 1024
    static let toolResultsAggregateByteCap = 1024 * 1024
    static let toolCallArgumentsPerCallByteCap = 1024 * 1024
    static let toolCallArgumentsAggregateByteCap = 2 * 1024 * 1024
    static let maxMessages = 256
    static let maxAssistantToolCalls = 128

    static func validate(_ messages: [ChatMessage]) throws {
        guard messages.count <= maxMessages else {
            throw APIError(status: 400, message: "messages may contain at most 256 entries", code: "messages_too_long")
        }

        var assistantIDs: [String: Int] = [:]
        var duplicateAssistantID: String?
        var totalToolCalls = 0
        var aggregateArgumentsBytes = 0

        for (messageIndex, message) in messages.enumerated() {
            guard let calls = message.toolCalls else { continue }
            totalToolCalls += calls.count
            guard totalToolCalls <= maxAssistantToolCalls else {
                throw APIError(status: 400, message: "assistant tool_calls may contain at most 128 entries", code: "too_many_tool_calls")
            }
            for (callIndex, call) in calls.enumerated() {
                guard isRequestAcceptedToolCallID(call.id) else {
                    throw APIError(status: 400, message: "Invalid tool_call id", code: "invalid_tool_call_id", param: "messages[\(messageIndex)].tool_calls[\(callIndex)].id")
                }
                if assistantIDs[call.id] != nil {
                    duplicateAssistantID = call.id
                } else {
                    assistantIDs[call.id] = messageIndex
                }
                aggregateArgumentsBytes += call.arguments.utf8.count
                guard aggregateArgumentsBytes <= toolCallArgumentsAggregateByteCap else {
                    throw APIError(status: 413, message: "assistant-history tool_call arguments exceed aggregate cap", code: "tool_call_arguments_aggregate_too_large")
                }
            }
        }
        if duplicateAssistantID != nil {
            throw APIError(status: 400, message: "Duplicate assistant tool_call id", code: "duplicate_tool_call_id")
        }

        var fulfilledToolIDs: Set<String> = []
        var aggregateToolResultBytes = 0
        for (messageIndex, message) in messages.enumerated() where message.role == .tool {
            guard let toolCallID = message.toolCallID, isRequestAcceptedToolCallID(toolCallID) else {
                throw APIError(status: 400, message: "Invalid tool_call_id", code: "invalid_tool_call_id", param: "messages[\(messageIndex)].tool_call_id")
            }
            guard let assistantIndex = assistantIDs[toolCallID] else {
                throw APIError(status: 400, message: "tool_call_id does not reference an earlier assistant tool_call", code: "tool_call_id_not_found")
            }
            guard assistantIndex < messageIndex else {
                throw APIError(status: 400, message: "tool result appears before matching assistant tool_call", code: "tool_call_result_out_of_order")
            }
            guard !fulfilledToolIDs.contains(toolCallID) else {
                throw APIError(status: 400, message: "Duplicate tool result for tool_call_id", code: "duplicate_tool_call_id")
            }
            fulfilledToolIDs.insert(toolCallID)

            let contentBytes = message.content?.utf8.count ?? 0
            guard contentBytes <= toolResultPerMessageByteCap else {
                throw APIError(status: 413, message: "tool message content exceeds 256 KiB", code: "tool_result_too_large", param: "messages[\(messageIndex)].content")
            }
            aggregateToolResultBytes += contentBytes
            guard aggregateToolResultBytes <= toolResultsAggregateByteCap else {
                throw APIError(status: 413, message: "tool message content exceeds aggregate cap", code: "tool_results_aggregate_too_large")
            }
        }
    }

    static func isRequestAcceptedToolCallID(_ value: String) -> Bool {
        guard value.hasPrefix("call_") else { return false }
        let suffix = value.dropFirst(5)
        guard (16 ... 64).contains(suffix.utf8.count) else { return false }
        return suffix.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
                (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122)
        }
    }
}
