import Foundation
import Security

enum KeychainStore {
    private static let providerService = "tech.malibu.provider"

    static func saveProviderToken(providerID: String, token: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: providerService,
                    kSecAttrAccount as String: providerID
                ]
                SecItemDelete(query as CFDictionary)
                var attrs = query
                attrs[kSecValueData as String] = Data(token.utf8)
                attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let status = SecItemAdd(attrs as CFDictionary, nil)
                if status == errSecSuccess { cont.resume() }
                else { cont.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }
            }
        }
    }

    static func hasProviderToken() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: providerService,
                    kSecReturnAttributes as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var out: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &out)
                cont.resume(returning: status == errSecSuccess)
            }
        }
    }

    static func deleteAllAppItems() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                for service in ["tech.malibu.provider", "tech.malibu.receipt", "tech.malibu.auth"] {
                    let query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service
                    ]
                    SecItemDelete(query as CFDictionary)
                }
                cont.resume()
            }
        }
    }
}
