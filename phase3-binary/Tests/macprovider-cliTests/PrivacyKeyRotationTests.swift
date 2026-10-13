import CryptoKit
import Foundation
import MacProviderCore
import XCTest
@testable import macprovider_cli

/// SPEC-049 §4.12 / SPEC-049-R031 provider side: the staged identity key, the
/// signed rotation, and promotion only on an accepted result.
final class PrivacyKeyRotationTests: XCTestCase {
    func testRotationFramingMatchesSharedVector() throws {
        let vector = try rotationFixture()
        let posture = try rotationPosture(try XCTUnwrap(vector["posture"] as? [String: Any]))
        XCTAssertEqual(try posture.digest(), vector["posture_digest"] as? String)
        let object = try XCTUnwrap(vector["statement"] as? [String: Any])
        let statement = PrivacyKeyRotationStatement(
            version: try XCTUnwrap(object["version"] as? String),
            privacyClass: try XCTUnwrap(object["privacy_class"] as? String),
            providerID: try XCTUnwrap(object["provider_id"] as? String),
            assignedSession: try XCTUnwrap(object["assigned_session"] as? String),
            nonce: try XCTUnwrap(object["nonce"] as? String),
            issuedAtUnix: try XCTUnwrap((object["issued_at_unix"] as? NSNumber)?.int64Value),
            previousIdentityPublicKey: try XCTUnwrap(object["previous_identity_public_key"] as? String),
            identityPublicKey: try XCTUnwrap(object["identity_public_key"] as? String),
            sePublicKey: try XCTUnwrap(object["se_public_key"] as? String),
            postureDigest: try XCTUnwrap(object["posture_digest"] as? String)
        )
        let framing = try statement.framing()
        XCTAssertEqual(framing.rotationHex, vector["rotation_framing_hex"] as? String)
        XCTAssertEqual(Set(statement.wireObject.keys), Set(object.keys))
        let previous = try Curve25519.Signing.PublicKey(rawRepresentation: RelayBlindBase64URL.decode(statement.previousIdentityPublicKey, exactCount: 32))
        let next = try Curve25519.Signing.PublicKey(rawRepresentation: RelayBlindBase64URL.decode(statement.identityPublicKey, exactCount: 32))
        XCTAssertTrue(previous.isValidSignature(try RelayBlindBase64URL.decode(try XCTUnwrap(vector["previous_identity_signature"] as? String), exactCount: 64), for: framing))
        XCTAssertTrue(next.isValidSignature(try RelayBlindBase64URL.decode(try XCTUnwrap(vector["identity_signature"] as? String), exactCount: 64), for: framing))
    }

    func testNoRotationRequestWithoutStagedKey() throws {
        let root = try makeRotationStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let responder = try makeRotationResponder(root: root, signer: try SELivenessTestSigning.generate()).responder
        XCTAssertNil(responder.rotationRequest())
        XCTAssertNil(try responder.respondToRotation(challenge: rotationChallenge(), assignedSession: "session-1"))
    }

    func testStagedRotationSignsWithAllThreeKeysAndPromotesOnlyWhenAccepted() throws {
        let root = try makeRotationStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let signer = try SELivenessTestSigning.generate()
        let (responder, runtime) = try makeRotationResponder(root: root, signer: signer)
        let original = runtime.identityPublicKeyBase64URL()
        let staged = try RelayBlindKeyManager.stageNextIdentity(directory: root)
        XCTAssertEqual(staged.current, original)
        XCTAssertNotEqual(staged.next, original)
        XCTAssertEqual(try RelayBlindKeyManager.stageNextIdentity(directory: root).next, staged.next, "staging is idempotent")

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(responder.rotationRequest(now: start)?["type"] as? String, "privacy_key_rotation_request")
        XCTAssertNil(responder.rotationRequest(now: start.addingTimeInterval(60)), "requests are spaced by the rotation interval")

        var malformed = rotationChallenge()
        malformed["extra"] = true
        XCTAssertThrowsError(try responder.respondToRotation(challenge: malformed, assignedSession: "session-1"))

        let message = try XCTUnwrap(responder.respondToRotation(challenge: rotationChallenge(), assignedSession: "session-1"))
        XCTAssertEqual(Set(message.keys), ["type", "version", "statement", "posture", "se_signature", "previous_identity_signature", "identity_signature"])
        let encoded = try JSONSerialization.data(withJSONObject: message)
        XCTAssertLessThanOrEqual(encoded.count, PrivacyClassConstants.maxKeyRotationBytes)
        let statementObject = try XCTUnwrap(message["statement"] as? [String: Any])
        XCTAssertEqual(statementObject["previous_identity_public_key"] as? String, original)
        XCTAssertEqual(statementObject["identity_public_key"] as? String, staged.next)
        XCTAssertEqual(statementObject["se_public_key"] as? String, signer.publicKeyRaw.base64EncodedString())
        let posture = try rotationPosture(try XCTUnwrap(message["posture"] as? [String: Any]))
        XCTAssertEqual(posture.nonce, statementObject["nonce"] as? String)
        XCTAssertEqual(try posture.digest(), statementObject["posture_digest"] as? String)
        let statement = PrivacyKeyRotationStatement(
            version: PrivacyClassConstants.keyRotationVersion,
            privacyClass: PrivacyClassConstants.v1,
            providerID: "provider-test",
            assignedSession: "session-1",
            nonce: posture.nonce,
            issuedAtUnix: try XCTUnwrap((statementObject["issued_at_unix"] as? NSNumber)?.int64Value),
            previousIdentityPublicKey: original,
            identityPublicKey: staged.next,
            sePublicKey: signer.publicKeyRaw.base64EncodedString(),
            postureDigest: try posture.digest()
        )
        let framing = try statement.framing()
        var x963 = Data([0x04])
        x963.append(signer.publicKeyRaw)
        let sePublic = try P256.Signing.PublicKey(x963Representation: x963)
        let seSignature = try RelayBlindBase64URL.decode(try XCTUnwrap(message["se_signature"] as? String))
        XCTAssertTrue(sePublic.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: seSignature), for: framing))
        for (key, field) in [(original, "previous_identity_signature"), (staged.next, "identity_signature")] {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: RelayBlindBase64URL.decode(key, exactCount: 32))
            let signature = try RelayBlindBase64URL.decode(try XCTUnwrap(message[field] as? String), exactCount: 64)
            XCTAssertTrue(publicKey.isValidSignature(signature, for: framing), field)
        }

        // A rejection or a result for another nonce keeps the enrolled key.
        XCTAssertFalse(try responder.applyRotationResult(rotationResult(nonce: posture.nonce, status: "rejected", reason: "rotation_stale")))
        XCTAssertEqual(runtime.identityPublicKeyBase64URL(), original)
        _ = try XCTUnwrap(responder.respondToRotation(challenge: rotationChallenge(nonce: Data(repeating: 0x33, count: 32)), assignedSession: "session-1"))
        XCTAssertFalse(try responder.applyRotationResult(rotationResult(nonce: RelayBlindBase64URL.encode(Data(repeating: 0x44, count: 32)), status: "accepted", reason: "accepted")))
        XCTAssertEqual(runtime.identityPublicKeyBase64URL(), original)
        XCTAssertThrowsError(try responder.applyRotationResult(["type": "privacy_key_rotation_result", "version": 1]))

        // The accepted result for the outstanding nonce switches the key on
        // disk and in memory, and new records are signed by the new key.
        let accepted = rotationResult(nonce: RelayBlindBase64URL.encode(Data(repeating: 0x33, count: 32)), status: "accepted", reason: "accepted")
        XCTAssertTrue(try responder.applyRotationResult(accepted))
        XCTAssertEqual(runtime.identityPublicKeyBase64URL(), staged.next)
        XCTAssertNil(try runtime.stagedIdentity())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(RelayBlindKeyManager.stagedIdentityFileName).path))
        let reloaded = try RelayBlindKeyManager(directory: root, models: ["model-a"], persistAgreementKey: false)
        XCTAssertEqual(reloaded.identityPublicKeyBase64URL(), staged.next)
        let records = try XCTUnwrap(responder.privacyKeyRecords())
        let keyRecord = try XCTUnwrap(records.first?["key_record"] as? [String: Any])
        let fingerprint = RelayBlindBase64URL.encode(Data(SHA256.hash(data: try RelayBlindBase64URL.decode(staged.next, exactCount: 32))))
        XCTAssertEqual(keyRecord["identity_fingerprint"] as? String, fingerprint)
        XCTAssertNil(responder.rotationRequest(now: start.addingTimeInterval(3_600)), "nothing left to rotate")
        XCTAssertFalse(try responder.applyRotationResult(accepted), "a replayed result does nothing")
    }

    /// A promotion that replaced the identity file but stopped before removing
    /// the staged copy is repaired on the next start.
    func testInterruptedPromotionIsRepairedAtStart() throws {
        let root = try makeRotationStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try RelayBlindKeyManager(directory: root, models: ["model-a"], persistAgreementKey: false)
        let staged = try RelayBlindKeyManager.stageNextIdentity(directory: root)
        let stagedURL = root.appendingPathComponent(RelayBlindKeyManager.stagedIdentityFileName)
        let identityURL = root.appendingPathComponent(RelayBlindKeyManager.identityFileName)
        try FileManager.default.removeItem(at: identityURL)
        try FileManager.default.copyItem(at: stagedURL, to: identityURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
        let manager = try RelayBlindKeyManager(directory: root, models: ["model-a"], persistAgreementKey: false)
        XCTAssertEqual(manager.identityPublicKeyBase64URL(), staged.next)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertNil(try manager.stagedIdentity())
    }
}

private final class StaticRotationProbe: PrivacyPostureProbe, @unchecked Sendable {
    func observe() -> PrivacyPostureObservation {
        PrivacyPostureObservation(
            hardenedRuntime: true,
            libraryValidation: true,
            getTaskAllow: false,
            csDebugged: false,
            pTraced: false,
            ptDenyAttachApplied: true,
            coreDumpsDisabled: true,
            sipEnabled: true,
            diagnosticEnvClear: true,
            kvDiskTierDisabled: true,
            runtimeSource: PrivacyClassConstants.runtimeSource,
            codeCDHash: String(repeating: "ab", count: 20),
            teamID: "AB12CD34EF",
            signingIdentifier: "live.malibu.provider.cli",
            binaryVersion: CoordinatorClient.binaryVersion,
            failureReasons: []
        )
    }

    func isTracedOrDebugged() -> Bool { false }
}

private func makeRotationResponder(root: URL, signer: SELivenessTestSigning) throws -> (responder: PrivacyPostureResponder, runtime: RelayBlindProviderRuntime) {
    let keys = try RelayBlindKeyManager(directory: root, models: ["model-a"], persistAgreementKey: false)
    let journal = try RelayBlindExecutionJournal(directory: try PrivacyStateDirectory.executionJournal(stateRoot: root))
    let runtime = RelayBlindProviderRuntime(keyManager: keys, journal: journal)
    let responder = PrivacyPostureResponder(
        probe: StaticRotationProbe(),
        seSigner: signer,
        seKeyBackend: PrivacyClassConstants.seBackendFile,
        relayBlindRuntime: runtime,
        providerID: "provider-test",
        binaryVersion: CoordinatorClient.binaryVersion
    )
    return (responder, runtime)
}

private func rotationChallenge(nonce: Data = Data(repeating: 0x22, count: 32)) -> [String: Any] {
    [
        "type": "privacy_key_rotation_challenge",
        "version": 1,
        "nonce": RelayBlindBase64URL.encode(nonce),
        "issued_at_unix": 1_700_000_000,
    ]
}

private func rotationResult(nonce: String, status: String, reason: String) -> [String: Any] {
    ["type": "privacy_key_rotation_result", "version": 1, "nonce": nonce, "status": status, "reason": reason]
}

private func makeRotationStateRoot() throws -> URL {
    var temporaryRoot = NSTemporaryDirectory()
    if temporaryRoot.hasPrefix("/var/") { temporaryRoot = "/private" + temporaryRoot }
    let root = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
        .appendingPathComponent("macprovider-privacy-rotation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root
}

private func rotationFixture() throws -> [String: Any] {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let url = tests.appendingPathComponent("../../../test/fixtures/relay-blind/privacy-key-rotation-v1.json").standardizedFileURL
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func rotationPosture(_ object: [String: Any]) throws -> PrivacyPostureStatement {
    func string(_ key: String) throws -> String { try XCTUnwrap(object[key] as? String) }
    func flag(_ key: String) throws -> Bool { try XCTUnwrap((object[key] as? NSNumber)?.boolValue) }
    return PrivacyPostureStatement(
        version: try string("version"),
        privacyClass: try string("privacy_class"),
        providerID: try string("provider_id"),
        assignedSession: try string("assigned_session"),
        nonce: try string("nonce"),
        sequence: try XCTUnwrap((object["sequence"] as? NSNumber)?.uint64Value),
        issuedAtUnix: try XCTUnwrap((object["issued_at_unix"] as? NSNumber)?.int64Value),
        binaryVersion: try string("binary_version"),
        codeCDHash: try string("code_cdhash"),
        teamID: try string("team_id"),
        signingIdentifier: try string("signing_identifier"),
        hardenedRuntime: try flag("hardened_runtime"),
        libraryValidation: try flag("library_validation"),
        getTaskAllow: try flag("get_task_allow"),
        csDebugged: try flag("cs_debugged"),
        pTraced: try flag("p_traced"),
        ptDenyAttachApplied: try flag("pt_deny_attach_applied"),
        coreDumpsDisabled: try flag("core_dumps_disabled"),
        sipEnabled: try flag("sip_enabled"),
        runtimeSource: try string("runtime_source"),
        diagnosticEnvClear: try flag("diagnostic_env_clear"),
        kvDiskTierDisabled: try flag("kv_disk_tier_disabled"),
        seKeyBackend: try string("se_key_backend"),
        privacyKeyRecordDigests: try XCTUnwrap(object["privacy_key_record_digests"] as? [String])
    )
}

private extension Data {
    var rotationHex: String { map { String(format: "%02x", $0) }.joined() }
}
