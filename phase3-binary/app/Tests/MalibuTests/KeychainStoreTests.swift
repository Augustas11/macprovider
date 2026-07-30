import Security
import XCTest
@testable import Malibu

final class KeychainStoreTests: XCTestCase {
    func testDeleteAllAppItemsPreservesReceiptService() async throws {
        let account = "receipt-test-\(UUID().uuidString)"
        try delete(service: "tech.malibu.receipt", account: account)
        try add(service: "tech.malibu.receipt", account: account, value: "receipt-secret")
        defer { try? delete(service: "tech.malibu.receipt", account: account) }

        do {
            try await KeychainStore.deleteAllAppItems()
        } catch {
            throw XCTSkip("Keychain unavailable in this test host: \(error.localizedDescription)")
        }

        XCTAssertEqual(try read(service: "tech.malibu.receipt", account: account), "receipt-secret")
    }

    private func add(service: String, account: String, value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(data: data, encoding: .utf8)
    }

    private func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
