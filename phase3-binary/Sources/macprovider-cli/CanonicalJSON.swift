import Foundation

// RFC 8785 JSON Canonicalization Scheme (JCS).
//
// Byte-identical mirror of the Malibu.app CanonicalJSON implementation at
// phase3-binary/app/Sources/Malibu/System/RegisterClient.swift and of the
// coordinator's Go implementation at phase4-coordinator/internal/billing/jcs.go.
//
// Used by the SPEC-026 identity_signature flow to build the canonical bytes
// whose SHA-256 the coordinator retains from the initial `auth_request`
// stage and requires echoed back — under the provider's Ed25519 signature
// — in the proof stage.

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
        for index in 0..<count {
            if lhsCodeUnits[index] != rhsCodeUnits[index] {
                return lhsCodeUnits[index] < rhsCodeUnits[index]
            }
        }
        return lhsCodeUnits.count < rhsCodeUnits.count
    }
}

extension CanonicalJSON {
    /// Convert a JSON-like Swift dictionary (`[String: Any]`) into a
    /// `CanonicalJSONValue`. Used by the SPEC-026 auth flow to canonicalise
    /// the outgoing initial `auth_request` payload for transcript hashing
    /// without duplicating the field list.
    static func fromJSONLike(_ any: Any) throws -> CanonicalJSONValue {
        switch any {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let raw = String(cString: number.objCType)
            if raw == "q" || raw == "l" || raw == "i" || raw == "s" || raw == "c" {
                return .number(String(number.int64Value))
            }
            return .number(number.stringValue)
        case let int as Int:
            return .number(String(int))
        case let int64 as Int64:
            return .number(String(int64))
        case let double as Double:
            guard double.isFinite else {
                throw CanonicalJSONError.nonFiniteNumber
            }
            if double == double.rounded() && abs(double) < Double(Int64.max) {
                return .number(String(Int64(double)))
            }
            return .number(String(double))
        case let array as [Any]:
            return try .array(array.map { try fromJSONLike($0) })
        case let dict as [String: Any]:
            var out: [String: CanonicalJSONValue] = [:]
            for (key, value) in dict {
                out[key] = try fromJSONLike(value)
            }
            return .object(out)
        default:
            throw CanonicalJSONError.invalidStringEncoding
        }
    }
}
