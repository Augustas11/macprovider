import Foundation
import MacProviderCore

/// The vendor's LFM template emits a list of keyword calls, not Python code.
/// Parse that bounded dialect without evaluating expressions or round-tripping
/// JSON numbers through floating point.
enum LFMToolCallParser {
    static let startMarker = "<|tool_call_start|>"
    static let endMarker = "<|tool_call_end|>"

    enum Invalid: Error { case syntax, limit }

    static func parse(_ text: String) throws -> [ToolCall] {
        guard let start = text.range(of: startMarker) else { return [] }
        // Bound before copying into the byte parser. Argument limits are also
        // enforced independently after conversion and by the common parser.
        let body = text[start.upperBound...]
        guard body.utf8.count <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP + 65_536 else {
            throw Invalid.limit
        }
        var parser = Parser(bytes: Array(body.utf8))
        return try parser.calls()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func calls() throws -> [ToolCall] {
            try require(91) // [
            var result: [ToolCall] = []
            var argumentBytes = 0
            guard !take(93) else { throw Invalid.syntax }
            while true {
                let name = try identifier()
                try require(40) // (
                var fields: [String] = []
                var keys = Set<String>()
                if !take(41) {
                    while true {
                        let key = try identifier()
                        guard keys.insert(key).inserted else { throw Invalid.syntax }
                        try require(61) // =
                        let json = try value(depth: 2, jsonOnly: false)
                        fields.append("\"\(key)\":" + json)
                        if take(41) { break }
                        try require(44)
                    }
                }
                let arguments = "{" + fields.joined(separator: ",") + "}"
                let count = arguments.utf8.count
                argumentBytes += count
                guard count <= ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP,
                    argumentBytes <= ToolCallParser.SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP else {
                    throw Invalid.limit
                }
                let parsed = try StrictJSONParser.parse(
                    arguments, maxDepth: ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH)
                guard ToolSelectionPolicy.supportsNumericDomain(parsed) else { throw Invalid.syntax }
                result.append(ToolCall(
                    id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    functionName: name, arguments: arguments))
                if take(93) { break }
                try require(44)
            }
            space()
            try literal(LFMToolCallParser.endMarker)
            space()
            guard index == bytes.count else { throw Invalid.syntax }
            return result
        }

        mutating func value(depth: Int, jsonOnly: Bool) throws -> String {
            guard depth <= ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH else { throw Invalid.limit }
            space()
            guard index < bytes.count else { throw Invalid.syntax }
            switch bytes[index] {
            case 34: return try string(singleQuoted: false)
            case 39 where !jsonOnly: return try string(singleQuoted: true)
            case 91:
                index += 1
                var values: [String] = []
                if take(93) { return "[]" }
                while true {
                    values.append(try value(depth: depth + 1, jsonOnly: true))
                    if take(93) { return "[" + values.joined(separator: ",") + "]" }
                    try require(44)
                }
            case 123:
                index += 1
                var fields: [String] = []
                if take(125) { return "{}" }
                while true {
                    space()
                    let key = try string(singleQuoted: false)
                    try require(58)
                    fields.append(key + ":" + (try value(depth: depth + 1, jsonOnly: true)))
                    if take(125) { return "{" + fields.joined(separator: ",") + "}" }
                    try require(44)
                }
            default:
                let start = index
                while index < bytes.count, ![9, 10, 13, 32, 44, 41, 93, 125].contains(bytes[index]) {
                    index += 1
                }
                guard index > start else { throw Invalid.syntax }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                if !jsonOnly {
                    switch token {
                    case "True": return "true"
                    case "False": return "false"
                    case "None": return "null"
                    default: break
                    }
                }
                // The final strict JSON parse rejects expressions, invalid
                // literals, nonfinite numbers and duplicate nested keys.
                return token
            }
        }

        mutating func string(singleQuoted: Bool) throws -> String {
            let quote: UInt8 = singleQuoted ? 39 : 34
            guard index < bytes.count, bytes[index] == quote else { throw Invalid.syntax }
            index += 1
            var output: [UInt8] = [34]
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == quote {
                    output.append(34)
                    return String(decoding: output, as: UTF8.self)
                }
                guard byte >= 32 else { throw Invalid.syntax }
                if byte == 92 {
                    guard index < bytes.count else { throw Invalid.syntax }
                    let escaped = bytes[index]
                    index += 1
                    if singleQuoted, escaped == 39 {
                        output.append(39)
                    } else {
                        guard [34, 47, 92, 98, 102, 110, 114, 116, 117].contains(escaped) else {
                            throw Invalid.syntax
                        }
                        output.append(contentsOf: [92, escaped])
                    }
                } else if singleQuoted, byte == 34 {
                    output.append(contentsOf: [92, 34])
                } else {
                    output.append(byte)
                }
            }
            throw Invalid.syntax
        }

        mutating func identifier() throws -> String {
            space()
            let start = index
            guard index < bytes.count, identifierStart(bytes[index]) else { throw Invalid.syntax }
            index += 1
            while index < bytes.count, identifierStart(bytes[index]) || (48...57).contains(bytes[index]) {
                index += 1
            }
            let name = String(decoding: bytes[start..<index], as: UTF8.self)
            guard ToolCallGrammar.isLFMIdentifier(name) else { throw Invalid.syntax }
            return name
        }

        func identifierStart(_ byte: UInt8) -> Bool {
            byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
        }

        mutating func space() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            space()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func require(_ byte: UInt8) throws {
            guard take(byte) else { throw Invalid.syntax }
        }

        mutating func literal(_ text: String) throws {
            let token = Array(text.utf8)
            guard bytes.count - index >= token.count,
                bytes[index..<(index + token.count)].elementsEqual(token) else { throw Invalid.syntax }
            index += token.count
        }
    }
}
