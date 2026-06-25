import Foundation

enum ToolCallParser {
    static func parseToolCalls(
        rawOutput: String,
        modelID: String,
        allowedFunctionNames: Set<String>? = nil
    ) -> (cleanedContent: String?, toolCalls: [ToolCall]) {
        let format = ToolCallFormat.detect(modelID: modelID, rawOutput: rawOutput)
        guard let format else {
            return (nilIfBlank(rawOutput), [])
        }

        do {
            let parsed = try parseDelimited(rawOutput, format: format)
            if let allowedFunctionNames,
               parsed.toolCalls.contains(where: { !allowedFunctionNames.contains($0.functionName) })
            {
                fputs("warning: tool-call output contains undeclared function for \(modelID)\n", stderr)
                return (nilIfBlank(rawOutput), [])
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

        while let startRange = rawOutput.range(of: format.startDelimiter, range: searchStart..<rawOutput.endIndex) {
            cleaned += rawOutput[searchStart..<startRange.lowerBound]
            let bodyStart = startRange.upperBound
            guard let endRange = rawOutput.range(of: format.endDelimiter, range: bodyStart..<rawOutput.endIndex) else {
                throw ParseError.missingEndDelimiter
            }
            let body = String(rawOutput[bodyStart..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            calls.append(try parseCall(body, argumentKey: format.argumentKey))
            searchStart = endRange.upperBound
        }

        cleaned += rawOutput[searchStart..<rawOutput.endIndex]
        guard !calls.isEmpty else {
            return (nilIfBlank(rawOutput), [])
        }
        return (nilIfBlank(cleaned), calls)
    }

    private static func parseCall(_ rawCall: String, argumentKey: String) throws -> ToolCall {
        if rawCall.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return try parseJSONCall(rawCall, argumentKey: argumentKey)
        }
        return try parsePythonStyleCall(rawCall)
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
        return String(decoding: data, as: UTF8.self)
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
            try parseValue()
            skipWhitespace()
            guard index == rawJSON.endIndex else {
                throw ParseError.invalidArguments
            }
        }

        private mutating func parseValue() throws {
            skipWhitespace()
            guard index < rawJSON.endIndex else {
                throw ParseError.invalidArguments
            }

            switch rawJSON[index] {
            case "{":
                try parseObject()
            case "[":
                try parseArray()
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

        private mutating func parseObject() throws {
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
                try parseValue()
                skipWhitespace()
                if consume("}") {
                    return
                }
                guard consume(",") else {
                    throw ParseError.invalidArguments
                }
            }
        }

        private mutating func parseArray() throws {
            advance()
            skipWhitespace()

            if consume("]") {
                return
            }

            while true {
                try parseValue()
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

    static func detect(modelID: String, rawOutput: String) -> ToolCallFormat? {
        if modelID.localizedCaseInsensitiveContains("llama-3.3") || rawOutput.contains("<|python_tag|>") {
            return .llama33
        }
        if modelID.localizedCaseInsensitiveContains("qwen2.5") || rawOutput.contains("<tool_call>") {
            return .qwen25
        }
        return nil
    }
}
