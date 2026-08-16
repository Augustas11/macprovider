import CryptoKit
import Foundation
import LocalAuthentication
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

    func testBootstrapIdentityRemainsStableAcrossReceiptRotation() throws {
        let providerId = "bootstrap-identity-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }
        let store = KeychainReceiptKeyStore()
        let first: Curve25519.Signing.PrivateKey
        do {
            first = try store.loadOrGenerate(providerId: providerId)
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain receipt-key lookup with errSecParam; CI must run this test without skipping")
        }
        let identity = try store.loadOrStoreBootstrapIdentity(providerId: providerId, candidate: first)
        let replacement = Curve25519.Signing.PrivateKey()
        try store.swapToCurrent(providerId: providerId, newKey: replacement)

        XCTAssertEqual(try store.loadCurrent(providerId: providerId)?.rawRepresentation, replacement.rawRepresentation)
        XCTAssertEqual(try store.loadBootstrapIdentity(providerId: providerId)?.rawRepresentation, identity.rawRepresentation)
        XCTAssertEqual(identity.rawRepresentation, first.rawRepresentation)
    }

    func testAdmissionIdentityUsesLegacySlotAndRemainsStableForLegacyProviderID() throws {
        let providerId = "augustass-macbook-air-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }
        let store = KeychainReceiptKeyStore()
        let candidate = Curve25519.Signing.PrivateKey()
        let identity: Curve25519.Signing.PrivateKey
        do {
            identity = try store.loadOrStoreAdmissionIdentity(providerId: providerId, candidate: candidate)
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain admission-key lookup with errSecParam; CI must run this test without skipping")
        }
        let losingCandidate = Curve25519.Signing.PrivateKey()

        XCTAssertEqual(
            try store.loadOrStoreAdmissionIdentity(providerId: providerId, candidate: losingCandidate).rawRepresentation,
            identity.rawRepresentation
        )
        XCTAssertEqual(
            try store.loadBootstrapIdentity(providerId: providerId)?.rawRepresentation,
            identity.rawRepresentation
        )
        XCTAssertEqual(KeychainReceiptKeyStore.admissionIdentityService, KeychainReceiptKeyStore.bootstrapIdentityService)
    }

    func testAdmissionIdentityRotationStagesOnceAndCommitsNamedCandidate() throws {
        let providerId = "admission-rotation-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }
        let store = KeychainReceiptKeyStore()
        let original = Curve25519.Signing.PrivateKey()
        do {
            _ = try store.loadOrStoreAdmissionIdentity(providerId: providerId, candidate: original)
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain admission-key lookup with errSecParam; CI must run this test without skipping")
        }

        let pending = try store.beginAdmissionIdentityRotation(providerId: providerId)
        let repeated = try store.beginAdmissionIdentityRotation(providerId: providerId)
        XCTAssertEqual(pending.rawRepresentation, repeated.rawRepresentation)
        let previousValidUntil = Date().addingTimeInterval(60)

        let committed = try store.commitAdmissionIdentityRotation(
            providerId: providerId,
            expectedPublicKey: pending.publicKey.rawRepresentation,
            previousValidUntil: previousValidUntil
        )
        XCTAssertEqual(committed.rawRepresentation, pending.rawRepresentation)
        XCTAssertEqual(try store.loadAdmissionIdentity(providerId: providerId)?.rawRepresentation, pending.rawRepresentation)
        XCTAssertEqual(try store.loadPreviousAdmissionIdentity(providerId: providerId)?.rawRepresentation, original.rawRepresentation)
        XCTAssertNil(try store.loadPendingAdmissionIdentity(providerId: providerId))

        let idempotent = try store.commitAdmissionIdentityRotation(
            providerId: providerId,
            expectedPublicKey: pending.publicKey.rawRepresentation,
            previousValidUntil: previousValidUntil
        )
        XCTAssertEqual(idempotent.rawRepresentation, pending.rawRepresentation)

        let afterGrace = previousValidUntil.addingTimeInterval(1)
        let futureStore = KeychainReceiptKeyStore(now: { afterGrace })
        XCTAssertNil(try futureStore.loadPreviousAdmissionIdentity(providerId: providerId))
    }

    func testAdmissionIdentityRotationRefusesUnknownCoordinatorCandidate() throws {
        let providerId = "admission-rotation-mismatch-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }
        let store = KeychainReceiptKeyStore()
        do {
            _ = try store.loadOrStoreAdmissionIdentity(
                providerId: providerId,
                candidate: Curve25519.Signing.PrivateKey()
            )
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain admission-key lookup with errSecParam; CI must run this test without skipping")
        }
        let pending = try store.beginAdmissionIdentityRotation(providerId: providerId)

        XCTAssertThrowsError(try store.commitAdmissionIdentityRotation(
            providerId: providerId,
            expectedPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            previousValidUntil: Date().addingTimeInterval(60)
        )) { error in
            XCTAssertEqual(
                error as? ReceiptKeyStoreError,
                .admissionIdentityCandidateMismatch(providerId: providerId)
            )
        }
        XCTAssertEqual(try store.loadPendingAdmissionIdentity(providerId: providerId)?.rawRepresentation, pending.rawRepresentation)
    }

    func testAdmissionIdentityRotationDoesNotRetainPreviousKeyAfterAuthoritativeGraceExpired() throws {
        let providerId = "admission-rotation-expired-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }
        let now = Date(timeIntervalSince1970: 1_784_025_600)
        let store = KeychainReceiptKeyStore(now: { now })
        let original = Curve25519.Signing.PrivateKey()
        do {
            _ = try store.loadOrStoreAdmissionIdentity(providerId: providerId, candidate: original)
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain admission-key lookup with errSecParam; CI must run this test without skipping")
        }
        let pending = try store.beginAdmissionIdentityRotation(providerId: providerId)

        _ = try store.commitAdmissionIdentityRotation(
            providerId: providerId,
            expectedPublicKey: pending.publicKey.rawRepresentation,
            previousValidUntil: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(
            try store.loadAdmissionIdentity(providerId: providerId)?.rawRepresentation,
            pending.rawRepresentation
        )
        XCTAssertNil(try store.loadPreviousAdmissionIdentityState(providerId: providerId))
    }

    func testAdmissionIdentityRecoveryStagesWithoutCurrentAndCommitsExactCandidate() throws {
        let providerId = "admission-recovery-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }
        let store = KeychainReceiptKeyStore()
        let pending: Curve25519.Signing.PrivateKey
        do {
            pending = try store.beginAdmissionIdentityRecovery(providerId: providerId)
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain recovery-key lookup with errSecParam; CI must run this test without skipping")
        }
        XCTAssertEqual(
            try store.beginAdmissionIdentityRecovery(providerId: providerId).rawRepresentation,
            pending.rawRepresentation
        )
        XCTAssertNil(try store.loadAdmissionIdentity(providerId: providerId))

        let committed = try store.commitAdmissionIdentityRecovery(
            providerId: providerId,
            expectedPublicKey: pending.publicKey.rawRepresentation
        )
        XCTAssertEqual(committed.rawRepresentation, pending.rawRepresentation)
        XCTAssertEqual(
            try store.loadAdmissionIdentity(providerId: providerId)?.rawRepresentation,
            pending.rawRepresentation
        )
        XCTAssertNil(try store.loadPendingAdmissionIdentity(providerId: providerId))
        XCTAssertNil(try store.loadPreviousAdmissionIdentity(providerId: providerId))
        XCTAssertThrowsError(try store.beginAdmissionIdentityRecovery(providerId: providerId)) { error in
            XCTAssertEqual(
                error as? ReceiptKeyStoreError,
                .admissionIdentityRecoveryNotRequired(providerId: providerId)
            )
        }
    }

    func testAdmissionIdentityRecoveryMarkerPersistsAndFencesRotationUntilCommit() throws {
        let providerId = "admission-recovery-marker-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }
        let store = KeychainReceiptKeyStore()
        let current = Curve25519.Signing.PrivateKey()
        do {
            _ = try store.loadOrStoreAdmissionIdentity(providerId: providerId, candidate: current)
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain recovery-marker lookup with errSecParam; CI must run this test without skipping")
        }

        let candidate = try store.beginAdmissionIdentityRecovery(
            providerId: providerId,
            allowExistingCurrent: true
        )
        let freshStore = KeychainReceiptKeyStore()
        XCTAssertTrue(try freshStore.isAdmissionIdentityRecoveryPending(
            providerId: providerId,
            candidatePublicKey: candidate.publicKey.rawRepresentation
        ))
        XCTAssertThrowsError(try freshStore.beginAdmissionIdentityRotation(providerId: providerId)) { error in
            XCTAssertEqual(
                error as? ReceiptKeyStoreError,
                .admissionIdentityRecoveryInProgress(providerId: providerId)
            )
        }

        _ = try freshStore.commitAdmissionIdentityRecovery(
            providerId: providerId,
            expectedPublicKey: candidate.publicKey.rawRepresentation
        )
        XCTAssertFalse(try freshStore.isAdmissionIdentityRecoveryPending(
            providerId: providerId,
            candidatePublicKey: candidate.publicKey.rawRepresentation
        ))
    }

    func testAdmissionIdentityRecoveryRetriesAfterInterruptionBetweenPendingKeyAndMarker() throws {
        let providerId = "admission-recovery-interruption-" + UUID().uuidString
        cleanupKeychainReceiptKeys(providerId: providerId)
        defer { cleanupKeychainReceiptKeys(providerId: providerId) }
        let store = KeychainReceiptKeyStore()
        let current = Curve25519.Signing.PrivateKey()
        do {
            _ = try store.loadOrStoreAdmissionIdentity(providerId: providerId, candidate: current)
        } catch ReceiptKeyStoreError.keychainReadFailed(_, let status) where status == errSecParam && ProcessInfo.processInfo.environment["CI"] != "true" {
            throw XCTSkip("local sandbox denied Keychain recovery-interruption lookup with errSecParam; CI must run this test without skipping")
        }

        enum SimulatedInterruption: Error { case afterPendingPersisted }
        XCTAssertThrowsError(try store.beginAdmissionIdentityRecovery(
            providerId: providerId,
            allowExistingCurrent: true,
            afterPendingPersisted: { _ in throw SimulatedInterruption.afterPendingPersisted }
        )) { error in
            XCTAssertTrue(error is SimulatedInterruption)
        }

        let pending = try XCTUnwrap(store.loadPendingAdmissionIdentity(providerId: providerId))
        XCTAssertNil(try store.loadAdmissionIdentityRecoveryMarker(providerId: providerId))
        XCTAssertEqual(
            AdmissionIdentityStartupTopology.resolve(
                currentPublicKey: current.publicKey.rawRepresentation,
                pendingPublicKey: pending.publicKey.rawRepresentation,
                recoveryMarkerPublicKey: nil
            ),
            .rotationPending
        )

        var retryCallbackPublicKey: Data?
        let retried = try store.beginAdmissionIdentityRecovery(
            providerId: providerId,
            allowExistingCurrent: true,
            afterPendingPersisted: { candidate in
                retryCallbackPublicKey = candidate.publicKey.rawRepresentation
            }
        )
        XCTAssertEqual(retried.rawRepresentation, pending.rawRepresentation)
        XCTAssertEqual(retryCallbackPublicKey, pending.publicKey.rawRepresentation)
        XCTAssertEqual(
            try store.loadAdmissionIdentityRecoveryMarker(providerId: providerId),
            pending.publicKey.rawRepresentation
        )
        XCTAssertEqual(
            AdmissionIdentityStartupTopology.resolve(
                currentPublicKey: current.publicKey.rawRepresentation,
                pendingPublicKey: pending.publicKey.rawRepresentation,
                recoveryMarkerPublicKey: pending.publicKey.rawRepresentation
            ),
            .recoveryPending
        )
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

    func testKeychainBaseQueryMatchesSpec015Attributes() throws {
        let query = KeychainReceiptKeyStore.baseQuery(providerId: "provider-a")

        XCTAssertEqual(query[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.malibu.provider.receipt-key")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "provider-a")
        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertNil(query[kSecAttrAccessible as String])
        XCTAssertNil(query[kSecAttrSynchronizable as String])
    }

    func testKeychainAddQueryMatchesSpec015AttributesAndStoresRawPrivateKey() {
        let key = Curve25519.Signing.PrivateKey()
        let query = KeychainReceiptKeyStore.addQuery(providerId: "provider-a", privateKey: key)

        XCTAssertEqual(query[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.malibu.provider.receipt-key")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "provider-a")
        let context = try! XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)
        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertNil(query[kSecAttrAccessible as String])
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
    _ = SecItemDelete(KeychainReceiptKeyStore.baseQuery(
        providerId: providerId,
        service: KeychainReceiptKeyStore.bootstrapIdentityService
    ) as CFDictionary)
    _ = SecItemDelete(KeychainReceiptKeyStore.baseQuery(
        providerId: providerId,
        service: KeychainReceiptKeyStore.pendingAdmissionIdentityService
    ) as CFDictionary)
    _ = SecItemDelete(KeychainReceiptKeyStore.baseQuery(
        providerId: providerId,
        service: KeychainReceiptKeyStore.previousAdmissionIdentityService
    ) as CFDictionary)
    _ = SecItemDelete(KeychainReceiptKeyStore.baseQuery(
        providerId: providerId,
        service: KeychainReceiptKeyStore.previousAdmissionIdentityValidUntilService
    ) as CFDictionary)
    _ = SecItemDelete(KeychainReceiptKeyStore.baseQuery(
        providerId: providerId,
        service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService
    ) as CFDictionary)
}
