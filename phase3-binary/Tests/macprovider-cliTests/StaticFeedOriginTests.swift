import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// Lab-only static-feed redirect (#1770 rehearsal): loopback only, all three
/// variables or none, never active unless set, and https-only otherwise.
final class StaticFeedOriginTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private func environment(origin: String = "http://127.0.0.1:19302", keyID: String = "lab-test-key", key: String? = nil) -> [String: String] {
        [
            labStaticFeedOriginKey: origin,
            labStaticFeedKeyIDKey: keyID,
            labStaticFeedPublicKeyKey: key ?? self.key,
        ]
    }

    func testValidLoopbackOverrideIsNormalized() throws {
        let override = try XCTUnwrap(readLabStaticFeedOverride(environment(origin: "http://127.0.0.1:19302/")))
        XCTAssertEqual(override.origin.absoluteString, "http://127.0.0.1:19302")
        XCTAssertEqual(override.keyID, "lab-test-key")
        XCTAssertEqual(override.publicKeyBase64, key)
    }

    func testOverrideRejectsRemoteHostsPathsPartialSetsAndBadKeys() {
        XCTAssertNil(readLabStaticFeedOverride([:]))
        for origin in [
            "https://coordinator.malibu.tech",
            "http://localhost:19302",
            "http://127.0.0.1",
            "http://127.0.0.1:19302/v1",
            "ftp://127.0.0.1:19302",
            "http://user@127.0.0.1:19302",
        ] {
            XCTAssertNil(readLabStaticFeedOverride(environment(origin: origin)), origin)
        }
        XCTAssertNil(readLabStaticFeedOverride(environment(key: Data(count: 16).base64EncodedString())))
        XCTAssertNil(readLabStaticFeedOverride(environment(keyID: "bad key")))
        var partial = environment()
        partial.removeValue(forKey: labStaticFeedPublicKeyKey)
        XCTAssertNil(readLabStaticFeedOverride(partial))
    }

    func testOverrideRefusesTrustedProductionKeyIDAndPublicKeyAndAcceptsThrowawayRelease() throws {
        // Production key IDs and public keys from trusted-keys.json must be refused.
        for (prodKeyID, prodPublicKey) in AutotuneStaticInputs.generatedTrustedPublicKeys {
            XCTAssertNil(
                readLabStaticFeedOverride(environment(keyID: prodKeyID)),
                "must refuse production key id \(prodKeyID)"
            )
            XCTAssertNil(
                readLabStaticFeedOverride(environment(keyID: "inkling2-lab-fresh-id", key: prodPublicKey)),
                "must refuse production public key for \(prodKeyID)"
            )
        }

        // A throwaway Ed25519 key is accepted by readLabStaticFeedOverride and
        // verifies a lab-signed Inkling challenge bank while production keys refuse it.
        let throwaway = Curve25519.Signing.PrivateKey()
        let pubBase64 = throwaway.publicKey.rawRepresentation.base64EncodedString()
        let labKeyID = "inkling2-native-mtp-rehearsal-test-v1"
        let override = try XCTUnwrap(readLabStaticFeedOverride(environment(
            origin: "http://127.0.0.1:19302",
            keyID: labKeyID,
            key: pubBase64
        )))
        XCTAssertEqual(override.origin.absoluteString, "http://127.0.0.1:19302")
        XCTAssertEqual(override.keyID, labKeyID)
        XCTAssertEqual(override.publicKeyBase64, pubBase64)

        let tokenDigest = NativeMTPSelfTest.tokenDigest([0])
        let payload = Data("""
        {"entries":[{"artifact_sha256":"75509c7fcd864d109d542676ed14763a2c5c570c731f3c1d1180d0207b6b9b34","challenge_id":"native-mtp-selftest-inkling2-mini-0001","expected_committed_state_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","expected_counters":{"accepted":0,"bonus":0,"committed":0,"rejected":0},"expected_terminal_reason":"length","expected_token_id_sha256":"\(tokenDigest)","expected_token_ids":[0],"fixed_proposal_depth":6,"max_completion_tokens":32,"model_hash":"75509c7fcd864d109d542676ed14763a2c5c570c731f3c1d1180d0207b6b9b34","model_id":"thinkingmachines/inkling-2-mini","mtp_manifest_sha256":"2222222222222222222222222222222222222222222222222222222222222222","prompt_token_ids":[791,6864,315,9822],"tokenizer_sha256":"1111111111111111111111111111111111111111111111111111111111111111"}],"expires_at":"2027-02-15T00:00:00Z","issued_at":"2026-11-28T00:00:00Z","release_id":"published-2026-11-28-inkling2-native-mtp-rehearsal-v1","schema_version":"macprovider.native-mtp-challenge-bank.v1","signer_key_id":"inkling2-native-mtp-rehearsal-test-v1"}
        """.utf8)
        let parsedBank = try NativeMTPSelfTest.parseChallengeBank(payload)
        XCTAssertEqual(parsedBank.entries.count, 1)
        XCTAssertEqual(parsedBank.entries[0].modelID, "thinkingmachines/inkling-2-mini")
        let signature = try throwaway.signature(for: payload)

        // Accepted when verified with the lab override keyring.
        var labKeys = AutotuneStaticInputs.generatedTrustedPublicKeys
        labKeys[override.keyID] = override.publicKeyBase64
        let labPubRaw = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(labKeys[labKeyID])))
        let labPubKey = try Curve25519.Signing.PublicKey(rawRepresentation: labPubRaw)
        XCTAssertTrue(labPubKey.isValidSignature(signature, for: payload))

        // Refused under production trusted-keys.json alone.
        XCTAssertNil(AutotuneStaticInputs.generatedTrustedPublicKeys[labKeyID])
        for prodPubBase64 in AutotuneStaticInputs.generatedTrustedPublicKeys.values {
            let prodRaw = try XCTUnwrap(Data(base64Encoded: prodPubBase64))
            let prodKey = try Curve25519.Signing.PublicKey(rawRepresentation: prodRaw)
            XCTAssertFalse(prodKey.isValidSignature(signature, for: payload))
        }
    }

    func testNoJoinHonorsLabStaticFeedOnlyWhenOverrideIsActive() {
        XCTAssertTrue(ServeCommand.noJoinHonorsLabStaticFeed(
            joiningCoordinator: false,
            servesPoolModelEntry: false,
            modelCatalogKey: "thinkingmachines/inkling-2-mini",
            labStaticFeedActive: true
        ))
        XCTAssertFalse(ServeCommand.noJoinHonorsLabStaticFeed(
            joiningCoordinator: false,
            servesPoolModelEntry: false,
            modelCatalogKey: "thinkingmachines/inkling-2-mini",
            labStaticFeedActive: false
        ))
        XCTAssertFalse(ServeCommand.noJoinHonorsLabStaticFeed(
            joiningCoordinator: true,
            servesPoolModelEntry: false,
            modelCatalogKey: "thinkingmachines/inkling-2-mini",
            labStaticFeedActive: true
        ))
        XCTAssertFalse(ServeCommand.noJoinHonorsLabStaticFeed(
            joiningCoordinator: false,
            servesPoolModelEntry: true,
            modelCatalogKey: "thinkingmachines/inkling-2-mini",
            labStaticFeedActive: true
        ))
        XCTAssertFalse(ServeCommand.noJoinHonorsLabStaticFeed(
            joiningCoordinator: false,
            servesPoolModelEntry: false,
            modelCatalogKey: "",
            labStaticFeedActive: true
        ))
    }

    func testWithoutAnOverrideEveryFeedUsesTheProductionOriginOverHTTPS() throws {
        XCTAssertNil(StaticFeedOrigin.labOverride, "the test process sets no lab override")
        XCTAssertEqual(StaticFeedOrigin.base, StaticFeedOrigin.production)
        XCTAssertEqual(NativeMTPAdmissionFeed.productionBaseURL, StaticFeedOrigin.production)
        XCTAssertEqual(AutotuneStaticInputs.defaultTrustedPublicKeys, AutotuneStaticInputs.generatedTrustedPublicKeys)
        XCTAssertFalse(StaticFeedOrigin.isLabLoopback(URL(string: "http://127.0.0.1:19302")!))
        let urls = try NativeMTPRevocationFeedManager.feedURLs(pinnedSignerKeyID: "streamvc-autotune-static-v4")
        XCTAssertEqual(urls.feed.absoluteString, "https://coordinator.malibu.tech/v1/native-mtp-revocations.streamvc-autotune-static-v4.json")
        XCTAssertThrowsError(try NativeMTPRevocationFeedManager.feedURLs(
            pinnedSignerKeyID: "streamvc-autotune-static-v4",
            origin: URL(string: "http://127.0.0.1:19302/v1/")!
        ))
    }

    func testLabSourceCommitAcceptsOnlyAFullCommitID() {
        XCTAssertNil(ModelRuntime.labNativeMTPSourceCommit([:]))
        XCTAssertNil(ModelRuntime.labNativeMTPSourceCommit(["MACPROVIDER_LAB_NATIVE_MTP_SOURCE_COMMIT": "abc"]))
        XCTAssertNil(ModelRuntime.labNativeMTPSourceCommit(["MACPROVIDER_LAB_NATIVE_MTP_SOURCE_COMMIT": String(repeating: "A", count: 40)]))
        XCTAssertEqual(
            ModelRuntime.labNativeMTPSourceCommit(["MACPROVIDER_LAB_NATIVE_MTP_SOURCE_COMMIT": String(repeating: "a", count: 40)]),
            String(repeating: "a", count: 40)
        )
    }

    func testStaticFeedFetchRetriesRateLimitedResponsesThenGivesUp() async throws {
        let url = URL(string: "https://coordinator.malibu.tech/v1/continuous-batching-policy")!
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        var statuses = [429, 429, 200]
        var sleeps = 0
        let data = try await AutotuneStaticInputs.fetchHonoringRateLimit(
            url,
            load: { _ in (Data("ok".utf8), response(statuses.removeFirst())) },
            sleep: { _ in sleeps += 1 }
        )
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual(sleeps, 2)

        var loads = 0
        do {
            _ = try await AutotuneStaticInputs.fetchHonoringRateLimit(
                url,
                load: { _ in loads += 1; return (Data(), response(429)) },
                sleep: { _ in }
            )
            XCTFail("a feed that stays rate limited must fail")
        } catch {
            XCTAssertEqual(loads, AutotuneStaticInputs.rateLimitRetries + 1)
        }

        var once = 0
        do {
            _ = try await AutotuneStaticInputs.fetchHonoringRateLimit(
                url,
                load: { _ in once += 1; return (Data(), response(503)) },
                sleep: { _ in XCTFail("only a 429 is retried") }
            )
            XCTFail("a 503 must fail")
        } catch {
            XCTAssertEqual(once, 1)
        }
    }

    func testRevocationAnchorStoreIsTheKeychainWithoutALabOverride() {
        XCTAssertNil(StaticFeedOrigin.labOverride)
        XCTAssertTrue(KeychainNativeMTPRevocationStore.live() is KeychainNativeMTPRevocationStore)
    }
}
