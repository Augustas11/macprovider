import Foundation

/// Canonical, schema-shaped output languages. Object keys use a stable order;
/// optional declared fields are emitted too. Values remain model-generated.
public enum GrammarTemplates {
    public static func grammar(for request: ChatCompletionRequest, traits: RequestOutputTraits) throws -> ByteGrammar? {
        switch request.responseFormat {
        case .jsonSchema(let spec): return schema(spec.schema)
        case .jsonObject: return .choice([genericObject(depth: 3), array(generic(depth: 2))])
        case .text: break
        }
        let selection = try ToolSelectionPolicy.selection(request.promptSource.toolChoice)
        guard selection.requiresCall else { return nil }
        guard let family = traits.toolGrammar ?? ToolCallGrammar.family(modelID: request.model) else { return nil }
        let schemas = try ToolSelectionPolicy.schemas(request)
        if family == .glm || family == .deepseekV4 || family == .gemma4 {
            for value in schemas.values { try validateTaggedSchema(value) }
        }
        let names = schemas.keys.sorted().filter { name in
            if case .named(let selected) = selection { return name == selected }
            return true
        }
        return .choice(names.compactMap { name in
            schemas[name].map { toolCall(name: name, parameters: $0, family: family) }
        })
    }

    public static func schema(_ value: JSONValue) -> ByteGrammar { schema(value, depth: 0, gemma: false) }

    public static func toolCall(name: String, parameters: JSONValue, family: ToolCallGrammar) -> ByteGrammar {
        let arguments = schema(parameters)
        switch family {
        case .qwen:
            return .sequence([.literal("<tool_call>{\"name\":" + quoted(name) + ",\"arguments\":"), arguments, .literal("}</tool_call>")])
        case .llama3:
            return .sequence([.literal("{\"name\":" + quoted(name) + ",\"parameters\":"), arguments, .literal("}")])
        case .deepseekV4, .glm:
            let dsml = family == .deepseekV4
            var parts: [ByteGrammar] = [.literal(dsml ? "<｜DSML｜tool_calls><｜DSML｜invoke name=\"" + name + "\">" : "<tool_call>" + name)]
            if case .object(let object) = parameters, case .object(let properties)? = object["properties"] {
                for key in properties.keys.sorted() {
                    let property = properties[key]!
                    let rawString: Bool
                    if case .object(let details) = property { rawString = details["type"] == .string("string") } else { rawString = false }
                    parts += [.literal(dsml ? "<｜DSML｜parameter name=\"" + key + "\" string=\"" + (rawString ? "true" : "false") + "\">" : "<arg_key>" + key + "</arg_key><arg_value>"),
                              rawString ? rawStringGrammar(property) : schema(property), .literal(dsml ? "</｜DSML｜parameter>" : "</arg_value>")]
                }
            }
            parts.append(.literal(dsml ? "</｜DSML｜invoke></｜DSML｜tool_calls>" : "</tool_call>"))
            return .sequence(parts)
        case .gemma4:
            return .sequence([.literal("<|tool_call>call:" + name), schema(parameters, depth: 0, gemma: true), .literal("<tool_call|>")])
        case .harmony:
            return .sequence([.literal("<|start|>assistant to=functions." + name + "<|channel|>commentary<|message|>"), arguments, .literal("<|call|>")])
        }
    }

    private static func validateTaggedSchema(_ value: JSONValue) throws {
        switch value {
        case .object(let object):
            if case .object(let properties)? = object["properties"] {
                for key in properties.keys {
                    guard (1...128).contains(key.utf8.count), key.utf8.allSatisfy({
                        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
                    }) else { throw unsupportedGrammar("Tagged tool grammar requires safe parameter names") }
                }
            }
            for child in object.values { try validateTaggedSchema(child) }
        case .array(let values): for child in values { try validateTaggedSchema(child) }
        case .string(let text):
            guard !text.contains("<") else { throw unsupportedGrammar("Tagged tool schema contains a reserved delimiter") }
        default: break
        }
    }

    private static func rawStringGrammar(_ property: JSONValue) -> ByteGrammar {
        if case .object(let details) = property, case .array(let values)? = details["enum"] {
            return .choice(values.compactMap { if case .string(let text) = $0 { return .literal(text) }; return nil })
        }
        return rawText
    }

    private static let digits = ByteGrammar.bytes(Set("0123456789".utf8))
    private static let nonzero = ByteGrammar.bytes(Set("123456789".utf8))
    private static let integer = ByteGrammar.sequence([.optional(.literal("-")), .choice([
        .literal("0"), .sequence([nonzero, .zeroOrMore(digits)])
    ])])
    private static let number = ByteGrammar.sequence([integer,
        .optional(.sequence([.literal("."), digits, .zeroOrMore(digits)])),
        .optional(.sequence([.bytes(Set("eE".utf8)), .optional(.bytes(Set("+-".utf8))), digits, .zeroOrMore(digits)]))
    ])
    // ASCII is a valid JSON string sublanguage. Unicode is available via escapes.
    private static let string = ByteGrammar.sequence([.literal("\""), .zeroOrMore(.choice([
        .bytes(Set(UInt8(32)...UInt8(126)).subtracting([34, 92, 60])),
        .sequence([.literal("\\"), .choice([.bytes(Set("\"\\/bfnrt".utf8)),
            .sequence([.literal("u"), hex, hex, hex, hex])])])
    ])), .literal("\"")])
    private static let hex = ByteGrammar.bytes(Set("0123456789abcdefABCDEF".utf8))
    private static let rawText = ByteGrammar.zeroOrMore(.bytes(Set(UInt8(32)...UInt8(126)).subtracting([60])))
    private static func quoted(_ value: String) -> String { (try? JSONValue.string(value).deterministicJSONString()) ?? "\"\"" }

    private static func schema(_ value: JSONValue, depth: Int, gemma: Bool) -> ByteGrammar {
        guard depth < 8, case .object(let object) = value else { return generic(depth: 2, gemma: gemma) }
        let supported: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "description", "title", "$schema"]
        guard Set(object.keys).isSubset(of: supported) else { return generic(depth: 2, gemma: gemma) }
        if case .array(let values)? = object["enum"], !values.isEmpty {
            return .choice(values.map { literal($0, gemma: gemma) })
        }
        switch object["type"] {
        case .string("object")?:
            guard case .object(let properties)? = object["properties"] else { return genericObject(depth: 2, gemma: gemma) }
            let entries = properties.keys.sorted().map { key in
                ByteGrammar.sequence([literal(.string(key), gemma: gemma), .literal(":"), schema(properties[key]!, depth: depth + 1, gemma: gemma)])
            }
            return .sequence([.literal("{"), joined(entries), .literal("}")])
        case .string("array")?: return array(schema(object["items"] ?? .object([:]), depth: depth + 1, gemma: gemma))
        case .string("string")?: return gemma ? .sequence([.literal("<|\"|>"), rawText, .literal("<|\"|>")]) : string
        case .string("number")?: return number
        case .string("integer")?: return integer
        case .string("boolean")?: return .choice([.literal("true"), .literal("false")])
        case .string("null")?: return .literal("null")
        default: return generic(depth: 2, gemma: gemma)
        }
    }

    private static func literal(_ value: JSONValue, gemma: Bool) -> ByteGrammar {
        guard gemma else { return .literal((try? value.deterministicJSONString()) ?? "null") }
        switch value {
        case .string(let text): return .literal("<|\"|>" + text + "<|\"|>")
        case .array(let values): return .sequence([.literal("["), joined(values.map { literal($0, gemma: true) }), .literal("]")])
        case .object(let object): return .sequence([.literal("{"), joined(object.keys.sorted().map { .sequence([literal(.string($0), gemma: true), .literal(":"), literal(object[$0]!, gemma: true)]) }), .literal("}")])
        default: return .literal((try? value.deterministicJSONString()) ?? "null")
        }
    }
    private static func joined(_ parts: [ByteGrammar]) -> ByteGrammar {
        .sequence(parts.enumerated().flatMap { $0.offset == 0 ? [$0.element] : [.literal(","), $0.element] })
    }
    private static func array(_ item: ByteGrammar) -> ByteGrammar {
        .sequence([.literal("["), .optional(.sequence([item, .zeroOrMore(.sequence([.literal(","), item]))])), .literal("]")])
    }
    private static func genericObject(depth: Int, gemma: Bool = false) -> ByteGrammar {
        let key = gemma ? ByteGrammar.sequence([.literal("<|\"|>"), rawText, .literal("<|\"|>")]) : string
        let entry = ByteGrammar.sequence([key, .literal(":"), generic(depth: max(0, depth - 1), gemma: gemma)])
        return .sequence([.literal("{"), .optional(.sequence([entry, .zeroOrMore(.sequence([.literal(","), entry]))])), .literal("}")])
    }
    private static func generic(depth: Int, gemma: Bool = false) -> ByteGrammar {
        var choices: [ByteGrammar] = [gemma ? .sequence([.literal("<|\"|>"), rawText, .literal("<|\"|>")]) : string, number, .literal("true"), .literal("false"), .literal("null")]
        if depth > 0 { choices += [genericObject(depth: depth, gemma: gemma), array(generic(depth: depth - 1, gemma: gemma))] }
        return .choice(choices)
    }
}
