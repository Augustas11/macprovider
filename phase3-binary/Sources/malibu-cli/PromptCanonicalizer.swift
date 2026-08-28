import Foundation
import MacProviderCore

enum PromptCanonicalizer {
    static func canonicalPromptObject(for request: ChatCompletionRequest) throws -> RFC8785JCS.Value {
        let source = request.promptSource
        return .object([
            "model": try source.model.jcsValue(),
            "messages": .array(try source.messages.map(canonicalMessage)),
            "tools": try canonicalTools(source.tools),
            "temperature": try jcsOrNull(source.temperature),
            "top_p": try jcsOrNull(source.topP),
            "max_tokens": try jcsOrNull(source.maxTokens),
            "stop": try jcsOrNull(source.stop),
            "seed": try jcsOrNull(source.seed),
            "response_format": try jcsOrNull(source.responseFormat),
            "tool_choice": try jcsOrNull(source.toolChoice),
            "presence_penalty": try jcsOrNull(source.presencePenalty),
            "frequency_penalty": try jcsOrNull(source.frequencyPenalty),
            "logit_bias": try jcsOrNull(source.logitBias),
            "logprobs": try jcsOrNull(source.logprobs),
            "top_logprobs": try jcsOrNull(source.topLogprobs),
            "n": try jcsOrNull(source.n),
        ])
    }

    static func promptHash(for request: ChatCompletionRequest) throws -> String {
        try RFC8785JCS.sha256Hex(of: canonicalPromptObject(for: request))
    }

    private static func canonicalMessage(_ value: JSONValue) throws -> RFC8785JCS.Value {
        let object = try objectValue(value, context: "message")
        return .object([
            "role": .string(try stringValue(object["role"], context: "message role")),
            "content": try canonicalContent(object["content"]),
            "name": try jcsOrNull(object["name"]),
            "tool_call_id": try jcsOrNull(object["tool_call_id"]),
            "tool_calls": try canonicalToolCalls(object["tool_calls"]),
        ])
    }

    private static func canonicalContent(_ value: JSONValue?) throws -> RFC8785JCS.Value {
        guard let value else { return .null }
        switch value {
        case .null:
            return .null
        case .string(let string):
            return .string(normalizeLineEndings(string))
        case .array(let parts):
            return .array(try parts.map(canonicalContentPart))
        default:
            throw Error.invalidContent
        }
    }

    private static func canonicalContentPart(_ value: JSONValue) throws -> RFC8785JCS.Value {
        let object = try objectValue(value, context: "content part")
        let type = try stringValue(object["type"], context: "content part type")
        switch type {
        case "text":
            return .object([
                "type": .string("text"),
                "text": .string(normalizeLineEndings(try stringValue(object["text"], context: "text content"))),
            ])
        case "image_url":
            let imageURL = try objectValue(object["image_url"], context: "image_url")
            return .object([
                "type": .string("image_url"),
                "image_url": .object([
                    "url": .string(try stringValue(imageURL["url"], context: "image_url.url")),
                    "detail": try jcsOrNull(imageURL["detail"]),
                ]),
            ])
        case "input_audio":
            let inputAudio = try objectValue(object["input_audio"], context: "input_audio")
            return .object([
                "type": .string("input_audio"),
                "input_audio": .object([
                    "data": .string(try stringValue(inputAudio["data"], context: "input_audio.data")),
                    "format": .string(try stringValue(inputAudio["format"], context: "input_audio.format")),
                ]),
            ])
        default:
            throw Error.invalidContentPartType(type)
        }
    }

    private static func canonicalTools(_ value: JSONValue?) throws -> RFC8785JCS.Value {
        guard let value, value != .null else { return .null }
        guard case .array(let tools) = value else {
            throw Error.invalidTools
        }
        return .array(try tools.map(canonicalTool))
    }

    private static func canonicalTool(_ value: JSONValue) throws -> RFC8785JCS.Value {
        let object = try objectValue(value, context: "tool")
        let function = try objectValue(object["function"], context: "tool.function")
        return .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(try stringValue(function["name"], context: "tool.function.name")),
                "description": try jcsOrNull(function["description"]),
                "parameters": try jcsOrNull(function["parameters"]),
            ]),
        ])
    }

    static func canonicalToolCalls(_ value: JSONValue?) throws -> RFC8785JCS.Value {
        guard let value, value != .null else { return .null }
        guard case .array(let calls) = value else {
            throw Error.invalidToolCalls
        }
        return .array(try calls.map(canonicalToolCall))
    }

    static func canonicalToolCall(_ value: JSONValue) throws -> RFC8785JCS.Value {
        let object = try objectValue(value, context: "tool_call")
        let function = try objectValue(object["function"], context: "tool_call.function")
        return .object([
            "id": .string(try stringValue(object["id"], context: "tool_call.id")),
            "type": .string("function"),
            "function": .object([
                "name": .string(try stringValue(function["name"], context: "tool_call.function.name")),
                "arguments": .rawString(try stringValue(function["arguments"], context: "tool_call.function.arguments")),
            ]),
        ])
    }

    static func jcsOrNull(_ value: JSONValue?) throws -> RFC8785JCS.Value {
        guard let value else { return .null }
        return try value.jcsValue()
    }

    static func objectValue(_ value: JSONValue?, context: String) throws -> [String: JSONValue] {
        guard case .object(let object) = value else {
            throw Error.expectedObject(context)
        }
        return object
    }

    static func stringValue(_ value: JSONValue?, context: String) throws -> String {
        guard case .string(let string) = value else {
            throw Error.expectedString(context)
        }
        return string
    }

    static func normalizeLineEndings(_ string: String) -> String {
        string.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    enum Error: Swift.Error, Equatable {
        case expectedObject(String)
        case expectedString(String)
        case invalidContent
        case invalidContentPartType(String)
        case invalidTools
        case invalidToolCalls
    }
}
