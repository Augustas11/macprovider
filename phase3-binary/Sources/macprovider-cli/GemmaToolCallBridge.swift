import Foundation
import MacProviderCore

/// Gemma 4 tool calls (`<|tool_call>call:NAME{key:<|"|>v<|"|>,n:5}<tool_call|>`,
/// the grammar its chat template renders with `format_argument`). A bounded
/// recursive-descent parser over the whole body: strings are `<|"|>`-delimited
/// at any depth, keys are bare or `<|"|>`-quoted, other scalars are JSON
/// literals. Duplicate keys, trailing text, excess depth or bytes fail closed
/// (SPEC-018 §3.4/§3.5), and a declared parameter type must match.
enum GemmaToolCallBridge {
    enum Failure: Error { case malformed }

    static let quote = "<|\"|>"

    static func call(_ body: String, schemas: [String: MacProviderCore.JSONValue]?) throws -> macprovider_cli.ToolCall {
        guard body.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP else { throw Failure.malformed }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("call:"), let brace = trimmed.firstIndex(of: "{") else { throw Failure.malformed }
        let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: "call:".count)..<brace])
        guard ToolCallParser.isValidToolFunctionName(name) else { throw Failure.malformed }
        var parser = Parser(scalars: Array(trimmed[brace...].unicodeScalars))
        let value = try parser.parseObject(depth: 1, topLevel: true)
        parser.skipWhitespace()
        guard parser.atEnd, case .object(let arguments) = value else { throw Failure.malformed }
        let schema = schemas?[name]
        for (key, argument) in arguments {
            if let type = ToolCallParser.explicitParameterType(key, schema: schema), !matches(argument, type: type) {
                throw Failure.malformed
            }
        }
        guard ToolSelectionPolicy.supportsNumericDomain(value) else { throw Failure.malformed }
        return macprovider_cli.ToolCall(
            id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            functionName: name,
            arguments: try value.deterministicJSONString()
        )
    }

    private static func matches(_ value: MacProviderCore.JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("number", .int), ("number", .double), ("integer", .int),
             ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null):
            return true
        default:
            return false
        }
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        private static let quoteScalars = Array(GemmaToolCallBridge.quote.unicodeScalars)

        init(scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        }

        private func hasQuote(at position: Int) -> Bool {
            guard position + Self.quoteScalars.count <= scalars.count else { return false }
            return Array(scalars[position..<position + Self.quoteScalars.count]) == Self.quoteScalars
        }

        private mutating func expect(_ scalar: Unicode.Scalar) throws {
            skipWhitespace()
            guard index < scalars.count, scalars[index] == scalar else { throw Failure.malformed }
            index += 1
        }

        mutating func parseObject(depth: Int, topLevel: Bool = false) throws -> MacProviderCore.JSONValue {
            guard depth <= ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH else { throw Failure.malformed }
            try expect("{")
            var object: [String: MacProviderCore.JSONValue] = [:]
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" {
                index += 1
                return .object(object)
            }
            while true {
                let key = try parseKey()
                guard object[key] == nil else { throw Failure.malformed }
                if topLevel, !ToolCallParser.isValidToolParameterName(key) { throw Failure.malformed }
                try expect(":")
                object[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < scalars.count else { throw Failure.malformed }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(object) }
                throw Failure.malformed
            }
        }

        private mutating func parseKey() throws -> String {
            skipWhitespace()
            if hasQuote(at: index) { return try parseQuotedString() }
            let start = index
            while index < scalars.count, scalars[index] != ":", !scalars[index].properties.isWhitespace {
                let s = scalars[index]
                guard s.isASCII, s.properties.isAlphabetic || ("0"..."9").contains(s) || s == "_" || s == "-" || s == "." else {
                    throw Failure.malformed
                }
                index += 1
            }
            guard index > start else { throw Failure.malformed }
            return String(String.UnicodeScalarView(scalars[start..<index]))
        }

        private mutating func parseQuotedString() throws -> String {
            index += Self.quoteScalars.count
            let start = index
            while index < scalars.count {
                if hasQuote(at: index) {
                    let text = String(String.UnicodeScalarView(scalars[start..<index]))
                    index += Self.quoteScalars.count
                    return text
                }
                index += 1
            }
            throw Failure.malformed
        }

        private mutating func parseValue(depth: Int) throws -> MacProviderCore.JSONValue {
            guard depth <= ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH else { throw Failure.malformed }
            skipWhitespace()
            guard index < scalars.count else { throw Failure.malformed }
            if hasQuote(at: index) { return .string(try parseQuotedString()) }
            switch scalars[index] {
            case "{":
                return try parseObject(depth: depth)
            case "[":
                index += 1
                var array: [MacProviderCore.JSONValue] = []
                skipWhitespace()
                if index < scalars.count, scalars[index] == "]" { index += 1; return .array(array) }
                while true {
                    array.append(try parseValue(depth: depth + 1))
                    skipWhitespace()
                    guard index < scalars.count else { throw Failure.malformed }
                    if scalars[index] == "," { index += 1; continue }
                    if scalars[index] == "]" { index += 1; return .array(array) }
                    throw Failure.malformed
                }
            default:
                let start = index
                while index < scalars.count, !",}]".unicodeScalars.contains(scalars[index]),
                      !scalars[index].properties.isWhitespace {
                    index += 1
                }
                let literal = String(String.UnicodeScalarView(scalars[start..<index]))
                switch literal {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "null", "None": return .null
                default:
                    guard let first = literal.unicodeScalars.first, first == "-" || ("0"..."9").contains(first),
                          let number = try? StrictJSONParser.parse(literal, maxDepth: 1) else {
                        throw Failure.malformed
                    }
                    switch number {
                    case .int, .double: return number
                    default: throw Failure.malformed
                    }
                }
            }
        }
    }
}
