import Foundation
import MacProviderCore

extension JSONValue {
    func jcsValue() throws -> RFC8785JCS.Value {
        switch self {
        case .object(let object):
            return .object(try object.mapValues { try $0.jcsValue() })
        case .array(let array):
            return .array(try array.map { try $0.jcsValue() })
        case .string(let string):
            return .string(string)
        case .int(let int):
            return .int(int)
        case .double(let double):
            return .double(double)
        case .bool(let bool):
            return .bool(bool)
        case .null:
            return .null
        }
    }
}
