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
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = InMemoryReceiptKeyStore(now: { currentDate })
        let first = try store.loadOrGenerate(providerId: "provider-a")
        try store.swapToCurrent(providerId: "provider-a", newKey: Curve25519.Signing.PrivateKey())

        XCTAssertEqual(
            store.previousKeyForTest(providerId: "provider-a")?.rawRepresentation,
            first.rawRepresentation
        )

        currentDate = currentDate.addingTimeInterval(KeychainReceiptKeyStore.previousRetention + 1)
        _ = try store.loadOrGenerate(providerId: "provider-a")

        XCTAssertNil(store.previousKeyForTest(providerId: "provider-a"))
    }

    func testKeychainBaseQueryMatchesSpec015Attributes() {
        let query = KeychainReceiptKeyStore.baseQuery(providerId: "provider-a")

        XCTAssertEqual(query[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.streamvc.macprovider.receipt-key")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "provider-a")
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as! CFString,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
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
