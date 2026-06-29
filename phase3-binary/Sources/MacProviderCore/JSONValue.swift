import Foundation

public indirect enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public static func parse(_ raw: Any) throws -> JSONValue {
        if raw is NSNull {
            return .null
        }
        if let string = raw as? String {
            return .string(string)
        }
        if let array = raw as? [Any] {
            return .array(try array.map { try parse($0) })
        }
        if let object = raw as? [String: Any] {
            return .object(try object.mapValues { try parse($0) })
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            guard double.isFinite else {
                throw APIError(status: 400, message: "JSON numbers must be finite", code: "invalid_request")
            }
            if double.rounded(.towardZero) == double,
               double >= Double(Int.min),
               double <= Double(Int.max) {
                return .int(number.intValue)
            }
            return .double(double)
        }
        throw APIError(status: 400, message: "Unsupported JSON value", code: "invalid_request")
    }

    public var jsonObject: Any {
        switch self {
        case .object(let object):
            return object.mapValues { $0.jsonObject }
        case .array(let array):
            return array.map { $0.jsonObject }
        case .string(let string):
            return string
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        }
    }

    public func deterministicJSONString() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
