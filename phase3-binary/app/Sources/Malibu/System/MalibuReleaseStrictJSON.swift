import Foundation

enum MalibuReleaseStrictJSON {
    static func parseCanonicalObject(
        _ data: Data,
        label: String,
        allowFinalNewline: Bool = false
    ) throws -> [String: Any] {
        var scanner = MalibuReleaseJSONScanner(data: data)
        try scanner.validate()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MalibuReleaseContractError.invalidJSON("\(label): top-level value must be an object")
        }
        let canonical = try CanonicalJSON.encode(CanonicalJSON.fromJSONLike(object))
        let accepted = canonical == data || (allowFinalNewline && canonical + Data([0x0A]) == data)
        guard accepted else {
            throw MalibuReleaseContractError.nonCanonical(label)
        }
        return object
    }
}

private struct MalibuReleaseJSONScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw invalid("trailing bytes") }
    }

    private mutating func parseValue() throws {
        guard index < bytes.count else { throw invalid("unexpected end") }
        switch bytes[index] {
        case 0x7B: try parseObject()
        case 0x5B: try parseArray()
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral("true")
        case 0x66: try consumeLiteral("false")
        case 0x6E: try consumeLiteral("null")
        default: try parseInteger()
        }
    }

    private mutating func parseObject() throws {
        index += 1
        skipWhitespace()
        var keys = Set<String>()
        if consume(0x7D) { return }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else { throw invalid("object key") }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw MalibuReleaseContractError.duplicateKey(key) }
            skipWhitespace()
            guard consume(0x3A) else { throw invalid("object colon") }
            skipWhitespace()
            try parseValue()
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw invalid("object separator") }
            skipWhitespace()
        }
    }

    private mutating func parseArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw invalid("array separator") }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let token = Data(bytes[start..<index])
                guard let value = try? JSONDecoder().decode(String.self, from: token) else {
                    throw invalid("string")
                }
                return value
            } else if byte < 0x20 {
                throw invalid("control character")
            }
        }
        throw invalid("unterminated string")
    }

    private mutating func parseInteger() throws {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw invalid("number") }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard token.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil else {
            throw invalid("only canonical integers are allowed")
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<index + expected.count]) == expected
        else { throw invalid("literal") }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func invalid(_ reason: String) -> MalibuReleaseContractError {
        .invalidJSON(reason)
    }
}
