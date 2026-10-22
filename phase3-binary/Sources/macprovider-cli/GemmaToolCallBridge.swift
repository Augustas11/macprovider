import Foundation
import MLXLMCommon
import MacProviderCore

/// Gemma 4 tool calls (`<|tool_call>call:NAME{key:<|"|>v<|"|>,n:5}<tool_call|>`,
/// the grammar its chat template renders). The brace dialect is parsed by
/// mlx-swift-lm's reviewed `GemmaFunctionParser`; this bridge adds the
/// SPEC-018 envelope checks and converts the result to canonical JSON.
enum GemmaToolCallBridge {
    enum Failure: Error { case malformed }

    static func call(_ body: String, schemas: [String: MacProviderCore.JSONValue]?) throws -> macprovider_cli.ToolCall {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("call:"), trimmed.hasSuffix("}"),
              let brace = trimmed.firstIndex(of: "{") else { throw Failure.malformed }
        let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: "call:".count)..<brace])
        guard ToolCallParser.isValidToolFunctionName(name) else { throw Failure.malformed }
        let parser = MLXLMCommon.ToolCallFormat.gemma4.createParser()
        guard let parsed = parser.parse(content: trimmed, tools: tools(from: schemas)),
              parsed.function.name == name else { throw Failure.malformed }
        guard parsed.function.arguments.keys.allSatisfy(ToolCallParser.isValidToolParameterName) else {
            throw Failure.malformed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(parsed.function.arguments)
        let value = try StrictJSONParser.parse(
            String(decoding: data, as: UTF8.self),
            maxDepth: ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH
        )
        guard case .object = value, ToolSelectionPolicy.supportsNumericDomain(value) else { throw Failure.malformed }
        return macprovider_cli.ToolCall(
            id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            functionName: name,
            arguments: try value.deterministicJSONString()
        )
    }

    /// The OpenAI tool list shape the parser reads declared types from.
    private static func tools(from schemas: [String: MacProviderCore.JSONValue]?) -> [[String: any Sendable]]? {
        guard let schemas, !schemas.isEmpty else { return nil }
        return schemas.keys.sorted().map { name in
            [
                "type": "function",
                "function": [
                    "name": name,
                    "parameters": sendable(schemas[name] ?? .null),
                ] as [String: any Sendable],
            ]
        }
    }

    private static func sendable(_ value: MacProviderCore.JSONValue) -> any Sendable {
        switch value {
        case .object(let object): return object.mapValues { sendable($0) } as [String: any Sendable]
        case .array(let array): return array.map { sendable($0) } as [any Sendable]
        case .string(let string): return string
        case .int(let int): return int
        case .double(let double): return double
        case .bool(let bool): return bool
        case .null: return Optional<String>.none as any Sendable
        }
    }
}
