import Foundation

/// Rejects JSON input that contains duplicate object keys. `JSONDecoder` (and
/// `JSONSerialization`) silently keep one value for a duplicated key, so an
/// ambiguous/malformed catalog-economics projection — e.g. first
/// `"economics_state":"trusted"` then a later conflicting value for the same key
/// — could otherwise reach trusted-row rendering. The closed-schema decoder
/// rejects unknown keys but not duplicate known keys, so this preflight runs
/// before decoding. Ported from the CLI's AutotuneStrictJSON duplicate-key
/// scanner to keep memory/CLI parity without adding a cross-package dependency.
enum MalibuStrictJSON {
    static func rejectDuplicateKeys(_ data: Data) throws {
        var scanner = JSONDuplicateKeyScanner(data: data)
        try scanner.validate()
    }
}

private struct JSONDuplicateKeyScanner {
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
        default: try parseNumber()
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
            guard keys.insert(key).inserted else { throw invalid("duplicate object key \(key)") }
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
                continue
            }
            if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let token = Data(bytes[start ..< index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
                    throw invalid("string")
                }
                return decoded
            } else if byte < 0x20 {
                throw invalid("control character")
            }
        }
        throw invalid("unterminated string")
    }

    private mutating func parseNumber() throws {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw invalid("number") }
        let token = Data(bytes[start ..< index])
        guard (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) is NSNumber else {
            throw invalid("number")
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index ..< index + expected.count]) == expected
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

    private func invalid(_ reason: String) -> ModelManagementError {
        .invalidCatalog
    }
}
