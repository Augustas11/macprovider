import Foundation
import Security

enum ConnectedBuyerKeychain {
    static let service = "tech.malibu.connected-apps"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "buyer"]
    }
    static func save(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4096,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw ConnectedAppsError.credential
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = query.merging(attributes) { _, new in new }
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw ConnectedAppsError.credential }
        } else if status != errSecSuccess { throw ConnectedAppsError.credential }
    }
    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw ConnectedAppsError.credential
        }
        return key
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectedAppsError.credential }
    }
}
