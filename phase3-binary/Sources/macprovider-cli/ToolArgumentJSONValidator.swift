import Foundation

// Duplicate-key and depth checks precede Foundation's final JSON/object validation.
// Keep family lexical behavior here; callers retain byte caps and error translation.
struct ToolArgumentJSONValidator {
    enum Syntax {
        case legacyToolCall
        case harmony
    }

    enum ValidationError: Error {
        case invalidArguments
    }

    private let syntax: Syntax
    private let rawJSON: String
    private var index: String.Index

    init(_ rawJSON: String, syntax: Syntax) {
        self.syntax = syntax
        self.rawJSON = rawJSON
        self.index = rawJSON.startIndex
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == rawJSON.endIndex else {
            throw ValidationError.invalidArguments
        }
    }

    private mutating func parseValue(depth: Int) throws {
        skipWhitespace()
        guard index < rawJSON.endIndex else {
            throw ValidationError.invalidArguments
        }

        switch current {
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
            try parseNumber()
        default:
            throw ValidationError.invalidArguments
        }
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth <= ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH else {
            throw ValidationError.invalidArguments
        }
        advance()
        skipWhitespace()
        var keys = Set<String>()

        if consume("}") {
            return
        }

        while true {
            skipWhitespace()
            guard index < rawJSON.endIndex, current == "\"" else {
                throw ValidationError.invalidArguments
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw ValidationError.invalidArguments
            }
            skipWhitespace()
            guard consume(":") else {
                throw ValidationError.invalidArguments
            }
            try parseValue(depth: depth)
            skipWhitespace()
            if consume("}") {
                return
            }
            guard consume(",") else {
                throw ValidationError.invalidArguments
            }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= ToolCallParser.SPEC018_ARGUMENTS_MAX_JSON_DEPTH else {
            throw ValidationError.invalidArguments
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
                throw ValidationError.invalidArguments
            }
        }
    }

    private mutating func parseString() throws -> String {
        guard index < rawJSON.endIndex, current == "\"" else {
            throw ValidationError.invalidArguments
        }

        var rawString = "\""
        advance()
        var escaped = false

        while index < rawJSON.endIndex {
            let ch = current
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
                    throw ValidationError.invalidArguments
                }
                return decoded
            }
        }

        throw ValidationError.invalidArguments
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        guard rawJSON[index...].hasPrefix(literal) else {
            throw ValidationError.invalidArguments
        }
        for _ in literal {
            advance()
        }
    }

    private mutating func parseNumber() throws {
        if syntax == .harmony {
            _ = consume("-")
            guard isDigit else { throw ValidationError.invalidArguments }
            if !consume("0") {
                while isDigit { advance() }
            }
            if consume(".") {
                guard isDigit else { throw ValidationError.invalidArguments }
                while isDigit { advance() }
            }
            if consume("e") || consume("E") {
                _ = consume("+") || consume("-")
                guard isDigit else { throw ValidationError.invalidArguments }
                while isDigit { advance() }
            }
            return
        }
        // Legacy calls leave numeric grammar to the caller's Foundation parse.
        while index < rawJSON.endIndex {
            switch current {
            case "-", "+", ".", "e", "E", "0"..."9":
                advance()
            default:
                return
            }
        }
    }

    private mutating func skipWhitespace() {
        while index < rawJSON.endIndex, isWhitespace {
            advance()
        }
    }

    private mutating func consume(_ expected: Character) -> Bool {
        guard index < rawJSON.endIndex, current == expected else {
            return false
        }
        advance()
        return true
    }

    // Legacy tool calls historically scan Characters; Harmony scans UTF-8 structural
    // bytes. Scalar iteration has the same structural boundaries as bytes for valid
    // Swift strings, without changing legacy handling of extended grapheme clusters.
    private var current: Character {
        syntax == .legacyToolCall ? rawJSON[index] : Character(String(rawJSON.unicodeScalars[index]))
    }

    private var isDigit: Bool {
        index < rawJSON.endIndex && ("0"..."9").contains(current)
    }

    private var isWhitespace: Bool {
        if syntax == .legacyToolCall { return current.isWhitespace }
        switch current {
        case " ", "\n", "\r", "\t": return true
        default: return false
        }
    }

    private mutating func advance() {
        index = syntax == .legacyToolCall
            ? rawJSON.index(after: index)
            : rawJSON.unicodeScalars.index(after: index)
    }
}
