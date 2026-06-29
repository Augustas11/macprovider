import Foundation

public enum StrictJSONParser {
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw ParseError.trailingData
        }
        return value
    }

    public enum ParseError: Error, Equatable {
        case unexpectedEnd
        case unexpectedCharacter
        case invalidString
        case invalidNumber
        case duplicateKey(String)
        case trailingData
    }

    private struct Parser {
        var scalars: [UnicodeScalar]
        var index = 0

        var isAtEnd: Bool { index >= scalars.count }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard !isAtEnd else { throw ParseError.unexpectedEnd }
            switch scalars[index] {
            case "{":
                return try parseObject()
            case "[":
                return try parseArray()
            case "\"":
                return .string(try parseString())
            case "t":
                try consumeLiteral("true")
                return .bool(true)
            case "f":
                try consumeLiteral("false")
                return .bool(false)
            case "n":
                try consumeLiteral("null")
                return .null
            default:
                return try parseNumber()
            }
        }

        mutating func parseObject() throws -> JSONValue {
            try consume("{")
            skipWhitespace()
            var object: [String: JSONValue] = [:]
            guard !consumeIf("}") else { return .object(object) }
            while true {
                skipWhitespace()
                guard peek() == "\"" else { throw ParseError.unexpectedCharacter }
                let key = try parseString()
                guard object[key] == nil else { throw ParseError.duplicateKey(key) }
                skipWhitespace()
                try consume(":")
                object[key] = try parseValue()
                skipWhitespace()
                if consumeIf("}") {
                    return .object(object)
                }
                try consume(",")
            }
        }

        mutating func parseArray() throws -> JSONValue {
            try consume("[")
            skipWhitespace()
            var array: [JSONValue] = []
            guard !consumeIf("]") else { return .array(array) }
            while true {
                array.append(try parseValue())
                skipWhitespace()
                if consumeIf("]") {
                    return .array(array)
                }
                try consume(",")
            }
        }

        mutating func parseString() throws -> String {
            try consume("\"")
            var result = String.UnicodeScalarView()
            while !isAtEnd {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" {
                    return String(result)
                }
                if scalar == "\\" {
                    guard !isAtEnd else { throw ParseError.invalidString }
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "\"", "\\", "/":
                        result.append(escaped)
                    case "b":
                        result.append(UnicodeScalar(0x08)!)
                    case "f":
                        result.append(UnicodeScalar(0x0c)!)
                    case "n":
                        result.append("\n")
                    case "r":
                        result.append("\r")
                    case "t":
                        result.append("\t")
                    case "u":
                        let first = try parseHexQuad()
                        if (0xd800 ... 0xdbff).contains(first) {
                            guard try consumeUnicodeEscapePrefixIfPresent() else { throw ParseError.invalidString }
                            let second = try parseHexQuad()
                            guard (0xdc00 ... 0xdfff).contains(second) else { throw ParseError.invalidString }
                            let combined = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
                            guard let scalar = UnicodeScalar(combined) else { throw ParseError.invalidString }
                            result.append(scalar)
                        } else {
                            guard !(0xdc00 ... 0xdfff).contains(first), let scalar = UnicodeScalar(first) else {
                                throw ParseError.invalidString
                            }
                            result.append(scalar)
                        }
                    default:
                        throw ParseError.invalidString
                    }
                    continue
                }
                guard scalar.value >= 0x20 else { throw ParseError.invalidString }
                result.append(scalar)
            }
            throw ParseError.unexpectedEnd
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            if consumeIf("-") {}
            if consumeIf("0") {
                // Leading zero consumed.
            } else {
                try consumeDigit1to9()
                while consumeDigit() {}
            }
            var isDouble = false
            if consumeIf(".") {
                isDouble = true
                guard consumeDigit() else { throw ParseError.invalidNumber }
                while consumeDigit() {}
            }
            if consumeIf("e") || consumeIf("E") {
                isDouble = true
                _ = consumeIf("+") || consumeIf("-")
                guard consumeDigit() else { throw ParseError.invalidNumber }
                while consumeDigit() {}
            }
            let literal = String(String.UnicodeScalarView(scalars[start..<index]))
            if isDouble {
                guard let double = Double(literal), double.isFinite else { throw ParseError.invalidNumber }
                return .double(double)
            }
            guard let int = Int(literal) else {
                guard let double = Double(literal), double.isFinite else { throw ParseError.invalidNumber }
                return .double(double)
            }
            return .int(int)
        }

        mutating func parseHexQuad() throws -> UInt32 {
            guard index + 4 <= scalars.count else { throw ParseError.invalidString }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let scalar = scalars[index]
                index += 1
                value <<= 4
                switch scalar.value {
                case 48 ... 57:
                    value += scalar.value - 48
                case 65 ... 70:
                    value += scalar.value - 55
                case 97 ... 102:
                    value += scalar.value - 87
                default:
                    throw ParseError.invalidString
                }
            }
            return value
        }

        mutating func consumeUnicodeEscapePrefixIfPresent() throws -> Bool {
            guard index + 2 <= scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" else {
                return false
            }
            index += 2
            return true
        }

        mutating func skipWhitespace() {
            while !isAtEnd, [" ", "\n", "\r", "\t"].contains(scalars[index]) {
                index += 1
            }
        }

        func peek() -> UnicodeScalar? {
            isAtEnd ? nil : scalars[index]
        }

        mutating func consumeLiteral(_ literal: String) throws {
            for scalar in literal.unicodeScalars {
                try consume(scalar)
            }
        }

        mutating func consume(_ expected: UnicodeScalar) throws {
            guard !isAtEnd, scalars[index] == expected else { throw ParseError.unexpectedCharacter }
            index += 1
        }

        mutating func consumeIf(_ expected: UnicodeScalar) -> Bool {
            guard !isAtEnd, scalars[index] == expected else { return false }
            index += 1
            return true
        }

        mutating func consumeDigit1to9() throws {
            guard !isAtEnd, (49 ... 57).contains(scalars[index].value) else { throw ParseError.invalidNumber }
            index += 1
        }

        mutating func consumeDigit() -> Bool {
            guard !isAtEnd, (48 ... 57).contains(scalars[index].value) else { return false }
            index += 1
            return true
        }
    }
}
