import Foundation

// Exact Malibu-side mirror of the provider CLI's CanonicalJSON contract.  It
// intentionally emits no trailing newline. Object keys sort by UTF-16 code
// units and string values are NFC-normalized before escaping.
enum CanonicalJSONError: Error {
    case nonFiniteNumber
    case invalidStringEncoding
}

enum CanonicalJSONValue: Equatable {
    case object([String: CanonicalJSONValue])
    case array([CanonicalJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

enum CanonicalJSON {
    static func encode(_ value: CanonicalJSONValue) throws -> Data {
        let text = try canonicalString(value)
        guard let data = text.data(using: .utf8) else {
            throw CanonicalJSONError.invalidStringEncoding
        }
        return data
    }

    static func canonicalString(_ value: CanonicalJSONValue) throws -> String {
        switch value {
        case let .object(dict):
            let pairs = try dict.keys.sorted(by: utf16LessThan).map { key -> String in
                try "\(quote(key)):\(canonicalString(dict[key]!))"
            }
            return "{\(pairs.joined(separator: ","))}"
        case let .array(values):
            return try "[\(values.map { try canonicalString($0) }.joined(separator: ","))]"
        case let .string(value):
            return try quote(value.precomposedStringWithCanonicalMapping)
        case let .number(value):
            return value
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    static func quote(_ raw: String) throws -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5c: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0c: out += "\\f"
            case 0x0a: out += "\\n"
            case 0x0d: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1f:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.append(Character(scalar))
            }
        }
        out += "\""
        return out
    }

    private static func utf16LessThan(_ lhs: String, _ rhs: String) -> Bool {
        let lhsCodeUnits = Array(lhs.utf16)
        let rhsCodeUnits = Array(rhs.utf16)
        let count = min(lhsCodeUnits.count, rhsCodeUnits.count)
        for index in 0..<count where lhsCodeUnits[index] != rhsCodeUnits[index] {
            return lhsCodeUnits[index] < rhsCodeUnits[index]
        }
        return lhsCodeUnits.count < rhsCodeUnits.count
    }

    static func fromJSONLike(_ any: Any) throws -> CanonicalJSONValue {
        switch any {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let raw = String(cString: number.objCType)
            if ["q", "l", "i", "s", "c", "Q", "L", "I", "S", "C"].contains(raw) {
                return .number(String(number.int64Value))
            }
            guard number.doubleValue.isFinite else {
                throw CanonicalJSONError.nonFiniteNumber
            }
            return .number(number.stringValue)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .number(String(int))
        case let array as [Any]:
            return try .array(array.map { try fromJSONLike($0) })
        case let dict as [String: Any]:
            return try .object(dict.mapValues { try fromJSONLike($0) })
        default:
            throw CanonicalJSONError.invalidStringEncoding
        }
    }
}
