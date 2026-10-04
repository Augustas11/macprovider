import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

final class PrivacyClassCryptoTests: XCTestCase {
    func testPrivacyGoldenVectorMatchesGo() throws {
        let vector = try privacyFixture()
        let golden = try goldenFixture()
        let envelope = try envelope(from: golden)
        let secret = try sharedSecret(golden: golden, envelope: envelope)
        let derived = try PrivacyResponseSealer.derive(sharedSecret: secret, aad: envelope.aad)
        XCTAssertEqual(derived.noncePrefix.count, 4)
        XCTAssertEqual(keyBase64(derived.key), try string(vector, "response_key"))
        XCTAssertEqual(RelayBlindBase64URL.encode(derived.noncePrefix), try string(vector, "nonce_prefix"))

        let transcript = Data(SHA256.hash(data: Data("macprovider/spec041/relay-blind/transcript/v1".utf8) + envelope.aad))
        let requestKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead/v1".utf8),
            outputByteCount: 32
        )
        XCTAssertNotEqual(keyBase64(derived.key), keyBase64(requestKey))

        let digest = try string(vector, "envelope_digest")
        let kid = try string(vector, "kid")
        let requestID = try string(vector, "request_id")
        let stream = try bool(vector["stream"])
        XCTAssertEqual(stream, envelope.stream)
        var shared = secret.withUnsafeBytes { Data($0) }
        defer { shared.resetBytes(in: 0..<shared.count) }
        XCTAssertEqual(RelayBlindBase64URL.encode(shared), try string(golden, "shared_secret"))
        var sealer = try PrivacyResponseSealer(
            sharedSecret: secret,
            aad: envelope.aad,
            envelopeDigest: digest,
            kid: kid,
            requestID: requestID,
            stream: stream
        )
        let frames = try XCTUnwrap(vector["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 3)
        var previousAAD = Data()
        for (index, item) in frames.enumerated() {
            let plaintextText = try string(item, "plaintext_utf8")
            let final = index == frames.count - 1
            let aad = PrivacyResponseSealer.frameAAD(
                envelopeDigest: digest, kid: kid, requestID: requestID, stream: stream, seq: UInt64(index), final: final
            )
            XCTAssertEqual(aad.hex, try string(item, "aad_hex"))
            XCTAssertNotEqual(aad, previousAAD)
            previousAAD = aad
            var plaintext = Data(plaintextText.utf8)
            let frame = try sealer.seal(&plaintext, final: final)
            XCTAssertEqual(plaintext, Data(repeating: 0, count: plaintextText.utf8.count))
            let expected = try object(item, "frame")
            XCTAssertEqual(try string(frame, "object"), try string(expected, "object"))
            XCTAssertEqual(try string(frame, "version"), try string(expected, "version"))
            XCTAssertEqual(try integer(frame["seq"]), try integer(expected["seq"]))
            XCTAssertEqual(try bool(frame["final"]), try bool(expected["final"]))
            XCTAssertEqual(try string(frame, "ciphertext"), try string(expected, "ciphertext"))
            XCTAssertEqual(sealer.nextSeq, UInt64(index + 1))
            try assertRoundTrip(
                ciphertext: try string(expected, "ciphertext"),
                key: derived.key,
                noncePrefix: derived.noncePrefix,
                aad: aad,
                seq: UInt64(index),
                plaintext: Data(plaintextText.utf8)
            )
        }
        XCTAssertEqual(sealer.nextSeq, 3)
    }

    func testSealerSequenceAndFinal() throws {
        let vector = try privacyFixture()
        let golden = try goldenFixture()
        let envelope = try envelope(from: golden)
        let secret = try sharedSecret(golden: golden, envelope: envelope)
        var sealer = try PrivacyResponseSealer(
            sharedSecret: secret,
            aad: envelope.aad,
            envelopeDigest: try string(vector, "envelope_digest"),
            kid: try string(vector, "kid"),
            requestID: try string(vector, "request_id"),
            stream: try bool(vector["stream"])
        )
        let frames = try XCTUnwrap(vector["frames"] as? [[String: Any]])
        for (index, item) in frames.enumerated() {
            var plaintext = Data((try string(item, "plaintext_utf8")).utf8)
            let count = plaintext.count
            let final = index == frames.count - 1
            let frame = try sealer.seal(&plaintext, final: final)
            XCTAssertEqual(try integer(frame["seq"]), UInt64(index))
            XCTAssertEqual(try bool(frame["final"]), final)
            XCTAssertEqual(sealer.nextSeq, UInt64(index + 1))
            XCTAssertEqual(plaintext.count, count)
            XCTAssertEqual(plaintext, Data(repeating: 0, count: count))
            XCTAssertFalse(try bool(frame["final"]) && index != frames.count - 1)
        }
        XCTAssertEqual(try bool((try object(frames[2], "frame"))["final"]), true)
    }

    func testPostureFramingMatchesGo() throws {
        let vector = try privacyFixture()
        let object = try object(vector, "posture")
        let statement = try posture(object)
        let framed = try statement.framing()
        XCTAssertEqual(framed.hex, try string(vector, "posture_framing_hex"))
        XCTAssertEqual(try statement.framing(), framed)
        XCTAssertEqual(Set(statement.wireObject.keys), Set(object.keys))
        for key in ["version", "privacy_class", "provider_id", "assigned_session", "nonce", "binary_version", "code_cdhash", "team_id", "signing_identifier", "runtime_source", "se_key_backend"] {
            XCTAssertEqual(try string(statement.wireObject, key), try string(object, key), key)
        }
        XCTAssertEqual(try integer(statement.wireObject["sequence"]), try integer(object["sequence"]))
        XCTAssertEqual(try signed(statement.wireObject["issued_at_unix"]), try signed(object["issued_at_unix"]))
        for key in ["hardened_runtime", "library_validation", "get_task_allow", "cs_debugged", "p_traced", "pt_deny_attach_applied", "core_dumps_disabled", "sip_enabled", "diagnostic_env_clear", "kv_disk_tier_disabled"] {
            XCTAssertEqual(try bool(statement.wireObject[key]), try bool(object[key]), key)
        }
        XCTAssertEqual(statement.wireObject["privacy_key_record_digests"] as? [String], object["privacy_key_record_digests"] as? [String])

        let failing = PrivacyPostureStatement(
            version: statement.version,
            privacyClass: statement.privacyClass,
            providerID: statement.providerID,
            assignedSession: statement.assignedSession,
            nonce: statement.nonce,
            sequence: statement.sequence,
            issuedAtUnix: statement.issuedAtUnix,
            binaryVersion: statement.binaryVersion,
            codeCDHash: statement.codeCDHash,
            teamID: statement.teamID,
            signingIdentifier: statement.signingIdentifier,
            hardenedRuntime: statement.hardenedRuntime,
            libraryValidation: statement.libraryValidation,
            getTaskAllow: true,
            csDebugged: true,
            pTraced: statement.pTraced,
            ptDenyAttachApplied: statement.ptDenyAttachApplied,
            coreDumpsDisabled: statement.coreDumpsDisabled,
            sipEnabled: false,
            runtimeSource: statement.runtimeSource,
            diagnosticEnvClear: statement.diagnosticEnvClear,
            kvDiskTierDisabled: statement.kvDiskTierDisabled,
            seKeyBackend: statement.seKeyBackend,
            privacyKeyRecordDigests: statement.privacyKeyRecordDigests
        )
        XCTAssertNotEqual(try failing.framing(), framed)

        let digests = (1...9).map { RelayBlindBase64URL.encode(Data(repeating: UInt8($0), count: 32)) }.sorted()
        XCTAssertThrowsError(try posture(object, digests: Array(digests)).framing())
        XCTAssertThrowsError(try posture(object, digests: [digests[1], digests[0]]).framing())
        XCTAssertNoThrow(try posture(object, digests: []).framing())
    }

    func testKeyAttestationMatchesGo() throws {
        let vector = try privacyFixture()
        let golden = try goldenFixture()
        let attestation = try keyAttestation(try object(vector, "key_attestation"))
        let framed = try attestation.framing()
        XCTAssertEqual(framed.hex, try string(vector, "key_attestation_framing_hex"))
        XCTAssertEqual(try attestation.framing(), framed)
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: try RelayBlindBase64URL.decode(
                try string(try object(golden, "pin"), "identity_public_key"),
                exactCount: 32
            )
        )
        let fixtureSignature = try RelayBlindBase64URL.decode(
            try string(vector, "key_attestation_signature"),
            exactCount: 64
        )
        XCTAssertTrue(publicKey.isValidSignature(fixtureSignature, for: framed))
        let identity = try Curve25519.Signing.PrivateKey(
            rawRepresentation: try RelayBlindBase64URL.decode(try string(golden, "identity_seed"), exactCount: 32)
        )
        let signature = try attestation.sign(identityKey: identity)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: framed))
        var mutated = framed
        mutated[mutated.count - 1] ^= 0x01
        XCTAssertFalse(publicKey.isValidSignature(signature, for: mutated))
        XCTAssertEqual(Set(attestation.wireObject.keys), Set((try object(vector, "key_attestation")).keys))
        XCTAssertEqual(attestation.expiresAtUnix - attestation.notBeforeUnix, PrivacyClassConstants.maxKeyLifetimeSeconds)

        let tooLong = PrivacyKeyAttestation(
            version: attestation.version,
            keyRecordDigest: attestation.keyRecordDigest,
            privacyClass: attestation.privacyClass,
            assurance: attestation.assurance,
            binaryVersion: attestation.binaryVersion,
            codeCDHash: attestation.codeCDHash,
            notBeforeUnix: attestation.notBeforeUnix,
            expiresAtUnix: attestation.notBeforeUnix + PrivacyClassConstants.maxKeyLifetimeSeconds + 1
        )
        XCTAssertThrowsError(try tooLong.framing())
        XCTAssertThrowsError(try tooLong.sign(identityKey: identity))
    }

    func testMemoryOnlyKeyManagerWritesNoAgreementKey() throws {
        let rejected = temporaryStateDirectory()
        XCTAssertThrowsError(try RelayBlindKeyManager(
            directory: rejected,
            models: ["model-a"],
            lifetimeSeconds: 3_601,
            persistAgreementKey: false
        )) { error in
            guard case RelayBlindProviderError.invalidConfiguration = error else {
                return XCTFail("expected invalid configuration, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.appendingPathComponent("encryption.current.x25519").path))

        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try RelayBlindKeyManager(
            directory: root,
            models: ["model-a"],
            lifetimeSeconds: 3_600,
            persistAgreementKey: false,
            now: now
        )
        let record = try first.currentRecord(now: now)
        XCTAssertEqual(record.expiresAtUnix - record.notBeforeUnix, 3_600)
        XCTAssertLessThanOrEqual(record.notBeforeUnix, Int64(now.timeIntervalSince1970))
        XCTAssertGreaterThan(record.expiresAtUnix, Int64(now.timeIntervalSince1970))
        try assertNoAgreementKey(in: root)

        let rotated = try first.rotate(now: now.addingTimeInterval(10))
        XCTAssertNotEqual(rotated.kid, record.kid)
        XCTAssertEqual(rotated.expiresAtUnix - rotated.notBeforeUnix, 3_600)
        try assertNoAgreementKey(in: root)

        let second = try RelayBlindKeyManager(
            directory: root,
            models: ["model-a"],
            lifetimeSeconds: 3_600,
            persistAgreementKey: false,
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(second.identityPublicKeyBase64URL(), first.identityPublicKeyBase64URL())
        XCTAssertNotEqual(try second.currentRecord(now: now.addingTimeInterval(10)).kid, rotated.kid)
        try assertNoAgreementKey(in: root)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains("identity.ed25519"))
    }

    func testOpenInstallsResponseSealerOnlyWhenPrivacyClassIsSet() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = "model-a"
        let session = "assigned-privacy"
        let keys = try RelayBlindKeyManager(directory: root, models: [model], persistAgreementKey: false)
        let runtime = RelayBlindProviderRuntime(
            keyManager: keys,
            journal: try RelayBlindExecutionJournal(directory: root.appendingPathComponent("journal")),
            assignedSession: session
        )
        let privacyMessage = try makeInferenceMessage(keys: keys, model: model, session: session, requestID: "privacy-open")
        let opened = try open(runtime, message: privacyMessage, privacyClass: true)
        var sealer = try XCTUnwrap(opened.responseSealer)
        XCTAssertEqual(sealer.nextSeq, 0)
        var chunk = Data("data: ok\n\n".utf8)
        let frame = try sealer.seal(&chunk, final: false)
        XCTAssertEqual(try integer(frame["seq"]), 0)
        XCTAssertEqual(try bool(frame["final"]), false)
        XCTAssertEqual(chunk, Data(repeating: 0, count: Data("data: ok\n\n".utf8).count))
        XCTAssertEqual(opened.request.model, model)
        try assertNoAgreementKey(in: root)

        let plainMessage = try makeInferenceMessage(keys: keys, model: model, session: session, requestID: "plain-open")
        let plain = try open(runtime, message: plainMessage, privacyClass: false)
        XCTAssertNil(plain.responseSealer)
    }

    private func assertRoundTrip(
        ciphertext: String,
        key: SymmetricKey,
        noncePrefix: Data,
        aad: Data,
        seq: UInt64,
        plaintext: Data
    ) throws {
        let sealed = try RelayBlindBase64URL.decode(ciphertext)
        XCTAssertGreaterThanOrEqual(sealed.count, 16)
        var nonce = Data(noncePrefix)
        nonce.appendUnsigned64(seq)
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: sealed.prefix(sealed.count - 16),
            tag: sealed.suffix(16)
        )
        var opened = try AES.GCM.open(box, using: key, authenticating: aad)
        defer { opened.resetBytes(in: 0..<opened.count) }
        XCTAssertEqual(opened, plaintext)
    }

    private func assertNoAgreementKey(in root: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains("encryption.current.x25519"))
        XCTAssertFalse(names.contains("encryption.current.json"))
        XCTAssertFalse(names.contains { $0.contains("x25519") })
    }

    private func sharedSecret(golden: [String: Any], envelope: RelayBlindEnvelope) throws -> SharedSecret {
        let providerKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: try RelayBlindBase64URL.decode(try string(golden, "provider_x25519_private_key"), exactCount: 32)
        )
        return try providerKey.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.buyerEphemeralPublicKey)
        )
    }

    private func envelope(from golden: [String: Any]) throws -> RelayBlindEnvelope {
        let envelopeObject = try object(golden, "envelope")
        let data = try JSONSerialization.data(withJSONObject: envelopeObject)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let issuedAt = try signed(envelopeObject["issued_at_unix"])
        return try RelayBlindEnvelope.parse(text, nowUnix: issuedAt)
    }

    private func posture(_ object: [String: Any], digests: [String]? = nil) throws -> PrivacyPostureStatement {
        let digestValues: [String]
        if let digests {
            digestValues = digests
        } else {
            digestValues = try XCTUnwrap(object["privacy_key_record_digests"] as? [String])
        }
        return PrivacyPostureStatement(
            version: try string(object, "version"),
            privacyClass: try string(object, "privacy_class"),
            providerID: try string(object, "provider_id"),
            assignedSession: try string(object, "assigned_session"),
            nonce: try string(object, "nonce"),
            sequence: try integer(object["sequence"]),
            issuedAtUnix: try signed(object["issued_at_unix"]),
            binaryVersion: try string(object, "binary_version"),
            codeCDHash: try string(object, "code_cdhash"),
            teamID: try string(object, "team_id"),
            signingIdentifier: try string(object, "signing_identifier"),
            hardenedRuntime: try bool(object["hardened_runtime"]),
            libraryValidation: try bool(object["library_validation"]),
            getTaskAllow: try bool(object["get_task_allow"]),
            csDebugged: try bool(object["cs_debugged"]),
            pTraced: try bool(object["p_traced"]),
            ptDenyAttachApplied: try bool(object["pt_deny_attach_applied"]),
            coreDumpsDisabled: try bool(object["core_dumps_disabled"]),
            sipEnabled: try bool(object["sip_enabled"]),
            runtimeSource: try string(object, "runtime_source"),
            diagnosticEnvClear: try bool(object["diagnostic_env_clear"]),
            kvDiskTierDisabled: try bool(object["kv_disk_tier_disabled"]),
            seKeyBackend: try string(object, "se_key_backend"),
            privacyKeyRecordDigests: digestValues
        )
    }

    private func keyBase64(_ key: SymmetricKey) -> String {
        var bytes = key.withUnsafeBytes { Data($0) }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return RelayBlindBase64URL.encode(bytes)
    }

    private func keyAttestation(_ object: [String: Any]) throws -> PrivacyKeyAttestation {
        PrivacyKeyAttestation(
            version: try string(object, "version"),
            keyRecordDigest: try string(object, "key_record_digest"),
            privacyClass: try string(object, "privacy_class"),
            assurance: try string(object, "assurance"),
            binaryVersion: try string(object, "binary_version"),
            codeCDHash: try string(object, "code_cdhash"),
            notBeforeUnix: try signed(object["not_before_unix"]),
            expiresAtUnix: try signed(object["expires_at_unix"])
        )
    }

    private func makeInferenceMessage(
        keys: RelayBlindKeyManager,
        model: String,
        session: String,
        requestID: String
    ) throws -> [String: Any] {
        let record = try keys.currentRecord()
        let buyer = Curve25519.KeyAgreement.PrivateKey()
        let providerBinding = RelayBlindBase64URL.encode(Data(repeating: 0x41, count: 32))
        let buyerBinding = RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(requestID.utf8))))
        let replay = Data(SHA256.hash(data: Data("replay-\(requestID)".utf8)))
        let inputCap: UInt64 = 5
        let outputCap: UInt64 = 4
        let now = Int64(Date().timeIntervalSince1970)
        let empty = RelayBlindEnvelope(
            model: model,
            providerModel: model,
            stream: false,
            requestID: requestID,
            maxOutputTokens: outputCap,
            inputTokenUpperBound: inputCap,
            reservationTokenCap: inputCap + outputCap,
            providerBinding: providerBinding,
            buyerBinding: buyerBinding,
            keyRecordDigest: record.keyRecordDigest,
            kid: record.kid,
            buyerEphemeralPublicKey: buyer.publicKey.rawRepresentation,
            requestReplayNonce: replay,
            issuedAtUnix: now,
            ciphertext: Data([0]),
            tag: Data(repeating: 0, count: 16)
        )
        let shared = try buyer.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: record.publicKey)
        )
        let transcript = Data(SHA256.hash(data: Data("macprovider/spec041/relay-blind/transcript/v1".utf8) + empty.aad))
        let requestKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead/v1".utf8),
            outputByteCount: 32
        )
        let nonceKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("macprovider/spec041/request/aead-nonce/v1".utf8),
            outputByteCount: 12
        )
        let inner: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "secret prompt"]],
            "max_tokens": outputCap,
            "stream": false,
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys])
        let sealed = try AES.GCM.seal(
            plaintext,
            using: requestKey,
            nonce: try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) }),
            authenticating: empty.aad
        )
        let envelopeObject: [String: Any] = [
            "version": RelayBlindEnvelope.version,
            "mode": RelayBlindEnvelope.mode,
            "endpoint_family": RelayBlindEnvelope.endpointFamily,
            "model": model,
            "provider_model": model,
            "stream": false,
            "request_id": requestID,
            "max_output_tokens": outputCap,
            "input_token_upper_bound": inputCap,
            "reservation_token_cap": inputCap + outputCap,
            "provider_binding": providerBinding,
            "buyer_binding": buyerBinding,
            "key_record_digest": record.keyRecordDigest,
            "kid": record.kid,
            "buyer_ephemeral_public_key": RelayBlindBase64URL.encode(buyer.publicKey.rawRepresentation),
            "request_replay_nonce": RelayBlindBase64URL.encode(replay),
            "issued_at_unix": now,
            "algorithm": RelayBlindKeyRecord.algorithm,
            "ciphertext": RelayBlindBase64URL.encode(sealed.ciphertext),
            "tag": RelayBlindBase64URL.encode(sealed.tag),
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelopeObject, options: [.sortedKeys])
        let body = try XCTUnwrap(String(data: envelopeData, encoding: .utf8))
        let digest: (String) -> String = { value in
            RelayBlindBase64URL.encode(Data(SHA256.hash(data: Data(value.utf8))))
        }
        return [
            "type": "inference_request",
            "request_id": requestID,
            "stream": false,
            "body": body,
            "body_encoding": RelayBlindEnvelope.version,
            "relay_blind_context": [
                "execution_auth_digest": digest("execution-auth-\(requestID)"),
                "envelope_digest": digest(body),
                "provider_binding_digest": digest(providerBinding),
                "buyer_binding_digest": digest(buyerBinding),
                "kid": record.kid,
                "assigned_session": session,
                "request_id": requestID,
                "input_token_upper_bound": inputCap,
                "max_output_tokens": outputCap,
            ],
        ]
    }

    private func open(
        _ runtime: RelayBlindProviderRuntime,
        message: [String: Any],
        privacyClass: Bool
    ) throws -> RelayBlindProviderRuntime.OpenedRequest {
        try runtime.open(
            envelopeBody: try XCTUnwrap(message["body"] as? String),
            outerRequestID: try XCTUnwrap(message["request_id"] as? String),
            outerStream: try XCTUnwrap(message["stream"] as? Bool),
            contextObject: try XCTUnwrap(message["relay_blind_context"] as? [String: Any]),
            expectedAssignedSession: nil,
            privacyClass: privacyClass
        )
    }

    private func privacyFixture() throws -> [String: Any] { try fixture("privacy-response-v1.json") }
    private func goldenFixture() throws -> [String: Any] { try fixture("golden-v1.json") }

    private func fixture(_ name: String) throws -> [String: Any] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = tests.appendingPathComponent("../../../test/fixtures/relay-blind/\(name)").standardizedFileURL
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func temporaryStateDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macprovider-privacy-\(UUID().uuidString)", isDirectory: true)
    }

    private func object(_ value: [String: Any], _ key: String) throws -> [String: Any] {
        try XCTUnwrap(value[key] as? [String: Any])
    }

    private func string(_ value: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(value[key] as? String)
    }

    private func bool(_ value: Any?) throws -> Bool {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        throw PrivacyClassError.invalidMaterial
    }

    private func integer(_ value: Any?) throws -> UInt64 {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int { return UInt64(value) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.uint64Value
        }
        throw PrivacyClassError.invalidMaterial
    }

    private func signed(_ value: Any?) throws -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.int64Value
        }
        throw PrivacyClassError.invalidMaterial
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
