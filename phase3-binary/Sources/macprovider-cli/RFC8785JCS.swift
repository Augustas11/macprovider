import CryptoKit
import Foundation

enum RFC8785JCS {
    enum Value: Equatable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case int(Int)
        case bool(Bool)
        case null
    }

    static func canonicalString(_ value: Value) throws -> String {
        switch value {
        case .object(let object):
            let keys = object.keys.sorted(by: utf16LexicographicLess)
            let members = try keys.map { key in
                guard let member = object[key] else {
                    throw Error.missingObjectMember(key)
                }
                return "\(escapeString(key)):\(try canonicalString(member))"
            }
            return "{\(members.joined(separator: ","))}"
        case .array(let array):
            return try "[\(array.map { try canonicalString($0) }.joined(separator: ","))]"
        case .string(let string):
            return escapeString(string)
        case .int(let int):
            return String(int)
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

    private static func escapeString(_ string: String) -> String {
        var escaped = "\""
        for scalar in string.unicodeScalars {
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
            case 0xfffd:
                escaped += "\\ufffd"
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
    }

    enum Error: Swift.Error, Equatable {
        case missingObjectMember(String)
    }
}
