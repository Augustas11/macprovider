import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// Golden vectors produced by the coordinator's Go encoders
/// (phase4-coordinator/internal/poolmanifest and internal/trustpool) for the
/// fixed inputs below. Any byte drift here means a creator signature the
/// coordinator would reject.
private enum CreatorGolden {
    static let identity =
        "6d616370726f76696465722f737065633034322f6964656e746974792d636f72652f7631000000146d616e6966657374" +
        "2d617574686f726974792d31000000201111111111111111111111111111111111111111111111111111111111111111"
    static let poolid =
        "kGMiH9jmDvQIYp8z58gc0A"
    static let authentry =
        "6d616370726f76696465722f737065633034322f617574686f726974792d6c6f672d656e7472792f7631000000166b47" +
        "4d6948396a6d447651495970387a35386763304100000000000000010000002000000000000000000000000000000000" +
        "00000000000000000000000000000000000000010000000f706f6c6963792d7369676e65722d31000000202222222222" +
        "222222222222222222222222222222222222222222222222222222000000000000000100000000000000010000000254" +
        "0be3ff000000000000000000000000"
    static let authmsg =
        "6d616370726f76696465722f737065633034322f617574686f726974792d6c6f672d656e7472792d7369672f7631d7e0" +
        "1956039a667bc3938fa6e3cce2bef75eb29baf9a787bcc4e26a721359284"
    static let corev2 =
        "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652f7632000000166b474d6948396a6d4476" +
        "51495970387a353867633041000000000000000100000020000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000100000003000000076d6f64656c2d61000000076d6f64656c2d6200000020706f" +
        "6f6c2f6b474d6948396a6d447651495970387a3538676330412f7a65746100000005312e382e300000000b73656c665f" +
        "7369676e65640000000007656e666f7263650000000000000000000000156465636c617265645f6e6f745f6578656375" +
        "746564000000087374616e646172640000000000000001000000046e6f6e650000000000000000087374616e64617264" +
        "0000000672656a656374000000000068e7780000000000695e1f0000000002000000116c6c616d616370705f6c6f6f70" +
        "6261636b0000000f6f6c6c616d615f6c6f6f706261636b0000000200000018706f6f6c5f61747465737465645f6d656d" +
        "626572732f76310000002d000000010000000c616363745f63726561746f7200000001000000116c6c616d616370705f" +
        "6c6f6f706261636b00000015706f6f6c5f6d6f64656c5f656e74726965732f7631000000ff0000000100000020706f6f" +
        "6c2f6b474d6948396a6d447651495970387a3538676330412f7a657461000000186d616370726f76696465722e676775" +
        "662d66696c652e7631000000403434343434343434343434343434343434343434343434343434343434343434343434" +
        "343434343434343434343434343434343434343434343434343434343400000002000000116c6c616d616370705f6c6f" +
        "6f706261636b0000000f6f6c6c616d615f6c6f6f706261636b0000000a4170616368652d322e30010000000000000064" +
        "000000000000003200000000000000c800000018706f6f6c5f61747465737465645f756e766572696669656400000000" +
        "00008000"
    static let corev2msg =
        "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652d7369672f763242924eaec928f1c60fcf" +
        "4d325d0c31c14da546e571d582e84a3721b1364a51e4"
    static let corev2digest =
        "42924eaec928f1c60fcf4d325d0c31c14da546e571d582e84a3721b1364a51e4"
    static let corev1 =
        "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652f7631000000166b474d6948396a6d4476" +
        "51495970387a353867633041000000000000000100000020000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000100000002000000076d6f64656c2d61000000076d6f64656c2d6200000005312e" +
        "382e300000000b73656c665f7369676e656400000000076f6273657276650000000000000000000000156465636c6172" +
        "65645f6e6f745f6578656375746564000000087374616e646172640000000000000001000000046e6f6e650000000000" +
        "000000087374616e646172640000000672656a656374000000000068e7780000000000695e1f00"
    static let corev1msg =
        "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652d7369672f7631f621eba94e259470d4d9" +
        "ba5ea367ce2c038069ae93d0a6b0c9c41df765c4f764"
    static let snapshot =
        "6d616370726f76696465722f737065633034322f6d616e69666573742d736e617073686f742f7632000000146d616e69" +
        "666573742d617574686f726974792d310000002011111111111111111111111111111111111111111111111111111111" +
        "11111111000000146d616e69666573742d617574686f726974792d310000002055555555555555555555555555555555" +
        "5555555555555555555555555555555500000001000000166b474d6948396a6d447651495970387a3538676330410000" +
        "000000000001000000200000000000000000000000000000000000000000000000000000000000000000000000010000" +
        "000f706f6c6963792d7369676e65722d3100000020222222222222222222222222222222222222222222222222222222" +
        "22222222220000000000000001000000000000000100000002540be3ff00000000000000000000000000000001000000" +
        "146d616e69666573742d617574686f726974792d31000000403333333333333333333333333333333333333333333333" +
        "333333333333333333333333333333333333333333333333333333333333333333333333333333333300000001020000" +
        "00166b474d6948396a6d447651495970387a353867633041000000000000000100000020000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000010000000300000020706f6f6c2f6b474d6948396a" +
        "6d447651495970387a3538676330412f7a657461000000076d6f64656c2d62000000076d6f64656c2d6100000005312e" +
        "382e300000000b73656c665f7369676e65640000000007656e666f7263650000000000000000000000156465636c6172" +
        "65645f6e6f745f6578656375746564000000087374616e646172640000000000000001000000046e6f6e650000000000" +
        "000000087374616e646172640000000672656a656374000000000068e7780000000000695e1f0000000002000000116c" +
        "6c616d616370705f6c6f6f706261636b0000000f6f6c6c616d615f6c6f6f706261636b0000000200000018706f6f6c5f" +
        "61747465737465645f6d656d626572732f76310000002d000000010000000c616363745f63726561746f720000000100" +
        "0000116c6c616d616370705f6c6f6f706261636b00000015706f6f6c5f6d6f64656c5f656e74726965732f7631000000" +
        "ff0000000100000020706f6f6c2f6b474d6948396a6d447651495970387a3538676330412f7a657461000000186d6163" +
        "70726f76696465722e676775662d66696c652e7631000000403434343434343434343434343434343434343434343434" +
        "343434343434343434343434343434343434343434343434343434343434343434343434343434343400000002000000" +
        "116c6c616d616370705f6c6f6f706261636b0000000f6f6c6c616d615f6c6f6f706261636b0000000a4170616368652d" +
        "322e30010000000000000064000000000000003200000000000000c800000018706f6f6c5f61747465737465645f756e" +
        "76657269666965640000000000008000000000010000000f706f6c6963792d7369676e65722d31000000406666666666" +
        "666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666666" +
        "66666666666666666666660000000068e7787b"
    static let emptysnapshot =
        "6d616370726f76696465722f737065633034322f6d616e69666573742d736e617073686f742f7631000000146d616e69" +
        "666573742d617574686f726974792d310000002011111111111111111111111111111111111111111111111111111111" +
        "11111111000000146d616e69666573742d617574686f726974792d310000002055555555555555555555555555555555" +
        "555555555555555555555555555555550000000000000000"
    static let spki =
        "3059301306072a8648ce3d020106082a8648ce3d030107034200041e18532fd4754c02f3041d9c75ceb33b83ffd81ac7" +
        "ce4fe882ccb1c98bc5896ea46c311c4e2ff40dd96a3653e6e45445d32dfe486eced75c7a90c6a18881c0a3"
    static let fingerprint =
        "abdd921c255d0ca2bfe247a75f08ba8faab43506c29b5baecf0a9a11d160c63c"
    static let rootmsg =
        "6d616370726f76696465722f737065633034332f726f6f742d6b65792d726567697374726174696f6e2d7369672f7631" +
        "7b22617070726f76616c5f7265636f72645f6964223a2273656c662d73657276653a616363745f63726561746f72222c" +
        "2263726561746f725f6163636f756e745f6964223a22616363745f63726561746f72222c2263757272656e745f617070" +
        "726f76616c5f76657273696f6e223a2273656c662d73657276652d31222c22656e7669726f6e6d656e74223a2273656c" +
        "665f73657276655f70726976617465222c2267656e657369735f6e6f6e63655f646967657374223a2238383838383838" +
        "383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838383838" +
        "383838383838383838222c22696e74656e6465645f706f6f6c5f646973706c61795f6e616d655f68617368223a223939" +
        "393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939393939" +
        "3939393939393939393939393939222c226c61756e63685f656e7669726f6e6d656e74223a2273656c665f7365727665" +
        "5f70726976617465222c226d616e69666573745f617574686f726974795f726f6f745f6b65795f6964223a226d616e69" +
        "666573742d617574686f726974792d31222c226d616e69666573745f617574686f726974795f726f6f745f7075626c69" +
        "635f6b6579223a2256565656565656565656565656565656565656565656565656565656565656565656565656565656" +
        "5656553d222c226e6f6e6365223a226e6f6e63652d6162635f444546222c226e6f6e63655f657870697279223a223230" +
        "32362d31302d30395431323a31353a30302e3132333435365a222c22707572706f7365223a22726f6f745f6973737565" +
        "725f726567697374726174696f6e222c22726f6f745f6973737565725f6b65795f6964223a22726f6f742d31222c2272" +
        "6f6f745f6973737565725f7075626c69635f6b65795f66696e6765727072696e74223a22616264643932316332353564" +
        "306361326266653234376137356630386261386661616234333530366332396235626165636630613961313164313630" +
        "63363363222c22726f6f745f7369676e61747572655f616c676f726974686d223a2265636473612d703235362d736861" +
        "323536222c22737472756374757265645f6b65795f637573746f64795f646973636c6f737572655f68617368223a2237" +
        "373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737373737" +
        "373737373737373737373737373737227d"
    static let manifestmsg =
        "6d616370726f76696465722f737065633034332f6d616e69666573742d61636365707465642d7369672f76317b226d61" +
        "6e69666573745f636f72655f646967657374223a22343239323465616563393238663163363066636634643332356430" +
        "63333163313464613534366535373164353832653834613337323162313336346135316534222c226d616e6966657374" +
        "5f736e617073686f745f736861323536223a223531373430336464333338353365613532653562666433363831366436" +
        "6339326636363237393831353161616666643263306463653230303537326330323262222c226d616e69666573745f76" +
        "657273696f6e5f646563223a2231222c22706f6f6c5f6964223a226b474d6948396a6d447651495970387a3538676330" +
        "41222c22726f6f745f6973737565725f6b65795f6964223a22726f6f742d31222c22726f6f745f6973737565725f7075" +
        "626c69635f6b65795f66696e6765727072696e74223a2261626464393231633235356430636132626665323437613735" +
        "663038626138666161623433353036633239623562616563663061396131316431363063363363227d"
}

final class CreatorPoolSigningTests: XCTestCase {
    private func rep(_ byte: UInt8, _ n: Int) -> Data { Data(repeating: byte, count: n) }

    private func hex(_ data: Data) -> String { PoolBytes.hex(data) }

    private var identity: PoolIdentityCore {
        PoolIdentityCore(rootIssuerKeyID: "manifest-authority-1", genesisNonce: rep(0x11, 32))
    }

    private func genesisEntry(poolID: String) -> PoolAuthorityLogEntry {
        PoolAuthorityLogEntry(
            poolID: poolID, signerSetVersion: 1, prevAuthorityLogEntryHash: rep(0, 32),
            keys: [PoolSignerKey(keyID: "policy-signer-1", publicKey: rep(0x22, 32))],
            threshold: 1, notBeforeUnix: 1, expiresAtUnix: 9_999_999_999, revokesVersions: [],
            authorizingSignerSetVersion: 0,
            signatures: [PoolSignature(keyID: "manifest-authority-1", sig: rep(0x33, 64))]
        )
    }

    private func v2Core(poolID: String) throws -> PoolPolicyCore {
        let entry = PoolModelEntry(
            poolModelID: "pool/\(poolID)/zeta", artifactHashAlgorithm: "macprovider.gguf-file.v1",
            artifactHash: hex(rep(0x44, 32)), allowedRuntimeSources: ["llamacpp_loopback", "ollama_loopback"],
            license: "Apache-2.0", paidServingAttested: true,
            pricing: PoolModelPricing(promptRatePerMtok: 100, promptCacheHitRatePerMtok: 50, completionRatePerMtok: 200),
            disclosureClass: "pool_attested_unverified", maxContextTokens: 32768
        )
        return PoolPolicyCore(
            poolID: poolID, manifestVersion: 1, prevManifestCoreHash: rep(0, 32), signerSetVersion: 1,
            modelAllowlist: ["pool/\(poolID)/zeta", "model-b", "model-a"], minBinaryVersion: "1.8.0",
            minAttestationTier: "self_signed", requireEncryptedLeg: false, settlementMode: "enforce",
            revenueSplitBps: 0, splitExecutionStatus: "declared_not_executed", retentionPolicyID: "standard",
            minEligibleMembers: 1, privacyMode: "none", relayBlindCapable: false, receiptContract: "",
            metadataVisible: "standard", downgradePolicy: "reject", stickyRoutingAllowed: false,
            notBeforeUnix: 1_760_000_000, expiresAtUnix: 1_767_776_000, encoding: 2,
            runtimeAllowlist: ["llamacpp_loopback", "ollama_loopback"],
            extensions: [
                PoolPolicyExtension(id: PoolExtensions.attestedMembersV1, body: try PoolExtensions.encodeAttestedMembers([
                    PoolAttestedMember(providerAccountID: "acct_creator", runtimeClasses: ["llamacpp_loopback"]),
                ])),
                PoolPolicyExtension(id: PoolExtensions.modelEntriesV1, body: try PoolExtensions.encodeModelEntries([entry])),
            ]
        )
    }

    func testIdentityCoreAndPoolIDMatchGo() throws {
        XCTAssertEqual(hex(try identity.canonicalBytes()), CreatorGolden.identity)
        XCTAssertEqual(try identity.poolID(), CreatorGolden.poolid)
    }

    func testAuthorityLogEntryMatchesGo() throws {
        let entry = genesisEntry(poolID: CreatorGolden.poolid)
        XCTAssertEqual(hex(try entry.canonicalContentBytes()), CreatorGolden.authentry)
        XCTAssertEqual(hex(try entry.signingMessage()), CreatorGolden.authmsg)
    }

    func testPolicyCoresMatchGo() throws {
        let core = try v2Core(poolID: CreatorGolden.poolid)
        XCTAssertEqual(hex(try core.canonicalBytes()), CreatorGolden.corev2)
        XCTAssertEqual(hex(try core.signingMessage()), CreatorGolden.corev2msg)
        XCTAssertEqual(hex(try core.manifestCoreDigest()), CreatorGolden.corev2digest)

        var v1 = core
        v1.encoding = 1
        v1.runtimeAllowlist = []
        v1.extensions = []
        v1.modelAllowlist = ["model-b", "model-a"]
        v1.settlementMode = "observe"
        XCTAssertEqual(hex(try v1.canonicalBytes()), CreatorGolden.corev1)
        XCTAssertEqual(hex(try v1.signingMessage()), CreatorGolden.corev1msg)
    }

    func testManifestSnapshotsMatchGo() throws {
        let poolID = CreatorGolden.poolid
        let snapshot = PoolManifestSnapshot(
            rootIssuerKeyID: "manifest-authority-1", genesisNonce: rep(0x11, 32),
            rootIssuerKey: PoolSignerKey(keyID: "manifest-authority-1", publicKey: rep(0x55, 32)),
            authorityLog: [genesisEntry(poolID: poolID)],
            policies: [PoolAcceptedPolicy(core: try v2Core(poolID: poolID), signatures: [PoolSignature(keyID: "policy-signer-1", sig: rep(0x66, 64))], acceptedAtUnix: 1_760_000_123)]
        )
        XCTAssertEqual(hex(try snapshot.canonicalBytes()), CreatorGolden.snapshot)
        var empty = snapshot
        empty.authorityLog = []
        empty.policies = []
        XCTAssertEqual(hex(try empty.canonicalBytes()), CreatorGolden.emptysnapshot)

        let digest = hex(try snapshot.policies[0].core.manifestCoreDigest())
        let msg = try CreatorRootSigning.manifestAcceptanceMessage(
            poolID: poolID, manifestVersion: 1, manifestCoreDigestHex: digest,
            manifestSnapshot: try snapshot.canonicalBytes(), rootIssuerKeyID: "root-1",
            rootFingerprint: CreatorGolden.fingerprint
        )
        XCTAssertEqual(hex(msg), CreatorGolden.manifestmsg)
    }

    func testRootFingerprintAndRegistrationMessageMatchGo() throws {
        let spki = try XCTUnwrap(PoolBytes.fromHex(CreatorGolden.spki))
        XCTAssertEqual(CreatorRootSigning.fingerprint(spkiDER: spki), CreatorGolden.fingerprint)
        // CryptoKit's derRepresentation is the same SPKI encoding Go marshals.
        let key = try P256.Signing.PrivateKey(rawRepresentation: rep(0x07, 32))
        XCTAssertEqual(hex(key.publicKey.derRepresentation), CreatorGolden.spki)

        let msg = try CreatorRootSigning.rootRegistrationMessage([
            "approval_record_id": "self-serve:acct_creator",
            "creator_account_id": "acct_creator",
            "current_approval_version": "self-serve-1",
            "environment": "self_serve_private",
            "genesis_nonce_digest": hex(rep(0x88, 32)),
            "intended_pool_display_name_hash": hex(rep(0x99, 32)),
            "launch_environment": "self_serve_private",
            "nonce": "nonce-abc_DEF",
            "nonce_expiry": "2026-10-09T12:15:00.123456Z",
            "purpose": "root_issuer_registration",
            "root_issuer_key_id": "root-1",
            "root_issuer_public_key_fingerprint": CreatorGolden.fingerprint,
            "root_signature_algorithm": "ecdsa-p256-sha256",
            "manifest_authority_root_key_id": "manifest-authority-1",
            "manifest_authority_root_public_key": rep(0x55, 32).base64EncodedString(),
            "structured_key_custody_disclosure_hash": hex(rep(0x77, 32)),
        ])
        XCTAssertEqual(hex(msg), CreatorGolden.rootmsg)

        let signature = try CreatorRootSigning.signP256(key, msg)
        let der = try XCTUnwrap(Data(base64Encoded: signature))
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: der)
        XCTAssertTrue(key.publicKey.isValidSignature(parsed, for: msg))
    }

    func testPolicyCoreRejectsNonCanonicalInputs() throws {
        var core = try v2Core(poolID: CreatorGolden.poolid)
        core.runtimeAllowlist = ["ollama_loopback", "llamacpp_loopback"]
        XCTAssertThrowsError(try core.canonicalBytes())
        core = try v2Core(poolID: CreatorGolden.poolid)
        core.extensions.reverse()
        XCTAssertThrowsError(try core.canonicalBytes())
        core = try v2Core(poolID: CreatorGolden.poolid)
        core.modelAllowlist.append("model-a")
        XCTAssertThrowsError(try core.canonicalBytes())
        core = try v2Core(poolID: CreatorGolden.poolid)
        core.prevManifestCoreHash = Data(count: 31)
        XCTAssertThrowsError(try core.canonicalBytes())
    }
}
