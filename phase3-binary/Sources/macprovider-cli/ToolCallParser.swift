import Foundation

enum ToolCallParser {
    static let SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP = 1_048_576
    static let SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP = 2_097_152
    static let SPEC018_ARGUMENTS_MAX_JSON_DEPTH = 32

    static func parseToolCalls(
        rawOutput: String,
        modelID: String,
        allowedFunctionNames: Set<String>? = nil
    ) -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nilIfBlank(rawOutput), [])
        }
        let format = ToolCallFormat.detect(modelID: modelID, rawOutput: rawOutput)
        guard let format else {
            return (nilIfBlank(rawOutput), [])
        }

        do {
            let parsed = try parseDelimited(rawOutput, format: format)
            if !parsed.toolCalls.isEmpty {
                if let allowedFunctionNames,
                   parsed.toolCalls.contains(where: { !allowedFunctionNames.contains($0.functionName) })
                {
                    fputs("warning: tool-call output contains undeclared function for \(modelID)\n", stderr)
                    return (nilIfBlank(rawOutput), [])
                }
                return parsed
            }
            // Function-XML (`<function=…>`) is a Qwen-row body grammar only (SPEC-018 §3.1
            // v0.2.7). Do NOT run it for other families (e.g. Llama-3.3), whose §3.1 rows
            // define only JSON/Python bodies — keep the parser-family boundary tight.
            if format == .qwen25, rawOutput.contains("<function=") {
                let bare = try parseBareNemotronCalls(rawOutput)
                if !bare.toolCalls.isEmpty {
                    if let allowedFunctionNames,
                       bare.toolCalls.contains(where: { !allowedFunctionNames.contains($0.functionName) })
                    {
                        fputs("warning: tool-call output contains undeclared function for \(modelID)\n", stderr)
                        return (nilIfBlank(rawOutput), [])
                    }
                    return bare
                }
            }
            return parsed
        } catch {
            fputs("warning: malformed tool-call output for \(modelID): \(error)\n", stderr)
            return (nilIfBlank(rawOutput), [])
        }
    }

    private static func parseDelimited(_ rawOutput: String, format: ToolCallFormat) throws -> (cleanedContent: String?, toolCalls: [ToolCall]) {
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
            let call = try parseCall(body, argumentKey: format.argumentKey, allowFunctionXML: format == .qwen25)
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
    private static func parseBareNemotronCalls(_ rawOutput: String) throws -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        var searchStart = rawOutput.startIndex
        var cleaned = ""
        var calls: [ToolCall] = []
        var responseArgumentBytes = 0

        while let open = rawOutput.range(of: "<function=", range: searchStart..<rawOutput.endIndex) {
            cleaned += rawOutput[searchStart..<open.lowerBound]
            let blockEnd = rawOutput.range(of: "</function>", range: open.lowerBound..<rawOutput.endIndex)?.upperBound ?? rawOutput.endIndex
            let block = String(rawOutput[open.lowerBound..<blockEnd])
            let call = try parseNemotronXMLCall(block)
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

    private static func parseCall(_ rawCall: String, argumentKey: String, allowFunctionXML: Bool) throws -> ToolCall {
        let trimmed = rawCall.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            return try parseJSONCall(rawCall, argumentKey: argumentKey)
        }
        if allowFunctionXML, trimmed.contains("<function=") {
            return try parseNemotronXMLCall(rawCall)
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

    private static func parseNemotronXMLCall(_ rawCall: String) throws -> ToolCall {
        let block = String(firstFunctionBlock(in: rawCall))
        guard let functionName = nemotronFunctionName(in: block) else {
            throw ParseError.invalidShape
        }
        let argumentsObject = try nemotronParameterObject(in: block, includeIncomplete: true)
        guard JSONSerialization.isValidJSONObject(argumentsObject) else {
            throw ParseError.invalidArguments
        }
        let data = try JSONSerialization.data(withJSONObject: argumentsObject, options: [.sortedKeys, .withoutEscapingSlashes])
        let arguments = String(decoding: data, as: UTF8.self)
        try validateNoDuplicateJSONKeys(arguments)
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

    static func nemotronArgumentsJSON(in raw: String, includeIncomplete: Bool) -> String? {
        let block = String(firstFunctionBlock(in: raw))
        guard let object = try? nemotronParameterObject(in: block, includeIncomplete: includeIncomplete),
              JSONSerialization.isValidJSONObject(object)
        else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func nemotronParameterObject(in raw: String, includeIncomplete: Bool) throws -> [String: Any] {
        var object: [String: Any] = [:]
        var searchStart = raw.startIndex

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
            object[name] = try nemotronParameterValue(rawValue)

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
    private static func isValidToolFunctionName(_ value: String) -> Bool {
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
    private static func isValidToolParameterName(_ value: String) -> Bool {
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
        var validator = JSONDuplicateKeyValidator(rawJSON)
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

    private struct JSONDuplicateKeyValidator {
        let rawJSON: String
        var index: String.Index

        init(_ rawJSON: String) {
            self.rawJSON = rawJSON
            self.index = rawJSON.startIndex
        }

        mutating func validate() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == rawJSON.endIndex else {
                throw ParseError.invalidArguments
            }
        }

        private mutating func parseValue(depth: Int) throws {
            skipWhitespace()
            guard index < rawJSON.endIndex else {
                throw ParseError.invalidArguments
            }

            switch rawJSON[index] {
            case "{":
                try parseObject(depth: depth + 1)
            case "[":
                try parseArray(depth: depth + 1)
            case "\"":
                _ = try parseString()
            case "t":
                try consumeLiteral("true")
            case "f":
                try consumeLiteral("false")
            case "n":
                try consumeLiteral("null")
            case "-", "0"..."9":
                parseNumber()
            default:
                throw ParseError.invalidArguments
            }
        }

        private mutating func parseObject(depth: Int) throws {
            guard depth <= SPEC018_ARGUMENTS_MAX_JSON_DEPTH else {
                throw ParseError.invalidArguments
            }
            advance()
            skipWhitespace()
            var keys = Set<String>()

            if consume("}") {
                return
            }

            while true {
                skipWhitespace()
                guard index < rawJSON.endIndex, rawJSON[index] == "\"" else {
                    throw ParseError.invalidArguments
                }
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw ParseError.invalidArguments
                }
                skipWhitespace()
                guard consume(":") else {
                    throw ParseError.invalidArguments
                }
                try parseValue(depth: depth)
                skipWhitespace()
                if consume("}") {
                    return
                }
                guard consume(",") else {
                    throw ParseError.invalidArguments
                }
            }
        }

        private mutating func parseArray(depth: Int) throws {
            guard depth <= SPEC018_ARGUMENTS_MAX_JSON_DEPTH else {
                throw ParseError.invalidArguments
            }
            advance()
            skipWhitespace()

            if consume("]") {
                return
            }

            while true {
                try parseValue(depth: depth)
                skipWhitespace()
                if consume("]") {
                    return
                }
                guard consume(",") else {
                    throw ParseError.invalidArguments
                }
            }
        }

        private mutating func parseString() throws -> String {
            guard index < rawJSON.endIndex, rawJSON[index] == "\"" else {
                throw ParseError.invalidArguments
            }

            var rawString = "\""
            advance()
            var escaped = false

            while index < rawJSON.endIndex {
                let ch = rawJSON[index]
                rawString.append(ch)
                advance()

                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    guard let data = rawString.data(using: .utf8),
                          let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
                    else {
                        throw ParseError.invalidArguments
                    }
                    return decoded
                }
            }

            throw ParseError.invalidArguments
        }

        private mutating func consumeLiteral(_ literal: String) throws {
            guard rawJSON[index...].hasPrefix(literal) else {
                throw ParseError.invalidArguments
            }
            for _ in literal {
                advance()
            }
        }

        private mutating func parseNumber() {
            while index < rawJSON.endIndex {
                switch rawJSON[index] {
                case "-", "+", ".", "e", "E", "0"..."9":
                    advance()
                default:
                    return
                }
            }
        }

        private mutating func skipWhitespace() {
            while index < rawJSON.endIndex, rawJSON[index].isWhitespace {
                advance()
            }
        }

        private mutating func consume(_ expected: Character) -> Bool {
            guard index < rawJSON.endIndex, rawJSON[index] == expected else {
                return false
            }
            advance()
            return true
        }

        private mutating func advance() {
            index = rawJSON.index(after: index)
        }
    }
}

private enum ToolCallFormat {
    case qwen25
    case llama33

    var startDelimiter: String {
        switch self {
        case .qwen25:
            return "<tool_call>"
        case .llama33:
            return "<|python_tag|>"
        }
    }

    var endDelimiter: String {
        switch self {
        case .qwen25:
            return "</tool_call>"
        case .llama33:
            return "<|eom_id|>"
        }
    }

    var argumentKey: String {
        switch self {
        case .qwen25:
            return "arguments"
        case .llama33:
            return "parameters"
        }
    }

    static func detect(modelID: String, rawOutput _: String) -> ToolCallFormat? {
        if modelID.localizedCaseInsensitiveContains("qwen2.5") ||
            modelID.localizedCaseInsensitiveContains("qwen3")
        {
            return .qwen25
        }
        if modelID.localizedCaseInsensitiveContains("llama-3.3") {
            return .llama33
        }
        return nil
    }
}
