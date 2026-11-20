import Foundation

/// Canonical, schema-shaped output languages. Object keys use a stable order;
/// optional declared fields are emitted too. Values remain model-generated.
public enum GrammarTemplates {
    /// `qwenCallFormat` is the call form the loaded Qwen-family template
    /// teaches (`GrammarConstraintState.promptsFunctionXMLHeader`); other
    /// families ignore it.
    public static func grammar(for request: ChatCompletionRequest, traits: RequestOutputTraits,
                               qwenCallFormat: ToolSelectionPolicy.CallFormat = .jsonEnvelope) throws -> ByteGrammar? {
        let family = traits.toolGrammar ?? ToolCallGrammar.family(modelID: request.model)
        switch request.responseFormat {
        case .jsonSchema(let spec):
            if !spec.strict {
                // Advisory schemas cannot narrow admission. Use generic JSON
                // rather than fail preparation on an incompatible schema hint.
                return structured(generic(depth: 1), family: family)
            }
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
        if family == .lfm2 { try ToolSelectionPolicy.validateLFMNames(schemas) }
        for value in schemas.values { try validateRequiredProperties(value) }
        if family == .glm || family == .dsml || family == .gemma4 || family == .minimax {
            for value in schemas.values { try validateTaggedSchema(value) }
        }
        let names = schemas.keys.sorted().filter { name in
            if case .named(let selected) = selection { return name == selected }
            return true
        }
        return .choice(names.compactMap { name in
            schemas[name].map { toolCall(name: name, parameters: $0, family: family, qwenCallFormat: qwenCallFormat) }
        })
    }

    public static func schema(_ value: JSONValue) -> ByteGrammar { schema(value, depth: 0, gemma: false) }

    public static func toolCall(name: String, parameters: JSONValue, family: ToolCallGrammar,
                                qwenCallFormat: ToolSelectionPolicy.CallFormat = .jsonEnvelope) -> ByteGrammar {
        if case .object(let object) = parameters, object["enum"] != nil {
            var declared: [String: JSONValue] = [:]
            if case .object(let properties)? = object["properties"] { declared = properties }
            return .choice(enumCandidates(object).compactMap { value in
                guard case .object(let fields) = value else { return nil }
                // The parser types a function-XML value by the buyer's schema, not by
                // this enum: a string field it does not declare as a string would read
                // back as a number, boolean or null ("1" -> 1). Those calls keep the
                // JSON envelope, where the string stays quoted.
                let stringsDeclared = fields.allSatisfy { key, field in
                    guard case .string = field else { return true }
                    if case .object(let details)? = declared[key] { return details["type"] == .string("string") }
                    return false
                }
                let format = stringsDeclared ? qwenCallFormat : .jsonEnvelope
                let properties = fields.mapValues { literalSchema($0) }
                let exactObject = JSONValue.object(["type": .string("object"), "properties": .object(properties),
                    "required": .array(fields.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
                return toolCall(name: name, parameters: exactObject, family: family, qwenCallFormat: format)
            })
        }
        // Unsupported top-level keywords must never widen a function's
        // parameters from an object into arbitrary JSON scalars.
        let parameters = canonicalToolObject(parameters)
        let arguments = schema(parameters)
        switch family {
        case .qwen where qwenCallFormat == .functionXML && functionXMLExpresses(parameters):
            // The call exactly as a function-XML Qwen template (Qwen3.5/3.6/
            // 3.8, Qwen3-Coder) renders one, which is what its model was trained
            // to write: a forced JSON envelope is off-distribution for it and
            // can run a value to the token budget. String values are raw text;
            // other values are JSON, as `ToolCallParser.guaranteedFunctionXMLCall`
            // reads them.
            var parts: [ByteGrammar] = [.literal("<tool_call>\n<function=" + name + ">\n")]
            if case .object(let object) = parameters, case .object(let properties)? = object["properties"] {
                for key in properties.keys.sorted() {
                    let property = properties[key]!
                    var rawString = false
                    if case .object(let details) = property { rawString = details["type"] == .string("string") }
                    parts += [.literal("<parameter=" + key + ">\n"),
                              rawString ? rawStringGrammar(property, multiline: true) : schema(property),
                              .literal("\n</parameter>\n")]
                }
            }
            parts.append(.literal("</function>\n</tool_call>"))
            return .sequence(parts)
        case .qwen:
            return .sequence([.literal("<tool_call>{\"name\":" + quoted(name) + ",\"arguments\":"), arguments, .literal("}</tool_call>")])
        case .llama3:
            return .sequence([.literal("{\"name\":" + quoted(name) + ",\"parameters\":"), arguments, .literal("}")])
        case .dsml, .glm:
            let dsml = family == .dsml
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
        case .minimax:
            // Strings raw, other values as JSON (as for GLM); the parser also
            // reads the template's nested-element form.
            let ns = "]<]minimax[>["
            var parts: [ByteGrammar] = [.literal(ns + "<tool_call>\n" + ns + "<invoke name=\"" + name + "\">")]
            if case .object(let object) = parameters, case .object(let properties)? = object["properties"] {
                for key in properties.keys.sorted() {
                    let property = properties[key]!
                    var rawString = false
                    if case .object(let details) = property { rawString = details["type"] == .string("string") }
                    parts += [.literal(ns + "<" + key + ">"), rawString ? rawStringGrammar(property) : schema(property),
                              .literal(ns + "</" + key + ">")]
                }
            }
            parts.append(.literal(ns + "</invoke>\n" + ns + "</tool_call>"))
            return .sequence(parts)
        case .gemma4:
            return .sequence([.literal("<|tool_call>call:" + name), schema(parameters, depth: 0, gemma: true), .literal("<tool_call|>")])
        case .lfm2:
            var parts: [ByteGrammar] = [.literal("<|tool_call_start|>[" + name + "(")]
            if case .object(let object) = parameters {
                let properties = objectProperties(object)
                for (index, key) in properties.keys.sorted().enumerated() {
                    if index > 0 { parts.append(.literal(",")) }
                    parts += [.literal(key + "="), schema(properties[key]!)]
                }
            }
            parts.append(.literal(")]<|tool_call_end|>"))
            return .sequence(parts)
        case .harmony:
            return .sequence([.literal("<|start|>assistant to=functions." + name + "<|channel|>commentary<|message|>"), arguments, .literal("<|call|>")])
        }
    }

    private static func literalSchema(_ value: JSONValue) -> JSONValue {
        let type: String
        switch value {
        case .object: type = "object"
        case .array: type = "array"
        case .string: type = "string"
        case .int: type = "integer"
        case .double: type = "number"
        case .bool: type = "boolean"
        case .null: type = "null"
        }
        return .object(["type": .string(type), "enum": .array([value])])
    }

    private static func enumCandidates(_ object: [String: JSONValue]) -> [JSONValue] {
        guard case .array(let values)? = object["enum"] else { return [] }
        let schema = JSONValue.object(object)
        // The strict validator's shape gate permits scalar enums only, but
        // its instance validator also compares object/array enum instances.
        var validationShape = object
        validationShape.removeValue(forKey: "enum")
        let strict = (try? JSONSchemaValidator.validateSchemaShape(schema: .object(validationShape))) != nil
        return values.filter { value in
            guard matchesSubset(value, schema: schema) else { return false }
            return !strict || (try? JSONSchemaValidator.validateInstance(value, against: schema)) != nil
        }
    }

    private static func matchesSubset(_ value: JSONValue, schema: JSONValue) -> Bool {
        guard case .object(let object) = schema else { return true }
        guard matchesDeclaredType(value, type: object["type"]) else { return false }
        if case .array(let values)? = object["enum"], !values.contains(value) { return false }
        if case .object(let fields) = value {
            if case .array(let required)? = object["required"], required.contains(where: {
                guard case .string(let name) = $0 else { return true }
                return fields[name] == nil
            }) { return false }
            if case .object(let properties)? = object["properties"] {
                if object["additionalProperties"] == .bool(false), !Set(fields.keys).isSubset(of: Set(properties.keys)) { return false }
                for (key, child) in fields {
                    if let childSchema = properties[key], !matchesSubset(child, schema: childSchema) { return false }
                }
            }
        }
        if case .array(let values) = value, let items = object["items"],
           values.contains(where: { !matchesSubset($0, schema: items) }) { return false }
        return true
    }

    private static func structured(_ body: ByteGrammar, family: ToolCallGrammar?) -> ByteGrammar {
        guard family == .harmony else { return body }
        return .sequence([.literal("<|start|>assistant<|channel|>final<|message|>"), body, .literal("<|return|>")])
    }

    private static func canonicalToolObject(_ value: JSONValue) -> JSONValue {
        guard case .object(let object) = value else {
            return .object(["type": .string("object"), "properties": .object([:])])
        }
        var result: [String: JSONValue] = ["type": .string("object"), "properties": .object(objectProperties(object))]
        for key in ["required", "additionalProperties"] { result[key] = object[key] }
        return .object(result)
    }

    private static func objectProperties(_ object: [String: JSONValue]) -> [String: JSONValue] {
        var properties: [String: JSONValue]
        if case .object(let declared)? = object["properties"] { properties = declared } else { properties = [:] }
        if case .array(let required)? = object["required"] {
            for value in required {
                if case .string(let name) = value, properties[name] == nil {
                    properties[name] = .object([:])
                }
            }
        }
        return properties
    }

    private static func validateRequiredProperties(_ value: JSONValue) throws {
        guard case .object(let object) = value else { return }
        if object["enum"] != nil, enumCandidates(object).isEmpty {
            throw unsupportedGrammar("Output enum has no values matching its declared type")
        }
        let properties: [String: JSONValue]
        if case .object(let declared)? = object["properties"] { properties = declared } else { properties = [:] }
        if let requiredValue = object["required"] {
            guard case .array(let required) = requiredValue else {
                throw unsupportedGrammar("Required output properties must be an array")
            }
            for key in required {
                guard case .string(let name) = key else {
                    throw unsupportedGrammar("Required output property names must be strings")
                }
                if properties[name] == nil, object["additionalProperties"] == .bool(false) {
                    throw unsupportedGrammar("Required property is forbidden by additionalProperties")
                }
            }
        }
        for child in properties.values { try validateRequiredProperties(child) }
        if let items = object["items"] { try validateRequiredProperties(items) }
    }

    private static func validateTaggedSchema(_ value: JSONValue) throws {
        switch value {
        case .object(let object):
            if object["properties"] != nil || object["required"] != nil {
                for key in objectProperties(object).keys {
                    guard (1...128).contains(key.utf8.count), key.utf8.allSatisfy({
                        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
                    }) else { throw unsupportedGrammar("Tagged tool grammar requires safe parameter names") }
                }
            }
            if case .array(let values)? = object["enum"] {
                for value in values {
                    if case .object(let fields) = value {
                        try validateTaggedSchema(.object(["properties": .object(fields.mapValues { literalSchema($0) })]))
                    }
                }
            }
            for child in object.values { try validateTaggedSchema(child) }
        case .array(let values): for child in values { try validateTaggedSchema(child) }
        case .string(let text):
            guard !text.contains("<") else { throw unsupportedGrammar("Tagged tool schema contains a reserved delimiter") }
        default: break
        }
    }

    private static func rawStringGrammar(_ property: JSONValue, multiline: Bool = false) -> ByteGrammar {
        if case .object(let details) = property, details["enum"] != nil {
            return .choice(enumCandidates(details).compactMap { if case .string(let text) = $0 { return .literal(text) }; return nil })
        }
        return multiline ? rawMultilineText : rawText
    }

    /// Whether every argument of a canonical tool object can be written as a
    /// function-XML `<parameter=KEY>`: a key the parser admits
    /// (`[A-Za-z0-9_-]{1,128}`) and no raw enum string holding `<` or a CR
    /// (see `rawMultilineText`). Anything
    /// else keeps the JSON envelope, which the guaranteed parser also reads.
    private static func functionXMLExpresses(_ parameters: JSONValue) -> Bool {
        guard case .object(let object) = parameters else { return false }
        guard case .object(let properties)? = object["properties"] else { return true }
        return properties.allSatisfy { key, property in
            guard (1...128).contains(key.utf8.count), key.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
            }) else { return false }
            guard case .object(let details) = property, details["type"] == .string("string"),
                  details["enum"] != nil else { return true }
            return enumCandidates(details).allSatisfy {
                if case .string(let text) = $0 { return !text.contains("<") && !text.unicodeScalars.contains("\r") }
                return true
            }
        }
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
    /// Function-XML string values: like `rawText` plus tab, newline and
    /// well-formed multi-byte UTF-8, since the value has no escape syntax.
    /// No CR: the parser drops one trailing line break as a Character, and a
    /// CR before the closing newline would merge with it.
    private static let rawMultilineText: ByteGrammar = {
        let tail = ByteGrammar.bytes(Set(UInt8(0x80)...UInt8(0xBF)))
        func range(_ low: UInt8, _ high: UInt8) -> ByteGrammar { .bytes(Set(low...high)) }
        return .zeroOrMore(.choice([
            .bytes(Set(UInt8(32)...UInt8(126)).subtracting([60]).union([9, 10])),
            .sequence([range(0xC2, 0xDF), tail]),
            .sequence([range(0xE0, 0xE0), range(0xA0, 0xBF), tail]),
            .sequence([.bytes(Set(UInt8(0xE1)...UInt8(0xEC)).union([0xEE, 0xEF])), tail, tail]),
            .sequence([range(0xED, 0xED), range(0x80, 0x9F), tail]),
            .sequence([range(0xF0, 0xF0), range(0x90, 0xBF), tail, tail]),
            .sequence([range(0xF1, 0xF3), tail, tail, tail]),
            .sequence([range(0xF4, 0xF4), range(0x80, 0x8F), tail, tail]),
        ]))
    }()
    private static func quoted(_ value: String) -> String { (try? JSONValue.string(value).deterministicJSONString()) ?? "\"\"" }

    private static func schema(_ value: JSONValue, depth: Int, gemma: Bool) -> ByteGrammar {
        guard depth < 8, case .object(let object) = value else { return generic(depth: 1, gemma: gemma) }
        let supported: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "description", "title", "$schema"]
        guard Set(object.keys).isSubset(of: supported) else { return generic(depth: 1, gemma: gemma) }
        if case .array? = object["enum"] {
            return .choice(enumCandidates(object).map { literal($0, gemma: gemma) })
        }
        switch object["type"] {
        case .string("object")?:
            guard object["properties"] != nil || object["required"] != nil
                    || object["additionalProperties"] == .bool(false) else { return genericObject(depth: 1, gemma: gemma) }
            let properties = objectProperties(object)
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
        // Unknown keys cannot be tracked for uniqueness by this bounded
        // regular fallback. At most one entry keeps strict JSON parsing safe.
        return .sequence([.literal("{"), .optional(entry), .literal("}")])
    }
    private static func generic(depth: Int, gemma: Bool = false) -> ByteGrammar {
        var choices: [ByteGrammar] = [gemma ? .sequence([.literal("<|\"|>"), rawText, .literal("<|\"|>")]) : string, number, .literal("true"), .literal("false"), .literal("null")]
        if depth > 0 { choices += [genericObject(depth: depth, gemma: gemma), array(generic(depth: depth - 1, gemma: gemma))] }
        return .choice(choices)
    }
}
