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
        let feed = try Self.feedData(generation: 7, signerKeyID: "native-mtp-revoker-v1", tuples: tuples, now: now)
        let state = try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: Self.signature(for: feed, signer: signer, keyID: "native-mtp-revoker-v1"),
            pinnedSignerKeyID: "native-mtp-revoker-v1",
            verifier: Self.verifier(signer: signer),
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
            verifier: Self.verifier(signer: signer),
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
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(Self.json([
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
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(Self.json([
            "schema_version": NativeMTPRevocationFeed.schemaVersion,
            "generation": 1,
            "issued_at": "2026-09-28T12:00:00Z",
            "expires_at": "2026-09-28T13:00:00Z",
            "revoked_admission_tuple_sha256": [],
        ]))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .missingField("signer_key_id"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(Self.json([
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
        XCTAssertEqual(exactLarge.generation, UInt64(9_007_199_254_740_993))
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(Self.json([
            "schema_version": NativeMTPRevocationFeed.schemaVersion,
            "generation": 1,
            "issued_at": "2026-09-28T12:00:00Z",
            "expires_at": "2026-09-28T13:00:00Z",
            "signer_key_id": "k",
            "revoked_admission_tuple_sha256": [Self.digest("02"), Self.digest("01")],
        ]))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidField("revoked_admission_tuple_sha256"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(Data("""
        {"schema_version":"macprovider.native-mtp-revocations.v1","generation":1,"issued_at":"2026-09-28T12:00:00.000Z","expires_at":"2026-09-28T13:00:00Z","signer_key_id":"k","revoked_admission_tuple_sha256":[]}
        """.utf8))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidField("issued_at"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeed.parse(Data("""
        {"schema_version":"macprovider.native-mtp-revocations.v1","generation":1,"issued_at":"2026-09-28T12:00:00+00:00","expires_at":"2026-09-28T13:00:00Z","signer_key_id":"k","revoked_admission_tuple_sha256":[]}
        """.utf8))) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidField("issued_at"))
        }
    }

    func testRejectsSignerMismatchBadSignatureFutureAndExpired() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let wrongSigner = Curve25519.Signing.PrivateKey()
        let store = MemoryRevocationStore()
        let now = Self.date("2026-09-28T12:00:00Z")
        let feed = try Self.feedData(generation: 1, signerKeyID: "revoker-a", tuples: [], now: now)

        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: Self.signature(for: feed, signer: signer, keyID: "revoker-a"),
            pinnedSignerKeyID: "revoker-b",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .signatureInvalid("unexpected_key_id"))
        }
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: Self.signature(for: feed, signer: wrongSigner, keyID: "revoker-a"),
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .signatureInvalid("verification_failed"))
        }
        let future = try Self.feedData(generation: 1, signerKeyID: "revoker-a", tuples: [], now: now.addingTimeInterval(3600))
        XCTAssertThrowsError(try Self.accept(future, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .futureIssued)
        }
        let expired = try Self.feedData(
            generation: 1,
            signerKeyID: "revoker-a",
            tuples: [],
            now: now.addingTimeInterval(-7200),
            expiresAt: now.addingTimeInterval(-3600)
        )
        XCTAssertThrowsError(try Self.accept(expired, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .expired)
        }
        let staleInitial = try Self.feedData(
            generation: 1,
            signerKeyID: "revoker-a",
            tuples: [],
            now: now.addingTimeInterval(-16 * 60),
            expiresAt: now.addingTimeInterval(40 * 60)
        )
        XCTAssertThrowsError(try Self.accept(staleInitial, signer: signer, store: MemoryRevocationStore(), now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .expired)
        }
    }

    func testRejectsRollbackReplayAndRevokedSetRegression() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let store = MemoryRevocationStore()
        let now = Self.date("2026-09-28T12:00:00Z")
        let firstTuple = Self.digest("01")
        let secondTuple = Self.digest("02")
        let initial = try Self.feedData(generation: 5, signerKeyID: "revoker-a", tuples: [firstTuple], now: now)
        _ = try Self.accept(initial, signer: signer, store: store, now: now)

        let rollback = try Self.feedData(generation: 4, signerKeyID: "revoker-a", tuples: [firstTuple], now: now)
        XCTAssertThrowsError(try Self.accept(rollback, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .rollback)
        }

        let sameGenerationChangedBody = try Self.feedData(generation: 5, signerKeyID: "revoker-a", tuples: [firstTuple, secondTuple], now: now)
        XCTAssertThrowsError(try Self.accept(sameGenerationChangedBody, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .rollback)
        }

        let regression = try Self.feedData(generation: 6, signerKeyID: "revoker-a", tuples: [secondTuple], now: now)
        XCTAssertThrowsError(try Self.accept(regression, signer: signer, store: store, now: now)) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .revokedSetRegression)
        }

        let superset = try Self.feedData(generation: 6, signerKeyID: "revoker-a", tuples: [firstTuple, secondTuple], now: now)
        XCTAssertNoThrow(try Self.accept(superset, signer: signer, store: store, now: now))
    }

    func testFailsClosedOnCorruptMissingAndInterruptedCacheState() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let now = Self.date("2026-09-28T12:00:00Z")
        let tuple = Self.digest("01")
        let store = MemoryRevocationStore()
        let feed = try Self.feedData(generation: 2, signerKeyID: "revoker-a", tuples: [tuple], now: now)
        _ = try Self.accept(feed, signer: signer, store: store, now: now)

        store.cachedFeed = nil
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .missingFeed)
        }

        store.cachedFeed = Data("not-json".utf8)
        store.cachedSignature = Self.signature(for: store.cachedFeed!, signer: signer, keyID: "revoker-a")
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidJSON("feed"))
        }

        store.cachedFeed = feed
        store.anchor = NativeMTPRevocationAnchor(
            generation: 3,
            bodySHA256: "bad",
            revokedSetSHA256: "bad"
        )
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .anchorMismatch)
        }

        let regressionStore = MemoryRevocationStore()
        let priorWithTwo = try Self.feedData(
            generation: 7,
            signerKeyID: "revoker-a",
            tuples: [Self.digest("01"), Self.digest("02")],
            now: now
        )
        _ = try Self.accept(priorWithTwo, signer: signer, store: regressionStore, now: now)
        let priorRegressionFeed = regressionStore.cachedFeed
        let priorRegressionSignature = regressionStore.cachedSignature
        let priorRegressionAnchor = regressionStore.cacheAnchor
        let regressingAhead = try Self.feedData(
            generation: 8,
            signerKeyID: "revoker-a",
            tuples: [Self.digest("02")],
            now: now
        )
        regressionStore.cachedFeed = regressingAhead
        regressionStore.cachedSignature = Self.signature(for: regressingAhead, signer: signer, keyID: "revoker-a")
        regressionStore.cacheAnchor = NativeMTPRevocationAnchor(
            generation: 8,
            bodySHA256: NativeMTPRevocationFeed.sha256Hex(regressingAhead),
            revokedSetSHA256: try NativeMTPRevocationFeed.parse(regressingAhead).revokedSetSHA256
        )
        regressionStore.priorCachedFeed = priorRegressionFeed
        regressionStore.priorCachedSignature = priorRegressionSignature
        regressionStore.priorCacheAnchor = priorRegressionAnchor
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: regressionStore,
            now: now
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .revokedSetRegression)
        }
    }

    func testSignedCacheAheadCompletesInterruptedAnchorUpdateAndAnchorAheadFails() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let now = Self.date("2026-09-28T12:00:00Z")
        let store = MemoryRevocationStore()
        let oldFeed = try Self.feedData(generation: 1, signerKeyID: "revoker-a", tuples: [Self.digest("01")], now: now)
        _ = try Self.accept(oldFeed, signer: signer, store: store, now: now)
        let priorFeed = store.cachedFeed
        let priorSignature = store.cachedSignature
        let priorAnchor = store.cacheAnchor

        let aheadFeed = try Self.feedData(generation: 2, signerKeyID: "revoker-a", tuples: [Self.digest("01"), Self.digest("02")], now: now)
        let aheadAnchor = NativeMTPRevocationAnchor(
            generation: 2,
            bodySHA256: NativeMTPRevocationFeed.sha256Hex(aheadFeed),
            revokedSetSHA256: try NativeMTPRevocationFeed.parse(aheadFeed).revokedSetSHA256
        )
        store.cachedFeed = aheadFeed
        store.cachedSignature = Self.signature(for: aheadFeed, signer: signer, keyID: "revoker-a")
        store.cacheAnchor = aheadAnchor
        store.priorCachedFeed = priorFeed
        store.priorCachedSignature = priorSignature
        store.priorCacheAnchor = priorAnchor

        let recovered = try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )
        XCTAssertEqual(recovered.feed.generation, 2)
        XCTAssertEqual(store.anchor?.generation, 2)

        let behindFeed = oldFeed
        store.cachedFeed = behindFeed
        store.cachedSignature = Self.signature(for: behindFeed, signer: signer, keyID: "revoker-a")
        store.cacheAnchor = NativeMTPRevocationAnchor(
            generation: 1,
            bodySHA256: NativeMTPRevocationFeed.sha256Hex(behindFeed),
            revokedSetSHA256: try NativeMTPRevocationFeed.parse(behindFeed).revokedSetSHA256
        )
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )) {
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
        let feed = try Self.feedData(generation: 11, signerKeyID: "revoker.file", tuples: [tuple], now: now)

        _ = try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: Self.signature(for: feed, signer: signer, keyID: "revoker.file"),
            pinnedSignerKeyID: "revoker.file",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )
        let recovered = try NativeMTPRevocationFeedManager.loadCached(
            pinnedSignerKeyID: "revoker.file",
            verifier: Self.verifier(signer: signer),
            store: store,
            now: now
        )

        XCTAssertTrue(recovered.isRevoked(tupleSHA256: tuple))
        XCTAssertFalse(recovered.isRevoked(tupleSHA256: otherTuple))
    }

    func testNetworkURLConstructionUsesCanonicalOperatorOriginAndKeyQualifiedNames() throws {
        let urls = try NativeMTPRevocationFeedManager.feedURLs(pinnedSignerKeyID: "revoker-a")

        XCTAssertEqual(
            urls.feed.absoluteString,
            "https://coordinator.malibu.tech/v1/native-mtp-revocations.revoker-a.json"
        )
        XCTAssertEqual(
            urls.signature.absoluteString,
            "https://coordinator.malibu.tech/v1/native-mtp-revocations.revoker-a.json.sig"
        )
        let encoded = try NativeMTPRevocationFeedManager.feedURLs(
            pinnedSignerKeyID: "revoker/a",
            origin: URL(string: "https://example.test/v1/")!
        )
        XCTAssertEqual(encoded.feed.absoluteString, "https://example.test/v1/native-mtp-revocations.revoker%2Fa.json")
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.feedURLs(
            pinnedSignerKeyID: "revoker-a",
            origin: URL(string: "http://coordinator.malibu.tech/v1/")!
        )) {
            XCTAssertEqual($0 as? NativeMTPRevocationFeedError, .invalidOrigin)
        }
    }

    func testNetworkFirstRejectsRedirectStatusAndOversizedResponses() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let now = Self.date("2026-09-28T12:00:00Z")

        await XCTAssertThrowsNativeMTPRevocationError(.missingFeed) {
            try await NativeMTPRevocationFeedManager.loadNetworkFirst(
                pinnedSignerKeyID: "revoker-a",
                verifier: Self.verifier(signer: signer),
                store: MemoryRevocationStore(),
                origin: URL(string: "https://example.test/v1/")!,
                fetcher: { _, _ in NativeMTPRevocationFetchResponse(statusCode: 302, body: Data(), redirected: true) },
                now: now
            )
        }
        await XCTAssertThrowsNativeMTPRevocationError(.missingFeed) {
            try await NativeMTPRevocationFeedManager.loadNetworkFirst(
                pinnedSignerKeyID: "revoker-a",
                verifier: Self.verifier(signer: signer),
                store: MemoryRevocationStore(),
                origin: URL(string: "https://example.test/v1/")!,
                fetcher: { _, _ in NativeMTPRevocationFetchResponse(statusCode: 503, body: Data()) },
                now: now
            )
        }
        await XCTAssertThrowsNativeMTPRevocationError(.payloadTooLarge("network")) {
            try await NativeMTPRevocationFeedManager.loadNetworkFirst(
                pinnedSignerKeyID: "revoker-a",
                verifier: Self.verifier(signer: signer),
                store: MemoryRevocationStore(),
                origin: URL(string: "https://example.test/v1/")!,
                fetcher: { _, _ in
                    NativeMTPRevocationFetchResponse(
                        statusCode: 200,
                        body: Data(repeating: 0x7b, count: NativeMTPRevocationFeed.maxFeedBytes + 1)
                    )
                },
                now: now
            )
        }
    }

    func testNetworkFirstAcceptsFreshNetworkAndFallsBackToCurrentCacheOnTransportFailure() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let store = MemoryRevocationStore()
        let now = Self.date("2026-09-28T12:00:00Z")
        let tuple = Self.digest("01")
        let feed = try Self.feedData(generation: 1, signerKeyID: "revoker-a", tuples: [tuple], now: now)
        let signature = Self.signature(for: feed, signer: signer, keyID: "revoker-a")
        let networkState = try await NativeMTPRevocationFeedManager.loadNetworkFirst(
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: store,
            origin: URL(string: "https://example.test/v1/")!,
            fetcher: { url, _ in
                if url.lastPathComponent.hasSuffix(".json.sig") {
                    return NativeMTPRevocationFetchResponse(statusCode: 200, body: signature)
                }
                return NativeMTPRevocationFetchResponse(statusCode: 200, body: feed)
            },
            now: now
        )

        XCTAssertEqual(networkState.source, .network)
        XCTAssertTrue(networkState.isRevoked(tupleSHA256: tuple))

        let cachedState = try await NativeMTPRevocationFeedManager.loadNetworkFirst(
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
            store: store,
            origin: URL(string: "https://example.test/v1/")!,
            fetcher: { _, _ in throw NativeMTPRevocationFeedError.transportFailed("offline") },
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(cachedState.source, .cache)
        XCTAssertTrue(cachedState.isRevoked(tupleSHA256: tuple))
    }

    func testNetworkFirstFailsClosedWhenNoCurrentAuthenticatedStateExists() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let now = Self.date("2026-09-28T12:00:00Z")

        await XCTAssertThrowsNativeMTPRevocationError(.missingFeed) {
            try await NativeMTPRevocationFeedManager.loadNetworkFirst(
                pinnedSignerKeyID: "revoker-a",
                verifier: Self.verifier(signer: signer),
                store: MemoryRevocationStore(),
                origin: URL(string: "https://example.test/v1/")!,
                fetcher: { _, _ in throw NativeMTPRevocationFeedError.transportFailed("offline") },
                now: now
            )
        }
    }

    func testRefreshNotifiesWhenCurrentTupleBecomesRevoked() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let store = MemoryRevocationStore()
        let now = Self.date("2026-09-28T12:00:00Z")
        let tuple = Self.digest("01")
        let initial = try Self.feedData(generation: 1, signerKeyID: "revoker-a", tuples: [], now: now)
        _ = try Self.accept(initial, signer: signer, store: store, now: now)
        let revoked = try Self.feedData(generation: 2, signerKeyID: "revoker-a", tuples: [tuple], now: now.addingTimeInterval(60))
        let revokedSignature = Self.signature(for: revoked, signer: signer, keyID: "revoker-a")
        let flag = AsyncFlag()

        let state = try await NativeMTPRevocationFeedManager.refreshOnce(
            pinnedSignerKeyID: "revoker-a",
            tupleSHA256: tuple,
            verifier: Self.verifier(signer: signer),
            store: store,
            origin: URL(string: "https://example.test/v1/")!,
            fetcher: { url, _ in
                if url.lastPathComponent.hasSuffix(".json.sig") {
                    return NativeMTPRevocationFetchResponse(statusCode: 200, body: revokedSignature)
                }
                return NativeMTPRevocationFetchResponse(statusCode: 200, body: revoked)
            },
            now: now.addingTimeInterval(60)
        ) { _ in
            await flag.mark()
        }

        XCTAssertEqual(state.feed.generation, 2)
        XCTAssertTrue(state.isRevoked(tupleSHA256: tuple))
        let wasNotified = await flag.value
        XCTAssertTrue(wasNotified)
    }

    func testPollingIntervalIsCappedAtFifteenMinutes() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let probe = SleepProbe()

        await NativeMTPRevocationFeedManager.pollWhileActive(
            pinnedSignerKeyID: "revoker-a",
            tupleSHA256: Self.digest("01"),
            verifier: Self.verifier(signer: signer),
            store: MemoryRevocationStore(),
            origin: URL(string: "https://example.test/v1/")!,
            fetcher: { _, _ in throw NativeMTPRevocationFeedError.transportFailed("offline") },
            intervalSeconds: 3_600,
            sleeper: { nanoseconds in
                await probe.record(nanoseconds)
                throw CancellationError()
            },
            now: { Self.date("2026-09-28T12:00:00Z") },
            onRevoked: { _ in }
        )

        let sleepValues = await probe.values
        XCTAssertEqual(sleepValues, [UInt64(15 * 60 * 1_000_000_000)])
    }

    func testPollingIntervalIsCappedByCurrentFeedExpiryBeforeFifteenMinutes() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let probe = SleepProbe()
        let now = Self.date("2026-09-28T12:00:00Z")

        await NativeMTPRevocationFeedManager.pollWhileActive(
            pinnedSignerKeyID: "revoker-a",
            tupleSHA256: Self.digest("01"),
            verifier: Self.verifier(signer: signer),
            store: MemoryRevocationStore(),
            origin: URL(string: "https://example.test/v1/")!,
            fetcher: { _, _ in throw NativeMTPRevocationFeedError.transportFailed("offline") },
            intervalSeconds: 15 * 60,
            sleeper: { nanoseconds in
                await probe.record(nanoseconds)
                throw CancellationError()
            },
            now: { now },
            initialExpiresAt: now.addingTimeInterval(5 * 60),
            onRevoked: { _ in },
            onUnavailable: {}
        )

        let sleepValues = await probe.values
        XCTAssertEqual(sleepValues, [UInt64(5 * 60 * 1_000_000_000)])
    }

    func testPollingFailsClosedImmediatelyWhenCurrentFeedIsExpired() async throws {
        let signer = Curve25519.Signing.PrivateKey()
        let probe = SleepProbe()
        let unavailable = AsyncFlag()
        let now = Self.date("2026-09-28T12:00:00Z")

        await NativeMTPRevocationFeedManager.pollWhileActive(
            pinnedSignerKeyID: "revoker-a",
            tupleSHA256: Self.digest("01"),
            verifier: Self.verifier(signer: signer),
            store: MemoryRevocationStore(),
            origin: URL(string: "https://example.test/v1/")!,
            fetcher: { _, _ in throw NativeMTPRevocationFeedError.transportFailed("offline") },
            sleeper: { nanoseconds in await probe.record(nanoseconds) },
            now: { now },
            initialExpiresAt: now,
            onRevoked: { _ in },
            onUnavailable: { await unavailable.mark() }
        )

        let wasUnavailable = await unavailable.value
        let sleepValues = await probe.values
        XCTAssertTrue(wasUnavailable)
        XCTAssertEqual(sleepValues, [])
    }

    private static func accept(
        _ feed: Data,
        signer: Curve25519.Signing.PrivateKey,
        store: MemoryRevocationStore,
        now: Date
    ) throws -> NativeMTPRevocationState {
        try NativeMTPRevocationFeedManager.accept(
            feedData: feed,
            signatureData: Self.signature(for: feed, signer: signer, keyID: "revoker-a"),
            pinnedSignerKeyID: "revoker-a",
            verifier: Self.verifier(signer: signer),
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
        try Self.json([
            "schema_version": NativeMTPRevocationFeed.schemaVersion,
            "generation": generation,
            "issued_at": Self.iso8601.string(from: now),
            "expires_at": Self.iso8601.string(from: expiresAt ?? now.addingTimeInterval(3600)),
            "signer_key_id": signerKeyID,
            "revoked_admission_tuple_sha256": tuples.sorted(),
        ])
    }

    private static func signature(for payload: Data, signer: Curve25519.Signing.PrivateKey, keyID: String) -> Data {
        let signature = try! signer.signature(for: payload).base64EncodedString()
        return try! Self.json([
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
        Self.iso8601.date(from: value)!
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private final class MemoryRevocationStore: NativeMTPRevocationStore, @unchecked Sendable {
    var anchor: NativeMTPRevocationAnchor?
    var cacheAnchor: NativeMTPRevocationAnchor?
    var cachedFeed: Data?
    var cachedSignature: Data?
    var priorCacheAnchor: NativeMTPRevocationAnchor?
    var priorCachedFeed: Data?
    var priorCachedSignature: Data?

    func loadAnchor(signerKeyID: String) throws -> NativeMTPRevocationAnchor? {
        anchor
    }

    func loadCachedRecord(signerKeyID: String) throws -> NativeMTPRevocationCacheSnapshot? {
        guard let cachedFeed,
              let cachedSignature,
              let cacheAnchor else {
            return nil
        }
        return NativeMTPRevocationCacheSnapshot(
            feedData: cachedFeed,
            signatureData: cachedSignature,
            anchor: cacheAnchor,
            priorFeedData: priorCachedFeed,
            priorSignatureData: priorCachedSignature,
            priorAnchor: priorCacheAnchor
        )
    }

    func commitAcceptedFeed(
        _ feedData: Data,
        signatureData: Data,
        anchor: NativeMTPRevocationAnchor,
        signerKeyID: String
    ) throws {
        if let cacheAnchor, cacheAnchor.generation < anchor.generation {
            priorCachedFeed = cachedFeed
            priorCachedSignature = cachedSignature
            priorCacheAnchor = cacheAnchor
        } else {
            priorCachedFeed = nil
            priorCachedSignature = nil
            priorCacheAnchor = nil
        }
        cachedFeed = feedData
        cachedSignature = signatureData
        cacheAnchor = anchor
        self.anchor = anchor
    }
}

private func XCTAssertThrowsNativeMTPRevocationError<T>(
    _ expected: NativeMTPRevocationFeedError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as NativeMTPRevocationFeedError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private actor AsyncFlag {
    private var stored = false

    var value: Bool { stored }

    func mark() {
        stored = true
    }
}

private actor SleepProbe {
    private var stored: [UInt64] = []

    var values: [UInt64] { stored }

    func record(_ value: UInt64) {
        stored.append(value)
    }
}
