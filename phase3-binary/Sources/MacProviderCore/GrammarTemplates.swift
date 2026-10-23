import Foundation

/// Canonical, schema-shaped output languages. Object keys use a stable order;
/// optional declared fields are emitted too. Values remain model-generated.
public enum GrammarTemplates {
    public static func grammar(for request: ChatCompletionRequest, traits: RequestOutputTraits) throws -> ByteGrammar? {
        let family = traits.toolGrammar ?? ToolCallGrammar.family(modelID: request.model)
        switch request.responseFormat {
        case .jsonSchema(let spec):
            try validateRequiredProperties(spec.schema)
            return structured(schema(spec.schema), family: family)
        case .jsonObject:
            return structured(.choice([genericObject(depth: 1), array(generic(depth: 0))]), family: family)
        case .text: break
        }
        let selection = try ToolSelectionPolicy.selection(request.promptSource.toolChoice)
        guard selection.requiresCall else { return nil }
        guard let family else { return nil }
        let schemas = try ToolSelectionPolicy.schemas(request)
        for value in schemas.values { try validateRequiredProperties(value) }
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
        // Unsupported top-level keywords must never widen a function's
        // parameters from an object into arbitrary JSON scalars.
        let parameters = canonicalToolObject(parameters)
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

    private static func structured(_ body: ByteGrammar, family: ToolCallGrammar?) -> ByteGrammar {
        guard family == .harmony else { return body }
        return .sequence([.literal("<|start|>assistant<|channel|>final<|message|>"), body, .literal("<|return|>")])
    }

    private static func canonicalToolObject(_ value: JSONValue) -> JSONValue {
        guard case .object(let object) = value else {
            return .object(["type": .string("object"), "properties": .object([:])])
        }
        var result: [String: JSONValue] = ["type": .string("object"), "properties": object["properties"] ?? .object([:])]
        for key in ["required", "additionalProperties"] { result[key] = object[key] }
        return .object(result)
    }

    private static func validateRequiredProperties(_ value: JSONValue) throws {
        guard case .object(let object) = value else { return }
        if case .array(let values)? = object["enum"],
           !values.contains(where: { matchesDeclaredType($0, type: object["type"]) }) {
            throw unsupportedGrammar("Output enum has no values matching its declared type")
        }
        let properties: [String: JSONValue]
        if case .object(let declared)? = object["properties"] { properties = declared } else { properties = [:] }
        if case .array(let required)? = object["required"] {
            for key in required {
                guard case .string(let name) = key, properties[name] != nil else {
                    throw unsupportedGrammar("Required output properties need declared schemas")
                }
            }
        }
        for child in properties.values { try validateRequiredProperties(child) }
        if let items = object["items"] { try validateRequiredProperties(items) }
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
    // Fifteen integral digits and nonpositive bounded exponents stay finite
    // and inside the parser's safe numeric magnitude for every generated value.
    private static let integer = ByteGrammar.sequence([.optional(.literal("-")), .choice([
        .literal("0"), .sequence([nonzero] + Array(repeating: .optional(digits), count: 14))
    ])])
    private static let number = ByteGrammar.sequence([integer,
        .optional(.sequence([.literal("."), digits, .zeroOrMore(digits)])),
        .optional(.sequence([.bytes(Set("eE".utf8)), .literal("-"), digits, .optional(digits)]))
    ])
    // ASCII is a valid JSON string sublanguage. Unicode is available via escapes.
    private static let unicodeEscape = ByteGrammar.choice([
        .sequence([.bytes(Set("0123456789abcABCeEfF".utf8)), hex, hex, hex]),
        .sequence([.bytes(Set("dD".utf8)), .bytes(Set("01234567".utf8)), hex, hex]),
        .sequence([.bytes(Set("dD".utf8)), .bytes(Set("89abAB".utf8)), hex, hex,
                   .literal("\\u"), .bytes(Set("dD".utf8)), .bytes(Set("cdefCDEF".utf8)), hex, hex])
    ])
    private static let string = ByteGrammar.sequence([.literal("\""), .zeroOrMore(.choice([
        .bytes(Set(UInt8(32)...UInt8(126)).subtracting([34, 92, 60])),
        .sequence([.literal("\\"), .choice([.bytes(Set("\"\\/bfnrt".utf8)),
            .sequence([.literal("u"), unicodeEscape])])])
    ])), .literal("\"")])
    private static let hex = ByteGrammar.bytes(Set("0123456789abcdefABCDEF".utf8))
    private static let rawText = ByteGrammar.zeroOrMore(.bytes(Set(UInt8(32)...UInt8(126)).subtracting([60])))
    private static func quoted(_ value: String) -> String { (try? JSONValue.string(value).deterministicJSONString()) ?? "\"\"" }

    private static func schema(_ value: JSONValue, depth: Int, gemma: Bool) -> ByteGrammar {
        guard depth < 8, case .object(let object) = value else { return generic(depth: 1, gemma: gemma) }
        let supported: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "description", "title", "$schema"]
        guard Set(object.keys).isSubset(of: supported) else { return generic(depth: 1, gemma: gemma) }
        if case .array(let values)? = object["enum"], !values.isEmpty {
            return .choice(values.filter { matchesDeclaredType($0, type: object["type"]) }.map { literal($0, gemma: gemma) })
        }
        switch object["type"] {
        case .string("object")?:
            guard case .object(let properties)? = object["properties"] else { return genericObject(depth: 1, gemma: gemma) }
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
        default: return generic(depth: 1, gemma: gemma)
        }
    }

    private static func matchesDeclaredType(_ value: JSONValue, type: JSONValue?) -> Bool {
        guard case .string(let type)? = type else { return true }
        switch (type, value) {
        case ("string", .string), ("integer", .int), ("number", .int), ("number", .double),
             ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null): return true
        default: return false
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
