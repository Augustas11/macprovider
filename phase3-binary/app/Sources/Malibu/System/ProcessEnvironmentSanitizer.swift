import Foundation

enum ProcessEnvironmentSanitizer {
    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case unsafeValue(String)

        var description: String {
            switch self {
            case let .unsafeValue(key):
                return "unsafe environment value for \(key)"
            }
        }
    }

    static func sanitized(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        extraEnvironment: [String: String] = [:]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in environment {
            guard isAllowedInheritedKey(key) else { continue }
            guard isSafeValue(value) else { throw Error.unsafeValue(key) }
            result[key] = value
        }
        for (key, value) in extraEnvironment {
            guard isSafeValue(value) else { throw Error.unsafeValue(key) }
            result[key] = value
        }
        return result
    }

    static func isSafeValue(_ value: String) -> Bool {
        for scalar in value.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0x7f || scalar.value < 0x20 {
                return false
            }
            if ";|&`$<>".unicodeScalars.contains(scalar) {
                return false
            }
        }
        return true
    }

    private static func isAllowedInheritedKey(_ key: String) -> Bool {
        switch key {
        case "PATH", "HOME", "USER", "TMPDIR", "LANG", "NSUnbufferedIO":
            return true
        default:
            return key.hasPrefix("LC_")
        }
    }
}
