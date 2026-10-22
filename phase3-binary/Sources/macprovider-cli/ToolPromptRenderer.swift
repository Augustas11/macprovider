import Foundation
import Jinja
import MLXLMCommon
import MacProviderCore

/// A chat template that refuses the conversation with `raise_exception` (for
/// example Llama 3.x, which renders one tool call per assistant turn) is a
/// request error, not a provider failure.
enum ChatTemplateRequestError {
    static func mapping(_ error: Error) -> Error {
        guard error is TemplateException else { return error }
        return APIError(
            status: 400,
            message: "The model's chat template does not accept this conversation (for example several tool calls in one assistant turn)",
            code: "invalid_request",
            param: "messages"
        )
    }
}

/// SPEC-018 §3.6: multi-turn tool history is rendered by the model's own chat
/// template. Assistant `tool_calls` reach the template as structured calls
/// whose `arguments` are an object, and `tool` messages carry `tool_call_id`
/// (and the called function's name), so every template renders its native
/// call and result grammar. Nothing is hand-rendered here.
enum ToolPromptRenderer {
    /// Family-selected grammar, for callers without a loaded template.
    static func renderMessages(_ messages: [ChatMessage], modelID: String) throws -> [Chat.Message] {
        try renderMessages(messages, grammar: ToolCallGrammar.family(modelID: modelID))
    }

    static func renderMessages(_ messages: [ChatMessage], grammar: ToolCallGrammar?) throws -> [Chat.Message] {
        let containsMultiTurnToolData = messages.contains { message in
            message.role == .tool || message.toolCalls?.isEmpty == false
        }
        guard containsMultiTurnToolData else {
            return messages.map(\.mlxMessage)
        }
        // A template without a tool grammar cannot render tool history.
        guard grammar != nil else {
            throw APIError(
                status: 400,
                message: "Model does not support multi-turn tool history rendering",
                code: "unsupported_modelID_for_multi_turn"
            )
        }

        var namesByCallID: [String: String] = [:]
        return try messages.map { message in
            switch message.role {
            case .system:
                return .system(message.content ?? "")
            case .user:
                return .user(message.content ?? "")
            case .assistant:
                guard let calls = message.toolCalls, !calls.isEmpty else {
                    return .assistant(message.content ?? "")
                }
                let structured = try calls.map { call -> MLXLMCommon.ToolCall in
                    // Templates write names (and, in XML/GLM/Gemma grammars,
                    // keys) unquoted: keep them inside the OpenAI charset so
                    // history cannot forge call markup.
                    guard ToolCallParser.isValidToolFunctionName(call.functionName) else {
                        throw APIError(status: 400, message: "Tool history names are outside the tool-call grammar", code: "invalid_tools")
                    }
                    namesByCallID[call.id] = call.functionName
                    return MLXLMCommon.ToolCall(
                        function: .init(name: call.functionName, arguments: try argumentsObject(call)),
                        id: call.id
                    )
                }
                return .assistant(message.content ?? "", toolCalls: structured)
            case .tool:
                let id = message.toolCallID ?? ""
                return .tool(message.content ?? "", id: id, name: namesByCallID[id])
            }
        }
    }

    /// History arguments are request input: bounded strict JSON objects.
    private static func argumentsObject(_ call: MacProviderCore.ToolCall) throws -> [String: MLXLMCommon.JSONValue] {
        let parsed: MacProviderCore.JSONValue
        do {
            parsed = try StrictJSONParser.parse(call.arguments)
        } catch {
            // The parser's output-depth error must not claim inference ran.
            throw APIError(status: 400, message: "Tool history arguments must be bounded strict JSON", code: "invalid_tools")
        }
        guard case .object(let object) = parsed else {
            throw APIError(status: 400, message: "Tool history arguments must be an object", code: "invalid_tools")
        }
        guard object.keys.allSatisfy(ToolCallParser.isValidToolParameterName) else {
            throw APIError(status: 400, message: "Tool history names are outside the tool-call grammar", code: "invalid_tools")
        }
        return object.mapValues(templateValue)
    }

    private static func templateValue(_ value: MacProviderCore.JSONValue) -> MLXLMCommon.JSONValue {
        switch value {
        case .object(let object): return .object(object.mapValues(templateValue))
        case .array(let array): return .array(array.map(templateValue))
        case .string(let string): return .string(string)
        case .int(let int): return .int(int)
        case .double(let double): return .double(double)
        case .bool(let bool): return .bool(bool)
        case .null: return .null
        }
    }
}

extension ChatMessage {
    var mlxMessage: Chat.Message {
        switch role {
        case .system:
            return .system(content ?? "")
        case .user:
            return .user(content ?? "")
        case .assistant:
            return .assistant(content ?? "")
        case .tool:
            return .tool(content ?? "", id: toolCallID)
        }
    }
}
