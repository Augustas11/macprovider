import Foundation
import MacProviderCore

// StructuredOutputRenderer
//
// Renders the SPEC-019 v0.1.5 structured-output schema instruction
// into the chat-template system position per family (Qwen3,
// Llama-3.3). Composed BEFORE ToolPromptRenderer.renderMessages
// per SPEC §4 composite-render rule: schema-adjusted ChatMessage →
// ToolPromptRenderer → UserInput.
//
// Stateless: no per-request, per-connection, or per-family cache.
// Concurrent requests render independently. Cache deferred to v0.2
// per SPEC §10.
//
// Family selection mirrors ToolPromptRenderer.detect(modelID:) —
// modelID substring match; Qwen3 / Llama-3.3 only in v0.1.0.
enum StructuredOutputRenderer {
    enum Family {
        case qwen3
        case llama33
        case generic
    }

    static func detect(modelID: String) -> Family {
        if modelID.localizedCaseInsensitiveContains("qwen2.5") ||
            modelID.localizedCaseInsensitiveContains("qwen3")
        {
            return .qwen3
        }
        if modelID.localizedCaseInsensitiveContains("llama-3.3") {
            return .llama33
        }
        return .generic
    }

    static func prependResponseFormatInstruction(to messages: [ChatMessage], responseFormat: ResponseFormat, modelID: String) throws -> [ChatMessage] {
        switch responseFormat {
        case .text:
            return messages
        case .jsonObject:
            return prependInstruction(
                jsonObjectInstruction(family: detect(modelID: modelID)),
                to: messages
            )
        case .jsonSchema(let spec):
            return try prependSchemaInstruction(
                to: messages,
                schema: spec.schema,
                modelID: modelID,
                name: spec.name,
                description: spec.description
            )
        }
    }

    static func renderSchemaInstruction(schema: JSONValue, family: Family, name: String, description: String?) throws -> String {
        let schemaJSON = try schema.deterministicJSONString()
        var lines: [String] = []
        switch family {
        case .qwen3:
            lines.append("Structured output instruction for Qwen-family models:")
        case .llama33:
            lines.append("Structured output instruction for Llama-3.3-family models:")
        case .generic:
            lines.append("Structured output instruction:")
        }
        lines.append("Return only a JSON value that conforms to the response_format json_schema.")
        lines.append("Do not include Markdown fences, prose before the JSON, or trailing commentary.")
        lines.append("Schema name: \(jsonString(name))")
        if let description {
            lines.append("Schema description: \(jsonString(description))")
        }
        lines.append("Schema JSON: \(schemaJSON)")
        return lines.joined(separator: "\n")
    }

    static func prependSchemaInstruction(
        to messages: [ChatMessage],
        schema: JSONValue,
        modelID: String,
        name: String,
        description: String?
    ) throws -> [ChatMessage] {
        try prependInstruction(
            renderSchemaInstruction(schema: schema, family: detect(modelID: modelID), name: name, description: description),
            to: messages
        )
    }

    private static func jsonObjectInstruction(family: Family) -> String {
        let prefix: String
        switch family {
        case .qwen3:
            prefix = "Structured JSON object instruction for Qwen-family models:"
        case .llama33:
            prefix = "Structured JSON object instruction for Llama-3.3-family models:"
        case .generic:
            prefix = "Structured JSON object instruction:"
        }
        return [
            prefix,
            "Return only valid JSON whose top-level value is an object or array.",
            "Do not include Markdown fences, prose before the JSON, or trailing commentary.",
        ].joined(separator: "\n")
    }

    private static func prependInstruction(_ instruction: String, to messages: [ChatMessage]) -> [ChatMessage] {
        guard let systemIndex = messages.firstIndex(where: { $0.role == .system }) else {
            return [ChatMessage(role: .system, content: instruction)] + messages
        }
        var adjusted = messages
        let system = adjusted[systemIndex]
        let existing = system.content ?? ""
        let separator = existing.isEmpty ? "" : "\n\n---\n\n"
        adjusted[systemIndex] = ChatMessage(
            role: .system,
            content: existing + separator + instruction,
            toolCallID: system.toolCallID,
            toolCalls: system.toolCalls
        )
        return adjusted
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        guard let data,
              let encoded = String(data: data, encoding: .utf8),
              encoded.hasPrefix("["),
              encoded.hasSuffix("]")
        else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}
