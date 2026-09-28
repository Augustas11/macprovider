import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class NativeMTPRevocationFeedTests: XCTestCase {
    func testAcceptsSignedFeedAndPersistsRecoverableAnchor() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let store = MemoryRevocationStore()
        let now = Self.date("2026-09-28T12:00:00Z")
        let tuples = [Self.digest("01"), Self.digest("02")]
        let feed = try feedData(generation: 7, signerKeyID: "native-mtp-revoker-v1", tuples: tuples, now: now)
        let state = try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: signature(for: feed, signer: signer, keyID: "native-mtp-revoker-v1"),
            pinnedSignerKeyID: "native-mtp-revoker-v1",
            verifier: verifier(signer: signer),
            store: store,
            now: now
        )

        XCTAssertEqual(state.source, .network)
        XCTAssertTrue(state.isRevoked(tupleSHA256: tuples[0]))
        XCTAssertFalse(state.isRevoked(tupleSHA256: Self.digest("ff")))
        XCTAssertEqual(store.anchor?.generation, 7)
        XCTAssertEqual(store.cachedFeed, feed)

        let recovered = try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "native-mtp-revoker-v1",
            store: store,
            now: now
        )
        XCTAssertEqual(recovered.source, .cache)
        XCTAssertEqual(recovered.feed.revokedAdmissionTupleSHA256, tuples)
    }

    func testRejectsDuplicateUnknownMissingAndMalformedFields() throws {
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(Data(#"{"schema_version":"macprovider.native-mtp-revocations.v1","schema_version":"macprovider.native-mtp-revocations.v1"}"#.utf8))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .duplicateKey("feed"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(json([
            "schema_version": NativeMTPRevocationFeed.schemaVersion,
            "generation": 1,
            "issued_at": "2026-09-28T12:00:00Z",
            "expires_at": "2026-09-28T13:00:00Z",
            "signer_key_id": "k",
            "revoked_admission_tuple_sha256": [],
            "extra": true,
        ]))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .unknownField("extra"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(json([
            "schema_version": NativeMTPRevocationFeed.schemaVersion,
            "generation": 1,
            "issued_at": "2026-09-28T12:00:00Z",
            "expires_at": "2026-09-28T13:00:00Z",
            "revoked_admission_tuple_sha256": [],
        ]))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .missingField("signer_key_id"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(json([
            "schema_version": NativeMTPRevocationFeed.schemaVersion,
            "generation": true,
            "issued_at": "2026-09-28T12:00:00Z",
            "expires_at": "2026-09-28T13:00:00Z",
            "signer_key_id": "k",
            "revoked_admission_tuple_sha256": [],
        ]))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidField("generation"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(Data("""
        {"schema_version":"macprovider.native-mtp-revocations.v1","generation":1e3,"issued_at":"2026-09-28T12:00:00Z","expires_at":"2026-09-28T13:00:00Z","signer_key_id":"k","revoked_admission_tuple_sha256":[]}
        """.utf8))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidField("generation"))
        }
        let exactLarge = try NativeMTPRevocationFeed.parse(Data("""
        {"schema_version":"macprovider.native-mtp-revocations.v1","generation":9007199254740993,"issued_at":"2026-09-28T12:00:00Z","expires_at":"2026-09-28T13:00:00Z","signer_key_id":"k","revoked_admission_tuple_sha256":[]}
        """.utf8))
        XCTAssertEqual(exactLarge.generation, 9_007_199_254_740_993)
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(json([
            "schema_version": NativeMTPRevocationFeed.schemaVersion,
            "generation": 1,
            "issued_at": "2026-09-28T12:00:00Z",
            "expires_at": "2026-09-28T13:00:00Z",
            "signer_key_id": "k",
            "revoked_admission_tuple_sha256": [Self.digest("02"), Self.digest("01")],
        ]))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidField("revoked_admission_tuple_sha256"))
        }
    }

    func testRejectsSignerMismatchBadSignatureFutureAndExpired() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let wrongSigner = Curve25519.Signing.PrivateKey()
        let store = MemoryRevocationStore()
        let now = Self.date("2026-09-28T12:00:00Z")
        let feed = try feedData(generation: 1, signerKeyID: "revoker-a", tuples: [], now: now)

        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: signature(for: feed, signer: signer, keyID: "revoker-a"),
            pinnedSignerKeyID: "revoker-b",
            verifier: verifier(signer: signer),
            store: store,
            now: now
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .signatureInvalid("unexpected_key_id"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: signature(for: feed, signer: wrongSigner, keyID: "revoker-a"),
            pinnedSignerKeyID: "revoker-a",
            verifier: verifier(signer: signer),
            store: store,
            now: now
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .signatureInvalid("verification_failed"))
        }
        let future = try feedData(generation: 1, signerKeyID: "revoker-a", tuples: [], now: now.addingTimeInterval(3600))
        XCTAssertThrowsError(try accept(future, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .futureIssued)
        }
        let expired = try feedData(
            generation: 1,
            signerKeyID: "revoker-a",
            tuples: [],
            now: now.addingTimeInterval(-7200),
            expiresAt: now.addingTimeInterval(-3600)
        )
        XCTAssertThrowsError(try accept(expired, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .expired)
        }
        let staleInitial = try feedData(
            generation: 1,
            signerKeyID: "revoker-a",
            tuples: [],
            now: now.addingTimeInterval(-16 * 60),
            expiresAt: now.addingTimeInterval(40 * 60)
        )
        XCTAssertThrowsError(try accept(staleInitial, signer: signer, store: MemoryRevocationStore(), now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .expired)
        }
    }

    func testRejectsRollbackReplayAndRevokedSetRegression() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let store = MemoryRevocationStore()
        let now = Self.date("2026-09-28T12:00:00Z")
        let firstTuple = Self.digest("01")
        let secondTuple = Self.digest("02")
        let initial = try feedData(generation: 5, signerKeyID: "revoker-a", tuples: [firstTuple], now: now)
        _ = try accept(initial, signer: signer, store: store, now: now)

        let rollback = try feedData(generation: 4, signerKeyID: "revoker-a", tuples: [firstTuple], now: now)
        XCTAssertThrowsError(try accept(rollback, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .rollback)
        }

        let sameGenerationChangedBody = try feedData(generation: 5, signerKeyID: "revoker-a", tuples: [firstTuple, secondTuple], now: now)
        XCTAssertThrowsError(try accept(sameGenerationChangedBody, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .rollback)
        }

        let regression = try feedData(generation: 6, signerKeyID: "revoker-a", tuples: [secondTuple], now: now)
        XCTAssertThrowsError(try accept(regression, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .revokedSetRegression)
        }

        let superset = try feedData(generation: 6, signerKeyID: "revoker-a", tuples: [firstTuple, secondTuple], now: now)
        XCTAssertNoThrow(try accept(superset, signer: signer, store: store, now: now))
    }

    func testFailsClosedOnCorruptMissingAndInterruptedCacheState() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let now = Self.date("2026-09-28T12:00:00Z")
        let tuple = Self.digest("01")
        let store = MemoryRevocationStore()
        let feed = try feedData(generation: 2, signerKeyID: "revoker-a", tuples: [tuple], now: now)
        _ = try accept(feed, signer: signer, store: store, now: now)

        store.cachedFeed = nil
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.loadCached(pinnedSignerKeyID: "revoker-a", store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .missingFeed)
        }

        store.cachedFeed = Data("not-json".utf8)
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.loadCached(pinnedSignerKeyID: "revoker-a", store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidJSON("feed"))
        }

        store.cachedFeed = feed
        store.anchor = NativeMTPRevocationAnchor(
            generation: 3,
            bodySHA256: "bad",
            revokedSetSHA256: "bad"
        )
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.loadCached(pinnedSignerKeyID: "revoker-a", store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .anchorMismatch)
        }
    }

    func testFileStoreCommitsAndRecoversTupleScopedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-mtp-revocation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = Curve25519.Signing.PrivateKey()
        let store = FileNativeMTPRevocationStore(directory: root)
        let now = Self.date("2026-09-28T12:00:00Z")
        let tuple = Self.digest("aa")
        let otherTuple = Self.digest("bb")
        let feed = try feedData(generation: 11, signerKeyID: "revoker.file", tuples: [tuple], now: now)

        _ = try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: signature(for: feed, signer: signer, keyID: "revoker.file"),
            pinnedSignerKeyID: "revoker.file",
            verifier: verifier(signer: signer),
            store: store,
            now: now
        )
        let recovered = try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "revoker.file",
            store: store,
            now: now
        )

        XCTAssertTrue(recovered.isRevoked(tupleSHA256: tuple))
        XCTAssertFalse(recovered.isRevoked(tupleSHA256: otherTuple))
    }

    private static func accept(
        _ feed: Data,
        signer: Curve25519.Signing.PrivateKey,
        store: MemoryRevocationStore,
        now: Date
    ) throws -> NativeMTPRevocationState {
        try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: signature(for: feed, signer: signer, keyID: "revoker-a"),
            pinnedSignerKeyID: "revoker-a",
            verifier: verifier(signer: signer),
            store: store,
            now: now
        )
    }

    private static func feedData(
        generation: UInt64,
        signerKeyID: String,
        tuples: [String],
        now: Date,
        expiresAt: Date? = nil
    ) throws -> Data {
        try json([
            "schema_version": NativeMTPRevocationFeed.schemaVersion,
            "generation": generation,
            "issued_at": iso8601.string(from: now),
            "expires_at": iso8601.string(from: expiresAt ?? now.addingTimeInterval(3600)),
            "signer_key_id": signerKeyID,
            "revoked_admission_tuple_sha256": tuples.sorted(),
        ])
    }

    private static func signature(for payload: Data, signer: Curve25519.Signing.PrivateKey, keyID: String) -> Data {
        let signature = try! signer.signature(for: payload).base64EncodedString()
        return try! json([
            "key_id": keyID,
            "alg": "ed25519",
            "signature": signature,
        ])
    }

    private static func verifier(signer: Curve25519.Signing.PrivateKey) -> NativeMTPRevocationEd25519Verifier {
        NativeMTPRevocationEd25519Verifier(publicKeysByKeyID: [
            "native-mtp-revoker-v1": signer.publicKey.rawRepresentation.base64EncodedString(),
            "revoker-a": signer.publicKey.rawRepresentation.base64EncodedString(),
            "revoker.file": signer.publicKey.rawRepresentation.base64EncodedString(),
        ])
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func digest(_ suffix: String) -> String {
        String(repeating: "0", count: 64 - suffix.count) + suffix
    }

    private static func date(_ value: String) -> Date {
        iso8601.date(from: value)!
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private final class MemoryRevocationStore: NativeMTPRevocationStore, @unchecked Sendable {
    var anchor: NativeMTPRevocationAnchor?
    var cachedFeed: Data?

    func loadAnchor(signerKeyID: String) throws -> NativeMTPRevocationAnchor? {
        anchor
    }

    func loadCachedFeed(signerKeyID: String) throws -> Data? {
        cachedFeed
    }

    func commitAcceptedFeed(_ feedData: Data, anchor: NativeMTPRevocationAnchor, signerKeyID: String) throws {
        cachedFeed = feedData
        self.anchor = anchor
    }
}
