import Foundation

public enum ProcessEnvironmentSanitizer {
    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case unsafeValue(String)

        public var description: String {
            switch self {
            case let .unsafeValue(key):
                return "unsafe environment value for \(key)"
            }
        }
    }

    public static func sanitized(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        allowMacProviderKeys: Bool = false
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in environment {
            guard isAllowedKey(key, allowMacProviderKeys: allowMacProviderKeys) else { continue }
            guard isSafeValue(value) else { throw Error.unsafeValue(key) }
            result[key] = value
        }
        return result
    }

    public static func isSafeValue(_ value: String) -> Bool {
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

    private static func isAllowedKey(_ key: String, allowMacProviderKeys: Bool) -> Bool {
        switch key {
        case "PATH", "HOME", "USER", "TMPDIR", "LANG", "NSUnbufferedIO":
            return true
        default:
            return key.hasPrefix("LC_") || (allowMacProviderKeys && key.hasPrefix("MACPROVIDER_"))
        }
    }
}
