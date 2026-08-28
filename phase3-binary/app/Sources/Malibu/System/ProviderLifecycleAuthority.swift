import Foundation

enum ProviderLifecycleAuthority {
    static let current = "malibu_cli"
    static let legacy = "macprovider_cli"

    static func isAccepted(_ value: String?) -> Bool {
        value == current || value == legacy
    }
}
