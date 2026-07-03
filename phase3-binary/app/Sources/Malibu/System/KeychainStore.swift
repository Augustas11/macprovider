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
                // AUDIT R1 SECURITY S5 fix: tighten from AfterFirstUnlock →
                // WhenUnlocked. The menu-bar app only runs while the user is
                // logged in, so a payout-bearing token stays behind the current
                // unlock session instead of any-unlock-after-boot.
                attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let status = SecItemAdd(attrs as CFDictionary, nil)
                if status == errSecSuccess { cont.resume() }
                else { cont.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }
            }
        }
    }

    static func readProviderToken(providerID: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: providerService,
                    kSecAttrAccount as String: providerID,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var out: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &out)
                guard status == errSecSuccess, let data = out as? Data else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    // AUDIT R1 CODE M2 / SECURITY S3 fix: delete synchronously (awaited by caller)
    // so uninstall can report residue instead of racing against NSApp.terminate.
    // Any non-noop non-notFound OSStatus is surfaced so the caller can decide.
    static func deleteAllAppItems() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                var firstError: NSError?
                for service in ["tech.malibu.provider", "tech.malibu.receipt", "tech.malibu.auth"] {
                    let query: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: service
                    ]
                    let status = SecItemDelete(query as CFDictionary)
                    if status != errSecSuccess && status != errSecItemNotFound && firstError == nil {
                        firstError = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                    }
                }
                if let err = firstError { cont.resume(throwing: err) }
                else { cont.resume() }
            }
        }
    }
}
