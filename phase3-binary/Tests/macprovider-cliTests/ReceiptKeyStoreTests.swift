import CryptoKit
import Foundation
import Security
import XCTest
@testable import macprovider_cli

final class ReceiptKeyStoreTests: XCTestCase {
    func testFirstLaunchGeneratesAndSecondLaunchLoadsSamePrivateKey() throws {
        let store = InMemoryReceiptKeyStore()

        let first = try store.loadOrGenerate(providerId: "provider-a")
        let second = try store.loadOrGenerate(providerId: "provider-a")

        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
    }

    func testDifferentProviderIDsProduceDifferentKeypairs() throws {
        let store = InMemoryReceiptKeyStore()

        let first = try store.loadOrGenerate(providerId: "provider-a")
        let second = try store.loadOrGenerate(providerId: "provider-b")

        XCTAssertNotEqual(first.rawRepresentation, second.rawRepresentation)
    }

    func testKeychainFirstLaunchGeneratesAndFreshLaunchLoadsSamePrivateKey() throws {
        let providerId = "spec015-keychain-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }

        let firstLaunchStore = KeychainReceiptKeyStore()
        let first: Curve25519.Signing.PrivateKey
        do {
            first = try firstLaunchStore.loadOrGenerate(providerId: providerId)
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain receipt-key lookup with errSecParam; CI must run this test without skipping")
        }

        let freshLaunchStore = KeychainReceiptKeyStore()
        let second = try freshLaunchStore.loadOrGenerate(providerId: providerId)
        let loaded = try freshLaunchStore.loadCurrent(providerId: providerId)

        XCTAssertEqual(first.rawRepresentation, second.rawRepresentation)
        XCTAssertEqual(first.rawRepresentation, loaded?.rawRepresentation)
        XCTAssertEqual(first.publicKey.rawRepresentation, second.publicKey.rawRepresentation)
    }

    func testStoreNewRejectsDuplicateCurrentKey() throws {
        let store = InMemoryReceiptKeyStore()
        let key = Curve25519.Signing.PrivateKey()
        try store.storeNew(providerId: "provider-a", privateKey: key)

        XCTAssertThrowsError(try store.storeNew(
            providerId: "provider-a",
            privateKey: Curve25519.Signing.PrivateKey()
        )) { error in
            XCTAssertEqual(
                error as? ReceiptKeyStoreError,
                .duplicateCurrentKey(providerId: "provider-a")
            )
        }
    }

    func testConcurrentLoadOrGenerateConvergesToOneFinalStoredKey() throws {
        let store = InMemoryReceiptKeyStore()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "receipt-key-race", attributes: .concurrent)
        let resultLock = NSLock()
        var results: [Data] = []
        var errors: [Error] = []

        for _ in 0..<2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let key = try store.loadOrGenerate(providerId: "provider-a")
                    resultLock.lock()
                    results.append(key.rawRepresentation)
                    resultLock.unlock()
                } catch {
                    resultLock.lock()
                    errors.append(error)
                    resultLock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results).count, 1)
        XCTAssertEqual(results.first, try store.loadCurrent(providerId: "provider-a")?.rawRepresentation)
    }

    func testSwapToCurrentMovesPriorKeyToPreviousSlot() throws {
        let store = InMemoryReceiptKeyStore()
        let first = try store.loadOrGenerate(providerId: "provider-a")
        let replacement = Curve25519.Signing.PrivateKey()

        try store.swapToCurrent(providerId: "provider-a", newKey: replacement)

        XCTAssertEqual(
            try store.loadCurrent(providerId: "provider-a")?.rawRepresentation,
            replacement.rawRepresentation
        )
        XCTAssertEqual(
            store.previousKeyForTest(providerId: "provider-a")?.rawRepresentation,
            first.rawRepresentation
        )
    }

    func testSwapToCurrentRequiresExistingCurrentKey() {
        let store = InMemoryReceiptKeyStore()

        XCTAssertThrowsError(try store.swapToCurrent(
            providerId: "provider-a",
            newKey: Curve25519.Signing.PrivateKey()
        )) { error in
            XCTAssertEqual(
                error as? ReceiptKeyStoreError,
                .missingCurrentKey(providerId: "provider-a")
            )
        }
    }

    func testLoadOrGenerateDeletesPreviousKeyOlderThanSevenDays() throws {
        let clock = ReceiptTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = InMemoryReceiptKeyStore(now: { @Sendable in clock.now() })
        let first = try store.loadOrGenerate(providerId: "provider-a")
        try store.swapToCurrent(providerId: "provider-a", newKey: Curve25519.Signing.PrivateKey())

        XCTAssertEqual(
            store.previousKeyForTest(providerId: "provider-a")?.rawRepresentation,
            first.rawRepresentation
        )

        clock.advance(by: KeychainReceiptKeyStore.previousRetention + 1)
        _ = try store.loadOrGenerate(providerId: "provider-a")

        XCTAssertNil(store.previousKeyForTest(providerId: "provider-a"))
    }

    func testKeychainBaseQueryMatchesSpec015Attributes() {
        let query = KeychainReceiptKeyStore.baseQuery(providerId: "provider-a")

        XCTAssertEqual(query[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.streamvc.macprovider.receipt-key")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "provider-a")
        XCTAssertNil(query[kSecAttrAccessible as String])
        XCTAssertNil(query[kSecAttrSynchronizable as String])
    }

    func testKeychainAddQueryMatchesSpec015AttributesAndStoresRawPrivateKey() {
        let key = Curve25519.Signing.PrivateKey()
        let query = KeychainReceiptKeyStore.addQuery(providerId: "provider-a", privateKey: key)

        XCTAssertEqual(query[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.streamvc.macprovider.receipt-key")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "provider-a")
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as! CFString,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecValueData as String] as? Data, key.rawRepresentation)
        XCTAssertEqual(key.rawRepresentation.count, 32)
    }
}

private final class ReceiptTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private func cleanupKeychainReceiptKeys(providerId: String) {
    _ = SecItemDelete(KeychainReceiptKeyStore.baseQuery(
        providerId: providerId,
        service: KeychainReceiptKeyStore.currentService
    ) as CFDictionary)
    _ = SecItemDelete(KeychainReceiptKeyStore.baseQuery(
        providerId: providerId,
        service: KeychainReceiptKeyStore.previousService
    ) as CFDictionary)
}
