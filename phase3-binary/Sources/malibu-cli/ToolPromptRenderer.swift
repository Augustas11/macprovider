import Foundation
import MLXLMCommon
import MacProviderCore

enum ToolPromptRenderer {
    static func renderMessages(_ messages: [ChatMessage], modelID: String) throws -> [Chat.Message] {
        let containsMultiTurnToolData = messages.contains { message in
            message.role == .tool || message.toolCalls?.isEmpty == false
        }
        guard containsMultiTurnToolData else {
            return messages.map(\.mlxMessage)
        }

        guard let profile = ToolPromptProfile.detect(modelID: modelID) else {
            throw APIError(
                status: 400,
                message: "Model does not support multi-turn tool history rendering",
                code: "unsupported_modelID_for_multi_turn"
            )
        }

        return try messages.map { message in
            switch message.role {
            case .system:
                return .system(message.content ?? "")
            case .user:
                return .user(message.content ?? "")
            case .assistant:
                return .assistant(try profile.renderAssistant(message))
            case .tool:
                return .tool(profile.renderToolResult(message))
            }
        }
    }
}

private enum ToolPromptProfile {
    case qwen3
    case llama33

    static func detect(modelID: String) -> ToolPromptProfile? {
        if modelID.localizedCaseInsensitiveContains("qwen2.5") ||
            modelID.localizedCaseInsensitiveContains("qwen3")
        {
            return .qwen3
        }
        if modelID.localizedCaseInsensitiveContains("llama-3.3") {
            return .llama33
        }
        return nil
    }

    func renderAssistant(_ message: ChatMessage) throws -> String {
        var rendered = message.content ?? ""
        guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else {
            return rendered
        }
        if !rendered.isEmpty {
            rendered += "\n"
        }
        rendered += try toolCalls.map(renderToolCall).joined(separator: "\n")
        return rendered
    }

    func renderToolResult(_ message: ChatMessage) -> String {
        let id = message.toolCallID ?? ""
        let content = message.content ?? ""
        switch self {
        case .qwen3:
            return "<tool_response id=\"\(escapeAttribute(id))\">\n\(content)\n</tool_response>"
        case .llama33:
            return "<|start_header_id|>ipython<|end_header_id|>\n\(content)<|eot_id|>"
        }
    }

    private func renderToolCall(_ call: MacProviderCore.ToolCall) throws -> String {
        let body = try toolCallBody(call)
        switch self {
        case .qwen3:
            return "<tool_call>\(body)</tool_call>"
        case .llama33:
            return "<|python_tag|>\(body)<|eom_id|>"
        }
    }

    private func toolCallBody(_ call: MacProviderCore.ToolCall) throws -> String {
        let argumentsObject: Any
        if let data = call.arguments.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           let object = parsed as? [String: Any]
        {
            argumentsObject = object
        } else {
            argumentsObject = call.arguments
        }

        let body: [String: Any]
        switch self {
        case .qwen3:
            body = [
                "name": call.functionName,
                "arguments": argumentsObject,
                "id": call.id,
                "type": "function",
            ]
        case .llama33:
            body = [
                "name": call.functionName,
                "parameters": argumentsObject,
                "id": call.id,
                "type": "function",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
            return .tool(content ?? "")
        }
    }
}
