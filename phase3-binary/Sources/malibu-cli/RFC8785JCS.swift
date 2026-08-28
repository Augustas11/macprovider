import CryptoKit
import Foundation
import JavaScriptCore

enum RFC8785JCS {
    enum Value: Equatable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case rawString(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null
    }

    static func canonicalString(_ value: Value) throws -> String {
        try canonicalString(value, normalizeStrings: true)
    }

    static func canonicalStringRawStrings(_ value: Value) throws -> String {
        try canonicalString(value, normalizeStrings: false)
    }

    private static func canonicalString(_ value: Value, normalizeStrings: Bool) throws -> String {
        switch value {
        case .object(let object):
            let keys = object.keys.sorted(by: utf16LexicographicLess)
            let members = try keys.map { key in
                guard let member = object[key] else {
                    throw Error.missingObjectMember(key)
                }
                return "\(escapeString(key, normalizeNFC: false)):\(try canonicalString(member, normalizeStrings: normalizeStrings))"
            }
            return "{\(members.joined(separator: ","))}"
        case .array(let array):
            return try "[\(array.map { try canonicalString($0, normalizeStrings: normalizeStrings) }.joined(separator: ","))]"
        case .string(let string):
            return escapeString(string, normalizeNFC: normalizeStrings)
        case .rawString(let string):
            return escapeString(string, normalizeNFC: false)
        case .int(let int):
            return String(int)
        case .double(let double):
            return try canonicalDouble(double)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        }
    }

    static func sha256Hex(of value: Value) throws -> String {
        let canonical = try canonicalString(value)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func utf16LexicographicLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }

    private static func canonicalDouble(_ double: Double) throws -> String {
        guard double.isFinite else {
            throw Error.nonFiniteDouble
        }
        guard let context = JSContext() else {
            throw Error.numberFormatterUnavailable
        }
        context.setObject(double, forKeyedSubscript: "n" as NSString)
        guard let formatted = context.evaluateScript("JSON.stringify(n)")?.toString(),
              formatted != "null" else {
            throw Error.numberFormatterUnavailable
        }
        return formatted
    }

    private static func escapeString(_ string: String, normalizeNFC: Bool) -> String {
        let source = normalizeNFC ? string.precomposedStringWithCanonicalMapping : string
        var escaped = "\""
        for scalar in source.unicodeScalars {
            switch scalar.value {
            case 0x22:
                escaped += "\\\""
            case 0x5c:
                escaped += "\\\\"
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0a:
                escaped += "\\n"
            case 0x0c:
                escaped += "\\f"
            case 0x0d:
                escaped += "\\r"
            case 0x00...0x1f:
                escaped += String(format: "\\u%04x", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
    }

    enum Error: Swift.Error, Equatable {
        case missingObjectMember(String)
        case nonFiniteDouble
        case numberFormatterUnavailable
    }
}
