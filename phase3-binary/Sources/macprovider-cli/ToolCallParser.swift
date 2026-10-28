import Foundation
import MacProviderCore

enum ToolCallParser {
    static let SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP = 1_048_576
    static let SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP = 2_097_152
    static let SPEC018_ARGUMENTS_MAX_JSON_DEPTH = 32

    /// Parsed auto-mode tool output. `leadingContent` is the prose before the
    /// first call (SPEC-018 §3.1, kept as assistant content).
    struct ParsedToolCalls {
        let cleanedContent: String?
        let toolCalls: [ToolCall]
        let leadingContent: String?
    }

    /// Family-selected parse, for callers without a loaded template.
    static func parseToolCalls(
        rawOutput: String,
        modelID: String,
        allowedFunctionNames: Set<String>? = nil,
        schemas: [String: JSONValue]? = nil
    ) -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        let parsed = parseToolCalls(
            rawOutput: rawOutput,
            grammar: ToolCallGrammar.family(modelID: modelID),
            modelID: modelID,
            allowedFunctionNames: allowedFunctionNames,
            schemas: schemas
        )
        return (parsed.cleanedContent, parsed.toolCalls)
    }

    /// SPEC-018 §3.1: one parser per catalog grammar, selected by the loaded
    /// chat template's grammar (`ToolCallGrammar`), never by model-ID text.
    /// The calls are de-duplicated and capped per reply (`uniqueCappedCalls`).
    static func parseToolCalls(
        rawOutput: String,
        grammar: ToolCallGrammar?,
        modelID: String,
        allowedFunctionNames: Set<String>? = nil,
        schemas: [String: JSONValue]? = nil
    ) -> ParsedToolCalls {
        let parsed = parseGrammarToolCalls(
            rawOutput: rawOutput, grammar: grammar, modelID: modelID,
            allowedFunctionNames: allowedFunctionNames, schemas: schemas
        )
        return ParsedToolCalls(
            cleanedContent: parsed.cleanedContent,
            toolCalls: uniqueCappedCalls(parsed.toolCalls),
            leadingContent: parsed.leadingContent
        )
    }

    /// SPEC-018 §3.1 (v0.3.2) per-reply call set: a call with the same name
    /// and the same canonical arguments as an earlier call in the same reply
    /// is dropped, and at most `ToolSelectionPolicy.maxCalls` (128, the §3.11
    /// per-reply bound) calls are kept, in generated order. Kept calls are
    /// unchanged; no text is rewritten or added. Auto mode only: guaranteed
    /// selection (`parseGuaranteedToolCalls`) validates every generated call
    /// against the requested cardinality (§3.11), so nothing is dropped there.
    static func uniqueCappedCalls(_ calls: [ToolCall]) -> [ToolCall] {
        var seen = Set<Data>()
        var kept: [ToolCall] = []
        for call in calls where kept.count < ToolSelectionPolicy.maxCalls {
            // Byte keys, never Swift `String` equality (which treats canonically
            // equivalent Unicode as equal). Key order is normalized only when
            // the arguments hold no number: the parser reads numbers as
            // `Double`, so two different literals could share a canonical form;
            // with numbers the raw bytes must match. Function names are
            // `[A-Za-z0-9_-]`, so the NUL separator cannot occur in one.
            var key = Data(call.functionName.utf8)
            if let parsed = try? StrictJSONParser.parse(call.arguments, maxDepth: 128), !containsNumber(parsed),
               let canonical = try? parsed.deterministicJSONString() {
                key.append(contentsOf: [0, 1])
                key.append(contentsOf: canonical.utf8)
            } else {
                key.append(contentsOf: [0, 2])
                key.append(contentsOf: call.arguments.utf8)
            }
            guard seen.insert(key).inserted else { continue }
            kept.append(call)
        }
        return kept
    }

    private static func containsNumber(_ value: JSONValue) -> Bool {
        switch value {
        case .int, .double: return true
        case .object(let object): return object.values.contains(where: containsNumber)
        case .array(let array): return array.contains(where: containsNumber)
        case .string, .bool, .null: return false
        }
    }

    private static func parseGrammarToolCalls(
        rawOutput: String,
        grammar: ToolCallGrammar?,
        modelID: String,
        allowedFunctionNames: Set<String>?,
        schemas: [String: JSONValue]?
    ) -> ParsedToolCalls {
        let none = ParsedToolCalls(cleanedContent: nilIfBlank(rawOutput), toolCalls: [], leadingContent: nil)
        let result: (cleanedContent: String?, toolCalls: [ToolCall])
        switch grammar {
        case .qwen?:
            if let bare = parseQwenBareCalls(rawOutput, allowedFunctionNames: allowedFunctionNames) {
                return ParsedToolCalls(cleanedContent: nil, toolCalls: bare, leadingContent: nil)
            }
            result = parseQwenToolCalls(rawOutput: rawOutput, modelID: modelID, allowedFunctionNames: allowedFunctionNames, schemas: schemas)
        case .glm?, .gemma4?, .llama3?, .dsml?, .lfm2?:
            do {
                let calls: [ToolCall]
                switch grammar {
                case .glm?: calls = try parseTaggedCalls(rawOutput, start: "<tool_call>", end: "</tool_call>") { try glmCall($0, schemas: schemas) }
                case .dsml?: calls = try parseDSMLCalls(rawOutput, schemas: schemas)
                case .lfm2?: calls = try LFMToolCallParser.parse(rawOutput)
                case .gemma4?: calls = try parseTaggedCalls(rawOutput, start: "<|tool_call>", end: "<tool_call|>") { try GemmaToolCallBridge.call($0, schemas: schemas) }
                default: calls = try parseLlama3Calls(rawOutput)
                }
                guard !calls.isEmpty else { return none }
                if let allowedFunctionNames, calls.contains(where: { !allowedFunctionNames.contains($0.functionName) }) {
                    fputs("warning: tool-call output contains undeclared function for \(modelID)\n", stderr)
                    return none
                }
                try enforceArgumentCaps(calls)
                result = (nil, calls)
            } catch {
                fputs("warning: malformed tool-call output for \(modelID): \(error)\n", stderr)
                return none
            }
        case .harmony?, nil:
            return none
        }
        guard !result.toolCalls.isEmpty else { return none }
        return ParsedToolCalls(
            cleanedContent: result.cleanedContent,
            toolCalls: result.toolCalls,
            leadingContent: leadingContent(rawOutput, grammar: grammar)
        )
    }

    /// Start markers of a call in each grammar, earliest first wins.
    static func callStartMarkers(_ grammar: ToolCallGrammar?) -> [String] {
        switch grammar {
        case .qwen?: return ["<tool_call>", "<function="]
        case .glm?: return ["<tool_call>"]
        case .gemma4?: return ["<|tool_call>"]
        case .llama3?: return ["<|python_tag|>", "{"]
        case .dsml?: return [DeepseekV4Encoding.toolCallsStart]
        case .lfm2?: return [LFMToolCallParser.startMarker]
        case .harmony?, nil: return []
        }
    }

    private static func leadingContent(_ rawOutput: String, grammar: ToolCallGrammar?) -> String? {
        var first = rawOutput.endIndex
        if grammar == .llama3, let start = llama3CallStart(in: rawOutput) {
            first = start
        } else {
            for marker in callStartMarkers(grammar) where marker != "{" {
                if let range = rawOutput.range(of: marker), range.lowerBound < first {
                    first = range.lowerBound
                }
            }
        }
        return nilIfBlank(String(rawOutput[..<first]))
    }

    /// Byte caps only: the per-reply call count is capped by
    /// `uniqueCappedCalls` after duplicates are dropped.
    private static func enforceArgumentCaps(_ calls: [ToolCall]) throws {
        var total = 0
        for call in calls {
            let bytes = call.arguments.utf8.count
            guard bytes <= SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else { throw ParseError.byteCapExceeded }
            total += bytes
            guard total <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else { throw ParseError.responseByteCapExceeded }
        }
    }

    /// Every `start…end` envelope becomes one call; prose between or after
    /// envelopes is dropped (SPEC-018 §2.4). The final envelope may omit `end`
    /// when the output ends there (the model's end-of-turn token replaced
    /// it), but its body must still parse completely.
    private static func parseTaggedCalls(
        _ rawOutput: String,
        start: String,
        end: String,
        body: (String) throws -> ToolCall
    ) throws -> [ToolCall] {
        var calls: [ToolCall] = []
        var searchFrom = rawOutput.startIndex
        while let open = rawOutput.range(of: start, range: searchFrom..<rawOutput.endIndex) {
            let cursor = open.lowerBound
            let bodyStart = rawOutput.index(cursor, offsetBy: start.count)
            let close = rawOutput.range(of: end, range: bodyStart..<rawOutput.endIndex)
            let bodyEnd = close?.lowerBound ?? rawOutput.endIndex
            let text = String(rawOutput[bodyStart..<bodyEnd])
            if close == nil, text.contains(start) { throw ParseError.missingEndDelimiter }
            calls.append(try body(text))
            guard let close else { break }
            searchFrom = close.upperBound
        }
        return calls
    }

    /// GLM `NAME<arg_key>K</arg_key><arg_value>V</arg_value>…`. The template
    /// writes string values raw and every other value as JSON, so a value is
    /// typed by its declared schema: `string` stays literal text, a declared
    /// non-string must be strict JSON of that type, and an undeclared one is
    /// JSON when it parses, else text.
    static func glmCall(_ body: String, schemas: [String: JSONValue]?) throws -> ToolCall {
        let nameEnd = body.range(of: "<arg_key>")?.lowerBound ?? body.endIndex
        let name = body[..<nameEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidToolFunctionName(name) else { throw ParseError.invalidShape }
        let schema = schemas?[name]
        var arguments: [String: JSONValue] = [:]
        var cursor = nameEnd
        while cursor < body.endIndex {
            let rest = body[cursor...]
            let trimmed = rest.drop(while: { $0.isWhitespace })
            if trimmed.isEmpty { break }
            guard trimmed.hasPrefix("<arg_key>") else { throw ParseError.invalidShape }
            let keyStart = trimmed.index(trimmed.startIndex, offsetBy: "<arg_key>".count)
            guard let keyClose = body.range(of: "</arg_key>", range: keyStart..<body.endIndex) else { throw ParseError.invalidShape }
            let key = body[keyStart..<keyClose.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidToolParameterName(key), arguments[key] == nil else { throw ParseError.invalidArguments }
            let afterKey = body[keyClose.upperBound...].drop(while: { $0.isWhitespace })
            guard afterKey.hasPrefix("<arg_value>") else { throw ParseError.invalidShape }
            let valueStart = afterKey.index(afterKey.startIndex, offsetBy: "<arg_value>".count)
            guard let valueClose = body.range(of: "</arg_value>", range: valueStart..<body.endIndex) else { throw ParseError.invalidShape }
            let raw = String(body[valueStart..<valueClose.lowerBound])
            for marker in ["<arg_key>", "<arg_value>", "<tool_call>", "</tool_call>"] where raw.contains(marker) {
                throw ParseError.invalidArguments
            }
            arguments[key] = try glmValue(raw, type: explicitParameterType(key, schema: schema))
            cursor = valueClose.upperBound
        }
        let value = JSONValue.object(arguments)
        guard ToolSelectionPolicy.supportsNumericDomain(value) else { throw ParseError.invalidArguments }
        let json = try value.deterministicJSONString()
        try validateNoDuplicateJSONKeys(json)
        return ToolCall(id: newCallID(), functionName: name, arguments: json)
    }

    private static func glmValue(_ raw: String, type: String?) throws -> JSONValue {
        if type == "string" { return .string(raw) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = try? StrictJSONParser.parse(trimmed, maxDepth: SPEC018_ARGUMENTS_MAX_JSON_DEPTH) else {
            guard type == nil else { throw ParseError.invalidArguments }
            return .string(raw)
        }
        guard let type else { return parsed }
        switch (type, parsed) {
        case ("number", .int), ("number", .double), ("integer", .int),
             ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null):
            return parsed
        default:
            throw ParseError.invalidArguments
        }
    }

    /// DeepSeek-V4 DSML (`parse_tool_calls`, `encoding_dsv4.py:646-700`).
    /// Each `<｜DSML｜tool_calls>` block holds one or more invokes, so one
    /// block can carry parallel calls; the last block may omit its close when
    /// the output ends there (the end-of-sentence token replaced it), but its
    /// invokes must be complete. Whitespace between the markup is free, where
    /// the reference demands its exact newlines.
    static func parseDSMLCalls(_ rawOutput: String, schemas: [String: JSONValue]?) throws -> [ToolCall] {
        let start = DeepseekV4Encoding.toolCallsStart
        let end = DeepseekV4Encoding.toolCallsEnd
        var calls: [ToolCall] = []
        var searchFrom = rawOutput.startIndex
        while let open = rawOutput.range(of: start, range: searchFrom..<rawOutput.endIndex) {
            let close = rawOutput.range(of: end, range: open.upperBound..<rawOutput.endIndex)
            let body = rawOutput[open.upperBound..<(close?.lowerBound ?? rawOutput.endIndex)]
            if close == nil, body.contains(start) { throw ParseError.missingEndDelimiter }
            calls += try dsmlInvokes(body, schemas: schemas)
            guard let close else { break }
            searchFrom = close.upperBound
        }
        return calls
    }

    private static let dsmlInvokeOpen = "<\(DeepseekV4Encoding.dsmlToken)invoke"
    private static let dsmlInvokeClose = "</\(DeepseekV4Encoding.dsmlToken)invoke>"
    private static let dsmlParameterOpen = "<\(DeepseekV4Encoding.dsmlToken)parameter"
    private static let dsmlParameterClose = "</\(DeepseekV4Encoding.dsmlToken)parameter>"

    private static func dsmlInvokes(_ block: Substring, schemas: [String: JSONValue]?) throws -> [ToolCall] {
        var calls: [ToolCall] = []
        var rest = block
        while true {
            rest = rest.drop(while: \.isWhitespace)
            if rest.isEmpty { break }
            guard rest.hasPrefix(dsmlInvokeOpen) else { throw ParseError.invalidShape }
            let header = try dsmlAttributes(rest.dropFirst(dsmlInvokeOpen.count), names: ["name"])
            let name = header.values[0]
            guard isValidToolFunctionName(name) else { throw ParseError.invalidShape }
            let schema = schemas?[name]
            rest = header.rest
            var arguments: [String: JSONValue] = [:]
            while true {
                rest = rest.drop(while: \.isWhitespace)
                if rest.hasPrefix(dsmlInvokeClose) {
                    rest = rest.dropFirst(dsmlInvokeClose.count)
                    break
                }
                guard !rest.isEmpty else { throw ParseError.missingEndDelimiter }
                guard rest.hasPrefix(dsmlParameterOpen) else { throw ParseError.invalidShape }
                let parameter = try dsmlAttributes(rest.dropFirst(dsmlParameterOpen.count), names: ["name", "string"])
                let key = parameter.values[0]
                guard isValidToolParameterName(key), arguments[key] == nil,
                      ["true", "false"].contains(parameter.values[1]) else { throw ParseError.invalidArguments }
                guard let close = parameter.rest.range(of: dsmlParameterClose) else { throw ParseError.missingEndDelimiter }
                let raw = String(parameter.rest[..<close.lowerBound])
                arguments[key] = try dsmlValue(raw, isString: parameter.values[1] == "true", type: explicitParameterType(key, schema: schema))
                rest = parameter.rest[close.upperBound...]
            }
            let value = JSONValue.object(arguments)
            guard ToolSelectionPolicy.supportsNumericDomain(value) else { throw ParseError.invalidArguments }
            let json = try value.deterministicJSONString()
            try validateNoDuplicateJSONKeys(json)
            calls.append(ToolCall(id: newCallID(), functionName: name, arguments: json))
        }
        return calls
    }

    /// ` name="…" string="…">`: the named attributes in order, then `>`.
    private static func dsmlAttributes(_ text: Substring, names: [String]) throws -> (values: [String], rest: Substring) {
        var rest = text
        var values: [String] = []
        for name in names {
            let trimmed = rest.drop(while: \.isWhitespace)
            // Each attribute follows whitespace.
            guard trimmed.startIndex > rest.startIndex, trimmed.hasPrefix(name + "=\"") else {
                throw ParseError.invalidShape
            }
            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: name.count + 2)
            guard let quote = trimmed[valueStart...].firstIndex(of: "\"") else { throw ParseError.invalidShape }
            values.append(String(trimmed[valueStart..<quote]))
            rest = trimmed[trimmed.index(after: quote)...]
        }
        guard rest.hasPrefix(">") else { throw ParseError.invalidShape }
        return (values, rest.dropFirst())
    }

    /// Declared non-string types must parse strictly regardless of the string
    /// flag. Otherwise `string="true"` preserves literal text, while
    /// `string="false"` values are typed as GLM values are.
    private static func dsmlValue(_ raw: String, isString: Bool, type: String?) throws -> JSONValue {
        if isString {
            if let type, type != "string" { return try glmValue(raw, type: type) }
            return .string(raw)
        }
        return try glmValue(raw, type: type)
    }

    /// Llama 3.x: the template asks for bare JSON `{"name", "parameters"}`;
    /// the model may prefix `<|python_tag|>` and end with `<|eom_id|>`.
    /// One or more call objects (`;`-separated) must end the output.
    private static func parseLlama3Calls(_ rawOutput: String) throws -> [ToolCall] {
        guard let start = llama3CallStart(in: rawOutput) else { return [] }
        var text = rawOutput[start...]
        if text.hasPrefix("<|python_tag|>") {
            text = text.dropFirst("<|python_tag|>".count)
            // Llama 3.3 builtin-style `name(key="value")` after the tag.
            let body = text.drop(while: { $0.isWhitespace })
            if !body.hasPrefix("{") {
                let end = ["<|eom_id|>", "<|eot_id|>"].compactMap { body.range(of: $0)?.lowerBound }.min() ?? body.endIndex
                guard body[end...].dropFirst(body[end...].hasPrefix("<|") ? 10 : 0).allSatisfy(\.isWhitespace) else {
                    throw ParseError.invalidShape
                }
                return [try parsePythonStyleCall(String(body[..<end]))]
            }
        }
        var calls: [ToolCall] = []
        while true {
            text = text.drop(while: { $0.isWhitespace || $0 == ";" || $0 == "," })
            for terminator in ["<|eom_id|>", "<|eot_id|>"] where text.hasPrefix(terminator) {
                text = text.dropFirst(terminator.count)
            }
            text = text.drop(while: { $0.isWhitespace })
            if text.isEmpty { break }
            guard let object = firstCompleteJSONObject(in: String(text)) else {
                throw calls.isEmpty ? ParseError.invalidShape : ParseError.missingEndDelimiter
            }
            calls.append(try parseJSONCall(object, argumentKey: "parameters"))
            text = text.dropFirst(object.count)
        }
        return calls
    }

    /// Where a Llama call starts: `<|python_tag|>`, or the first `{"` that
    /// opens a complete, bounded JSON object with a string `name` and an
    /// object `parameters`/`arguments` (in any member order). Only `{"`
    /// openings are scanned, at most `llama3MaxCallCandidates` of them, and
    /// only within the response byte cap, so detection stays linear.
    static func llama3CallStart(in rawOutput: String) -> String.Index? {
        if let tag = rawOutput.range(of: "<|python_tag|>") { return tag.lowerBound }
        guard rawOutput.utf8.count <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else { return nil }
        var searchFrom = rawOutput.startIndex
        var candidates = 0
        while candidates < llama3MaxCallCandidates,
              let brace = rawOutput.range(of: "{", range: searchFrom..<rawOutput.endIndex)?.lowerBound {
            searchFrom = rawOutput.index(after: brace)
            // A JSON object opening (`{` then a key); member order is free.
            guard rawOutput[searchFrom...].drop(while: { $0.isWhitespace }).hasPrefix("\"") else { continue }
            candidates += 1
            guard let object = firstCompleteJSONObject(in: String(rawOutput[brace...])),
                  case .object(let parsed)? = try? StrictJSONParser.parse(object, maxDepth: SPEC018_ARGUMENTS_MAX_JSON_DEPTH),
                  case .string? = parsed["name"] else { continue }
            if case .object? = parsed["parameters"] { return brace }
            if case .object? = parsed["arguments"] { return brace }
        }
        return nil
    }

    static let llama3MaxCallCandidates = 16

    private static func newCallID() -> String {
        "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The Qwen `<tool_call>` grammar (JSON or function-XML body), including
    /// the Qwen3-Coder unclosed-envelope recovery.
    private static func parseQwenToolCalls(
        rawOutput: String,
        modelID: String,
        allowedFunctionNames: Set<String>?,
        schemas: [String: JSONValue]?
    ) -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        let format = ToolCallFormat.qwen25

        do {
            let parsed = try parseDelimited(rawOutput, format: format, schemas: schemas)
            if !parsed.toolCalls.isEmpty {
                if let allowedFunctionNames,
                   parsed.toolCalls.contains(where: { !allowedFunctionNames.contains($0.functionName) })
                {
                    fputs("warning: tool-call output contains undeclared function for \(modelID)\n", stderr)
                    return (nilIfBlank(rawOutput), [])
                }
                return parsed
            }
            if let recovered = recoverQwenUnclosedToolCall(
                rawOutput,
                format: format,
                modelID: modelID,
                allowedFunctionNames: allowedFunctionNames,
                schemas: schemas
            ) {
                return recovered
            }
            return parsed
        } catch {
            fputs("warning: malformed tool-call output for \(modelID): \(error)\n", stderr)
            // Qwen3-Coder often emits a complete inner call and then stops before
            // </tool_call> (or opens a second <tool_call>). parseDelimited throws
            // missingEndDelimiter and used to leak the markup as assistant text, so
            // OpenAI clients never ran the tool. Recover JSON-in-<tool_call> first
            // (SPEC-018 §3.1 order), then inner function-XML.
            if let recovered = recoverQwenUnclosedToolCall(
                rawOutput,
                format: format,
                modelID: modelID,
                allowedFunctionNames: allowedFunctionNames,
                schemas: schemas
            ) {
                return recovered
            }
            return (nilIfBlank(rawOutput), [])
        }
    }

    /// SPEC-018 §3.1 Qwen bare envelope body: Qwen2.5-Coder answers with the
    /// template's `{"name", "arguments"}` body but without the `<tool_call>`
    /// tags, sometimes inside the `<tools>` wrapper its system prompt shows
    /// (one wrapper around all calls, or one wrapper per call).
    /// Accepted only when the whole output is one or more such objects (no
    /// prose), each with exactly those two keys, an object `arguments` and a
    /// declared name. A wrapped output is a sequence of closed, non-empty
    /// `<tools>` groups. Anything else returns nil and the tagged grammar runs.
    static func parseQwenBareCalls(_ rawOutput: String, allowedFunctionNames: Set<String>?) -> [ToolCall]? {
        guard let allowedFunctionNames, !allowedFunctionNames.isEmpty,
              rawOutput.utf8.count <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else { return nil }
        var text = Substring(rawOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        let wrapped = text.hasPrefix(qwenBareWrapperOpen)
        var calls: [ToolCall] = []
        func nextCall() -> Bool {
            text = text.drop(while: { $0.isWhitespace })
            guard let object = firstCompleteJSONObject(in: String(text)),
                  // Shape check only; `parseJSONCall` applies the tagged path's
                  // argument validator (and its depth rule) to the same object.
                  case .object(let parsed)? = try? StrictJSONParser.parse(object, maxDepth: 128),
                  Set(parsed.keys) == ["name", "arguments"],
                  case .string(let name)? = parsed["name"], allowedFunctionNames.contains(name),
                  case .object? = parsed["arguments"],
                  let call = try? parseJSONCall(object, argumentKey: "arguments") else { return false }
            calls.append(call)
            text = text.dropFirst(object.count)
            return true
        }
        while true {
            text = text.drop(while: { $0.isWhitespace })
            if text.isEmpty { break }
            guard wrapped else {
                guard nextCall() else { return nil }
                continue
            }
            guard text.hasPrefix(qwenBareWrapperOpen) else { return nil }
            text = text.dropFirst(qwenBareWrapperOpen.count)
            var groupCalls = 0
            while true {
                text = text.drop(while: { $0.isWhitespace })
                if text.hasPrefix(qwenBareWrapperClose) {
                    guard groupCalls > 0 else { return nil }
                    text = text.dropFirst(qwenBareWrapperClose.count)
                    break
                }
                guard nextCall() else { return nil }
                groupCalls += 1
            }
        }
        guard !calls.isEmpty, (try? enforceArgumentCaps(calls)) != nil else { return nil }
        return calls
    }

    static let qwenBareWrapperOpen = "<tools>"
    static let qwenBareWrapperClose = "</tools>"

    /// Guaranteed native families share main's typed parser, without the
    /// auto-mode duplicate/call-cap projection. The caller validates the whole
    /// generated envelope first; output policy still validates every call.
    static func parseGuaranteedToolCalls(_ rawOutput: String, grammar: ToolCallGrammar?, modelID: String,
                                         schemas: [String: JSONValue]) throws -> [ToolCall] {
        if grammar == .qwen { return try parseGuaranteedToolCalls(rawOutput, schemas: schemas) }
        guard rawOutput.utf8.count <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
            throw ToolSelectionPolicy.outputError("Tool output exceeded byte limit")
        }
        let parsed = parseGrammarToolCalls(rawOutput: rawOutput, grammar: grammar, modelID: modelID,
                                          allowedFunctionNames: Set(schemas.keys), schemas: schemas)
        guard !parsed.toolCalls.isEmpty, parsed.toolCalls.count <= ToolSelectionPolicy.maxCalls else {
            throw ToolSelectionPolicy.outputError("Malformed native tool output")
        }
        return parsed.toolCalls
    }

    /// Guaranteed modes deliberately exclude the auto-mode recovery paths. Every
    /// byte outside a closed `<tool_call>` envelope must be blank. An envelope
    /// body is either strict JSON or one complete function-XML call (the format
    /// the supported Qwen3.6 chat template instructs), typed by `schemas`.
    static func parseGuaranteedToolCalls(_ rawOutput: String, schemas: [String: JSONValue] = [:]) throws -> [ToolCall] {
        guard rawOutput.utf8.count <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
            throw ToolSelectionPolicy.outputError("Tool output exceeded byte limit")
        }
        var remainder = rawOutput[...]
        var calls: [ToolCall] = []
        while !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remainder = remainder.drop(while: { $0.isWhitespace })
            guard remainder.hasPrefix("<tool_call>") else {
                throw ToolSelectionPolicy.outputError("Tool output requires complete closed JSON envelopes")
            }
            let bodyAndRest = remainder.dropFirst("<tool_call>".count).drop(while: { $0.isWhitespace })
            if bodyAndRest.hasPrefix("<function=") {
                let call = try guaranteedFunctionXMLCall(bodyAndRest, schemas: schemas)
                let tail = call.rest.drop(while: { $0.isWhitespace })
                guard tail.hasPrefix("</tool_call>") else {
                    throw ToolSelectionPolicy.outputError("Tool output requires complete closed envelopes")
                }
                calls.append(ToolCall(
                    id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                    functionName: call.name,
                    arguments: try JSONValue.object(call.arguments).deterministicJSONString()
                ))
                guard calls.count <= ToolSelectionPolicy.maxCalls else {
                    throw ToolSelectionPolicy.outputError("Too many tool calls")
                }
                remainder = tail.dropFirst("</tool_call>".count)
                continue
            }
            // Locate the complete JSON value before interpreting delimiters:
            // marker text inside an argument string remains ordinary data.
            guard let body = firstCompleteJSONObject(in: String(bodyAndRest)) else {
                throw ToolSelectionPolicy.outputError("Tool output requires a complete JSON object")
            }
            let tail = bodyAndRest.dropFirst(body.count).drop(while: { $0.isWhitespace })
            guard tail.hasPrefix("</tool_call>") else {
                throw ToolSelectionPolicy.outputError("Tool output requires complete closed JSON envelopes")
            }
            do {
                guard case .object(let object) = try StrictJSONParser.parse(body, maxDepth: JSONSchemaValidator.maxDepth + 1),
                      Set(object.keys) == Set(["name", "arguments"]),
                      case .string(let name)? = object["name"], !name.isEmpty,
                      case .object(let arguments)? = object["arguments"],
                      ToolSelectionPolicy.supportsNumericDomain(.object(arguments)) else {
                    throw ToolSelectionPolicy.outputError("Malformed tool JSON envelope")
                }
                calls.append(ToolCall(
                    id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                    functionName: name,
                    arguments: try JSONValue.object(arguments).deterministicJSONString()
                ))
            } catch {
                throw ToolSelectionPolicy.outputError("Malformed tool JSON envelope")
            }
            guard calls.count <= ToolSelectionPolicy.maxCalls else {
                throw ToolSelectionPolicy.outputError("Too many tool calls")
            }
            remainder = tail.dropFirst("</tool_call>".count)
        }
        return calls
    }

    /// One complete `<function=NAME>(<parameter=KEY>VALUE</parameter>)*</function>`
    /// call, rendered as the Qwen3.6 chat template renders tool calls: one
    /// newline around each value, a `string`-typed parameter's value is its
    /// literal text, and any other parameter's value is strict JSON. NAME and
    /// every KEY must be declared; nothing is coerced, repaired or defaulted,
    /// and a value holding call markup is treated as malformed, not as data.
    private static func guaranteedFunctionXMLCall(
        _ text: Substring,
        schemas: [String: JSONValue]
    ) throws -> (name: String, arguments: [String: JSONValue], rest: Substring) {
        let malformed = ToolSelectionPolicy.outputError("Malformed tool function envelope")
        var cursor = text.dropFirst("<function=".count)
        guard let nameEnd = cursor.firstIndex(of: ">") else { throw malformed }
        let name = String(cursor[..<nameEnd])
        guard isValidToolFunctionName(name), case .object(let schema)? = schemas[name] else { throw malformed }
        var properties: [String: JSONValue] = [:]
        if let declared = schema["properties"] {
            guard case .object(let object) = declared else { throw malformed }
            properties = object
        }
        cursor = cursor[cursor.index(after: nameEnd)...]
        // SPEC-018 §3.11 v0.3.1: a non-strict schema may require a key it does
        // not declare in `properties`; such a key is read untyped.
        let strict = ToolSelectionPolicy.isStrictSubset(.object(schema))
        var arguments: [String: JSONValue] = [:]
        while true {
            cursor = cursor.drop(while: { $0.isWhitespace })
            if cursor.hasPrefix("</function>") {
                guard ToolSelectionPolicy.supportsNumericDomain(.object(arguments)) else { throw malformed }
                return (name, arguments, cursor.dropFirst("</function>".count))
            }
            guard cursor.hasPrefix("<parameter=") else { throw malformed }
            cursor = cursor.dropFirst("<parameter=".count)
            guard let keyEnd = cursor.firstIndex(of: ">") else { throw malformed }
            let key = String(cursor[..<keyEnd])
            guard isValidToolParameterName(key), arguments[key] == nil else { throw malformed }
            let property: [String: JSONValue]
            if case .object(let declared)? = properties[key] {
                property = declared
            } else {
                // Absent or a non-object (boolean) subschema: untyped, and only
                // where the schema is non-strict.
                guard !strict else { throw malformed }
                property = [:]
            }
            cursor = cursor[cursor.index(after: keyEnd)...]
            guard let close = cursor.range(of: "</parameter>") else { throw malformed }
            var raw = cursor[..<close.lowerBound]
            // "\r\n" is one Character, so each drop removes a whole LF or CRLF.
            if raw.hasPrefix("\n") || raw.hasPrefix("\r\n") { raw = raw.dropFirst() }
            if raw.hasSuffix("\n") || raw.hasSuffix("\r\n") { raw = raw.dropLast() }
            for marker in ["<parameter=", "<function=", "</function>", "<tool_call>", "</tool_call>"] where raw.contains(marker) {
                throw malformed
            }
            if property["type"] == .string("string") {
                arguments[key] = .string(String(raw))
            } else if case .string? = property["type"] {
                guard let value = try? StrictJSONParser.parse(String(raw), maxDepth: JSONSchemaValidator.maxDepth - 1) else {
                    throw malformed
                }
                arguments[key] = value
            } else {
                // A non-strict property without one declared type (SPEC-018
                // §3.11 v0.3.1): JSON when the value parses, else its text, as
                // the template writes non-string values as JSON.
                arguments[key] = (try? StrictJSONParser.parse(String(raw), maxDepth: JSONSchemaValidator.maxDepth - 1))
                    ?? .string(String(raw))
            }
            cursor = cursor[close.upperBound...]
        }
    }

    private static func recoverQwenUnclosedToolCall(
        _ rawOutput: String,
        format: ToolCallFormat,
        modelID: String,
        allowedFunctionNames: Set<String>?,
        schemas: [String: JSONValue]?
    ) -> (cleanedContent: String?, toolCalls: [ToolCall])? {
        if let recovered = recoverUnclosedJSONToolCall(
            rawOutput,
            format: format,
            modelID: modelID,
            allowedFunctionNames: allowedFunctionNames
        ) {
            return recovered
        }
        return recoverBareFunctionXML(
            rawOutput,
            format: format,
            modelID: modelID,
            allowedFunctionNames: allowedFunctionNames,
            schemas: schemas
        )
    }

    /// Qwen3-Coder hybrid grammar: `<tool_call>` + a complete JSON object, often
    /// without `</tool_call>`. Same missing-end recovery as function-XML.
    private static func recoverUnclosedJSONToolCall(
        _ rawOutput: String,
        format: ToolCallFormat,
        modelID: String,
        allowedFunctionNames: Set<String>?
    ) -> (cleanedContent: String?, toolCalls: [ToolCall])? {
        guard format == .qwen25, rawOutput.contains(format.startDelimiter) else {
            return nil
        }
        var searchStart = rawOutput.startIndex
        var cleaned = ""
        var calls: [ToolCall] = []
        var responseArgumentBytes = 0

        while let startRange = rawOutput.range(of: format.startDelimiter, range: searchStart..<rawOutput.endIndex) {
            cleaned += rawOutput[searchStart..<startRange.lowerBound]
            let bodyStart = startRange.upperBound
            let endRange = rawOutput.range(of: format.endDelimiter, range: bodyStart..<rawOutput.endIndex)
            let bodyLimit = endRange?.lowerBound ?? rawOutput.endIndex
            let body = String(rawOutput[bodyStart..<bodyLimit])
            guard let json = firstCompleteJSONObject(in: body),
                  let call = try? parseJSONCall(json, argumentKey: format.argumentKey)
            else {
                return nil
            }
            if let allowedFunctionNames, !allowedFunctionNames.contains(call.functionName) {
                fputs("warning: tool-call output contains undeclared function for \(modelID)\n", stderr)
                return (nilIfBlank(rawOutput), [])
            }
            let argumentBytes = call.arguments.utf8.count
            guard argumentBytes <= SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP,
                  responseArgumentBytes + argumentBytes <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP
            else {
                return nil
            }
            responseArgumentBytes += argumentBytes
            calls.append(call)
            if let jsonRange = body.range(of: json) {
                cleaned += body[jsonRange.upperBound...]
            }
            if let endRange {
                searchStart = endRange.upperBound
            } else {
                searchStart = rawOutput.endIndex
            }
        }

        guard !calls.isEmpty else {
            return nil
        }
        return (stripToolCallWrappers(nilIfBlank(cleaned)), calls)
    }

    private static func recoverBareFunctionXML(
        _ rawOutput: String,
        format: ToolCallFormat,
        modelID: String,
        allowedFunctionNames: Set<String>?,
        schemas: [String: JSONValue]?
    ) -> (cleanedContent: String?, toolCalls: [ToolCall])? {
        // Function-XML (`<function=…>`) is a Qwen-row body grammar only (SPEC-018 §3.1
        // v0.2.7). Require a closed </function> so we do not turn a truncated command
        // into a dispatchable tool call.
        guard format == .qwen25,
              rawOutput.contains("<function="),
              rawOutput.contains("</function>")
        else {
            return nil
        }
        guard let bare = try? parseBareNemotronCalls(rawOutput, schemas: schemas), !bare.toolCalls.isEmpty else {
            return nil
        }
        if let allowedFunctionNames,
           bare.toolCalls.contains(where: { !allowedFunctionNames.contains($0.functionName) })
        {
            fputs("warning: tool-call output contains undeclared function for \(modelID)\n", stderr)
            return (nilIfBlank(rawOutput), [])
        }
        return (stripToolCallWrappers(bare.cleanedContent), bare.toolCalls)
    }

    private static func stripToolCallWrappers(_ content: String?) -> String? {
        guard var text = content else {
            return nil
        }
        text = text.replacingOccurrences(of: "<tool_call>", with: "")
        text = text.replacingOccurrences(of: "</tool_call>", with: "")
        return nilIfBlank(text)
    }

    private static func parseDelimited(_ rawOutput: String, format: ToolCallFormat, schemas: [String: JSONValue]?) throws -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        var searchStart = rawOutput.startIndex
        var cleaned = ""
        var calls: [ToolCall] = []
        var responseArgumentBytes = 0

        while let startRange = rawOutput.range(of: format.startDelimiter, range: searchStart..<rawOutput.endIndex) {
            cleaned += rawOutput[searchStart..<startRange.lowerBound]
            let bodyStart = startRange.upperBound
            guard let endRange = rawOutput.range(of: format.endDelimiter, range: bodyStart..<rawOutput.endIndex) else {
                throw ParseError.missingEndDelimiter
            }
            let body = String(rawOutput[bodyStart..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let call = try parseCall(body, argumentKey: format.argumentKey, allowFunctionXML: format == .qwen25, schemas: schemas)
            let argumentBytes = call.arguments.utf8.count
            guard argumentBytes <= SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else {
                throw ParseError.byteCapExceeded
            }
            responseArgumentBytes += argumentBytes
            guard responseArgumentBytes <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                throw ParseError.responseByteCapExceeded
            }
            calls.append(call)
            searchStart = endRange.upperBound
        }

        cleaned += rawOutput[searchStart..<rawOutput.endIndex]
        guard !calls.isEmpty else {
            return (nilIfBlank(rawOutput), [])
        }
        return (nilIfBlank(cleaned), calls)
    }

    // The `<function=NAME><parameter=key>value</parameter></function>` XML grammar handled by
    // the `*Nemotron*`-named helpers below is NOT Nemotron-specific: it is the shared function-
    // XML tool-call grammar emitted by NVIDIA Nemotron AND by Qwen3-Coder. It is a recognized
    // grammar under SPEC-018 §3.1 (Qwen row body-grammar alternative). Names follow the OpenAI/
    // MCP charset (see isValidToolFunctionName / isValidToolParameterName), not Python identifiers.
    private static func parseBareNemotronCalls(_ rawOutput: String, schemas: [String: JSONValue]?) throws -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        var searchStart = rawOutput.startIndex
        var cleaned = ""
        var calls: [ToolCall] = []
        var responseArgumentBytes = 0

        while let open = rawOutput.range(of: "<function=", range: searchStart..<rawOutput.endIndex) {
            cleaned += rawOutput[searchStart..<open.lowerBound]
            let blockEnd = rawOutput.range(of: "</function>", range: open.lowerBound..<rawOutput.endIndex)?.upperBound ?? rawOutput.endIndex
            let block = String(rawOutput[open.lowerBound..<blockEnd])
            let call = try parseNemotronXMLCall(block, schemas: schemas)
            let argumentBytes = call.arguments.utf8.count
            guard argumentBytes <= SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else {
                throw ParseError.byteCapExceeded
            }
            responseArgumentBytes += argumentBytes
            guard responseArgumentBytes <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                throw ParseError.responseByteCapExceeded
            }
            calls.append(call)
            searchStart = blockEnd
        }

        cleaned += rawOutput[searchStart..<rawOutput.endIndex]
        guard !calls.isEmpty else {
            return (nilIfBlank(rawOutput), [])
        }
        return (nilIfBlank(cleaned), calls)
    }

    private static func parseCall(_ rawCall: String, argumentKey: String, allowFunctionXML: Bool, schemas: [String: JSONValue]?) throws -> ToolCall {
        let trimmed = rawCall.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return try parseJSONCall(rawCall, argumentKey: argumentKey)
        }
        if allowFunctionXML, trimmed.contains("<function=") {
            return try parseNemotronXMLCall(rawCall, schemas: schemas)
        }
        return try parsePythonStyleCall(rawCall)
    }

    /// Returns the substring covering the FIRST `<function=…>…</function>` block (through the
    /// first `</function>`, or to the end if unterminated for a streaming prefix). Name and
    /// parameter parsing MUST be scoped to this block: otherwise a `<parameter=…>` belonging to
    /// a LATER (possibly undeclared) function block could be attributed to this call, letting a
    /// declared-but-empty first function inherit an undeclared function's arguments.
    static func firstFunctionBlock(in raw: String) -> Substring {
        guard let open = raw.range(of: "<function=") else {
            return raw[raw.startIndex..<raw.startIndex]
        }
        let end = raw.range(of: "</function>", range: open.lowerBound..<raw.endIndex)?.upperBound ?? raw.endIndex
        return raw[open.lowerBound..<end]
    }

    private static func parseNemotronXMLCall(_ rawCall: String, schemas: [String: JSONValue]?) throws -> ToolCall {
        let block = String(firstFunctionBlock(in: rawCall))
        guard let functionName = nemotronFunctionName(in: block) else {
            throw ParseError.invalidShape
        }
        let arguments = try nemotronArgumentsJSONString(in: block, includeIncomplete: true, schemas: schemas)
        return ToolCall(
            id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            functionName: functionName,
            arguments: arguments
        )
    }

    static func nemotronFunctionName(in raw: String) -> String? {
        guard let open = raw.range(of: "<function=") else {
            return nil
        }
        let nameStart = open.upperBound
        guard let close = raw.range(of: ">", range: nameStart..<raw.endIndex) else {
            return nil
        }
        let name = String(raw[nameStart..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidToolFunctionName(name) else {
            return nil
        }
        return name
    }

    static func firstCompleteJSONObject(in text: String) -> String? {
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "{" else {
            return nil
        }
        return scanJSONValue(in: text, from: index, allowIncomplete: false)
    }

    static func jsonToolCallNameAndArguments(
        in jsonObject: String,
        argumentKey: String
    ) -> (name: String, arguments: String)? {
        guard let call = try? parseJSONCall(jsonObject, argumentKey: argumentKey) else {
            return nil
        }
        return (call.functionName, call.arguments)
    }

    static func jsonArgumentsPrefix(in body: String, argumentKey: String) -> String? {
        let keys = argumentKey == "arguments" ? ["arguments"] : [argumentKey, "arguments"]
        for key in keys {
            guard let keyRange = body.range(of: "\"\(key)\""),
                  let colon = body.range(of: ":", range: keyRange.upperBound..<body.endIndex)
            else {
                continue
            }
            var index = colon.upperBound
            while index < body.endIndex, body[index].isWhitespace {
                index = body.index(after: index)
            }
            guard index < body.endIndex else {
                return nil
            }
            if let complete = scanJSONValue(in: body, from: index, allowIncomplete: false) {
                return complete
            }
            return scanJSONValue(in: body, from: index, allowIncomplete: true)
        }
        return nil
    }

    private static func scanJSONValue(in text: String, from start: String.Index, allowIncomplete: Bool) -> String? {
        guard start < text.endIndex else {
            return nil
        }
        var index = start
        var depth = 0
        var inString = false
        var escaped = false
        var started = false
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                    if depth == 0 {
                        index = text.index(after: index)
                        return String(text[start..<index])
                    }
                }
                index = text.index(after: index)
                continue
            }
            switch ch {
            case "\"":
                inString = true
                started = true
            case "{", "[":
                depth += 1
                started = true
            case "}", "]":
                if depth == 0 {
                    return allowIncomplete ? String(text[start..<index]) : nil
                }
                depth -= 1
                if depth == 0 {
                    index = text.index(after: index)
                    return String(text[start..<index])
                }
            default:
                if !started, ch.isWhitespace {
                    break
                }
                started = true
                if depth == 0, !"0123456789-tfn".contains(ch) {
                    return nil
                }
            }
            index = text.index(after: index)
        }
        if allowIncomplete, started, depth > 0 || inString {
            return String(text[start..<index])
        }
        if allowIncomplete, started, depth == 0, !inString {
            return String(text[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func nemotronArgumentsJSON(in raw: String, includeIncomplete: Bool, schemas: [String: JSONValue]? = nil) -> String? {
        try? nemotronArgumentsJSONString(in: raw, includeIncomplete: includeIncomplete, schemas: schemas)
    }

    /// Final parsing and streaming/serial-stop validation share this entire path.
    private static func nemotronArgumentsJSONString(in raw: String, includeIncomplete: Bool, schemas: [String: JSONValue]?) throws -> String {
        let block = String(firstFunctionBlock(in: raw))
        let object = try nemotronParameterObject(in: block, includeIncomplete: includeIncomplete, schemas: schemas)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ParseError.invalidArguments
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let arguments = String(decoding: data, as: UTF8.self)
        guard arguments.utf8.count <= SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else {
            throw ParseError.byteCapExceeded
        }
        try validateNoDuplicateJSONKeys(arguments)
        return arguments
    }

    private static func nemotronParameterObject(in raw: String, includeIncomplete: Bool, schemas: [String: JSONValue]?) throws -> [String: Any] {
        var object: [String: Any] = [:]
        var searchStart = raw.startIndex
        let functionName = nemotronFunctionName(in: raw)
        let schema = functionName.flatMap { schemas?[$0] }

        while let paramOpen = raw.range(of: "<parameter=", range: searchStart..<raw.endIndex) {
            let nameStart = paramOpen.upperBound
            guard let nameEnd = raw.range(of: ">", range: nameStart..<raw.endIndex) else {
                throw ParseError.invalidShape
            }
            let name = String(raw[nameStart..<nameEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidToolParameterName(name) else {
                throw ParseError.invalidArguments
            }
            guard object[name] == nil else {
                throw ParseError.invalidArguments
            }

            let valueStart = nameEnd.upperBound
            let valueEnd = nemotronParameterValueEnd(in: raw, from: valueStart)
            let hasClosingTag = raw[valueStart..<raw.endIndex].contains("</parameter>")
                && raw.range(of: "</parameter>", range: valueStart..<valueEnd) != nil
            let hasSuccessor = raw.range(of: "<parameter=", range: valueStart..<valueEnd) != nil
                || raw.range(of: "</function>", range: valueStart..<valueEnd) != nil
            guard includeIncomplete || hasClosingTag || hasSuccessor else {
                break
            }

            let rawValue = String(raw[valueStart..<valueEnd])
            if let type = explicitParameterType(name, schema: schema) {
                guard raw.range(of: "</parameter>", range: valueStart..<raw.endIndex)?.lowerBound == valueEnd else {
                    throw ParseError.invalidArguments
                }
                object[name] = try typedXMLParameterValue(rawValue, type: type).jsonObject
            } else {
                object[name] = try nemotronParameterValue(rawValue)
            }

            if let closeTag = raw.range(of: "</parameter>", range: valueStart..<raw.endIndex),
               closeTag.lowerBound == valueEnd
            {
                searchStart = closeTag.upperBound
            } else if let nextParam = raw.range(of: "<parameter=", range: valueStart..<raw.endIndex),
                      nextParam.lowerBound == valueEnd
            {
                searchStart = nextParam.lowerBound
            } else if let closeFunction = raw.range(of: "</function>", range: valueStart..<raw.endIndex),
                      closeFunction.lowerBound == valueEnd
            {
                searchStart = closeFunction.upperBound
            } else {
                searchStart = valueEnd
                break
            }
        }

        return object
    }

    static func explicitParameterType(_ name: String, schema: JSONValue?) -> String? {
        guard case .object(let object)? = schema,
              case .object(let properties)? = object["properties"],
              case .object(let property)? = properties[name],
              case .string(let type)? = property["type"],
              ["string", "number", "integer", "boolean", "object", "array", "null"].contains(type) else {
            return nil
        }
        return type
    }

    private static func typedXMLParameterValue(_ rawValue: String, type: String) throws -> JSONValue {
        var raw = rawValue[...]
        // LF and CRLF each form one Character. Preserve all other literal whitespace.
        if raw.hasPrefix("\n") || raw.hasPrefix("\r\n") { raw = raw.dropFirst() }
        if raw.hasSuffix("\n") || raw.hasSuffix("\r\n") { raw = raw.dropLast() }
        // Structured values share the existing JSON parser's pre-parse budget;
        // their per-call cap is checked after canonical serialization.
        let rawByteCap = type == "string" ? SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP : SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP
        guard raw.utf8.count <= rawByteCap else {
            throw ParseError.byteCapExceeded
        }
        for marker in ["<parameter=", "<function=", "</function>", "<tool_call>", "</tool_call>"] where raw.contains(marker) {
            throw ParseError.invalidArguments
        }
        if type == "string" { return .string(String(raw)) }
        // The shared final validator counts container depth on the complete
        // arguments object; StrictJSONParser also counts scalar leaf depth.
        // Strict parser errors can carry argument text (for example a duplicate
        // key). The outer parser logs errors, so expose only a payload-free error.
        guard let value = try? StrictJSONParser.parse(String(raw), maxDepth: SPEC018_ARGUMENTS_MAX_JSON_DEPTH) else {
            throw ParseError.invalidArguments
        }
        guard ToolSelectionPolicy.supportsNumericDomain(value) else { throw ParseError.invalidArguments }
        switch (type, value) {
        case ("number", .int), ("number", .double), ("integer", .int),
             ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null):
            return value
        default:
            throw ParseError.invalidArguments
        }
    }

    private static func nemotronParameterValueEnd(in raw: String, from valueStart: String.Index) -> String.Index {
        if let close = raw.range(of: "</parameter>", range: valueStart..<raw.endIndex) {
            return close.lowerBound
        }
        if let next = raw.range(of: "<parameter=", range: valueStart..<raw.endIndex) {
            return next.lowerBound
        }
        if let closeFunction = raw.range(of: "</function>", range: valueStart..<raw.endIndex) {
            return closeFunction.lowerBound
        }
        return raw.endIndex
    }

    private static func nemotronParameterValue(_ rawValue: String) throws -> Any {
        var trimmed = rawValue
        if trimmed.hasPrefix("\n") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("\n") {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        do {
            return try parsePythonLiteral(trimmed)
        } catch {
            return trimmed
        }
    }

    private static func parseJSONCall(_ rawJSON: String, argumentKey: String) throws -> ToolCall {
        guard let data = rawJSON.data(using: .utf8) else {
            throw ParseError.invalidUTF8
        }
        try validateNoDuplicateJSONKeys(rawJSON)
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any],
              let name = object["name"] as? String,
              !name.isEmpty
        else {
            throw ParseError.invalidShape
        }

        let rawArguments = object[argumentKey] ?? object["arguments"] ?? object["parameters"]
        let arguments = try argumentsString(rawArguments)
        return ToolCall(id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())", functionName: name, arguments: arguments)
    }

    private static func parsePythonStyleCall(_ rawCall: String) throws -> ToolCall {
        let trimmed = rawCall.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("),
              trimmed.last == ")"
        else {
            throw ParseError.invalidShape
        }
        let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPythonIdentifier(name) else {
            throw ParseError.invalidShape
        }

        let argumentsStart = trimmed.index(after: open)
        let argumentsEnd = trimmed.index(before: trimmed.endIndex)
        let rawArguments = String(trimmed[argumentsStart..<argumentsEnd])
        let arguments = try pythonKeywordArguments(rawArguments)
        return ToolCall(id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())", functionName: name, arguments: arguments)
    }

    private static func pythonKeywordArguments(_ rawArguments: String) throws -> String {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "{}"
        }

        var object: [String: Any] = [:]
        for item in try splitPythonArguments(trimmed) {
            guard let equals = item.firstIndex(of: "=") else {
                throw ParseError.invalidArguments
            }
            let key = String(item[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPythonIdentifier(key) else {
                throw ParseError.invalidArguments
            }
            guard object[key] == nil else {
                throw ParseError.invalidArguments
            }
            let valueStart = item.index(after: equals)
            let value = String(item[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            object[key] = try parsePythonLiteral(value)
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ParseError.invalidArguments
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let arguments = String(decoding: data, as: UTF8.self)
        try validateNoDuplicateJSONKeys(arguments)
        return arguments
    }

    private static func splitPythonArguments(_ rawArguments: String) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for ch in rawArguments {
            if let activeQuote = quote {
                current.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                current.append(ch)
            case ",":
                let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.isEmpty else {
                    throw ParseError.invalidArguments
                }
                parts.append(item)
                current = ""
            default:
                current.append(ch)
            }
        }
        guard quote == nil else {
            throw ParseError.invalidArguments
        }
        let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.isEmpty else {
            throw ParseError.invalidArguments
        }
        parts.append(item)
        return parts
    }

    private static func parsePythonLiteral(_ rawValue: String) throws -> Any {
        if rawValue.hasPrefix("\"") || rawValue.hasPrefix("'") {
            return try parsePythonString(rawValue)
        }
        switch rawValue {
        case "True", "true":
            return true
        case "False", "false":
            return false
        case "None", "null":
            return NSNull()
        default:
            if let intValue = Int(rawValue) {
                return intValue
            }
            if let doubleValue = Double(rawValue), rawValue.contains(".") {
                return doubleValue
            }
            throw ParseError.invalidArguments
        }
    }

    private static func parsePythonString(_ rawValue: String) throws -> String {
        guard rawValue.count >= 2,
              let first = rawValue.first,
              let last = rawValue.last,
              (first == "\"" || first == "'"),
              first == last
        else {
            throw ParseError.invalidArguments
        }
        var out = ""
        var escaped = false
        for ch in rawValue.dropFirst().dropLast() {
            if escaped {
                switch ch {
                case "n":
                    out.append("\n")
                case "r":
                    out.append("\r")
                case "t":
                    out.append("\t")
                case "\\", "'", "\"":
                    out.append(ch)
                default:
                    throw ParseError.invalidArguments
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        guard !escaped else {
            throw ParseError.invalidArguments
        }
        return out
    }

    private static func isPythonIdentifier(_ value: String) -> Bool {
        guard let first = value.first,
              first == "_" || first.isLetter
        else {
            return false
        }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Validates a tool/function name against the OpenAI function-name charset —
    /// ASCII letters, digits, underscore, and hyphen, 1–64 chars. `isPythonIdentifier`
    /// wrongly rejected MCP-namespaced names such as `buzz-dev-mcp__shell` (hyphens),
    /// which made valid Qwen3-Coder `<function=…>` tool calls leak as raw text instead
    /// of parsing into structured `tool_calls`. The declared-tool allowlist
    /// (`allowedFunctionNames` in `parseToolCalls`) remains the security boundary: any
    /// name not among the request's declared tools is still rejected.
    static func isValidToolFunctionName(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else {
            return false
        }
        return value.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "-")
        }
    }

    /// Validates a `<parameter=NAME>` (function-XML grammar) property name. These become JSON
    /// object keys in `function.arguments`; JSON-Schema / MCP property names are NOT restricted
    /// to Python identifiers, so hyphens and other OpenAI/MCP-legal characters are accepted here.
    /// (Python-style call bodies keep identifier-only keys per SPEC-018 §3.3.) ASCII
    /// `[A-Za-z0-9_-]`, length 1..128.
    static func isValidToolParameterName(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else {
            return false
        }
        return value.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "-")
        }
    }

    private static func argumentsString(_ rawArguments: Any?) throws -> String {
        guard let rawArguments else {
            return "{}"
        }
        if rawArguments is NSNull {
            throw ParseError.invalidArguments
        }
        if let string = rawArguments as? String {
            guard string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return "{}"
            }
            try validateNoDuplicateJSONKeys(string)
            guard let data = string.data(using: .utf8),
                  try JSONSerialization.jsonObject(with: data) is [String: Any]
            else {
                throw ParseError.invalidArguments
            }
            return string
        }
        guard let argumentObject = rawArguments as? [String: Any],
              JSONSerialization.isValidJSONObject(argumentObject)
        else {
            throw ParseError.invalidArguments
        }
        let data = try JSONSerialization.data(withJSONObject: argumentObject, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func validateNoDuplicateJSONKeys(_ rawJSON: String) throws {
        guard rawJSON.utf8.count <= SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
            throw ParseError.invalidArguments
        }
        var validator = ToolArgumentJSONValidator(rawJSON, syntax: .legacyToolCall)
        try validator.validate()
    }

    private static func nilIfBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum ParseError: Error {
        case missingEndDelimiter
        case invalidUTF8
        case invalidShape
        case invalidArguments
        case byteCapExceeded
        case responseByteCapExceeded
    }
}

private enum ToolCallFormat {
    case qwen25

    var startDelimiter: String { "<tool_call>" }
    var endDelimiter: String { "</tool_call>" }
    var argumentKey: String { "arguments" }
}
